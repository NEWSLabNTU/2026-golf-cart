#!/usr/bin/env bash
# record_aruco.sh — Record everything the ArUco indoor localizer needs, and
# nothing else.
#
# Usage:
#   just bag record-aruco                       # auto-named bag
#   just bag record-aruco bench_static_1board_3m
#   scripts/rosbag/record_aruco.sh bench_static_1board_3m
#
# COMPRESSED, not raw. Three 1920x1280 streams at 30 Hz is roughly 2 GB per
# minute raw, which fills a disk during a single session and, worse, makes the
# recorder drop frames. A dropped frame is invisible in the bag afterwards: it
# looks like the camera simply did not produce an image, and it is
# indistinguishable from a detection failure. The sensor kit only publishes the
# compressed topic anyway (`enable_pub_plugins: ["image_transport/compressed"]`),
# so there is no raw image to record even if you wanted one.
#
# camera_info is recorded ALONGSIDE the images on purpose. Calibration is applied
# downstream of the raw image, so a bag recorded before the intrinsics are
# finalised stays valid — but only if what was assumed at capture time is
# visible. Without it, a re-analysis six weeks later cannot tell whether a
# changed result came from the new calibration or from something else.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUTPUT_DIR="${REPO_ROOT}/rosbags"

SCENARIO="${1:-session}"
BAG_NAME="aruco_${SCENARIO}_$(date +%Y%m%d_%H%M%S)"
BAG_PATH="${OUTPUT_DIR}/${BAG_NAME}"

CAMERAS=(left right rear)

TOPICS=(
  /tf
  /tf_static
  /sensing/imu/imu_data
  # Zeros until the Turing Drive interface lands. Recorded anyway: a bag with a
  # flat velocity channel is still readable, a bag missing the channel entirely
  # cannot be replayed through the localizer at all.
  /vehicle/status/velocity_status
  /diagnostics
)
for camera in "${CAMERAS[@]}"; do
  TOPICS+=("/sensing/camera/${camera}/image_raw/compressed")
  TOPICS+=("/sensing/camera/${camera}/camera_info")
done

# If the detector is running, record what it saw. Not required — the bag is
# replayable through the detector afterwards — but having both makes it possible
# to tell a detector change from a data change.
for camera in "${CAMERAS[@]}"; do
  TOPICS+=("/sensing/camera/${camera}/aruco_detections")
done

mkdir -p "${OUTPUT_DIR}"

# Roughly 20 MB/minute per compressed 1080p stream at 30 Hz, three streams.
AVAILABLE_MB="$(df -Pm "${OUTPUT_DIR}" | awk 'NR==2 {print $4}')"
ESTIMATED_MB_PER_MIN=60
if [[ "${AVAILABLE_MB}" -lt $((ESTIMATED_MB_PER_MIN * 10)) ]]; then
  echo "WARNING: ${AVAILABLE_MB} MB free at ${OUTPUT_DIR}." >&2
  echo "         Roughly ${ESTIMATED_MB_PER_MIN} MB/min expected, so under ten minutes of headroom." >&2
  echo "         A recorder that runs out of disk drops frames silently." >&2
  echo >&2
fi

WORKSPACE_SETUP="${REPO_ROOT}/install/setup.bash"
if [[ -f "${WORKSPACE_SETUP}" ]]; then
  # shellcheck disable=SC1090
  source "${WORKSPACE_SETUP}"
fi

MISSING=()
PUBLISHED="$(ros2 topic list 2>/dev/null || true)"
for topic in "${TOPICS[@]}"; do
  if ! grep -qx -- "${topic}" <<<"${PUBLISHED}"; then
    MISSING+=("${topic}")
  fi
done

# Listed, not fatal: `ros2 bag record` happily records a topic that nobody
# publishes and produces an empty channel, which is exactly how a session gets
# recorded with no camera data and nobody notices until the drive home.
if [[ ${#MISSING[@]} -gt 0 ]]; then
  echo "These topics are NOT currently being published:" >&2
  printf '  %s\n' "${MISSING[@]}" >&2
  echo >&2
  echo "Recording will still start and their channels will be empty." >&2
  read -r -p "Continue anyway? [y/N] " reply
  [[ "${reply}" =~ ^[Yy]$ ]] || exit 1
  echo >&2
fi

NOTE_PATH="${BAG_PATH}.md"

echo "Recording to: ${BAG_PATH}"
echo "Topics: ${#TOPICS[@]}"
printf '  %s\n' "${TOPICS[@]}"
echo
echo "Write the sidecar note at ${NOTE_PATH} when you stop."
echo "Press Ctrl-C to stop recording."
echo

ros2 bag record -o "${BAG_PATH}" "${TOPICS[@]}"

# The single cheapest thing that makes a bag useful later. Written after the
# recording rather than before, so the scenario is described as it actually
# happened rather than as it was planned.
if [[ ! -f "${NOTE_PATH}" ]]; then
  cp "${REPO_ROOT}/scripts/rosbag/bag_note_template.md" "${NOTE_PATH}" 2>/dev/null || true
  echo
  echo "Sidecar note started at ${NOTE_PATH} — fill it in NOW, while you remember."
fi
