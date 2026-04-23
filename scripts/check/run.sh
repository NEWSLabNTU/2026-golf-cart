#!/usr/bin/env bash
# Golf cart sensor & interface health check
# 1. Runs hardware-level connectivity checks (no ROS required)
# 2. Launches available sensor drivers + RViz for live visualization
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

lidar_iface=""
while IFS= read -r line; do
    if [[ "$line" == *"$LIDAR_SUBNET"* ]]; then
        lidar_iface="$line"
    fi
done < <(ip -4 addr show 2>/dev/null)

if [[ -n "$lidar_iface" ]]; then
    ok "Network interface configured on ${LIDAR_SUBNET}x subnet"
else
    fail "No interface on ${LIDAR_SUBNET}x subnet — configure with: sudo ip addr add 192.168.7.1/24 dev <iface> && sudo ip link set <iface> up"
fi

if ping -c 1 -W 1 "$LIDAR_IP" &>/dev/null; then
    ok "VLP-32C reachable at $LIDAR_IP"
    lidar_ok=true
else
    fail "VLP-32C not reachable at $LIDAR_IP (ping failed)"
fi

if dpkg -l ros-humble-nebula-ros-1-5-0 &>/dev/null; then
    ok "Nebula LiDAR driver installed"
else
    fail "Nebula LiDAR driver not installed (ros-humble-nebula-ros-1-5-0)"
    lidar_ok=false
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
