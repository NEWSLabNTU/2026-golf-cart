#!/usr/bin/env bash
# doctor.sh - read-only diagnostic for the golf cart environment.
#
# Reports host identity, the DDS profile actually in effect, kernel buffer
# limits, ros2 daemon state, golfcart-* user units and the bag directory.
#
# It changes nothing: no daemon is stopped, no unit is started, no file written.
# Safe to run anywhere, including a dev laptop with none of this installed.
#
# Exit status:
#   0  everything checked is fine (warnings allowed)
#   1  something is definitely broken
set -uo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "${SCRIPT_DIR}/.." && pwd)

# ── Output helpers ───────────────────────────────────────────────────────────
if [ -t 1 ]; then
    RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
    CYAN=$'\033[0;36m'; BOLD=$'\033[1m'; NC=$'\033[0m'
else
    RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; NC=''
fi

fails=0; warns=0

ok()   { printf '  %s[ OK ]%s   %s\n'  "$GREEN"  "$NC" "$1"; }
warn() { printf '  %s[WARN]%s   %s\n'  "$YELLOW" "$NC" "$1"; warns=$((warns + 1)); }
fail() { printf '  %s[FAIL]%s   %s\n'  "$RED"    "$NC" "$1"; fails=$((fails + 1)); }
info() { printf '           %s\n' "$1"; }
section() { printf '\n%s%s-- %s --%s\n' "$CYAN" "$BOLD" "$1" "$NC"; }

# Human-readable free space of the nearest existing ancestor of a path.
free_space_of() {
    local p="$1"
    while [ -n "$p" ] && [ ! -d "$p" ]; do p=$(dirname "$p"); [ "$p" = "/" ] && break; done
    df -h --output=avail "$p" 2>/dev/null | tail -1 | tr -d ' '
}

printf '%sGolf Cart environment doctor%s  (%s)\n' "$BOLD" "$NC" "$REPO_ROOT"

# ── 1. Host identity and DDS profile ─────────────────────────────────────────
section "Host identity and DDS profile"

# config/host is the current location; the repo-root dotfile is the older one
# and is still honoured by scripts/env.sh, so report whichever is in play.
MARKER="${REPO_ROOT}/config/host"
[ -f "${MARKER}" ] || MARKER="${REPO_ROOT}/.golfcart-host"
MARKER_REL="${MARKER#${REPO_ROOT}/}"
inherited_uri="${CYCLONEDDS_URI:-}"

if [ -f "${REPO_ROOT}/scripts/env.sh" ]; then
    # Resolve exactly the way a shell would, but quietly: this script reports
    # the outcome itself rather than echoing env.sh's banners.
    # shellcheck source=/dev/null
    GOLFCART_ENV_RESOLVE_ONLY=1 GOLFCART_ENV_QUIET=1 source "${REPO_ROOT}/scripts/env.sh"
else
    fail "scripts/env.sh not found — cannot resolve the DDS profile"
    GOLFCART_HOST="${GOLFCART_HOST:-unknown}"
    GOLFCART_DDS_PROFILE_SOURCE="${GOLFCART_DDS_PROFILE_SOURCE:-unknown}"
fi

case "${GOLFCART_DDS_PROFILE_SOURCE:-unknown}" in
    env)
        ok "host role: ${GOLFCART_HOST}  (from \$GOLFCART_DDS_PROFILE)"
        info "an explicit environment variable overrides ${MARKER##*/}"
        ;;
    marker)
        ok "host role: ${GOLFCART_HOST}  (from ${MARKER_REL})"
        ;;
    marker-demoted)
        warn "host role: ${GOLFCART_HOST} (from ${MARKER_REL}); DDS transport demoted to loopback"
        info "the peer did not answer a ping, so the stack stays on 'lo'"
        info "the machine is still ${GOLFCART_HOST}: only the transport changed"
        info "the ${GOLFCART_DDS_DEMOTED_FROM:-master} profile puts every topic on the"
        info "shared 100 Mb/s LAN, which two LiDARs alone saturate — that is what"
        info "takes ssh to the other machine down when it is running solo"
        info "expected when running single-machine; bring the peer up, or force it with:"
        info "    GOLFCART_DDS_PROBE=0"
        info "(not GOLFCART_DDS_PROFILE — it is ignored when it matches ${MARKER_REL})"
        ;;
    fallback)
        warn "no config/host marker — falling back to the loopback profile"
        info "Two-machine operation needs one. On this machine run:"
        info "    echo master > config/host      # or: orin"
        ;;
    invalid-marker)
        fail "${MARKER_REL} names a profile with no config/cyclonedds/<name>.xml"
        info "marker contents: $(tr -d '\n' < "$MARKER" 2>/dev/null)"
        info "available:       $(golfcart_dds_profiles 2>/dev/null | tr '\n' ' ')"
        info "running on the loopback profile instead"
        ;;
    invalid-env)
        fail "\$GOLFCART_DDS_PROFILE names a profile with no matching XML"
        info "available: $(golfcart_dds_profiles 2>/dev/null | tr '\n' ' ')"
        info "running on the loopback profile instead"
        ;;
    *)
        fail "could not resolve the DDS profile"
        ;;
esac

if [ "${GOLFCART_HOST:-}" = "loopback" ] && [ "${GOLFCART_DDS_PROFILE_SOURCE:-}" = "marker" ]; then
    info "loopback is single-machine only; cross-machine topics will not appear"
fi

# Which middleware, and then that middleware's own config. Reported before the
# transport details because it decides which of them even apply: under
# GOLFCART_RMW=zenoh an unset CYCLONEDDS_URI is correct, not a fault, and the
# reverse holds for the ZENOH_* variables.
ok "middleware: ${GOLFCART_RMW:-cyclonedds}  (config/runtime.conf)"

if [ "${GOLFCART_RMW:-cyclonedds}" = "zenoh" ]; then
    if [ "${RMW_IMPLEMENTATION:-}" != "rmw_zenoh_cpp" ]; then
        fail "GOLFCART_RMW=zenoh but RMW_IMPLEMENTATION=${RMW_IMPLEMENTATION:-<unset>}"
    else
        ok "RMW_IMPLEMENTATION -> rmw_zenoh_cpp"
    fi

    # Unset is a legitimate, deliberate answer here: it means the shipped
    # rmw_zenoh defaults, which is exactly right for the loopback role.
    for v in ZENOH_SESSION_CONFIG_URI; do
        path="${!v:-}"   # bash indirect expansion; doctor.sh is #!/usr/bin/env bash
        if [ -z "$path" ]; then
            info "${v} unset — using rmw_zenoh's shipped defaults"
        elif [ -f "$path" ]; then
            ok "${v} -> ${path}"
        else
            fail "${v} points at a missing file: ${path}"
            info "regenerate it:  scripts/zenoh/generate_profiles.sh"
        fi
    done

    # No router runs in this deployment: discovery is multicast, the way
    # CycloneDDS does it with SPDP. What can break is the interface the profile
    # binds — if nothing owns that address, or it carries no MULTICAST flag,
    # every node starts, publishes and discovers nobody, with no error anywhere.
    zaddr=$(sed -n 's|^ *"tcp/\([0-9.]*\):0".*|\1|p' "${ZENOH_SESSION_CONFIG_URI:-/dev/null}" 2>/dev/null | head -1)
    if [ -z "$zaddr" ]; then
        fail "no Zenoh profile for the '${GOLFCART_HOST:-?}' role"
        info "nodes would fall back to rmw_zenoh defaults, which expect a router"
        info "on localhost:7447 that this deployment never starts - so nothing"
        info "would discover anything, silently, on either machine."
        info "config/host is gitignored; on this machine run one of:"
        info "    echo master > config/host"
        info "    echo orin   > config/host"
    else
        ziface=$(ip -o addr show 2>/dev/null | awk -v a="$zaddr" '$4 ~ "^"a"/" {print $2; exit}')
        if [ -z "$ziface" ]; then
            fail "session profile binds ${zaddr}, but no interface has that address"
            info "nodes would start, publish and discover nobody"
        elif ip link show "$ziface" 2>/dev/null | grep -q MULTICAST; then
            ok "discovery: multicast on ${ziface} (${zaddr})"
        else
            fail "${ziface} (${zaddr}) has no MULTICAST flag — discovery cannot work"
            info "enable it:  sudo ip link set ${ziface} multicast on"
        fi
    fi

    if [ -n "$inherited_uri" ]; then
        warn "this shell has CYCLONEDDS_URI set (${inherited_uri}) while on zenoh"
        info "harmless to zenoh, but it will mislead anyone reading the environment"
    fi
else
    # CYCLONEDDS_URI
    uri="${CYCLONEDDS_URI:-}"
    if [ -z "$uri" ]; then
        fail "CYCLONEDDS_URI is not set"
    else
        uri_path="${uri#file://}"
        if [ -f "$uri_path" ]; then
            ok "CYCLONEDDS_URI -> ${uri_path}"
        else
            fail "CYCLONEDDS_URI points at a missing file: ${uri_path}"
        fi
    fi

    if [ -n "$inherited_uri" ] && [ "$inherited_uri" != "${CYCLONEDDS_URI:-}" ]; then
        warn "this shell had a different CYCLONEDDS_URI: ${inherited_uri}"
        info "processes started from it use that one, not the profile above"
    fi

    if [ -n "${RMW_IMPLEMENTATION:-}" ] && [ "${RMW_IMPLEMENTATION}" != "rmw_cyclonedds_cpp" ]; then
        warn "RMW_IMPLEMENTATION=${RMW_IMPLEMENTATION} — the profiles above only apply to CycloneDDS"
    fi
fi

# ── 2. ros2 daemon ───────────────────────────────────────────────────────────
section "ros2 daemon"

daemon_running=unknown
if command -v ros2 >/dev/null 2>&1; then
    # `ros2 daemon status` only queries; it never starts a daemon.
    if timeout 10 ros2 daemon status 2>/dev/null | grep -qi 'is running'; then
        daemon_running=yes
    else
        daemon_running=no
    fi
elif pgrep -f 'ros2cli\.daemon' >/dev/null 2>&1; then
    daemon_running=yes
else
    daemon_running=no_ros2
fi

case "$daemon_running" in
    yes)
        # The daemon's own argv carries the RMW it was started with, so this can
        # be reported as fact rather than as a caution. Its XML-RPC port is
        # 11511 + ROS_DOMAIN_ID with no RMW in it, which is why a daemon from the
        # other middleware is reachable, used, and answers from an empty graph.
        daemon_rmw="$(golfcart_daemon_rmw 2>/dev/null)"
        if [ -n "$daemon_rmw" ] && [ "$daemon_rmw" != "${RMW_IMPLEMENTATION:-}" ]; then
            fail "ros2 daemon is running under ${daemon_rmw}, this host is ${RMW_IMPLEMENTATION:-?}"
            info "every graph query (topic list, node list, topic hz) will report an"
            info "EMPTY graph while the stack runs perfectly. Fix it with:"
            info "    just rmw daemon-stop"
        else
            warn "a ros2 daemon is running${daemon_rmw:+ (${daemon_rmw})}"
            info "its transport context was fixed when it started, so it may still be"
            info "on a different profile than the one above. If the graph looks wrong"
            info "(\`ros2 topic list\` empty while the stack runs), run:"
            info "    ros2 daemon stop"
        fi
        ;;
    no)
        ok "no ros2 daemon running (the next ros2 command will start one with the profile above)"
        ;;
    no_ros2)
        warn "ros2 not on PATH — ROS environment not sourced in this shell"
        info "source /opt/ros/humble/setup.bash, or: source scripts/env.sh"
        ;;
esac

# ── 3. Kernel buffers ────────────────────────────────────────────────────────
# CycloneDDS only. The 10MB floor is the <SocketReceiveBufferSize min=> in
# config/cyclonedds/*.xml, which Cyclone treats as a hard requirement; zenoh
# carries data over TCP and has no equivalent, so under it this whole section
# would send an operator to tune sysctls that cannot affect anything.
if [ "${GOLFCART_RMW:-cyclonedds}" = "cyclonedds" ]; then
section "Kernel network buffers"

MIN_RMEM=10485760   # 10 MB; below this CycloneDDS refuses to create a domain
# Read /proc directly when sysctl is not on PATH (it lives in /sbin).
rmem=$(sysctl -n net.core.rmem_max 2>/dev/null || cat /proc/sys/net/core/rmem_max 2>/dev/null || echo "")
if ! printf '%s' "$rmem" | grep -Eq '^[0-9]+$'; then
    warn "net.core.rmem_max unreadable on this system"
elif [ "$rmem" -lt "$MIN_RMEM" ]; then
    fail "net.core.rmem_max = ${rmem} (< ${MIN_RMEM} required by our DDS profiles)"
    info "CycloneDDS will refuse to create a domain. Usual culprit:"
    info "    /etc/sysctl.d/60-zed-buffers.conf  (installed by the ZED SDK)"
    info "Fix: cd setup && just cyclonedds-sysctl"
    for f in /etc/sysctl.d/*.conf /etc/sysctl.conf; do
        [ -f "$f" ] || continue
        if grep -q 'net\.core\.rmem_max' "$f" 2>/dev/null; then
            info "  sets rmem_max: $f -> $(grep -h 'net\.core\.rmem_max' "$f" | tr -d ' ')"
        fi
    done
else
    ok "net.core.rmem_max = ${rmem} (>= ${MIN_RMEM})"
fi

# The send side, and it fails exactly as hard. c228d87 added
# <SocketSendBufferSize min="16MB"> to every profile so the LiDARs hold 10 Hz,
# and CycloneDDS treats an unmet `min` as fatal to the DOMAIN, not as a
# warning: every node dies in its first second with "rmw_create_node: failed
# to create domain" and the real reason one line above it on stderr. This was
# missed here because the section only ever checked rmem_max, while the two
# sysctls are set by different generations of the setup step -- the orin had
# rmem_max at 2 GB and wmem_max at the kernel's 212992. See docs/roadblocks.md.
MIN_WMEM=16777216   # the min= in config/cyclonedds/*.xml
wmem=$(sysctl -n net.core.wmem_max 2>/dev/null || cat /proc/sys/net/core/wmem_max 2>/dev/null || echo "")
if ! printf '%s' "$wmem" | grep -Eq '^[0-9]+$'; then
    warn "net.core.wmem_max unreadable on this system"
elif [ "$wmem" -lt "$MIN_WMEM" ]; then
    fail "net.core.wmem_max = ${wmem} (< ${MIN_WMEM} required by our DDS profiles)"
    info "CycloneDDS will refuse to create a domain; every node exits at startup."
    info "Fix: ./setup.sh --rerun cyclonedds-sysctl"
else
    ok "net.core.wmem_max = ${wmem} (>= ${MIN_WMEM})"
fi

fi  # GOLFCART_RMW = cyclonedds (kernel buffer section)

# ── 4. golfcart-* user units ─────────────────────────────────────────────────
section "systemd user units"

if ! command -v systemctl >/dev/null 2>&1; then
    ok "systemctl not available — no user units to check"
else
    units=$(systemctl --user list-unit-files 'golfcart-*' --no-legend 2>/dev/null | awk '{print $1}')
    if [ -z "$units" ]; then
        ok "no golfcart-* user units installed"
    else
        while read -r unit; do
            [ -n "$unit" ] || continue
            state=$(systemctl --user is-active "$unit" 2>/dev/null || true)
            case "$state" in
                active|activating)   ok   "${unit}: ${state}" ;;
                failed)              fail "${unit}: failed — systemctl --user status ${unit}" ;;
                inactive|deactivating|"") ok "${unit}: ${state:-inactive}" ;;
                *)                   warn "${unit}: ${state}" ;;
            esac
        done <<< "$units"
    fi
fi

# ── 5. Bag directory ─────────────────────────────────────────────────────────
section "Recording directory"

bag_dir="${GOLFCART_BAG_DIR:-${HOME}/rosbags}"
if [ -n "${GOLFCART_BAG_DIR:-}" ]; then
    origin="GOLFCART_BAG_DIR"
else
    origin="default"
fi

if [ -d "$bag_dir" ]; then
    if [ -w "$bag_dir" ]; then
        ok "bag dir: ${bag_dir} (${origin}), free: $(free_space_of "$bag_dir")"
    else
        fail "bag dir: ${bag_dir} (${origin}) exists but is not writable"
    fi
else
    parent=$(dirname "$bag_dir")
    if [ -d "$parent" ] && [ -w "$parent" ]; then
        warn "bag dir: ${bag_dir} (${origin}) does not exist yet; it will be created on first record"
        info "free space on $(dirname "$bag_dir"): $(free_space_of "$parent")"
    else
        fail "bag dir: ${bag_dir} (${origin}) cannot be created (${parent} missing or not writable)"
    fi
fi

# ── Summary ──────────────────────────────────────────────────────────────────
printf '\n'
if [ "$fails" -gt 0 ]; then
    printf '%s%d problem(s), %d warning(s)%s\n' "$RED" "$fails" "$warns" "$NC"
    exit 1
elif [ "$warns" -gt 0 ]; then
    printf '%s0 problems, %d warning(s)%s\n' "$YELLOW" "$warns" "$NC"
else
    printf '%sAll checks passed%s\n' "$GREEN" "$NC"
fi
exit 0
