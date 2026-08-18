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
