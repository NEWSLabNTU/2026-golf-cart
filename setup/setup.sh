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
  ./setup.sh --dry-run    Pick components and print the selection, install nothing
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
  "OPENCV|y|0|OpenCV consistency (4.5.4)|JetPack leaves 4.8.0 headers over a 4.5.4 runtime. Also what makes aruco/contrib available."
  "NETWORK_DDS|y|0|Network configuration (DDS)|REQUIRED to run ROS here. Both sub-steps below; scripts/env.sh refuses to load without them."
  "CYCLONEDDS_SYSCTL|y|1|└ kernel socket buffers|net.core.rmem_max=2GB + ipfrag. Writes /etc/sysctl.d/99-cyclonedds-max.conf. Below 10MB no ros2 node can start."
  "MULTICAST_LO|y|1|└ multicast on lo (persistent)|Installs multicast-lo.service. Without it lo loses MULTICAST on reboot and the loopback profile dies."
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

# Rendering is cursor-driven: the block is drawn once, then redrawn in place
# by moving the cursor back up over it. Clearing the whole screen instead would
# throw away whatever the user was looking at before running setup.
#
# That trick only works while the block fits on screen. Draw more lines than the
# terminal has and it scrolls, the cursor-up rewind lands in the wrong place, and
# every redraw smears a fresh copy down the terminal. So the item list is drawn
# through a viewport: MENU_TOP is the first item shown, the window is sized from
# the real terminal height on every render, and the block never scrolls.
MENU_LINES=0
MENU_TOP=0

# Rows one item occupies: its own line, plus its note line if it has one.
menu_item_height() {
    local note
    note=$(menu_field "${MENU_ITEMS[$1]}" 5)
    [[ -n "$note" ]] && printf 2 || printf 1
}

# Rows available for items, after the header, the footer and the two indicator
# slots. Read on every render so a resize is picked up without a redraw loop.
menu_body_budget() {
    local term_lines budget
    term_lines=$(tput lines 2>/dev/null) || term_lines="${LINES:-24}"
    [[ "$term_lines" =~ ^[0-9]+$ ]] || term_lines=24
    # 3 header + 2 footer + 2 indicator slots, and one spare line so the shell
    # prompt that follows does not push the block up by itself.
    budget=$(( term_lines - 8 ))
    # Below this there is no useful viewport left; show one item and let the
    # terminal be too small rather than dividing by nothing.
    (( budget < 2 )) && budget=2
    printf '%s' "$budget"
}

# Terminal width, for the truncation below.
menu_cols() {
    local cols
    cols=$(tput cols 2>/dev/null) || cols="${COLUMNS:-80}"
    [[ "$cols" =~ ^[0-9]+$ ]] || cols=80
    printf '%s' "$cols"
}

# Cut a label or note to the width it is drawn in.
#
# Not cosmetic. A line longer than the terminal wraps, and a wrapped line takes
# two physical rows while this code counts it as one. MENU_LINES then
# understates the block, the rewind lands inside it instead of above it, and
# every redraw leaves a copy of the tail behind. Several of these notes are over
# a hundred characters, so an 80-column terminal hits it immediately.
menu_fit() {
    local text="$1" width="$2"
    (( width < 10 )) && width=10
    if (( ${#text} > width )); then
        printf '%s…' "${text:0:width-1}"
    else
        printf '%s' "$text"
    fi
}

# Slide the viewport just far enough that the cursor's item is fully visible,
# note included. Only ever moves by whole items, so a note never appears
# orphaned from the label it belongs to.
menu_scroll_into_view() {
    local budget="$1" used i
    (( MENU_CURSOR < MENU_TOP )) && MENU_TOP=$MENU_CURSOR
    while (( MENU_TOP < MENU_CURSOR )); do
        used=0
        for (( i = MENU_TOP; i <= MENU_CURSOR; i++ )); do
            used=$(( used + $(menu_item_height "$i") ))
        done
        (( used <= budget )) && break
        MENU_TOP=$(( MENU_TOP + 1 ))
    done
}

menu_render() {
    local i key label note indent mark dim pointer lines=0
    local budget used=0 last_shown cols
    cols=$(menu_cols)
    budget=$(menu_body_budget)
    menu_scroll_into_view "$budget"

    printf "\n${BLUE}Golf Cart Setup${NC}  —  %s\n\n" \
        "$(menu_fit "core (ROS 2, dev tools, GeographicLib, Python deps) is always installed" $(( cols - 21 )))"
    lines=$(( lines + 3 ))

    # The indicator slots are always drawn, blank when there is nothing beyond
    # the edge. A slot that appears and disappears would change the block height
    # between renders, and the rewind is computed from that height.
    if (( MENU_TOP > 0 )); then
        printf "      ${BLUE}↑ %d more above${NC}\n" "$MENU_TOP"
    else
        printf "\n"
    fi
    lines=$(( lines + 1 ))

    last_shown=$(( MENU_TOP - 1 ))
    for (( i = MENU_TOP; i < ${#MENU_ITEMS[@]}; i++ )); do
        (( used + $(menu_item_height "$i") > budget )) && break
        used=$(( used + $(menu_item_height "$i") ))
        last_shown=$i
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

        # The cursor line is marked by a caret and reverse video rather than by
        # colour alone: colour is what a dimmed sub-option already uses, so a
        # second colour would collide with it.
        if (( i == MENU_CURSOR )); then
            pointer="${BLUE}❯${NC}"
        else
            pointer=" "
        fi

        # Widths are the printed prefix: " x [x] " is 7 columns, an indented
        # label adds 4, and a note is indented by 8.
        if [[ "$indent" == "1" ]]; then
            printf " %b [%b] %b    %s${NC}\n" "$pointer" "$mark" "$dim" \
                "$(menu_fit "$label" $(( cols - 12 )))"
        else
            printf " %b [%b] %b%s${NC}\n" "$pointer" "$mark" "$dim" \
                "$(menu_fit "$label" $(( cols - 8 )))"
        fi
        lines=$(( lines + 1 ))
        if [[ -n "$note" ]]; then
            printf "        %b%s${NC}\n" "${dim:-$YELLOW}" \
                "$(menu_fit "$note" $(( cols - 9 )))"
            lines=$(( lines + 1 ))
        fi
    done

    local remaining=$(( ${#MENU_ITEMS[@]} - last_shown - 1 ))
    if (( remaining > 0 )); then
        printf "      ${BLUE}↓ %d more below${NC}\n" "$remaining"
    else
        printf "\n"
    fi
    lines=$(( lines + 1 ))

    # Two hint sets, because the full one is 96 columns and would wrap.
    if (( cols >= 100 )); then
        printf "\n  ${BLUE}↑↓${NC} move   ${BLUE}PgUp/PgDn${NC} page   ${BLUE}Home/End${NC} ends   ${BLUE}SPACE${NC} toggle   ${BLUE}a${NC}/${BLUE}n${NC} all/none   ${BLUE}ENTER${NC} go   ${BLUE}q${NC} quit\n"
    else
        printf "\n  ${BLUE}↑↓${NC} move  ${BLUE}SPACE${NC} toggle  ${BLUE}a${NC}/${BLUE}n${NC} all/none  ${BLUE}ENTER${NC} go  ${BLUE}q${NC} quit\n"
    fi
    lines=$(( lines + 2 ))
    MENU_LINES=$lines
}

# Move back over the block just drawn so the next render overwrites it.
menu_rewind() {
    (( MENU_LINES > 0 )) || return 0
    printf '\033[%dA\033[J' "$MENU_LINES"
}

# One keypress, with arrow keys decoded. Arrows arrive as ESC [ A/B, and the
# trailing reads are given a timeout so a bare ESC does not block.
menu_read_key() {
    local key rest
    IFS= read -rsn1 key || return 1
    if [[ "$key" == $'\033' ]]; then
        read -rsn2 -t 0.05 rest || rest=""
        # PgUp/PgDn/Home/End arrive as ESC [ <digit> ~, one byte longer than the
        # arrows. Without swallowing that trailing ~ it is read as the next
        # keystroke, and the menu reacts to a key nobody pressed.
        if [[ "$rest" =~ ^\[[0-9]$ ]]; then
            local tail
            read -rsn1 -t 0.05 tail || tail=""
            case "${rest}${tail}" in
                '[5~') printf 'pgup'  ; return 0 ;;
                '[6~') printf 'pgdn'  ; return 0 ;;
                '[1~'|'[7~') printf 'home' ; return 0 ;;
                '[4~'|'[8~') printf 'end'  ; return 0 ;;
                *)     printf 'esc'   ; return 0 ;;
            esac
        fi
        case "$rest" in
            '[A') printf 'up' ;;
            '[B') printf 'down' ;;
            '[C') printf 'right' ;;
            '[D') printf 'left' ;;
            '[H') printf 'home' ;;
            '[F') printf 'end' ;;
            'OH') printf 'home' ;;
            'OF') printf 'end' ;;
            *)    printf 'esc' ;;
        esac
        return 0
    fi
    case "$key" in
        '')      printf 'enter' ;;
        ' ')     printf 'space' ;;
        k|K)     printf 'up' ;;
        j|J)     printf 'down' ;;
        *)       printf '%s' "$key" ;;
    esac
}

menu_toggle_current() {
    local key indent
    key=$(menu_field "${MENU_ITEMS[$MENU_CURSOR]}" 1)
    indent=$(menu_field "${MENU_ITEMS[$MENU_CURSOR]}" 3)
    # A sub-option whose parent is off cannot be turned on from here: the run
    # would drop it anyway, so accepting the keystroke would be a lie.
    if [[ "$indent" == "1" ]] && ! menu_parent_on "$MENU_CURSOR"; then
        return 0
    fi
    [[ "${MENU_STATE[$key]}" == "y" ]] && MENU_STATE[$key]="n" || MENU_STATE[$key]="y"
}

interactive_setup() {
    local i key def action

    for i in "${!MENU_ITEMS[@]}"; do
        key=$(menu_field "${MENU_ITEMS[$i]}" 1)
        def=$(menu_field "${MENU_ITEMS[$i]}" 2)
        # Isaac ROS is Jetson-only; do not offer it elsewhere.
        if [[ "$key" == "ISAAC_ROS" && "$(uname -m)" != "aarch64" ]]; then
            def="n"
        fi
        MENU_STATE["$key"]="$def"
    done

    MENU_CURSOR=0

    # Without a terminal there are no keystrokes to read. Take the defaults and
    # say so, rather than blocking on a read that will never return.
    if [[ ! -t 0 ]]; then
        printf "${YELLOW}Not a terminal — using default component selection.${NC}\n"
    else
        # The cursor is hidden for the duration and restored however we leave,
        # including Ctrl-C: a terminal left without a cursor is a bad parting gift.
        printf '\033[?25l'
        trap 'printf "\033[?25h"' EXIT

        while true; do
            menu_render
            action=$(menu_read_key) || { printf '\033[?25h'; printf "\n${YELLOW}Cancelled${NC}\n"; exit 130; }
            case "$action" in
                up)    (( MENU_CURSOR > 0 )) && MENU_CURSOR=$(( MENU_CURSOR - 1 )) ;;
                down)  (( MENU_CURSOR < ${#MENU_ITEMS[@]} - 1 )) && MENU_CURSOR=$(( MENU_CURSOR + 1 )) ;;
                pgup)  MENU_CURSOR=$(( MENU_CURSOR - 5 )); (( MENU_CURSOR < 0 )) && MENU_CURSOR=0 ;;
                pgdn)  MENU_CURSOR=$(( MENU_CURSOR + 5 ))
                       (( MENU_CURSOR > ${#MENU_ITEMS[@]} - 1 )) && MENU_CURSOR=$(( ${#MENU_ITEMS[@]} - 1 )) ;;
                home)  MENU_CURSOR=0 ;;
                end)   MENU_CURSOR=$(( ${#MENU_ITEMS[@]} - 1 )) ;;
                space) menu_toggle_current ;;
                a|A)   for key in "${!MENU_STATE[@]}"; do MENU_STATE[$key]="y"; done ;;
                n|N)   for key in "${!MENU_STATE[@]}"; do MENU_STATE[$key]="n"; done ;;
                enter) menu_rewind; menu_render; break ;;
                q|Q)   printf '\033[?25h'; printf "${YELLOW}Cancelled${NC}\n"; exit 0 ;;
            esac
            menu_rewind
        done

        printf '\033[?25h'
        trap - EXIT
    fi

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
    # Sub-steps are meaningless when the parent is off; menu_parent_on() dims
    # them in the UI but does not clear them, so gate them here too.
    if [[ "${MENU_STATE[NETWORK_DDS]}" == "y" ]]; then
        export CONFIGURE_CYCLONEDDS_SYSCTL="${MENU_STATE[CYCLONEDDS_SYSCTL]}"
        export CONFIGURE_MULTICAST_LO="${MENU_STATE[MULTICAST_LO]}"
    else
        export CONFIGURE_CYCLONEDDS_SYSCTL="n"
        export CONFIGURE_MULTICAST_LO="n"
    fi
    export INSTALL_TURBOVNC_VIRTUALGL="${MENU_STATE[TURBOVNC_VIRTUALGL]}"
    export INSTALL_HARDWARE_CONFIG="${MENU_STATE[HARDWARE_CONFIG]}"
    export INSTALL_OTOCAM="${MENU_STATE[OTOCAM]}"
    export INSTALL_OPENCV="${MENU_STATE[OPENCV]}"
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

    # --dry-run drives the menu and prints what would be installed without
    # touching the machine. Worth having on its own terms, and it is the only
    # way to exercise the menu without running a multi-gigabyte install.
    if [[ "$1" == "--dry-run" ]]; then
        interactive_setup
        printf "${BLUE}Dry run — nothing installed. Selection:${NC}\n"
        local k
        for k in SKIP_AUTOWARE_DEBIAN AUTOWARE_PREREQ_ROS AUTOWARE_PREREQ_SPCONV \
                 SETUP_AUTOWARE_DATA BUILD_TENSORRT_ENGINES INSTALL_ISAAC_ROS \
                 INSTALL_OPENCV \
                 CONFIGURE_CYCLONEDDS_SYSCTL CONFIGURE_MULTICAST_LO \
                 INSTALL_TURBOVNC_VIRTUALGL \
                 INSTALL_HARDWARE_CONFIG INSTALL_OTOCAM INSTALL_LINUXPTP; do
            printf "  %-32s %s\n" "$k" "${!k}"
        done
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
