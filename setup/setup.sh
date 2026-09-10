#!/usr/bin/env bash
# Golf cart setup: a launcher, and nothing else.
#
# This was 586 lines once, of which ~250 were a hand-written menu that re-forked
# `tput` and `cut` on every keystroke. That became a Python menu on Textual,
# which fixed the lag and cost a 15 MB venv plus ~54 s of uv bootstrapping on a
# cold first run. The menu is now `curses`, which is in the standard library, so
# there is no environment to build and nothing here to do but hand over.
#
#   ./setup.sh                pick a preset, then the steps
#   ./setup.sh --status       what is installed
#   ./setup.sh --list         every step, and whether it applies here
#   ./setup.sh --run --profile vehicle --yes
#   ./setup.sh --run --all --skip tensorrt-engines
#   ./setup.sh --rerun opencv
#   ./setup.sh --plain        numbered menu, for a terminal curses cannot drive

set -euo pipefail

# This file lives at setup/setup.sh; the repo root carries a symlink to it, so
# resolve the link before deriving anything from the path.
SETUP_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
MAIN="$SETUP_DIR/main.py"

if [[ "${1:-}" == "--reset-env" ]]; then
    # Kept only to clean up after the Textual era; setup has no venv now.
    if [[ -d "$SETUP_DIR/.venv" ]]; then
        rm -rf "$SETUP_DIR/.venv"
        printf 'Removed the old setup venv. Setup no longer uses one.\n'
    else
        printf 'Nothing to reset: setup runs on the system python3.\n'
    fi
    exit 0
fi

command -v python3 >/dev/null || {
    printf 'python3 not found (expected on Ubuntu 22.04)\n' >&2
    exit 1
}

exec python3 "$MAIN" "$@"
