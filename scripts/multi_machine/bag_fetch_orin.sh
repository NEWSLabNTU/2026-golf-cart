#!/usr/bin/env bash
# bag_fetch_orin.sh - copy the orin's rosbags to the master over the LAN.
#
# The two hosts record separately to their own disks (the shared 100 Mb/s link
# cannot carry full-rate image topics), so a session leaves a master_<ts> bag here
# and an orin_<ts> bag there. This brings the orin's side over for analysis.
#
# Usage:
#   bag_fetch_orin.sh              # fetch every orin bag not already here
#   bag_fetch_orin.sh --latest     # fetch only the newest one
#   bag_fetch_orin.sh --list       # show what is on the orin, copy nothing
#   bag_fetch_orin.sh <name>       # fetch one bag by directory name
#
# Nothing is ever deleted from the orin: rsync runs without --remove-source-files
# so an interrupted transfer can simply be re-run. Clean the orin up by hand once
# you have checked the copies.
#
# Environment:
#   GOLFCART_ORIN_SSH   ssh destination, overrides ORIN_SSH from
#                       config/multi_machine.conf (default jetson@192.168.125.101)
#   GOLFCART_BAG_DIR    local destination (default ~/rosbags)
#   GOLFCART_ORIN_BAG_DIR   remote source (default ~/rosbags on the orin)

set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONF="${REPO_ROOT}/config/multi_machine.conf"
# One tracked copy of the destination, shared with on_orin.sh and the
# watchdog; an absent conf falls through to the same default it ships with.
# shellcheck source=/dev/null
[ -f "${CONF}" ] && . "${CONF}"

ORIN="${ORIN_SSH:-${GOLFCART_ORIN_SSH:-jetson@192.168.125.101}}"
LOCAL_DIR="${GOLFCART_BAG_DIR:-${HOME}/rosbags}"
REMOTE_DIR="${GOLFCART_ORIN_BAG_DIR:-rosbags}"

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5)

# Dedicated golf cart key at a fixed, non-default path (see config/multi_machine.conf).
# ssh only tries the default id_* names on its own, so it has to be named here;
# added only when present so a host without it keeps its previous behaviour.
# Note this also reaches rsync, which is invoked as `-e "ssh ${SSH_OPTS[*]}"`.
ORIN_KEY="${ORIN_SSH_KEY:-${GOLFCART_ORIN_SSH_KEY:-${HOME}/.ssh/golfcart_orin}}"
[ -f "${ORIN_KEY}" ] && SSH_OPTS+=(-i "${ORIN_KEY}")

remote_bags() {
    # -d with a trailing slash lists the directories themselves, not contents.
    ssh "${SSH_OPTS[@]}" "${ORIN}" \
        "ls -1dt ${REMOTE_DIR}/orin_*/ 2>/dev/null | sed 's:/*\$::' | xargs -r -n1 basename"
}

if ! ssh "${SSH_OPTS[@]}" "${ORIN}" true 2>/dev/null; then
    echo "ERROR: cannot reach ${ORIN}." >&2
    echo "       Check the link, and that key-based ssh is set up (ssh-copy-id)." >&2
    exit 1
fi

mapfile -t BAGS < <(remote_bags)

if (( ${#BAGS[@]} == 0 )); then
    echo "No orin_* bags found in ${ORIN}:${REMOTE_DIR}/"
    exit 0
fi

case "${1:-}" in
  --list)
    echo "Bags on ${ORIN}:${REMOTE_DIR}/ (newest first):"
    ssh "${SSH_OPTS[@]}" "${ORIN}" "du -sh ${REMOTE_DIR}/orin_*/ 2>/dev/null" | sort -k2
    exit 0
    ;;
  --latest)
    SELECTED=("${BAGS[0]}")
    ;;
  "")
    SELECTED=("${BAGS[@]}")
    ;;
  -*)
    echo "Usage: $0 [--latest|--list|<bag-name>]" >&2
    exit 2
    ;;
  *)
    SELECTED=("$1")
    ;;
esac

mkdir -p "${LOCAL_DIR}"
echo "Fetching ${#SELECTED[@]} bag(s) from ${ORIN} into ${LOCAL_DIR}/"

# --info=progress2 rewrites one line with \r, which is useful on a terminal and
# unreadable in a log or CI capture, where every update lands on its own line.
if [ -t 1 ]; then
    PROGRESS=(--info=progress2)
else
    PROGRESS=()
fi

# Verify a fetched bag really arrived intact.
#
# `ros2 bag info` is NOT sufficient: it reads metadata.yaml and never opens the
# database, so a truncated .db3 reports full message counts and looks healthy. A
# fetch that ran while the destination filesystem was full produced exactly that,
# and the corruption only surfaced later in `ros2 bag convert`:
#   database disk image is malformed
verify_bag() {
    local bag="$1"
    local remote_size local_size

    remote_size=$(ssh "${SSH_OPTS[@]}" "${ORIN}" "du -sb ${REMOTE_DIR}/${bag} | cut -f1" 2>/dev/null)
    local_size=$(du -sb "${LOCAL_DIR}/${bag}" 2>/dev/null | cut -f1)

    if [ -n "${remote_size}" ] && [ "${remote_size}" != "${local_size}" ]; then
        echo "    FAILED: size mismatch - remote ${remote_size}B, local ${local_size}B" >&2
        return 1
    fi

    # No sqlite3 CLI on these hosts; python3's stdlib module does the same job.
    local db
    for db in "${LOCAL_DIR}/${bag}"/*.db3; do
        [ -e "${db}" ] || continue
        if ! python3 - "${db}" <<'PY'
import sqlite3, sys
try:
    con = sqlite3.connect(f"file:{sys.argv[1]}?mode=ro", uri=True)
    result = con.execute("PRAGMA quick_check").fetchone()[0]
    con.close()
except Exception as exc:
    print(f"    FAILED: {exc}", file=sys.stderr)
    sys.exit(1)
if result != "ok":
    print(f"    FAILED: quick_check said {result}", file=sys.stderr)
    sys.exit(1)
PY
        then
            return 1
        fi
    done

    echo "    verified: size matches, database intact"
    return 0
}

FAILED=()

for bag in "${SELECTED[@]}"; do
    echo
    echo "==> ${bag}"
    # -a preserves timestamps, which the bags' metadata is compared against;
    # --partial keeps a half-copied file so a re-run resumes instead of restarting.
    if ! rsync -ah --partial "${PROGRESS[@]}" \
        -e "ssh ${SSH_OPTS[*]}" \
        "${ORIN}:${REMOTE_DIR}/${bag}/" \
        "${LOCAL_DIR}/${bag}/"; then
        echo "    FAILED: rsync error" >&2
        FAILED+=("${bag}")
        continue
    fi
    verify_bag "${bag}" || FAILED+=("${bag}")
done

echo
if (( ${#FAILED[@]} > 0 )); then
    echo "FAILED to fetch ${#FAILED[@]} bag(s) intact:" >&2
    printf '  %s\n' "${FAILED[@]}" >&2
    echo "The originals on the orin are untouched - re-run to resume." >&2
    exit 1
fi

echo "Done. Fetched into ${LOCAL_DIR}/"
echo "Nothing was deleted on the orin; remove the originals there once verified."
