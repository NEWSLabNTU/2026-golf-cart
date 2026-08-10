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
#   GOLFCART_ORIN_SSH   ssh destination (default jetson@192.168.125.101)
#   GOLFCART_BAG_DIR    local destination (default ~/rosbags)
#   GOLFCART_ORIN_BAG_DIR   remote source (default ~/rosbags on the orin)

set -eo pipefail

ORIN="${GOLFCART_ORIN_SSH:-jetson@192.168.125.101}"
LOCAL_DIR="${GOLFCART_BAG_DIR:-${HOME}/rosbags}"
REMOTE_DIR="${GOLFCART_ORIN_BAG_DIR:-rosbags}"

SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5)

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

for bag in "${SELECTED[@]}"; do
    echo
    echo "==> ${bag}"
    # -a preserves timestamps, which the bags' metadata is compared against;
    # --partial keeps a half-copied file so a re-run resumes instead of restarting.
    rsync -ah --partial "${PROGRESS[@]}" \
        -e "ssh ${SSH_OPTS[*]}" \
        "${ORIN}:${REMOTE_DIR}/${bag}/" \
        "${LOCAL_DIR}/${bag}/"
done

echo
echo "Done. Fetched into ${LOCAL_DIR}/"
echo "Nothing was deleted on the orin; remove the originals there once verified."
