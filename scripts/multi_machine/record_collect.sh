#!/usr/bin/env bash
# record_collect.sh - bring one session's orin bag over and merge it with the
# master bag, so the session ends as a single merged_<ts> on this host.
#
#   record_collect.sh                          # newest master_<ts> here
#   record_collect.sh master_20260924_124734   # a given session
#
# `just record stop` runs this after both recorders have finalized; `just record
# collect` runs it on its own, for a stop that skipped it (merge=off, or the
# orin was unreachable at the time).
#
# PAIRING: the two recorders are separate units started one after the other by
# `just record start`, so their bag names carry their own start times, normally
# the same second and a few seconds apart at worst. The orin bag paired with a
# master bag is the one whose timestamp is nearest, and only if it is within
# MAX_SKEW_S. Anything further is a different session, and merging it would
# produce a bag that looks fine and interleaves two unrelated drives.
#
# Only unit-style names (<role>_YYYYMMDD_HHMMSS) are considered: a
# `just bag record NAME` bag is master_<ts>_NAME and has no orin counterpart.
#
# Idempotent: the fetch resumes and skips what is already here, and an existing
# merged_<ts> for the session is left alone.
#
# Environment:
#   GOLFCART_BAG_DIR        local bag directory (scripts/env.sh resolves it)
#   GOLFCART_ORIN_BAG_DIR   bag directory on the orin, relative to its home
#                           (default rosbags, as in bag_fetch_orin.sh)

set -eo pipefail

MAX_SKEW_S=60

REPO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." &> /dev/null && pwd)"
cd "${REPO_DIR}"

# ros2 for the merge, and the same GOLFCART_BAG_DIR the recorder unit wrote to.
GOLFCART_ENV_QUIET=1 source "${REPO_DIR}/scripts/env.sh"
export GOLFCART_BAG_DIR="${GOLFCART_BAG_DIR:-${HOME}/rosbags}"
BAG_DIR="${GOLFCART_BAG_DIR}"
REMOTE_DIR="${GOLFCART_ORIN_BAG_DIR:-rosbags}"

TS_RE='[0-9]{8}_[0-9]{6}'

# YYYYMMDD_HHMMSS -> epoch seconds
ts_epoch() {
    local ts="$1"
    date -d "${ts:0:8} ${ts:9:2}:${ts:11:2}:${ts:13:2}" +%s
}

# ── The master side ─────────────────────────────────────────────────────────
MASTER="${1:-}"
if [ -z "${MASTER}" ]; then
    shopt -s nullglob
    for candidate in "${BAG_DIR}"/master_*; do
        [[ "$(basename "${candidate}")" =~ ^master_${TS_RE}$ ]] || continue
        if [ -z "${MASTER}" ] || [ "${candidate}" -nt "${MASTER}" ]; then
            MASTER="${candidate}"
        fi
    done
    shopt -u nullglob
    if [ -z "${MASTER}" ]; then
        echo "record_collect: no master_<ts> bag in ${BAG_DIR}" >&2
        exit 1
    fi
elif [ ! -d "${MASTER}" ] && [ -d "${BAG_DIR}/${MASTER}" ]; then
    MASTER="${BAG_DIR}/${MASTER}"
fi
MASTER="${MASTER%/}"
MASTER_NAME="$(basename "${MASTER}")"

if ! [[ "${MASTER_NAME}" =~ ^master_(${TS_RE})$ ]]; then
    echo "record_collect: '${MASTER_NAME}' is not a master_<YYYYMMDD_HHMMSS> bag" >&2
    exit 2
fi
TS="${BASH_REMATCH[1]}"

# A 0-byte metadata.yaml is an unfinalized bag; convert cannot read it.
if [ ! -s "${MASTER}/metadata.yaml" ]; then
    echo "record_collect: ${MASTER} is not finalized (metadata.yaml missing or empty)" >&2
    exit 1
fi

MERGED="${BAG_DIR}/merged_${TS}"
if [ -e "${MERGED}" ]; then
    echo "record_collect: ${MERGED} already exists, nothing to do"
    exit 0
fi

# ── The orin side ───────────────────────────────────────────────────────────
# on_orin.sh cd's into the orin's checkout, so the listing is anchored at $HOME.
if ! ./scripts/multi_machine/on_orin.sh true 2>/dev/null; then
    echo "record_collect: cannot reach the orin; run \`just record collect ${MASTER_NAME}\` later" >&2
    exit 1
fi
# `|| true`: an orin with no bags yet makes ls exit non-zero.
REMOTE_LIST="$(./scripts/multi_machine/on_orin.sh \
    bash -c 'cd ~ && ls -1d "$1"/orin_*/ 2>/dev/null | xargs -r -n1 basename' _ "${REMOTE_DIR}" || true)"

MASTER_EPOCH="$(ts_epoch "${TS}")"
ORIN_NAME=""
BEST=""
while read -r name; do
    [[ "${name}" =~ ^orin_(${TS_RE})$ ]] || continue
    delta=$(( $(ts_epoch "${BASH_REMATCH[1]}") - MASTER_EPOCH ))
    delta=${delta#-}
    if [ -z "${BEST}" ] || (( delta < BEST )); then
        BEST="${delta}"
        ORIN_NAME="${name}"
    fi
done <<< "${REMOTE_LIST}"

if [ -z "${ORIN_NAME}" ] || (( BEST > MAX_SKEW_S )); then
    echo "record_collect: no orin bag within ${MAX_SKEW_S}s of ${MASTER_NAME}" >&2
    [ -n "${ORIN_NAME}" ] && echo "                nearest is ${ORIN_NAME} (${BEST}s away)" >&2
    exit 1
fi

echo "record_collect: pairing ${MASTER_NAME} with ${ORIN_NAME} (${BEST}s apart)"

# ── Fetch, then merge ───────────────────────────────────────────────────────
./scripts/multi_machine/bag_fetch_orin.sh "${ORIN_NAME}"

if [ ! -s "${BAG_DIR}/${ORIN_NAME}/metadata.yaml" ]; then
    echo "record_collect: ${ORIN_NAME} is not finalized (metadata.yaml missing or empty)" >&2
    exit 1
fi

# The merge rewrites the whole master bag - 13 GB for a few minutes of driving -
# so it is only worth it when the orin actually recorded something. /tf_static
# does not count: the recorder latches it whether or not the ZED is up.
ORIN_DATA="$(python3 - "${BAG_DIR}/${ORIN_NAME}/metadata.yaml" <<'PY'
import sys, yaml
info = yaml.safe_load(open(sys.argv[1]))["rosbag2_bagfile_information"]
print(sum(t["message_count"] for t in info["topics_with_message_count"]
          if t["topic_metadata"]["name"] != "/tf_static"))
PY
)"
if [ "${ORIN_DATA}" -eq 0 ]; then
    echo "record_collect: ${ORIN_NAME} recorded nothing but /tf_static; not merging" >&2
    echo "                (was the orin stack up? \`just service host-status\` on the orin)" >&2
    exit 1
fi

./scripts/multi_machine/bag_merge.sh -o "${MERGED}" "${MASTER}" "${BAG_DIR}/${ORIN_NAME}"
