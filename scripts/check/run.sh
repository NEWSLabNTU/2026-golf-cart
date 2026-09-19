#!/usr/bin/env bash
# Golf cart sensor & interface health check
# 1. Runs hardware-level connectivity checks (no ROS required)
# 2. Launches available sensor drivers + RViz for live visualization
#
# Unlike scripts/check/vehicle.sh, this script has no ssh-routing concept: the
# LiDAR checks below (and phase 2's `ros2 launch`) always run against THIS
# host. If config/sensors.conf's LIDAR_HOST is ever set to orin, run this
# script ON the orin instead of adding remote routing here - phase 2 starts
# real ROS nodes and RViz locally, which cannot sensibly be done "for" another
# machine. See docs/roadmaps/8-lidar-on-orin.md.
set -uo pipefail

script_dir=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &>/dev/null && pwd )
repo_dir="$script_dir/../.."

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'
BOLD='\033[1m'; NC='\033[0m'

pass=0; warn=0; fail=0

ok()   { echo -e "  ${GREEN}[OK]${NC}   $1"; pass=$((pass + 1)); }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $1"; warn=$((warn + 1)); }
fail() { echo -e "  ${RED}[FAIL]${NC} $1"; fail=$((fail + 1)); }

section() { echo -e "\n${CYAN}${BOLD}── $1 ──${NC}"; }

# Track which sensors are available for the ROS launch phase
lidar_ok=false
gnss_ok=false
camera_ok=false

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 1: Hardware checks
# ═══════════════════════════════════════════════════════════════════════════════
echo -e "${BOLD}Phase 1: Hardware checks${NC}"

# ── 1. Velodyne VLP-32C LiDAR ───────────────────────────────────────────────
LIDAR_IP="192.168.7.10"
LIDAR_SUBNET="192.168.7."

section "Velodyne VLP-32C LiDAR"

lidar_iface=$(ip -4 -o addr show 2>/dev/null | awk -v subnet="$LIDAR_SUBNET" '$4 ~ subnet {print $2; exit}')

if [[ -n "$lidar_iface" ]]; then
    ok "Network interface configured on ${LIDAR_SUBNET}x subnet (${lidar_iface})"
else
    fail "No interface on ${LIDAR_SUBNET}x subnet — configure with: sudo ip addr add 192.168.7.1/24 dev <iface> && sudo ip link set <iface> up"
fi

if ping -c 1 -W 1 "$LIDAR_IP" &>/dev/null; then
    ok "VLP-32C reachable at $LIDAR_IP"
    lidar_ok=true
else
    fail "VLP-32C not reachable at $LIDAR_IP (ping failed)"
fi

# A reachable LiDAR may still be silent if its destination IP (set in the
# web UI at http://$LIDAR_IP) does not match this host. Sniff port 2368.
if [[ -n "$lidar_iface" ]] && $lidar_ok; then
    if ! command -v tcpdump &>/dev/null; then
        warn "tcpdump not installed — skipping UDP stream check (sudo apt install tcpdump)"
    else
        echo "timeout 2 tcpdump -i $lidar_iface -nn -c 1 udp port 2368"
        tcpdump_cmd=(timeout 2 tcpdump -i "$lidar_iface" -nn -c 1 'udp port 2368')
        capture_out=$("${tcpdump_cmd[@]}" 2>&1)
        capture_rc=$?
        if [[ $capture_rc -ne 0 ]] && echo "$capture_out" | grep -qiE "permission|operation not permitted"; then
            capture_out=$(sudo -n "${tcpdump_cmd[@]}" 2>&1)
            capture_rc=$?
            if echo "$capture_out" | grep -qiE "password is required|sudo:"; then
                warn "UDP stream check needs root — run: sudo setcap cap_net_raw,cap_net_admin=eip \$(which tcpdump)"
                capture_rc=-1
            fi
        fi
        case $capture_rc in
            0)
                ok "VLP-32C streaming UDP packets on port 2368"
                # Nebula binds its UDP socket to host_ip (192.168.7.1), so the
                # kernel only delivers packets whose dst is exactly that IP.
                # A broadcast dst (255.255.255.255 or 192.168.7.255) is dropped
                # silently → driver reports "Missed pointcloud output deadline".
                host_ip=$(ip -4 -o addr show "$lidar_iface" 2>/dev/null | awk '{split($4,a,"/"); print a[1]; exit}')
                bcast_ip=$(ip -4 -o addr show "$lidar_iface" 2>/dev/null | awk '{print $6; exit}')
                pkt_dst=$(echo "$capture_out" | grep -oE 'IP [0-9.]+\.[0-9]+ > [0-9.]+\.[0-9]+' | head -1 | awk '{print $4}' | sed 's/\.[0-9]*$//')
                if [[ -n "$pkt_dst" ]]; then
                    if [[ "$pkt_dst" == "255.255.255.255" || "$pkt_dst" == "$bcast_ip" ]]; then
                        warn "LiDAR is broadcasting to ${pkt_dst}; Nebula binds to ${host_ip} and won't receive — set destination IP to ${host_ip} in web UI: http://${LIDAR_IP}"
                    elif [[ "$pkt_dst" != "$host_ip" ]]; then
                        warn "LiDAR sending to ${pkt_dst} but host_ip is ${host_ip} — Nebula will not receive packets"
                    fi
                fi
                ;;
            124) fail "VLP-32C reachable but NOT streaming on port 2368 — set destination IP to this host in web UI: http://${LIDAR_IP}" ;;
            -1)  ;;  # already warned
            *)   warn "tcpdump exited $capture_rc: $(echo "$capture_out" | tail -1)" ;;
        esac
    fi
fi

if dpkg -l ros-humble-nebula-ros-1-5-0 &>/dev/null; then
    ok "Nebula LiDAR driver installed"
else
    fail "Nebula LiDAR driver not installed (ros-humble-nebula-ros-1-5-0)"
    lidar_ok=false
fi

# VLP32.param.yaml carries udp_only: false, so Nebula's HTTP client is live and
# setup_sensor pushes rotation_speed and return_mode at start-up. Read them back
# to confirm the push landed. If udp_only is ever flipped to true the HTTP client
# is disabled and those two become assumptions about the EEPROM instead, which
# nothing in the stack would report — hence the harsher verdict below.
vlp_cfg="$repo_dir/src/sensor_kit/golfcart_sensor_kit_launch/golfcart_sensor_kit_launch/config/VLP32.param.yaml"

yaml_scalar() { awk -F': *' -v k="$2" '$0 ~ "^ *"k":" {gsub(/[[:space:]\r]/,"",$2); print $2; exit}' "$1"; }

if [[ -f "$vlp_cfg" ]] && $lidar_ok; then
    want_rpm=$(yaml_scalar "$vlp_cfg" rotation_speed)
    want_ret=$(yaml_scalar "$vlp_cfg" return_mode)
    udp_only=$(yaml_scalar "$vlp_cfg" udp_only)

    # With udp_only the driver cannot correct a mismatch, so it is a failure.
    # Without it, setup_sensor pushes the config at start-up and a mismatch
    # right now is only worth a warning.
    if [[ "$udp_only" == "true" ]]; then
        mismatch=fail
        why="udp_only: true, so the driver will not correct this"
    else
        mismatch=warn
        why="setup_sensor should push this at start-up"
    fi

    if ! command -v curl &>/dev/null; then
        warn "curl not installed — cannot read back LiDAR RPM/return mode (sudo apt install curl)"
    else
        vlp_settings=$(curl -sf -m 3 "http://${LIDAR_IP}/cgi/settings.json" 2>/dev/null)
        vlp_status=$(curl -sf -m 3 "http://${LIDAR_IP}/cgi/status.json" 2>/dev/null)

        if [[ -z "$vlp_settings" && -z "$vlp_status" ]]; then
            warn "VLP-32C web interface at http://${LIDAR_IP} did not answer — cannot verify RPM/return mode (this is also why udp_only may have been set)"
        else
            # Firmware revisions disagree on types and nesting, so pull the
            # values out by key wherever they sit rather than by fixed path.
            read -r have_rpm have_ret < <(
                VLP_SETTINGS="$vlp_settings" VLP_STATUS="$vlp_status" python3 - <<'PY' 2>/dev/null || echo " "
import json, os

def load(name):
    try:
        return json.loads(os.environ.get(name, "") or "null")
    except ValueError:
        return None

def find(node, key):
    if isinstance(node, dict):
        for k, v in node.items():
            if k == key and not isinstance(v, (dict, list)):
                return v
            hit = find(v, key)
            if hit is not None:
                return hit
    elif isinstance(node, list):
        for v in node:
            hit = find(v, key)
            if hit is not None:
                return hit
    return None

settings, status = load("VLP_SETTINGS"), load("VLP_STATUS")
# status.json reports the motor's measured RPM; settings.json the commanded one.
rpm = find(status, "rpm")
if rpm is None:
    rpm = find(settings, "rpm")
ret = find(settings, "returns")
if ret is None:
    ret = find(status, "returns")
print(rpm if rpm is not None else "?", str(ret) if ret is not None else "?")
PY
            )

            if [[ ! "${have_rpm:-}" =~ ^[0-9]+$ ]]; then
                warn "VLP-32C answered but reported no usable RPM (${have_rpm:-none}) — check http://${LIDAR_IP} by hand"
            else
                # Measured RPM drifts a little around the commanded value.
                if (( have_rpm > want_rpm - 30 && have_rpm < want_rpm + 30 )); then
                    ok "VLP-32C RPM ${have_rpm} matches rotation_speed ${want_rpm} ($((want_rpm / 60)) Hz)"
                else
                    $mismatch "VLP-32C running at ${have_rpm} RPM but VLP32.param.yaml says ${want_rpm} — ${why}; fix at http://${LIDAR_IP}"
                fi
            fi

            # Nebula and the Velodyne web UI name the return modes differently:
            # return_mode must be spelled SingleStrongest/SingleLast/SingleFirst/Dual
            # (nebula_common.hpp's generic parser; anything else aborts the node),
            # while settings.json answers Strongest/Last/Dual. Compare in the
            # sensor's vocabulary.
            case "${want_ret,,}" in
                singlestrongest) want_ret_sensor=strongest ;;
                singlelast)      want_ret_sensor=last ;;
                singlefirst)     want_ret_sensor=first ;;
                *)               want_ret_sensor="${want_ret,,}" ;;
            esac

            if [[ "${have_ret:-?}" == "?" || -z "${have_ret:-}" ]]; then
                warn "VLP-32C answered but no return-mode field found — check http://${LIDAR_IP} by hand"
            elif [[ "${have_ret,,}" == "$want_ret_sensor" ]]; then
                ok "VLP-32C return mode ${have_ret} matches return_mode ${want_ret}"
            else
                $mismatch "VLP-32C return mode is ${have_ret} but VLP32.param.yaml says ${want_ret} — ${why}; fix at http://${LIDAR_IP}"
            fi
        fi
    fi
fi


# ── 1. Seyond Falcon LiDAR ───────────────────────────────────────────────
LIDAR_IP="172.168.1.10"
LIDAR_SUBNET="172.168.1."
LIDAR_PORT="8010"

section "Seyond Falcon LiDAR"

lidar_iface=$(ip -4 -o addr show 2>/dev/null | awk -v subnet="$LIDAR_SUBNET" '$4 ~ subnet {print $2; exit}')

if [[ -n "$lidar_iface" ]]; then
    ok "Network interface configured on ${LIDAR_SUBNET}x subnet (${lidar_iface})"
else
    fail "No interface on ${LIDAR_SUBNET}x subnet — configure with: sudo ip addr add 192.168.7.1/24 dev <iface> && sudo ip link set <iface> up"
fi

if ping -c 1 -W 1 "$LIDAR_IP" &>/dev/null; then
    ok "Falcon reachable at $LIDAR_IP"
    lidar_ok=true
else
    fail "Falcon not reachable at $LIDAR_IP (ping failed)"
fi

if ros2 pkg list | grep -q "^seyond$"; then
    ok "Seyond ROS2 package found"
else
    fail "Seyond ROS2 package not found"
    lidar_ok=false
fi

# ── 2. u-blox GNSS ──────────────────────────────────────────────────────────
section "u-blox GNSS"

if [[ -e /dev/ublox-gps ]]; then
    ok "u-blox device found at /dev/ublox-gps"
    gnss_ok=true
elif ls /dev/ttyACM* &>/dev/null; then
    warn "No /dev/ublox-gps symlink, but /dev/ttyACM* found — udev rule may not match"
else
    fail "No u-blox device found (/dev/ublox-gps missing, no /dev/ttyACM*)"
fi

if [[ -f /etc/udev/rules.d/99-ublox-gps.rules ]]; then
    ok "u-blox udev rules installed"
else
    warn "u-blox udev rules not installed at /etc/udev/rules.d/99-ublox-gps.rules"
fi

if id -nG | grep -qw dialout; then
    ok "User in dialout group"
else
    fail "User NOT in dialout group — run: sudo usermod -aG dialout \$USER (then re-login)"
    gnss_ok=false
fi

if dpkg -l ros-humble-ublox-gps &>/dev/null; then
    ok "u-blox ROS driver installed"
else
    fail "u-blox ROS driver not installed (ros-humble-ublox-gps)"
    gnss_ok=false
fi

# ── 3. Tamagawa IMU ─────────────────────────────────────────────────────────
section "Tamagawa IMU"

if dpkg -l 2>/dev/null | grep -q tamagawa; then
    ok "Tamagawa IMU driver installed"
else
    fail "Tamagawa IMU driver not installed (blocked — request from Turing Drive)"
fi

uart_ports=()
for dev in /dev/ttyTHS*; do
    [[ -e "$dev" ]] && uart_ports+=("$dev")
done
if [[ ${#uart_ports[@]} -gt 0 ]]; then
    ok "UART ports available: ${uart_ports[*]}"
else
    warn "No UART ports found (/dev/ttyTHS*)"
fi

# ── 4. Cameras ───────────────────────────────────────────────────────────────
section "Cameras"

video_devs=()
for dev in /dev/video*; do
    [[ -e "$dev" ]] && video_devs+=("$dev")
done

if [[ ${#video_devs[@]} -gt 0 ]]; then
    ok "Camera devices found: ${video_devs[*]}"
    camera_ok=true
else
    fail "No camera devices found (/dev/video*)"
fi

if dpkg -l ros-humble-usb-cam &>/dev/null; then
    ok "usb-cam ROS driver installed (covers USB and TIER IV C1 via UVC)"
else
    fail "usb-cam ROS driver not installed — run: sudo apt install ros-humble-usb-cam"
    camera_ok=false
fi

# ── 5. CAN Bus (Turing Drive DBW) ───────────────────────────────────────────
section "CAN Bus (Turing Drive DBW)"

can_ifaces=()
for iface in /sys/class/net/can*; do
    [[ -e "$iface" ]] && can_ifaces+=("$(basename "$iface")")
done

if [[ ${#can_ifaces[@]} -gt 0 ]]; then
    ok "CAN interfaces present: ${can_ifaces[*]}"
    for iface in "${can_ifaces[@]}"; do
        state=$(cat "/sys/class/net/$iface/operstate" 2>/dev/null || echo "unknown")
        if [[ "$state" == "up" ]]; then
            ok "  $iface is UP"
        else
            warn "  $iface is DOWN — bring up with: sudo ip link set $iface up type can bitrate 500000"
        fi
    done
else
    fail "No CAN interfaces found"
fi

# ── 6. System ────────────────────────────────────────────────────────────────
section "System"

if [[ -d /opt/autoware/1.5.0 ]]; then
    ok "Autoware 1.5.0 installed at /opt/autoware/1.5.0/"
else
    fail "Autoware 1.5.0 not found at /opt/autoware/1.5.0/"
fi

workspace_ok=false
if [[ -f "$repo_dir/install/setup.bash" ]]; then
    ok "Workspace built (install/setup.bash exists)"
    workspace_ok=true
else
    warn "Workspace not built — run: just build"
fi

avail_gb=$(df --output=avail / | tail -1)
avail_gb=$((avail_gb / 1048576))
if [[ $avail_gb -ge 10 ]]; then
    ok "Disk space: ${avail_gb}GB free"
else
    warn "Disk space low: ${avail_gb}GB free (recommend >=10GB)"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}━━━ Summary ━━━${NC}"
echo -e "  ${GREEN}$pass passed${NC}  ${YELLOW}$warn warnings${NC}  ${RED}$fail failed${NC}"

if [[ $fail -eq 0 && $warn -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}All checks passed!${NC}"
elif [[ $fail -eq 0 ]]; then
    echo -e "  ${YELLOW}${BOLD}Passed with warnings.${NC}"
else
    echo -e "  ${RED}${BOLD}Some checks failed — see above.${NC}"
fi

# ═══════════════════════════════════════════════════════════════════════════════
# Phase 2: Launch sensor drivers + RViz
# ═══════════════════════════════════════════════════════════════════════════════

any_sensor=false
if $lidar_ok || $gnss_ok || $camera_ok; then
    any_sensor=true
fi

if ! $any_sensor; then
    echo -e "\n${YELLOW}No sensors detected — skipping ROS visualization.${NC}"
    echo -e "Connect sensors and re-run to launch drivers + RViz."
    exit 1
fi

if ! $workspace_ok; then
    echo -e "\n${YELLOW}Workspace not built — skipping ROS visualization.${NC}"
    echo -e "Run 'just build' first, then re-run."
    exit 1
fi

echo ""
echo -e "${BOLD}Phase 2: Launching sensor drivers + RViz${NC}"
echo -e "  LiDAR:  $( $lidar_ok  && echo -e "${GREEN}yes${NC}" || echo -e "${YELLOW}skip${NC}" )"
echo -e "  GNSS:   $( $gnss_ok   && echo -e "${GREEN}yes${NC}" || echo -e "${YELLOW}skip${NC}" )"
echo -e "  Camera: $( $camera_ok  && echo -e "${GREEN}yes${NC}" || echo -e "${YELLOW}skip${NC}" )"
echo ""

source "$repo_dir/install/setup.bash"
cd "$script_dir"
ros2 launch sensors.launch.xml \
    "launch_lidar:=$lidar_ok" \
    "launch_gnss:=$gnss_ok" \
    "launch_camera:=$camera_ok"
