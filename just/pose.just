# Initial pose per map, instead of a click in RViz
#
# When RTK is not solid the GNSS initializer seeds NDT somewhere wrong, and the
# fix is a 2D Pose Estimate in RViz. This replaces the click with a pose
# captured once at a known start spot:
#
#   just launch map_path:=./data/ntu-campus-planning/r01   # stack on that map
#   # first time only, at the spot: click once in RViz, let NDT settle, then
#   just pose capture ntu-r01 gate
#   # every time after, parked at the same spot:
#   just pose init ntu-r01 gate
#
# Poses live in config/initial_poses/<map>/<spot>.yaml; a map is any directory
# there with a map.yaml naming its data directory. `init` refuses a pose that
# falls outside the map, or a map the running stack did not load. It calls
# /localization/initialize with method AUTO, so NDT refines the seed, and it
# works with the default pose_initializer:=gnss.
#
# Recipes here run from the REPO ROOT, not from just/.
set working-directory := '..'

# List this module's recipes
default:
    @just --list pose

# Seed localization from a captured spot. Park on the spot first.
init MAP SPOT:
    python3 ./scripts/localization/set_initial_pose.py --map {{MAP}} {{SPOT}}

# Save the current converged pose as a spot on MAP
capture MAP SPOT:
    python3 ./scripts/localization/capture_initial_pose.py --map {{MAP}} {{SPOT}}

# Maps and the spots captured on each
list:
    #!/usr/bin/env bash
    set -euo pipefail
    for d in config/initial_poses/*/; do
        [ -f "$d/map.yaml" ] || continue
        m=$(basename "$d")
        spots=$(find "$d" -maxdepth 1 -name '*.yaml' ! -name map.yaml -printf '%f\n' | sed 's/\.yaml$//' | sort | tr '\n' ' ')
        printf '%-10s %-34s %s\n' "$m" "$(sed -n 's/^map_path: //p' "$d/map.yaml")" "${spots:-(no spots yet)}"
    done
