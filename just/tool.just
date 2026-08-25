# Development and monitoring tools
#
# Recipes here run from the REPO ROOT, not from just/. Without this a module
# recipe runs with its cwd set to this directory, and every `./scripts/...` path
# in the repo breaks with "not found".
set working-directory := '..'

# just runs a module's FIRST recipe when the module is named with no recipe,
# so without this `just vehicle` would bring up the vehicle interface and
# `just ntu-test` would start a bag. Naming it `default` makes the harmless
# thing the accident.
# List this module's recipes
default:
    @just --list tool

# Launch RViz with Golf Cart configuration
rviz:
    rviz2 -d ./src/launcher/golfcart_launch/rviz/golfcart.rviz

# Check sensor transforms: cameras and LiDARs on one sphere at base_link
sphere:
    # Read-only. LCTK computes the extrinsics; this shows what the running
    # system believes them to be, so a wrong one is visible rather than
    # computed. docs/guides/sphere_sensor_view.md says how to read it.
    rviz2 -d ./src/tools/golfcart_sphere_view/config/sphere_view.rviz

# The sphere view against synthetic sensors, with no vehicle attached
sphere-demo:
    #!/usr/bin/env bash
    # Three cameras and a wall with a doorway in it. For working on the display
    # itself: it proves nothing about any real calibration, because the
    # synthetic sensors agree with each other by construction.
    set -euo pipefail
    PACKAGE=./src/tools/golfcart_sphere_view
    python3 "$PACKAGE/test/fake_camera.py" &
    CAMERAS=$!
    python3 "$PACKAGE/test/fake_lidar.py" &
    LIDAR=$!
    # Kill the publishers however RViz exits, including a Ctrl-C that lands on
    # the whole process group.
    trap 'kill $CAMERAS $LIDAR 2>/dev/null || true' EXIT
    rviz2 -d "$PACKAGE/test/sphere_view_demo.rviz"

# Launch PlotJuggler for data visualization
plotjuggler:
    ros2 run plotjuggler plotjuggler

# Launch drive monitor TUI (shows pose, speed, component states)
tui:
    python3 ./scripts/testing/drive/run.py

# ============================================================================
# Vehicle Interface - standalone bring-up and bench testing

# Launch manual keyboard control
controller:
    ros2 run control_test keyboard_control
