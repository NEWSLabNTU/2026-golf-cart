#!/usr/bin/env bash
# record_indoor_mapping.sh — Record the indoor mapping run for phase 3B.
#
# Feeds two consumers with one drive:
#   * GLIM offline LiDAR-inertial SLAM  -> PCD map        (LiDAR + IMU)
#   * Phase 3C tag-map bootstrap        -> Lanelet2 tags  (cameras)
#
# See docs/design/indoor_pcd_mapping_reflector_anchor.md §6.1 and
# docs/roadmaps/3-indoor-b-indoor-mapping.md.
#
# Differences from record_outdoor.sh, both deliberate:
#   * No GNSS topics. Indoors they carry nothing, and recording them invites a
#     downstream tool to trust a fix that does not exist.
#   * pointcloud_raw_ex is mandatory, not optional: it is the only topic
#     carrying intensity (board detection) and per-point time (deskew).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUTPUT_DIR="${GOLFCART_BAG_DIR:-${REPO_ROOT}/rosbags}"
BAG_NAME="indoor_mapping_$(date +%Y%m%d_%H%M%S)"

TOPICS=(
  # LiDAR — raw_ex carries intensity and per-point timestamps. GLIM needs the
  # per-point time to deskew; the board detector needs the intensity.
  /sensing/lidar/top/pointcloud_raw_ex
  /sensing/lidar/velodyne_packets

  # IMU — raw, so the offline pipeline applies its own bias handling rather
  # than inheriting the runtime corrector's.
  /sensing/imu/imu_raw

  # Cameras. Mapping does not use them; phase 3C replays this same bag to
  # bootstrap the tag map, so the tags must already be mounted for this drive.
  # Compressed only — the raw streams are far too large to sustain.
  # No camera_info: gscam publishes none for these, so phase 3C must take
  # intrinsics from the sub-phase A calibration files rather than from the bag.
  /sensing/camera/left/image_raw/compressed
  /sensing/camera/right/image_raw/compressed
  /sensing/camera/rear/image_raw/compressed

  # Vehicle status, for reference during processing. Note velocity_report is
  # still a DBW stub publishing zeros — do not feed it to anything.
  /vehicle/status/velocity_status
  /vehicle/status/steering_status
  /diagnostics

  /tf
  /tf_static
)

mkdir -p "$OUTPUT_DIR"

cat <<EOF
Recording indoor mapping bag: $OUTPUT_DIR/$BAG_NAME
Topics: ${#TOPICS[@]}

Before starting, confirm:
  * The reflective board is mounted and will stay mounted. It defines the map
    origin; moving it later invalidates the map without any visible error.
  * Tags for phase 3C are in place.
  * The route closes its loops, and passes the board at the start, mid-run,
    and end.
  * Speed stays at or below 1 m/s, with smooth steering.
  * No pedestrians in the space — they survive into the map as smeared walls.

Press Ctrl-C to stop.

EOF

printf '  %s\n' "${TOPICS[@]}"
echo

WORKSPACE_SETUP="${REPO_ROOT}/install/setup.bash"
if [[ -f "$WORKSPACE_SETUP" ]]; then
    # shellcheck disable=SC1090
    source "$WORKSPACE_SETUP"
fi

ros2 bag record -o "$OUTPUT_DIR/$BAG_NAME" "${TOPICS[@]}"
