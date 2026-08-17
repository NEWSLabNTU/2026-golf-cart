#!/usr/bin/env bash
# Golf Cart Setup Wrapper
# Interactive setup with optional components

set -e

# Resolve symlinks to find the actual script location
SCRIPT_PATH="$(readlink -f "$0")"
SCRIPT_DIR="$(dirname "$SCRIPT_PATH")"
MARKER_DIR="${SCRIPT_DIR}/.markers"
SUDO_PID_FILE="${MARKER_DIR}/.sudo-loop-pid"
SUDO_LOOP_PID=""

# Colors
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

# Show usage
show_usage() {
    cat << 'EOF'
Golf Cart Setup Script

Usage:
  ./setup.sh              Run interactive setup
  ./setup.sh status       Show setup status
  ./setup.sh <recipe>     Run specific recipe (ros2, dev-tools, etc.)
  ./setup.sh --help       Show this help

Examples:
  ./setup.sh              # Interactive full setup
  ./setup.sh status       # Check what's installed
  ./setup.sh ros2         # Install only ROS 2
  ./setup.sh clean-markers # Reset all installation markers

For available recipes, run: just --list
EOF
}

# Cleanup function - called on exit (normal or abnormal)
cleanup() {
    local exit_code=$?
    if [[ -n "$SUDO_LOOP_PID" ]] && kill -0 "$SUDO_LOOP_PID" 2>/dev/null; then
        kill "$SUDO_LOOP_PID" 2>/dev/null || true
    fi
    rm -f "$SUDO_PID_FILE"

    # Show cancellation message if interrupted (but not on normal exit)
    if [[ $exit_code -eq 130 ]]; then
        printf "\n${YELLOW}Cancelled by user${NC}\n" >&2
    fi
}

# Handle interrupt signal (Ctrl-C)
interrupt_handler() {
    printf "\n${YELLOW}Interrupted${NC}\n" >&2
    exit 130
}

# Set trap for cleanup on any exit
trap cleanup EXIT
trap interrupt_handler INT TERM

# Recipes that don't need sudo
NO_SUDO_RECIPES="status clean-marker clean-markers default"

# Check if recipe needs sudo
needs_sudo() {
    local recipe="${1:-setup}"
    for r in $NO_SUDO_RECIPES; do
        [[ "$recipe" == "$r" ]] && return 1
    done
    return 0
}

# Start sudo keep-alive loop
start_sudo_loop() {
    mkdir -p "$MARKER_DIR"

    # Check if we already have sudo credentials cached
    if ! sudo -n true 2>/dev/null; then
        printf "${YELLOW}→${NC} Requesting sudo privileges...\n"
        sudo -v || { printf "${RED}✗${NC} Failed to obtain sudo credentials\n"; exit 1; }
    fi

    # Start background sudo refresh loop (silent)
    (
        while true; do
            sudo -n true
            sleep 50
        done
    ) </dev/null >/dev/null 2>&1 &
    SUDO_LOOP_PID=$!
    disown $SUDO_LOOP_PID 2>/dev/null || true
    echo "$SUDO_LOOP_PID" > "$SUDO_PID_FILE"
}

# Ask yes/no question
ask_yes_no() {
    local question="$1"
    local default="${2-y}"
    local prompt

    if [[ -z "$default" ]]; then
        prompt="[y/n/q]"
    elif [[ "$default" == "y" ]]; then
        prompt="[Y/n/q]"
    else
        prompt="[y/N/q]"
    fi

    while true; do
        printf "${BLUE}?${NC} %s %s " "$question" "$prompt"
        read -r response || {
            # Handle Ctrl-D (EOF)
            printf "\n${YELLOW}Cancelled${NC}\n"
            exit 130
        }
        response="${response:-$default}"
        case "${response,,}" in
            y|yes) return 0 ;;
            n|no) return 1 ;;
            q|quit|exit)
                printf "\n${YELLOW}Cancelled${NC}\n"
                exit 0
                ;;
            *) printf "${RED}Please answer yes, no, or q to quit.${NC}\n" ;;
        esac
    done
}

# ── Component menu ──────────────────────────────────────────────────────────
#
# One screen the user can review and toggle, rather than a run of yes/no
# prompts. The prompts had two problems: an answer could not be revised once
# given, and the Autoware step went on to ask ITS OWN questions partway
# through the install — a second interview arriving after you thought you were
# done. Those are folded in here (see AUTOWARE_PREREQ_* below) and passed to
# that script as flags.
#
# Each entry: key|default|indent|label|note
# `indent` marks a sub-option of the entry above it: shown indented, and
# ignored entirely unless its parent is selected.
MENU_ITEMS=(
  "AUTOWARE|y|0|Autoware Debian packages|~2-3 GB. Skip to build from source instead."
  "AUTOWARE_PREREQ_ROS|n|1|└ let Autoware install ROS 2 Humble|Normally NO: this setup installs ROS 2 itself, earlier."
  "AUTOWARE_PREREQ_SPCONV|n|1|└ SpConv/Cumm libraries|Only for BEVFusion-class models; this stack does not use them."
  "AUTOWARE_DATA|y|0|Writable Autoware data dir|Seconds. Without it TensorRT cannot cache engines and perception fails."
  "TENSORRT_ENGINES|n|1|└ compile TensorRT engines now|~11 min on an Orin. Otherwise the first launch pays it, with perception down."
  "ISAAC_ROS|y|0|Isaac ROS Visual Localization|cuVSLAM + cuVGL. Camera-only localization without LiDAR/GNSS. Jetson only."
  "CYCLONEDDS_SYSCTL|y|0|CycloneDDS kernel buffers|Writes /etc/sysctl.d/10-cyclone-max.conf (system-wide)."
  "TURBOVNC_VIRTUALGL|y|0|TurboVNC + VirtualGL|GPU-accelerated rendering over VNC."
  "HARDWARE_CONFIG|n|0|Hardware configs (CAN + LiDAR network)|Vehicle computer only — matches specific MAC addresses."
  "OTOCAM|n|0|OTOCAM GMSL camera kmods|Needs vendor blob and kernel 5.15.148-tegra. Reboot required."
  "LINUXPTP|n|0|linuxptp (ptp4l + phc2sys)|PTP time sync, hardcoded to interface enP5p5s0."
)

declare -A MENU_STATE

menu_field() { printf '%s' "$1" | cut -d'|' -f"$2"; }

# Is this entry's parent selected? Sub-options are meaningless otherwise.
menu_parent_on() {
    local idx="$1" i
    for (( i = idx - 1; i >= 0; i-- )); do
        if [[ "$(menu_field "${MENU_ITEMS[$i]}" 3)" == "0" ]]; then
            [[ "${MENU_STATE[$(menu_field "${MENU_ITEMS[$i]}" 1)]}" == "y" ]]
            return $?
        fi
    done
    return 0
}

menu_render() {
    local i key label note indent mark dim
    printf "\n${BLUE}Golf Cart Setup${NC}  —  core (ROS 2, dev tools, GeographicLib, Python deps) is always installed\n\n"
    for i in "${!MENU_ITEMS[@]}"; do
        key=$(menu_field "${MENU_ITEMS[$i]}" 1)
        indent=$(menu_field "${MENU_ITEMS[$i]}" 3)
        label=$(menu_field "${MENU_ITEMS[$i]}" 4)
        note=$(menu_field "${MENU_ITEMS[$i]}" 5)
        [[ "${MENU_STATE[$key]}" == "y" ]] && mark="${GREEN}x${NC}" || mark=" "

        # Grey out a sub-option whose parent is off — still listed, so its
        # existence is discoverable, but plainly not in play.
        dim=""
        if [[ "$indent" == "1" ]] && ! menu_parent_on "$i"; then
            dim="${YELLOW}"
            mark="-"
        fi
        if [[ "$indent" == "1" ]]; then
            printf "  %2d  [%b] %b    %s${NC}\n" "$((i + 1))" "$mark" "$dim" "$label"
        else
            printf "  %2d  [%b] %b%s${NC}\n" "$((i + 1))" "$mark" "$dim" "$label"
        fi
        [[ -n "$note" ]] && printf "         %b%s${NC}\n" "${dim:-$YELLOW}" "$note"
    done
    printf "\n  ${BLUE}number${NC} toggle   ${BLUE}a${NC} all   ${BLUE}n${NC} none   ${BLUE}ENTER${NC} continue   ${BLUE}q${NC} quit\n"
}

interactive_setup() {
    local i key def
    for i in "${!MENU_ITEMS[@]}"; do
        key=$(menu_field "${MENU_ITEMS[$i]}" 1)
        def=$(menu_field "${MENU_ITEMS[$i]}" 2)
        # Isaac ROS is Jetson-only; do not offer it elsewhere.
        if [[ "$key" == "ISAAC_ROS" && "$(uname -m)" != "aarch64" ]]; then
            def="n"
        fi
        MENU_STATE["$key"]="$def"
    done

    while true; do
        menu_render
        printf "${BLUE}?${NC} "
        read -r reply || { printf "\n${YELLOW}Cancelled${NC}\n"; exit 130; }
        case "${reply,,}" in
            "") break ;;
            q|quit|exit) printf "${YELLOW}Cancelled${NC}\n"; exit 0 ;;
            a|all)  for key in "${!MENU_STATE[@]}"; do MENU_STATE[$key]="y"; done ;;
            n|none) for key in "${!MENU_STATE[@]}"; do MENU_STATE[$key]="n"; done ;;
            *)
                # Accept "1 3 5" and "1,3,5" alike.
                for tok in ${reply//,/ }; do
                    if [[ "$tok" =~ ^[0-9]+$ ]] && (( tok >= 1 && tok <= ${#MENU_ITEMS[@]} )); then
                        key=$(menu_field "${MENU_ITEMS[$((tok - 1))]}" 1)
                        [[ "${MENU_STATE[$key]}" == "y" ]] && MENU_STATE[$key]="n" || MENU_STATE[$key]="y"
                    else
                        printf "${RED}Not a listed number: %s${NC}\n" "$tok"
                    fi
                done
                ;;
        esac
    done

    # A sub-option whose parent ended up off must not leak into the run.
    for i in "${!MENU_ITEMS[@]}"; do
        key=$(menu_field "${MENU_ITEMS[$i]}" 1)
        if [[ "$(menu_field "${MENU_ITEMS[$i]}" 3)" == "1" ]] && ! menu_parent_on "$i"; then
            MENU_STATE[$key]="n"
        fi
    done

    # Export for the justfile. SKIP_AUTOWARE_DEBIAN keeps its inverted sense
    # because setup/justfile already reads it that way.
    export SKIP_AUTOWARE_DEBIAN="$([[ "${MENU_STATE[AUTOWARE]}" == "n" ]] && echo 1 || echo 0)"
    export AUTOWARE_PREREQ_ROS="${MENU_STATE[AUTOWARE_PREREQ_ROS]}"
    export AUTOWARE_PREREQ_SPCONV="${MENU_STATE[AUTOWARE_PREREQ_SPCONV]}"
    export SETUP_AUTOWARE_DATA="${MENU_STATE[AUTOWARE_DATA]}"
    export BUILD_TENSORRT_ENGINES="${MENU_STATE[TENSORRT_ENGINES]}"
    export INSTALL_ISAAC_ROS="${MENU_STATE[ISAAC_ROS]}"
    export CONFIGURE_CYCLONEDDS_SYSCTL="${MENU_STATE[CYCLONEDDS_SYSCTL]}"
    export INSTALL_TURBOVNC_VIRTUALGL="${MENU_STATE[TURBOVNC_VIRTUALGL]}"
    export INSTALL_HARDWARE_CONFIG="${MENU_STATE[HARDWARE_CONFIG]}"
    export INSTALL_OTOCAM="${MENU_STATE[OTOCAM]}"
    export INSTALL_LINUXPTP="${MENU_STATE[LINUXPTP]}"

    printf "\nInstalling: Core"
    for i in "${!MENU_ITEMS[@]}"; do
        key=$(menu_field "${MENU_ITEMS[$i]}" 1)
        [[ "${MENU_STATE[$key]}" == "y" ]] || continue
        [[ "$(menu_field "${MENU_ITEMS[$i]}" 3)" == "1" ]] && continue
        printf " + %s" "$(menu_field "${MENU_ITEMS[$i]}" 4)"
    done
    printf "\n"
    if [[ "${MENU_STATE[TENSORRT_ENGINES]}" == "y" ]]; then
        printf "${YELLOW}Note:${NC} TensorRT engine compilation adds ~11 minutes.\n"
    fi
    printf "\n"

    if ! ask_yes_no "Continue?" "y"; then
        printf "${YELLOW}Cancelled${NC}\n"
        exit 0
    fi
    printf "\n"
}

# Main
main() {
    # Handle --help/-h
    if [[ "$1" == "--help" ]] || [[ "$1" == "-h" ]]; then
        show_usage
        exit 0
    fi

    local recipe="${1:-setup}"

    # Check if just is installed
    if ! command -v just &> /dev/null; then
        printf "${RED}✗${NC} 'just' not found\n"
        printf "Install: curl --proto '=https' --tlsv1.2 -sSf https://just.systems/install.sh | bash -s -- --to ~/.local/bin\n"
        exit 1
    fi

    # If running full setup, show interactive wizard
    if [[ "$recipe" == "setup" ]]; then
        if [[ ! -t 0 ]]; then
            # Non-interactive mode (piped input)
            printf "${YELLOW}→${NC} Non-interactive mode\n"
        else
            # Interactive mode
            interactive_setup
        fi
    fi

    # Start sudo loop if needed (silently)
    if needs_sudo "$recipe"; then
        start_sudo_loop
    fi

    # Run just with all arguments
    cd "$SCRIPT_DIR"
    if [[ $# -eq 0 ]]; then
        # No arguments, run setup
        just setup
    else
        # Pass through all arguments
        just "$@"
    fi



    # After successful setup, show direnv instructions
    if [[ "$recipe" == "setup" ]]; then
        if ! command -v direnv &> /dev/null; then
            printf "\n${YELLOW}┌────────────────────────────────────────────────────────────┐${NC}\n"
            printf "${YELLOW}│ IMPORTANT: Install direnv for environment management      │${NC}\n"
            printf "${YELLOW}└────────────────────────────────────────────────────────────┘${NC}\n\n"
            printf "  ${BLUE}# Install direnv${NC}\n"
            printf "  sudo apt install direnv\n\n"
            printf "  ${BLUE}# Add to your shell (bash)${NC}\n"
            printf "  echo 'eval \"\$(direnv hook bash)\"' >> ~/.bashrc\n"
            printf "  source ~/.bashrc\n\n"
            printf "  ${BLUE}# Allow .envrc${NC}\n"
            printf "  direnv allow\n\n"
            printf "See: ${BLUE}https://direnv.net/${NC}\n"
        else
            printf "\n${GREEN}✓ direnv detected!${NC}\n"
            printf "Run this to activate environment: ${BLUE}direnv allow${NC}\n"
        fi
    fi
}

main "$@"
