#!/usr/bin/env bash
# bag_merge.sh - merge per-host rosbags into a single bag.
#
# A session leaves a master_<ts> bag and an orin_<ts> bag. `ros2 bag convert`
# accepts repeated -i arguments and interleaves the messages by timestamp, which
# only produces something meaningful because chrony holds the two clocks within
# tens of microseconds of each other. Without that, the halves would be stitched
# together wrong and nothing would say so.
#
# Usage:
#   bag_merge.sh <bag> <bag> [bag ...]              # output next to the inputs
#   bag_merge.sh -o /path/to/merged <bag> <bag>
#
# The inputs are left untouched; the merge writes a new bag.
#
# Environment:
#   GOLFCART_BAG_DIR   where a relative bag name is looked up (default ~/rosbags)

set -eo pipefail

BAG_DIR="${GOLFCART_BAG_DIR:-${HOME}/rosbags}"
OUTPUT=""

while [ $# -gt 0 ]; do
    case "$1" in
      -o|--output) OUTPUT="$2"; shift 2 ;;
      -h|--help)
        echo "Usage: $0 [-o OUTPUT] <bag> <bag> [bag ...]" >&2
        exit 0
        ;;
      -*) echo "Unknown option: $1" >&2; exit 2 ;;
      *)  break ;;
    esac
done

if [ $# -lt 2 ]; then
    echo "Usage: $0 [-o OUTPUT] <bag> <bag> [bag ...]" >&2
    echo "Need at least two bags to merge." >&2
    exit 2
fi

INPUTS=()
for bag in "$@"; do
    # Accept either a path or a bare name relative to GOLFCART_BAG_DIR.
    if [ -d "${bag}" ]; then
        INPUTS+=("$(cd "${bag}" && pwd)")
    elif [ -d "${BAG_DIR}/${bag}" ]; then
        INPUTS+=("${BAG_DIR}/${bag}")
    else
        echo "ERROR: no such bag: ${bag}" >&2
        exit 1
    fi
done

if [ -z "${OUTPUT}" ]; then
    OUTPUT="$(dirname "${INPUTS[0]}")/merged_$(date +%Y%m%d_%H%M%S)"
fi

if [ -e "${OUTPUT}" ]; then
    echo "ERROR: output already exists: ${OUTPUT}" >&2
    exit 1
fi

# Refuse to start a merge that cannot finish: the output is roughly the sum of
# the inputs, and a full disk during a bag write is what corrupts them.
NEEDED=0
for bag in "${INPUTS[@]}"; do
    NEEDED=$(( NEEDED + $(du -sb "${bag}" | cut -f1) ))
done
AVAIL=$(( $(df -B1 --output=avail "$(dirname "${OUTPUT}")" | tail -1) ))
if (( AVAIL < NEEDED + NEEDED / 10 )); then
    echo "ERROR: need ~$(( NEEDED / 1024 / 1024 ))MB for the merge, only $(( AVAIL / 1024 / 1024 ))MB free" >&2
    echo "       at $(dirname "${OUTPUT}"). Point -o at the external SSD." >&2
    exit 1
fi

OPTIONS_FILE="$(mktemp -t golfcart-merge-XXXXXX.yaml)"
trap 'rm -f "${OPTIONS_FILE}"' EXIT

cat > "${OPTIONS_FILE}" <<EOF
output_bags:
- uri: ${OUTPUT}
  storage_id: sqlite3
  all: true
EOF

CONVERT_ARGS=()
for bag in "${INPUTS[@]}"; do
    # The storage id is given explicitly: bags recovered with `ros2 bag reindex`
    # carry an empty storage_id in their metadata, and convert will not infer it.
    CONVERT_ARGS+=(-i "${bag}" sqlite3)
done

echo "Merging ${#INPUTS[@]} bags into ${OUTPUT}"
printf '  %s\n' "${INPUTS[@]}"

ros2 bag convert "${CONVERT_ARGS[@]}" -o "${OPTIONS_FILE}"

echo
echo "Done: ${OUTPUT}"
ros2 bag info "${OUTPUT}" 2>/dev/null | sed -n '2,8p' || true
