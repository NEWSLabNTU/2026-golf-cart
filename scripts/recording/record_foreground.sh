#!/usr/bin/env bash
# record_foreground.sh - a one-host recording session in this terminal.
#
# Usage: scripts/recording/record_foreground.sh [NAME] [SCOPE] [--can IFACE...]
#        just bag record [NAME]          scope ros: this host's topic list
#        just can record [IFACE]         scope can: CAN only
#
# The terminal counterpart of golfcart-record.service (`just record start`):
# the same runner (scripts/recording/session.py), the same scopes
# (config/recording/scopes.yaml), the same layout, recordings/<id>/<role>/,
# with id YYYYmmdd_HHMMSS[_NAME]. There is no second list to keep in step.
#
# The role is the one scripts/env.sh resolves for this checkout (config/host).
# Under master or orin it records that host's half of the scope. Any other role
# is one machine running everything, so it records the union (both topic lists).
#
# Ctrl-C stops it: the runner sends each recorder one SIGINT and waits for the
# bag to finalize. Ctrl-C once, then wait.

set -eo pipefail
# No `set -u`: the ROS setup chain that env.sh sources reads unbound variables.

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
NAME="${1:-}"
SCOPE="${2:-ros}"
shift 2 2>/dev/null || shift $#

cd "${REPO_ROOT}"
export GOLFCART_ENV_QUIET=1
# shellcheck source=/dev/null
source "${REPO_ROOT}/scripts/env.sh"

SID="$(python3 scripts/recording/session.py new-id "${NAME}")" || exit 2
python3 scripts/recording/session.py preflight --scope "${SCOPE}" || exit 1
echo "session ${SID} (scope ${SCOPE}) -> ${REPO_ROOT}/recordings/${SID}/  Ctrl-C to stop."

# exec: the runner owns the terminal's SIGINT and forwards exactly one to each
# recorder, which runs in its own process group.
exec python3 scripts/recording/session.py run --id "${SID}" --scope "${SCOPE}" "$@"
