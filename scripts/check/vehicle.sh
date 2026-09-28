#!/usr/bin/env bash
# vehicle.sh - hardware bring-up check for the golf cart. No ROS, no colcon,
# no sourcing of anything in this repo: it is deliberately self-contained so it
# can be scp'd to a bare machine and run before the workspace is built.
#
# Checks, in order:
#   ssh       pubkey login to the orin (every remote check rides on this)
#   velodyne  VLP-32C reachable + actually emitting UDP packets
#   seyond    Falcon reachable + actually emitting UDP packets
#   zedx      ZED X on the orin: SDK, daemon, camera enumerated (over ssh)
#   otocam    three oToBrite GMSL cameras present as v4l2 capture devices
#   can       VCU on can0: link state, bitrate, live RX frames
#   gnss      u-blox on a serial port: node, permissions, bytes, NMEA/UBX sync
#
# velodyne and seyond run against THIS host by default. Set LIDAR_HOST=orin
# (must match config/sensors.conf) to route both over ssh instead, the same
# way zedx already does - see docs/roadmaps/8-lidar-on-orin.md.
#
# Usage:
#   scripts/check/vehicle.sh                # everything
#   scripts/check/vehicle.sh velodyne can   # only those
#   scripts/check/vehicle.sh --list
#
# Every setting below is overridable from the environment:
#   VELODYNE_IP=192.168.7.11 scripts/check/vehicle.sh velodyne
#   LIDAR_HOST=orin scripts/check/vehicle.sh velodyne seyond
#
# Exit status: 0 = no failures (warnings allowed), 1 = at least one failure.

# No `pipefail` on purpose. Almost every probe here ends in `... | grep -q`,
# and grep -q exits the moment it matches, which kills the producer with
# SIGPIPE. Under pipefail that 141 becomes the pipeline's status and a
# successful check reads as a failure - intermittently, depending on whether
# the producer had finished writing first.
set -u

# ═══════════════════════════════════════════════════════════════════════════
# CONFIGURATION - edit here, or override per run from the environment
# ═══════════════════════════════════════════════════════════════════════════

# ── Orin (slave host: ZED X, its own recorder) ─────────────────────────────
ORIN_SSH="${ORIN_SSH:-jetson@192.168.125.101}"            # user@addr, key auth only
ORIN_SSH_KEY="${ORIN_SSH_KEY:-$HOME/.ssh/golfcart_orin}"  # empty = ssh defaults
SSH_TIMEOUT="${SSH_TIMEOUT:-5}"                           # seconds for the connect

# Which host the two LiDARs are cabled to: master | orin. Must match
# config/sensors.conf's LIDAR_HOST - this script does not read that file, since
# it is meant to run standalone before the workspace exists. master (default)
# means "this host"; orin routes the velodyne/seyond checks below over ssh,
# the same way the zedx check already does, instead of against this host's own
# interfaces. See docs/roadmaps/8-lidar-on-orin.md.
LIDAR_HOST="${LIDAR_HOST:-master}"

# ── Velodyne VLP-32C ───────────────────────────────────────────────────────
VELODYNE_IP="${VELODYNE_IP:-192.168.7.10}"                # the sensor
VELODYNE_HOST_IP="${VELODYNE_HOST_IP:-192.168.7.1}"       # this host on that link
VELODYNE_PORT="${VELODYNE_PORT:-2368}"                    # UDP data port

# ── Seyond Falcon ──────────────────────────────────────────────────────────
# Two ports, and they are not the same kind of thing. 8010 is the sensor's TCP
# control port, which the driver connects to and which answers whether or not
# anything is streaming. udp_port is where the sensor then sends data - only
# AFTER that handshake, so with no driver running it is silent by design and
# silence there is not a fault. Both are `port:` and `udp_port:` in the sensor
# kit's seyond.param.yaml.
SEYOND_IP="${SEYOND_IP:-172.168.1.10}"
SEYOND_HOST_IP="${SEYOND_HOST_IP:-172.168.1.1}"
SEYOND_PORT="${SEYOND_PORT:-8010}"            # TCP control
SEYOND_UDP_PORT="${SEYOND_UDP_PORT:-8010}"    # UDP data

# How long to listen for LiDAR data, and how much of it makes a pass. A VLP-32C
# at 600 RPM sends ~1500 packets/s of 1206 bytes, the Falcon far more, so these
# thresholds are "a few packets", not "a full sweep".
SNIFF_SECS="${SNIFF_SECS:-2}"
SNIFF_MIN_BYTES="${SNIFF_MIN_BYTES:-2000}"      # when listening on the port with nc
SNIFF_MIN_PACKETS="${SNIFF_MIN_PACKETS:-5}"     # when sniffing with tcpdump/tshark

# ── ZED X, on the orin ─────────────────────────────────────────────────────
ZED_SDK_DIR="${ZED_SDK_DIR:-/usr/local/zed}"
ZED_DAEMON="${ZED_DAEMON:-zed_x_daemon}"                  # systemd service, on the orin
ZED_ENUM_TIMEOUT="${ZED_ENUM_TIMEOUT:-25}"                # ZED_Explorer can be slow

# ── oToBrite GMSL cameras (this host) ──────────────────────────────────────
# by-path nodes, not /dev/videoN: the index a camera lands on moves between
# boots, the capture-vi path does not. These are the three the sensor kit's
# camera_{right,rear,left}.yaml name.
OTOCAM_DEVICES=(
    "/dev/v4l/by-path/platform-tegra-capture-vi-video-index0:right"
    "/dev/v4l/by-path/platform-tegra-capture-vi-video-index10:rear"
    "/dev/v4l/by-path/platform-tegra-capture-vi-video-index12:left"
)
OTOCAM_STREAM_TEST="${OTOCAM_STREAM_TEST:-0}"             # 1 = also grab one frame

# ── VCU on CAN ─────────────────────────────────────────────────────────────
CAN_IFACE="${CAN_IFACE:-can0}"
CAN_BITRATE="${CAN_BITRATE:-500000}"
CAN_SAMPLE_SECS="${CAN_SAMPLE_SECS:-2}"
# The VCU is AT THE VENDOR FOR REPAIR. With this at 0, a missing or silent bus
# is reported as a warning rather than a failure, so a cart with no VCU in it
# still exits 0 on the checks that do apply. Set to 1 when the unit is back.
VCU_EXPECTED="${VCU_EXPECTED:-0}"

# ── u-blox GNSS ────────────────────────────────────────────────────────────
GNSS_DEV="${GNSS_DEV:-/dev/ttyUSB0}"
GNSS_BAUD="${GNSS_BAUD:-38400}"
GNSS_READ_SECS="${GNSS_READ_SECS:-3}"
# Which machine the receiver is cabled to: local | orin. It moved to the orin
# once the oToCam overlay took the Advantech's USB ports, so set this to orin
# if this host is not the one holding the receiver.
GNSS_HOST="${GNSS_HOST:-local}"

# ═══════════════════════════════════════════════════════════════════════════
# Plumbing
# ═══════════════════════════════════════════════════════════════════════════

if [ -t 1 ]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    CYAN=$'\033[0;36m'; DIM=$'\033[2m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; DIM=''; BOLD=''; NC=''
fi

passes=0; warns=0; fails=0; skips=0

ok()   { printf '  %s[ OK ]%s   %s\n' "$GREEN"  "$NC" "$1"; passes=$((passes+1)); }
warn() { printf '  %s[WARN]%s   %s\n' "$YELLOW" "$NC" "$1"; warns=$((warns+1)); }
fail() { printf '  %s[FAIL]%s   %s\n' "$RED"    "$NC" "$1"; fails=$((fails+1)); }
skip() { printf '  %s[SKIP]%s   %s\n' "$DIM"    "$NC" "$1"; skips=$((skips+1)); }
info() { printf '           %s%s%s\n' "$DIM" "$1" "$NC"; }
section() { printf '\n%s%s-- %s --%s\n' "$CYAN" "$BOLD" "$1" "$NC"; }

have() { command -v "$1" >/dev/null 2>&1; }

# Report a missing or silent device as fail or warn depending on whether it is
# expected to be there at all. Exists for the VCU while it is at the vendor.
verdict() { # verdict <expected 0|1> <message> [note when not expected]
    if [ "$1" = "1" ]; then
        fail "$2"
    else
        warn "$2"
        [ -n "${3:-}" ] && info "$3"
    fi
}

# BatchMode + PasswordAuthentication=no: a password prompt is a failure, not a
# question. Same constraint the systemd units run under - they carry no ssh
# agent - so a key that only works by hand fails here too.
ssh_opts=(-o BatchMode=yes -o PasswordAuthentication=no
          -o StrictHostKeyChecking=accept-new -o ConnectTimeout="${SSH_TIMEOUT}")
[ -n "$ORIN_SSH_KEY" ] && [ -f "$ORIN_SSH_KEY" ] && ssh_opts+=(-i "$ORIN_SSH_KEY")

orin_reachable=unknown   # set by check_ssh; the remote checks refuse without it

orin_sh() { ssh "${ssh_opts[@]}" "$ORIN_SSH" "$@"; }

# When LIDAR_HOST=orin the two LiDARs are cabled to the orin instead of this
# host, so check_velodyne/check_seyond below run there over ssh - the same
# routing the zedx check already uses - rather than against this host's own
# interfaces. Empty when LIDAR_HOST=master (the default): every "${lidar_remote[@]}"
# prefix below then vanishes and the command runs locally, unchanged from
# before LIDAR_HOST existed.
lidar_remote=()
[ "$LIDAR_HOST" = orin ] && lidar_remote=(ssh "${ssh_opts[@]}" "$ORIN_SSH")

# Like have(), but checks the routed host - a local `command -v` says nothing
# about what the orin has installed when LIDAR_HOST=orin.
have_remote() {
    if [ "${#lidar_remote[@]}" -eq 0 ]; then
        have "$1"
    else
        "${lidar_remote[@]}" command -v "$1" >/dev/null 2>&1
    fi
}

# Interface carrying a given host address, e.g. 192.168.7.1 -> enP5p3s0.
# Routed by lidar_remote: see above.
iface_for_ip() {
    "${lidar_remote[@]}" ip -4 -o addr show 2>/dev/null | awk -v want="$1" '
        { split($4, a, "/"); if (a[1] == want) { print $2; exit } }'
}

# Is there UDP data on a port? Three routes, in this order:
#
#   1. nc, listening on the port itself. No privileges, no setup, and it is the
#      normal case for this script: it runs before the stack, so nothing holds
#      the port. Measures BYTES.
#   2. tshark/dumpcap - rootless once the user is in the wireshark group.
#   3. tcpdump - rootless once it carries cap_net_raw.
#
# 2 and 3 only matter when a driver already holds the port, and they sniff the
# wire instead of binding, so they also see packets addressed elsewhere.
# Prints "<metric> <count> <method>": metric is BYTES, PKTS, NOPERM or NOTOOL.
count_udp() { # count_udp <port> <seconds> [iface]
    local port="$1" secs="$2" iface="${3:-any}" out n

    # Nothing bound to the port: just listen on it. No privileges involved.
    # Routed by lidar_remote when LIDAR_HOST=orin: nc runs there, piping its
    # output back to this host's own wc over the ssh connection.
    if have_remote nc && port_free_udp "$port"; then
        out=$(timeout "$secs" "${lidar_remote[@]}" nc -u -l -n "$port" 2>/dev/null | wc -c)
        printf 'BYTES %s nc\n' "${out:-0}"
        return 0
    fi

    # Port is taken (or no nc): sniff the wire instead.
    local sniffer
    for sniffer in tshark tcpdump; do
        have_remote "$sniffer" || continue
        case "$sniffer" in
            tshark)  out=$(timeout $((secs + 5)) "${lidar_remote[@]}" tshark -i "$iface" -a "duration:${secs}" \
                             -f "udp port ${port}" 2>&1) ;;
            tcpdump) out=$(timeout $((secs + 3)) "${lidar_remote[@]}" tcpdump -nn -q -i "$iface" -c 200 \
                             "udp port ${port}" 2>&1) ;;
        esac
        if printf '%s' "$out" | grep -qiE 'permission|not permitted|are you root|couldn.t run|no such device'; then
            printf 'NOPERM 0 %s\n' "$sniffer"
            return 1
        fi
        case "$sniffer" in
            # Both tools report their own total; parse that rather than lines.
            tshark)  n=$(printf '%s\n' "$out" | grep -oE '[0-9]+ packets? captured' | tail -1 | awk '{print $1}') ;;
            tcpdump) n=$(printf '%s\n' "$out" | grep -oE '[0-9]+ packets? captured' | tail -1 | awk '{print $1}') ;;
        esac
        printf 'PKTS %s %s\n' "${n:-0}" "$sniffer"
        return 0
    done

    printf 'NOTOOL 0 none\n'; return 1
}

# Is nothing bound to this UDP port? ss is in iproute2, already a dependency
# for `ip`.
#
# `ss -l` is the wrong list here and silently answers "free" when it is not: a
# UDP socket that has received a datagram gets connected to that peer and is
# reported ESTAB, not LISTEN, so a running LiDAR driver never appears in it.
# Match any UDP socket whose local address ends in the port instead.
#
# The test matters because nc cannot detect the collision itself: it sets
# SO_REUSEADDR, so a second bind to a live port succeeds, reads nothing, and
# would report a healthy sensor as silent.
port_free_udp() { # port_free_udp <port>
    have_remote ss || return 0
    ! "${lidar_remote[@]}" ss -uanH 2>/dev/null | awk -v p=":$1\$" '$5 ~ p {found=1} END {exit !found}'
}

# Advice printed when a sniffer refused for lack of privileges. Both fixes are
# the distribution's own supported ones - neither needs the script to run as root.
sniffer_permission_help() { # sniffer_permission_help <tool>
    case "$1" in
        tshark)
            info "rootless capture: sudo dpkg-reconfigure wireshark-common   (answer Yes)"
            info "then: sudo usermod -aG wireshark $(id -un) and log in again" ;;
        *)
            info "rootless capture: sudo setcap cap_net_raw,cap_net_admin=eip \$(command -v tcpdump)" ;;
    esac
}

# Can we open a TCP connection to <host> <port>?
tcp_open() { # tcp_open <host> <port> [seconds]
    local host="$1" port="$2" secs="${3:-3}"
    have_remote nc || return 2
    timeout "$secs" "${lidar_remote[@]}" nc -z -w "$secs" "$host" "$port" >/dev/null 2>&1
}

# ═══════════════════════════════════════════════════════════════════════════
# Checks
# ═══════════════════════════════════════════════════════════════════════════

check_deps() {
    section "Dependencies"

    # tool:package:what it is for. Everything here is in Ubuntu main; nothing is
    # built, and nothing is a ROS package.
    local required=(
        "ip:iproute2:host addresses and the CAN link state"
        "ping:iputils-ping:sensor reachability"
        "nc:netcat-openbsd:UDP data and the Seyond TCP control port"
        "ssh:openssh-client:the orin checks"
        "stty:coreutils:serial port setup for the GNSS check"
        "od:coreutils:reading the GNSS byte stream"
    )
    local optional=(
        "v4l2-ctl:v4l-utils:proving a camera node is really a capture device"
        "tshark:tshark:capturing LiDAR packets when a driver already holds the port"
    )

    local missing_pkgs="" entry tool pkg why
    for entry in "${required[@]}"; do
        IFS=: read -r tool pkg why <<<"$entry"
        if have "$tool"; then
            ok "${tool}"
        else
            fail "${tool} missing (${pkg}) - needed for ${why}"
            missing_pkgs="${missing_pkgs} ${pkg}"
        fi
    done
    for entry in "${optional[@]}"; do
        IFS=: read -r tool pkg why <<<"$entry"
        if have "$tool"; then
            ok "${tool}"
        else
            warn "${tool} missing (${pkg}) - optional: ${why}"
            missing_pkgs="${missing_pkgs} ${pkg}"
        fi
    done

    if [ -n "${missing_pkgs// /}" ]; then
        info "sudo apt install$(printf '%s' "$missing_pkgs" | tr ' ' '\n' | sort -u | tr '\n' ' ')"
    fi

    # Capture privileges only matter when a driver already holds the LiDAR port;
    # nc needs none. Report the state so the fix is known before it is needed.
    if have tshark; then
        if id -nG | grep -qw wireshark; then
            ok "$(id -un) is in the wireshark group - rootless capture available"
        else
            warn "$(id -un) is not in the wireshark group - tshark cannot capture without root"
            sniffer_permission_help tshark
        fi
    fi
    if have tcpdump; then
        local caps; caps=$(getcap "$(command -v tcpdump)" 2>/dev/null)
        if printf '%s' "$caps" | grep -q cap_net_raw; then
            ok "tcpdump has cap_net_raw - rootless capture available"
        else
            warn "tcpdump has no cap_net_raw - it cannot capture without root"
            sniffer_permission_help tcpdump
        fi
    fi
}

check_ssh() {
    section "Orin SSH (${ORIN_SSH})"

    if ! have ssh; then fail "ssh not installed"; orin_reachable=no; return; fi

    if [ -n "$ORIN_SSH_KEY" ]; then
        if [ -f "$ORIN_SSH_KEY" ]; then
            local perm; perm=$(stat -c '%a' "$ORIN_SSH_KEY" 2>/dev/null)
            case "$perm" in
                600|400) ok "key ${ORIN_SSH_KEY} (mode ${perm})" ;;
                *)       warn "key ${ORIN_SSH_KEY} is mode ${perm}; ssh refuses anything looser than 600" ;;
            esac
        else
            warn "key ${ORIN_SSH_KEY} does not exist - falling back to ssh's default identities"
            info "ssh-keygen -t ed25519 -f ${ORIN_SSH_KEY} && ssh-copy-id -i ${ORIN_SSH_KEY} ${ORIN_SSH}"
        fi
    fi

    local out rc
    out=$(orin_sh 'echo golfcart-ok; uname -sr' 2>&1); rc=$?
    if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q golfcart-ok; then
        ok "pubkey login works - $(printf '%s' "$out" | tail -1)"
        orin_reachable=yes
    else
        orin_reachable=no
        fail "pubkey login to ${ORIN_SSH} failed (rc=${rc})"
        info "$(printf '%s' "$out" | head -2 | tr '\n' ' ')"
        case "$out" in
            *"Permission denied"*)
                info "key not in the orin's authorized_keys, or the wrong key: ssh-copy-id -i ${ORIN_SSH_KEY} ${ORIN_SSH}" ;;
            *"No route to host"*|*"timed out"*|*"Connection refused"*)
                info "link down, wrong address, or sshd not running - ping ${ORIN_SSH##*@}" ;;
        esac
    fi
}

check_lidar() { # check_lidar <name> <sensor ip> <host ip> <port>
    local name="$1" sip="$2" hip="$3" port="$4"
    section "${name} (${sip})$([ "${#lidar_remote[@]}" -gt 0 ] && echo " on ${ORIN_SSH}")"

    local iface; iface=$(iface_for_ip "$hip")
    if [ -n "$iface" ]; then
        ok "host address ${hip} is up on ${iface}"
    else
        fail "no interface carries ${hip} - the driver binds to it and will hear nothing"
        info "sudo ip addr add ${hip}/24 dev <iface> && sudo ip link set <iface> up"
    fi

    if "${lidar_remote[@]}" ping -c 1 -W 1 "$sip" >/dev/null 2>&1; then
        ok "${sip} answers ping"
    else
        fail "${sip} does not answer ping"
    fi

    # Reachable and silent is the usual failure: the sensor's destination IP
    # still points at whichever host configured it last.
    local res metric count method
    res=$(count_udp "$port" "$SNIFF_SECS" "${iface:-any}")
    read -r metric count method <<<"$res"
    case "$metric" in
        NOPERM)
            warn "cannot measure UDP ${port}: the port is busy and ${method} may not capture as $(id -un)"
            sniffer_permission_help "$method" ;;
        NOTOOL)
            warn "no nc, tshark or tcpdump - cannot check for packets (see the deps check)" ;;
        BYTES)
            if [ "$count" -ge "$SNIFF_MIN_BYTES" ]; then
                ok "${count} bytes of UDP on port ${port} in ${SNIFF_SECS}s (${method})"
            else
                fail "only ${count} bytes on UDP ${port} in ${SNIFF_SECS}s (${method}) - the sensor is quiet"
                info "check the sensor's destination IP is ${hip} and not a broadcast address"
            fi ;;
        PKTS)
            if [ "$count" -ge "$SNIFF_MIN_PACKETS" ]; then
                ok "${count} UDP packets on port ${port} in ${SNIFF_SECS}s (${method})"
            else
                fail "only ${count} packets on UDP ${port} in ${SNIFF_SECS}s (${method}) - the sensor is quiet"
                info "check the sensor's destination IP is ${hip} and not a broadcast address"
            fi ;;
    esac
}

check_velodyne() { check_lidar "Velodyne VLP-32C" "$VELODYNE_IP" "$VELODYNE_HOST_IP" "$VELODYNE_PORT"; }

check_seyond() {
    section "Seyond Falcon (${SEYOND_IP})$([ "${#lidar_remote[@]}" -gt 0 ] && echo " on ${ORIN_SSH}")"

    local iface; iface=$(iface_for_ip "$SEYOND_HOST_IP")
    if [ -n "$iface" ]; then
        ok "host address ${SEYOND_HOST_IP} is up on ${iface}"
    else
        fail "no interface carries ${SEYOND_HOST_IP} - the driver binds to it and will hear nothing"
        info "sudo ip addr add ${SEYOND_HOST_IP}/24 dev <iface> && sudo ip link set <iface> up"
    fi

    if "${lidar_remote[@]}" ping -c 1 -W 1 "$SEYOND_IP" >/dev/null 2>&1; then
        ok "${SEYOND_IP} answers ping"
    else
        fail "${SEYOND_IP} does not answer ping"
    fi

    # The control port is the real liveness test for this sensor: it answers
    # with no driver running, which the data port does not.
    local tcp_ok=0 rc
    tcp_open "$SEYOND_IP" "$SEYOND_PORT" 3; rc=$?
    case "$rc" in
        0) ok "TCP control port ${SEYOND_PORT} open"; tcp_ok=1 ;;
        2) warn "nc not installed - cannot test the TCP control port (see the deps check)" ;;
        *) fail "TCP control port ${SEYOND_PORT} refused - the driver cannot start the stream" ;;
    esac

    # Data. Unlike the Velodyne, an idle sensor here is correct: it sends
    # nothing until the driver's TCP handshake asks it to.
    local res metric count method live=0
    res=$(count_udp "$SEYOND_UDP_PORT" "$SNIFF_SECS" "${iface:-any}")
    read -r metric count method <<<"$res"
    case "$metric" in
        NOPERM)
            warn "cannot measure UDP ${SEYOND_UDP_PORT}: the port is busy and ${method} may not capture as $(id -un)"
            sniffer_permission_help "$method"; return ;;
        NOTOOL)
            warn "no nc, tshark or tcpdump - cannot check for packets (see the deps check)"; return ;;
        BYTES) [ "$count" -ge "$SNIFF_MIN_BYTES" ]   && live=1 ;;
        PKTS)  [ "$count" -ge "$SNIFF_MIN_PACKETS" ] && live=1 ;;
    esac

    if [ "$live" = 1 ]; then
        ok "UDP data on ${SEYOND_UDP_PORT}: ${count} $([ "$metric" = BYTES ] && echo bytes || echo packets) in ${SNIFF_SECS}s (${method}) - the stream is running"
    elif [ "$tcp_ok" = 1 ]; then
        ok "no UDP on ${SEYOND_UDP_PORT}, as expected with no driver running"
        info "the sensor streams only after the driver's TCP handshake; the control port above is the liveness test"
    else
        fail "no UDP on ${SEYOND_UDP_PORT} and no control port - the sensor is not responding at all"
    fi
}

check_zedx() {
    section "ZED X (on ${ORIN_SSH})"

    if [ "$orin_reachable" != yes ]; then
        skip "orin not reachable over ssh - nothing to ask"
        return
    fi

    if orin_sh "test -d '${ZED_SDK_DIR}'" 2>/dev/null; then
        ok "ZED SDK present at ${ZED_SDK_DIR}"
    else
        fail "no ZED SDK at ${ZED_SDK_DIR} on the orin - the ZED packages are build-skipped without it"
        return
    fi

    # The GMSL link is what wedges in practice, and the daemon owns it.
    local state
    state=$(orin_sh "systemctl is-active ${ZED_DAEMON} 2>/dev/null || echo unknown" 2>/dev/null | tr -d '\r')
    case "$state" in
        active)  ok "${ZED_DAEMON} active" ;;
        unknown) warn "${ZED_DAEMON} is not known to systemd on the orin" ;;
        *)       fail "${ZED_DAEMON} is ${state} - no ZED X capture without it"
                 info "sudo service ${ZED_DAEMON} restart; sleep 25" ;;
    esac

    # ZED_Explorer --all enumerates without opening a stream. It goes through
    # the daemon, so a frozen GMSL link shows up here and not at launch time.
    local out
    out=$(orin_sh "timeout ${ZED_ENUM_TIMEOUT} ${ZED_SDK_DIR}/tools/ZED_Explorer --all 2>&1 || true" 2>/dev/null | tr -d '\r')
    if [ -z "$out" ]; then
        warn "ZED_Explorer produced no output (tool missing, or it timed out after ${ZED_ENUM_TIMEOUT}s)"
    elif printf '%s' "$out" | grep -qiE 'FROZEN'; then
        fail "GMSL link frozen: $(printf '%s' "$out" | grep -i FROZEN | head -1)"
        info "sudo service ${ZED_DAEMON} restart; sleep 25"
    elif printf '%s' "$out" | grep -qiE 'ZED ?X|ZEDX|S/N'; then
        ok "camera enumerated: $(printf '%s' "$out" | grep -iE 'ZED ?X|ZEDX|S/N' | head -1 | sed 's/^ *//')"
    else
        fail "no ZED camera enumerated on the orin"
        info "$(printf '%s' "$out" | head -2 | tr '\n' ' ')"
    fi
}

check_otocam() {
    section "oToBrite GMSL cameras (${#OTOCAM_DEVICES[@]} expected)"

    local found=0 entry dev name target
    for entry in "${OTOCAM_DEVICES[@]}"; do
        dev="${entry%%:*}"; name="${entry##*:}"

        if [ ! -e "$dev" ]; then
            fail "${name}: ${dev} missing"
            continue
        fi
        target=$(readlink -f "$dev")
        if [ ! -c "$target" ]; then
            fail "${name}: ${dev} is not a character device"
            continue
        fi
        if [ ! -r "$target" ]; then
            fail "${name}: ${target} is not readable by $(id -un) - add the user to the video group"
            continue
        fi

        # The node existing already means the driver bound; only the capability
        # bit proves it is a capture device, and that needs v4l2-ctl.
        if have v4l2-ctl; then
            local caps; caps=$(v4l2-ctl --device "$target" --all 2>/dev/null)
            if printf '%s' "$caps" | grep -q 'Video Capture'; then
                ok "${name}: ${target} (video capture)"
                found=$((found+1))
            else
                fail "${name}: ${target} exists but reports no Video Capture capability"
                continue
            fi
            if [ "$OTOCAM_STREAM_TEST" = "1" ]; then
                if timeout 8 v4l2-ctl --device "$target" --stream-mmap --stream-count=1 >/dev/null 2>&1; then
                    ok "${name}: captured one frame"
                else
                    fail "${name}: node present but capturing a frame failed - deserializer or GMSL link"
                fi
            fi
        else
            ok "${name}: ${target} present"
            found=$((found+1))
            info "sudo apt install v4l-utils to verify it is really a capture device"
        fi
    done

    if [ "$found" -eq 0 ] && ! ls /dev/video* >/dev/null 2>&1; then
        info "no /dev/video* at all: usually the device tree overlay or the otocam"
        info "modules did not load - see scripts/hardware/otocam/README.md"
    fi
}

check_can() {
    section "VCU on ${CAN_IFACE}"

    if [ "$VCU_EXPECTED" != "1" ]; then
        info "VCU_EXPECTED=0: the unit is away for repair, so problems below are warnings"
    fi

    if [ ! -d "/sys/class/net/${CAN_IFACE}" ]; then
        verdict "$VCU_EXPECTED" "${CAN_IFACE} does not exist" \
                "no CAN controller on this host, or the mttcan modules are not loaded"
        return
    fi
    ok "${CAN_IFACE} exists"

    local operstate; operstate=$(cat "/sys/class/net/${CAN_IFACE}/operstate" 2>/dev/null)
    if [ "$operstate" = up ]; then
        ok "${CAN_IFACE} is up"
    else
        verdict "$VCU_EXPECTED" "${CAN_IFACE} is ${operstate:-unknown}" \
                "sudo ip link set ${CAN_IFACE} up type can bitrate ${CAN_BITRATE}"
        return
    fi

    # Bitrate and controller state come from `ip -details`: it is the only place
    # the CAN-specific fields live.
    local det bitrate canstate
    det=$(ip -details -statistics link show "$CAN_IFACE" 2>/dev/null)
    bitrate=$(printf '%s' "$det" | grep -oE 'bitrate [0-9]+' | head -1 | awk '{print $2}')
    canstate=$(printf '%s' "$det" | grep -oE 'state (ERROR-ACTIVE|ERROR-WARNING|ERROR-PASSIVE|BUS-OFF|STOPPED|SLEEPING)' | head -1 | awk '{print $2}')

    if [ -z "$bitrate" ]; then
        warn "${CAN_IFACE} reports no bitrate - is it a real CAN interface? (vcan has none)"
    elif [ "$bitrate" = "$CAN_BITRATE" ]; then
        ok "bitrate ${bitrate}"
    else
        fail "bitrate ${bitrate}, but the VCU runs at ${CAN_BITRATE} - every frame will be an error"
    fi

    case "$canstate" in
        ERROR-ACTIVE) ok "controller state ERROR-ACTIVE (normal)" ;;
        BUS-OFF)      verdict "$VCU_EXPECTED" "controller is BUS-OFF - wiring, termination, or a bitrate mismatch" ;;
        "")           : ;;
        *)            warn "controller state ${canstate}" ;;
    esac

    # Live traffic, counted straight out of the kernel: no candump, no ROS.
    local rx0 rx1 delta
    rx0=$(cat "/sys/class/net/${CAN_IFACE}/statistics/rx_packets" 2>/dev/null || echo 0)
    sleep "$CAN_SAMPLE_SECS"
    rx1=$(cat "/sys/class/net/${CAN_IFACE}/statistics/rx_packets" 2>/dev/null || echo 0)
    delta=$((rx1 - rx0))
    if [ "$delta" -gt 0 ]; then
        ok "${delta} frames received in ${CAN_SAMPLE_SECS}s - the VCU is talking"
    else
        verdict "$VCU_EXPECTED" "no CAN frames in ${CAN_SAMPLE_SECS}s - the bus is silent"
        if [ "$VCU_EXPECTED" = "1" ]; then
            info "VelocityReport and the control mode both come from these frames, so"
            info "localization has no twist and the vehicle interface cannot engage"
            info "check in this order: VCU powered, CAN-H/CAN-L not swapped, 120 ohm"
            info "termination at both ends, then watch the wire with: candump ${CAN_IFACE}"
        else
            info "expected while the VCU is at the vendor; VelocityReport and the control"
            info "mode both come from these frames, so nothing downstream can work yet"
        fi
    fi
}

# The GNSS probe as one shell snippet, so the same code runs locally or over ssh
# depending on which machine the receiver is cabled to.
gnss_probe_src() {
    cat <<PROBE
dev=${GNSS_DEV}; baud=${GNSS_BAUD}; secs=${GNSS_READ_SECS}
if [ ! -e "\$dev" ]; then
    echo "MISSING \$(ls /dev/ttyUSB* /dev/ttyACM* /dev/ublox-gps 2>/dev/null | tr '\n' ' ')"
    exit 0
fi
if [ ! -r "\$dev" ] || [ ! -w "\$dev" ]; then
    echo "NOPERM \$(stat -c '%U:%G %a' "\$dev")"
    exit 0
fi
stty -F "\$dev" "\$baud" raw -echo 2>/dev/null || echo STTYFAIL
data=\$(timeout "\$secs" head -c 512 "\$dev" 2>/dev/null | od -An -tx1 | tr -d ' \n')
echo "BYTES \$(( \${#data} / 2 )) \$(printf '%s' "\$data" | head -c 64)"
PROBE
}

check_gnss() {
    section "u-blox GNSS (${GNSS_DEV} on ${GNSS_HOST})"

    local out
    if [ "$GNSS_HOST" = orin ]; then
        if [ "$orin_reachable" != yes ]; then skip "orin not reachable over ssh"; return; fi
        out=$(orin_sh "$(gnss_probe_src)" 2>/dev/null | tr -d '\r')
    else
        out=$(bash -c "$(gnss_probe_src)" 2>/dev/null)
        if ! id -nG | grep -qw dialout; then
            warn "$(id -un) is not in the dialout group - access depends on the udev mode instead"
            info "sudo usermod -aG dialout $(id -un), then log in again"
        fi
    fi

    case "$out" in
        MISSING*)
            fail "${GNSS_DEV} does not exist"
            local others="${out#MISSING }"
            if [ -n "${others// /}" ]; then
                info "other serial nodes present: ${others}"
            else
                info "no /dev/ttyUSB* or /dev/ttyACM* either - receiver unplugged, or on the other host (GNSS_HOST=orin)"
            fi
            return ;;
        NOPERM*)
            fail "${GNSS_DEV} is not readable/writable: $(printf '%s' "$out" | cut -d' ' -f2-)"
            return ;;
    esac

    ok "${GNSS_DEV} present and accessible"
    printf '%s' "$out" | grep -q STTYFAIL && \
        warn "stty failed on ${GNSS_DEV} - wrong device type, or held open by another process"

    # Bytes alone prove the cable and the baud rate; the sync pattern proves it
    # is a u-blox and not some other USB-serial adapter. 24 47 = "$G" (NMEA),
    # b5 62 = UBX.
    local nbytes hex
    nbytes=$(printf '%s' "$out" | awk '/^BYTES/ {print $2}')
    hex=$(printf '%s' "$out" | awk '/^BYTES/ {print $3}')
    if [ -z "$nbytes" ] || [ "$nbytes" -eq 0 ]; then
        fail "no data in ${GNSS_READ_SECS}s at ${GNSS_BAUD} baud"
        info "wrong baud (try GNSS_BAUD=9600 or 115200), or the receiver's output is disabled"
        return
    fi

    if printf '%s' "$hex" | grep -q 'b562'; then
        ok "${nbytes} bytes at ${GNSS_BAUD} baud, UBX sync (b5 62) seen"
    elif printf '%s' "$hex" | grep -q '2447'; then
        ok "${nbytes} bytes at ${GNSS_BAUD} baud, NMEA seen"
    else
        warn "${nbytes} bytes at ${GNSS_BAUD} baud, but no NMEA or UBX framing"
        info "first bytes: ${hex} - a baud mismatch produces exactly this"
    fi
}

# ═══════════════════════════════════════════════════════════════════════════
# Dispatch
# ═══════════════════════════════════════════════════════════════════════════

ALL_CHECKS=(deps ssh velodyne seyond zedx otocam can gnss)

usage() {
    cat <<USAGE
usage: ${0##*/} [check ...]

checks: ${ALL_CHECKS[*]}   (default: all of them, in that order)

  deps      the command line tools the checks below need, and capture rights
  ssh       pubkey login to the orin; the remote checks below ride on it
  velodyne  VLP-32C: host address, ping, UDP packets on ${VELODYNE_PORT} (LIDAR_HOST=${LIDAR_HOST})
  seyond    Falcon:  host address, ping, TCP control ${SEYOND_PORT}, UDP data ${SEYOND_UDP_PORT} (LIDAR_HOST=${LIDAR_HOST})
  zedx      ZED X on the orin: SDK, ${ZED_DAEMON}, camera enumerated
  otocam    three oToBrite GMSL capture nodes on this host
  can       VCU on ${CAN_IFACE}: link, bitrate, live frames
  gnss      u-blox on ${GNSS_DEV} (GNSS_HOST=${GNSS_HOST})

Settings are the CONFIGURATION block at the top of this file; each one also
takes an environment override, e.g. VCU_EXPECTED=1 ${0##*/} can
USAGE
}

selected=()
for arg in "$@"; do
    case "$arg" in
        -h|--help) usage; exit 0 ;;
        --list)    printf '%s\n' "${ALL_CHECKS[@]}"; exit 0 ;;
        -*)        printf 'unknown option: %s\n' "$arg" >&2; usage >&2; exit 2 ;;
        *)
            found=0
            for c in "${ALL_CHECKS[@]}"; do [ "$c" = "$arg" ] && found=1; done
            [ "$found" = 1 ] || { printf 'unknown check: %s\n' "$arg" >&2; usage >&2; exit 2; }
            selected+=("$arg") ;;
    esac
done
[ ${#selected[@]} -eq 0 ] && selected=("${ALL_CHECKS[@]}")

# zedx, gnss when the receiver is on the orin, and velodyne/seyond when
# LIDAR_HOST=orin all ride on the ssh login. Run it first even when it was not
# asked for, or they skip for the wrong reason.
needs_ssh=0
for c in "${selected[@]}"; do
    [ "$c" = zedx ] && needs_ssh=1
    [ "$c" = gnss ] && [ "$GNSS_HOST" = orin ] && needs_ssh=1
    { [ "$c" = velodyne ] || [ "$c" = seyond ]; } && [ "$LIDAR_HOST" = orin ] && needs_ssh=1
done
case " ${selected[*]} " in *" ssh "*) needs_ssh=0 ;; esac

printf '%sGolf cart vehicle check%s  %s(%s)%s\n' \
    "$BOLD" "$NC" "$DIM" "$(date '+%Y-%m-%d %H:%M:%S')" "$NC"
[ "$needs_ssh" = 1 ] && check_ssh

for c in "${selected[@]}"; do
    case "$c" in
        deps)     check_deps ;;
        ssh)      check_ssh ;;
        velodyne) check_velodyne ;;
        seyond)   check_seyond ;;
        zedx)     check_zedx ;;
        otocam)   check_otocam ;;
        can)      check_can ;;
        gnss)     check_gnss ;;
    esac
done

printf '\n%s-- summary --%s\n' "$BOLD" "$NC"
printf '  %s%d ok%s  %s%d warn%s  %s%d fail%s  %s%d skip%s\n' \
    "$GREEN" "$passes" "$NC" "$YELLOW" "$warns" "$NC" \
    "$RED" "$fails" "$NC" "$DIM" "$skips" "$NC"

[ "$fails" -gt 0 ] && exit 1
exit 0
