#!/usr/bin/env bash
# Restricted-FOV study: how far can the top LiDAR's field of view be cut before
# NDT stops localizing?
#
# Motive: the vehicle is to carry a Seyond Robin-W solid-state LiDAR, which sees
# 120 deg horizontally against the sample bag's spinning 360 deg, and no Robin-W
# recording exists to test against. This crops the sample bag at decode time to
# stand in for one.
#
# READ docs/research/localization/restricted-fov-ndt.md BEFORE trusting a number
# from here. The emulation is partial, and which parts are honest is written
# down there, not in this script. In particular the arguments are SENSOR AZIMUTH,
# which runs opposite to vehicle bearing: bearing = 85 deg - azimuth, so azimuth
# 85 is straight ahead and azimuth 0 is 85 degrees to the left.
#
# Usage:
#   scripts/fov_study.sh <min_angle> <max_angle> <max_range> <label>
#   scripts/fov_study.sh 0 360 250.0 baseline
#
# The three knobs reach the sensor kit through the environment, because the
# installed tier4 sensing launch chain between here and the kit forwards a fixed
# set of arguments and drops everything else. See the comment block in
# tests/rosbag_replay/rosbag_sensor_kit_launch/launch/lidar.launch.xml.

set -eo pipefail

CAMPAIGN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# This campaign lives in the superproject but drives the cuda_ndt_matcher
# submodule's replay harness, so both roots are resolved rather than assumed.
ROOT="$(git -C "$CAMPAIGN_DIR" rev-parse --show-toplevel)"
PROJECT_DIR="$ROOT/src/localization/cuda_ndt_matcher"
SCRIPT_DIR="$PROJECT_DIR/scripts"
AUTOWARE_ACTIVATE="$SCRIPT_DIR/activate_autoware.sh"

MIN_ANGLE="${1:?min angle in degrees}"
MAX_ANGLE="${2:?max angle in degrees}"
MAX_RANGE="${3:?max range in metres}"
LABEL="${4:?run label}"

# The decoder cuts scans at scan_phase, so a phase outside the retained window
# means the boundary is never reached and the top sensor publishes nothing at
# all. Pin it to the start of the window. Overridable, but there is no known
# reason to want it elsewhere.
#
# The phase is necessary and NOT sufficient. A window also has to contain
# azimuth 0 or azimuth 300 to produce any cloud at all -- the azimuth counter's
# wrap, and the cut this bag was recorded at. Windows such as 25..145 stay empty
# at every phase. Since azimuth 85 is straight ahead, that means a forward-facing
# wedge cannot be cut here at all; see the doc for the consequence.
#
# CHECK EVERY RUN with scripts/localization/fov_azimuth_probe.py. An empty top
# sensor does not announce itself: the stack stays up and NDT keeps publishing,
# because the rig's two VLP16s ignore this crop entirely.
export NDT_FOV_SCAN_PHASE="${NDT_FOV_SCAN_PHASE:-$MIN_ANGLE.0}"
export NDT_FOV_MIN_ANGLE="$MIN_ANGLE"
export NDT_FOV_MAX_ANGLE="$MAX_ANGLE"
export NDT_FOV_MAX_RANGE="$MAX_RANGE"

OUT_DIR="$ROOT/data/fov_study/$LABEL"
rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"

# Each run gets its own debug file. The default is a fixed path in /tmp, so a
# sweep would otherwise interleave every run's JSONL into one file and the
# per-run timings would be unreadable.
export NDT_DEBUG_FILE="$OUT_DIR/ndt_debug.jsonl"

# A distinct readiness flag per run, for the same reason: a stale flag from the
# previous run makes the player start against a stack that is not up.
export NDT_READY_FILE="/tmp/ndt_sim_ready_fov_$LABEL"
rm -f "$NDT_READY_FILE"

echo "=== FOV run '$LABEL': azimuth ${MIN_ANGLE}..${MAX_ANGLE} deg, range ${MAX_RANGE} m ==="

"$SCRIPT_DIR/run_demo.sh" --cuda \
    "$PROJECT_DIR/data/sample-map" \
    "$PROJECT_DIR/data/sample-rosbag-fixed" \
    "$OUT_DIR" 2>&1 | tee "$OUT_DIR/run.log"

echo "=== '$LABEL' done, output in $OUT_DIR ==="
