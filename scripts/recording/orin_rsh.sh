#!/usr/bin/env bash
# orin_rsh.sh - rsync's remote shell for the orin, through on_orin.sh.
#
#   rsync -a --rsh=scripts/recording/orin_rsh.sh orin:recordings/<id>/orin/ dest/
#
# rsync calls `RSH [-l user] HOST rsync --server ...`. The host word is dropped:
# on_orin.sh already knows how to reach the orin (config/multi_machine.conf, the
# dedicated key, BatchMode) and cd's into its checkout, so remote paths are
# relative to the orin's repo. GOLFCART_ON_ORIN replaces on_orin.sh (tests).
set -uo pipefail
REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." &> /dev/null && pwd)"
[ "${1:-}" = "-l" ] && shift 2
shift   # the host
exec "${GOLFCART_ON_ORIN:-${REPO_DIR}/scripts/multi_machine/on_orin.sh}" "$@"
