#!/usr/bin/env bash
# collect.sh - copy the orin's half of a recording session to this host.
#
#   collect.sh [ID] [merge=on|off]        ID defaults to the newest session here
#
# rsync, resumable (--partial; a rerun after a dropped link continues), from the
# orin's recordings/<id>/orin/ into this host's recordings/<id>/orin/, over
# on_orin.sh (scripts/recording/orin_rsh.sh), then a size check of every file
# against the orin's own listing. Never deletes anything on the orin.
#
# merge=on also merges master/bag and orin/bag into recordings/<id>/merged/ with
# scripts/multi_machine/bag_merge.sh (both must be finalized).
#
# Environment: GOLFCART_ON_ORIN replaces scripts/multi_machine/on_orin.sh, so
# the two-host flow can be tested against a second local checkout.
set -uo pipefail

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." &> /dev/null && pwd)"
cd "${REPO_DIR}"
ON_ORIN="${GOLFCART_ON_ORIN:-${REPO_DIR}/scripts/multi_machine/on_orin.sh}"
REC="${GOLFCART_RECORDINGS_DIR:-${REPO_DIR}/recordings}"

SID=""
MERGE=off
for a in "$@"; do
    case "$a" in
        merge=on|merge=true)   MERGE=on ;;
        merge=off|merge=false) MERGE=off ;;
        "") ;;
        *) SID="$a" ;;
    esac
done
if [ -z "${SID}" ]; then
    SID="$(python3 scripts/recording/session.py newest-id)" || {
        echo "collect: no session in ${REC}" >&2; exit 1; }
fi
if ! [[ "${SID}" =~ ^[0-9]{8}_[0-9]{6}(_[A-Za-z0-9-]+)?$ ]]; then
    echo "collect: '${SID}' is not a session id (YYYYmmdd_HHMMSS[_NAME])" >&2
    exit 2
fi

# The orin's listing, from its own disk: relative path <TAB> size. Plain find and
# sed, so this works whatever the orin's checkout version is.
LISTING="$("${ON_ORIN}" bash -c '
    d="recordings/$1/orin"
    [ -d "$d" ] || { echo "MISSING"; exit 0; }
    echo "STATE $(sed -n "s/^state: //p" "$d/session.yaml" 2>/dev/null)"
    cd "$d" && find . -type f ! -name "*.tmp" -printf "%P\t%s\n"' _ "${SID}")" || {
    echo "collect: cannot reach the orin; run \`just record collect ${SID}\` later" >&2
    exit 1; }
if [ "${LISTING}" = "MISSING" ]; then
    echo "collect: the orin has no recordings/${SID}/orin/" >&2
    exit 1
fi
STATE="$(sed -n 's/^STATE //p' <<< "${LISTING}")"
case "${STATE}" in
    stopped|ended|failed) ;;
    *) echo "collect: the orin's half is '${STATE:-unknown}', not stopped; \`just record stop\` first" >&2
       exit 1 ;;
esac

DEST="${REC}/${SID}/orin"
mkdir -p "${DEST}"
echo "collect: orin:recordings/${SID}/orin/ -> ${DEST}/"
# -a keeps mtimes, so a rerun skips what is complete; --partial keeps a half-copied
# file so the rerun continues it.
rsync -a --partial --info=progress2,stats0 \
    --rsh="${REPO_DIR}/scripts/recording/orin_rsh.sh" \
    "orin:recordings/${SID}/orin/" "${DEST}/" || {
    echo "collect: rsync failed; rerun to resume: just record collect ${SID}" >&2; exit 1; }

BAD=0; N=0; TOTAL=0
while IFS=$'\t' read -r rel size; do
    [ -n "${rel}" ] || continue
    N=$((N + 1)); TOTAL=$((TOTAL + size))
    have=$(stat -c %s "${DEST}/${rel}" 2>/dev/null || echo missing)
    if [ "${have}" != "${size}" ]; then
        echo "collect: SIZE MISMATCH ${rel}: orin ${size}, here ${have}" >&2
        BAD=1
    fi
done < <(grep -v '^STATE ' <<< "${LISTING}")
[ "${BAD}" -eq 0 ] || exit 1
echo "collect: ${N} files, $((TOTAL / 1000000)) MB, sizes match the orin's"

if [ "${MERGE}" = on ]; then
    M="${REC}/${SID}/master/bag" O="${DEST}/bag" OUT="${REC}/${SID}/merged"
    for b in "$M" "$O"; do
        [ -s "$b/metadata.yaml" ] || { echo "collect: $b is not a finalized bag; not merging" >&2; exit 1; }
    done
    if [ -e "${OUT}" ]; then
        echo "collect: ${OUT} already exists"
    else
        GOLFCART_ENV_QUIET=1 source scripts/env.sh >/dev/null 2>&1
        ./scripts/multi_machine/bag_merge.sh -o "${OUT}" "$M" "$O"
    fi
fi
