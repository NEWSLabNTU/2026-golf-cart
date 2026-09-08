#!/usr/bin/env bash
# Golf cart setup: bootstrap only.
#
# This script does one thing -- make a Python environment exist -- and hands off
# to setup/main.py. It is the only part that must run with no dependencies at
# all, so it stays small and deliberately dull.
#
# The previous version was 586 lines, of which ~250 were a hand-written menu:
# viewport scrolling, cursor rewind arithmetic, and an escape-sequence decoder,
# re-forking `tput` and `cut` on every keystroke. That is what made it laggy, and
# it is why the menu lives in Python now.
#
#   ./setup.sh                open the menu
#   ./setup.sh --status       what is installed  (no venv needed)
#   ./setup.sh --list         every step and whether it applies here
#   ./setup.sh --profile vehicle --yes
#   ./setup.sh --rerun opencv
#   ./setup.sh --reset-env    rebuild the venv, then exit

set -euo pipefail

# This file lives at setup/setup.sh; the repo root carries a symlink to it, so
# resolve the link before deriving anything from the path.
SETUP_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
VENV="$SETUP_DIR/.venv"
MAIN="$SETUP_DIR/main.py"

RED='\033[0;31m'; YELLOW='\033[0;33m'; BLUE='\033[0;34m'; NC='\033[0m'

die() { printf "${RED}✗${NC} %s\n" "$1" >&2; exit 1; }

# These read state and never import anything outside the standard library, so
# they must keep working when the venv is the thing that is broken -- which is
# exactly when someone needs to see what state the machine is in.
for arg in "$@"; do
    case "$arg" in
        --status|--list|--help|-h)
            exec python3 "$MAIN" "$@" ;;
    esac
done

if [[ "${1:-}" == "--reset-env" ]]; then
    rm -rf "$VENV"
    printf "${YELLOW}→${NC} Removed %s\n" "$VENV"
    printf "Run ./setup.sh again to rebuild it.\n"
    exit 0
fi

command -v python3 >/dev/null || die "python3 not found (expected on Ubuntu 22.04)"

# uv rather than python3 -m venv: one static binary, no system Python packages
# to install first, and resolves in seconds. If it is already here, say nothing.
UV="$(command -v uv || true)"
if [[ -z "$UV" ]]; then
    [[ -x "$HOME/.local/bin/uv" ]] && UV="$HOME/.local/bin/uv"
fi
if [[ -z "$UV" ]]; then
    printf "${BLUE}→${NC} Installing uv (Python environment manager)...\n"
    curl -LsSf https://astral.sh/uv/install.sh | sh >/dev/null 2>&1 \
        || die "could not install uv -- check network access"
    UV="$HOME/.local/bin/uv"
    [[ -x "$UV" ]] || die "uv installed but not at $UV"
fi

# Rebuild whenever requirements change: the stamp holds the file's hash, so an
# edited requirements.txt is picked up without anyone remembering to reset.
REQ="$SETUP_DIR/requirements.txt"
STAMP="$VENV/.requirements-sha"
WANT="$(sha256sum "$REQ" | cut -d' ' -f1)"
if [[ ! -x "$VENV/bin/python" ]] || [[ "$(cat "$STAMP" 2>/dev/null || true)" != "$WANT" ]]; then
    printf "${BLUE}→${NC} Preparing the setup environment...\n"
    "$UV" venv --quiet "$VENV" || die "could not create $VENV"
    VIRTUAL_ENV="$VENV" "$UV" pip install --quiet -r "$REQ" \
        || die "could not install setup dependencies -- try ./setup.sh --reset-env"
    printf '%s' "$WANT" > "$STAMP"
fi

exec "$VENV/bin/python" "$MAIN" "$@"
