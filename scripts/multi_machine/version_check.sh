#!/usr/bin/env bash
# version_check.sh - can this host run Autoware VERSION from this checkout?
#
#   scripts/multi_machine/version_check.sh VERSION
#
# `just up` runs it here and, through on_orin.sh, on the orin, before it starts
# anything: both hosts must run the same Autoware (DiagNodeStatus, which crosses
# the link, changed between 1.5.0 and 2.1.0), so a version one host cannot run
# stops the start rather than leaving one side down.
#
# Checks /opt/autoware/VERSION/setup.bash (the packages) and
# install-VERSION/local_setup.bash (this checkout built against them). Prints
# one line per miss with its fix. Exit 0 ready, 1 not, 2 usage.
set -uo pipefail

VER="${1:-}"
[[ "${VER}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: $(basename "$0") X.Y.Z" >&2; exit 2; }

REPO="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
HOST="$(hostname)"
rc=0
if [ ! -f "/opt/autoware/${VER}/setup.bash" ]; then
    echo "${HOST}: Autoware ${VER} is not installed (no /opt/autoware/${VER}/setup.bash)." >&2
    echo "${HOST}:   fix: GOLFCART_AUTOWARE_VERSION=${VER} ./setup.sh --only autoware-debian" >&2
    rc=1
fi
if [ ! -f "${REPO}/install-${VER}/local_setup.bash" ]; then
    echo "${HOST}: this checkout is not built for Autoware ${VER} (no ${REPO}/install-${VER}/)." >&2
    echo "${HOST}:   fix: GOLFCART_AUTOWARE_VERSION=${VER} just build" >&2
    rc=1
fi
[ "${rc}" -eq 0 ] && echo "${HOST}: Autoware ${VER} ready"
exit "${rc}"
