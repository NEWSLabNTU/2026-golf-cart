# Indoor cold-start replay: the reflective board seeds NDT, no GNSS.
#
# D1a of docs/roadmaps/7-reflective-board-cold-start.md. Run these in order,
# each in its own terminal (bag, up and rviz stay running):
#
#   just indoor-test bag         # 1. bag PAUSED -- publishes /clock only
#   just indoor-test up          # 2. stack, sensor drivers off, no RViz
#   just indoor-test rviz        # 3. RViz on bag time, map visible
#   just indoor-test resume      # 4. let the scans flow, watch the service call
#   just indoor-test down        # stop everything
#
# There is no `init` step, unlike ntu-test: the board detector IS the init.
# Success is /localization/board_detector/board_pose being published while the
# cart is stopped near the board, and board_pose_initializer logging the align
# result of its /localization/initialize call. This bag has no velocity in it,
# so the replay proves initialization and nothing after it; see the header of
# indoor_logging_sim.launch.xml.
#
# The order is not cosmetic: the bag leads so everything after it is born on
# bag time. See the comment at the top of scripts/rosbag/indoor_sim_bag.sh.
#
# Recipes here run from the REPO ROOT, not from just/. Without this a module
# recipe runs with its cwd set to this directory, and every `./scripts/...`
# path in the repo breaks with "not found".
set working-directory := '..'

# just runs a module's FIRST recipe when the module is named with no recipe,
# so this is `default` on purpose: `just indoor-test` lists, it does not start
# a bag.
# List this module's recipes
default:
    @just --list indoor-test

# Runs the steps above in the one order that works, waiting on each stage
# rather than sleeping, then holds until Ctrl-C and tears everything down.
#
#   just indoor-test run                    # with RViz
#   just indoor-test run rviz=off
#   just indoor-test run on "pose_source:=cuda_ndt"
# Run the whole indoor cold-start replay end to end (bag, stack, RViz, resume)
run RVIZ="on" ARGS="":
    ./scripts/rosbag/indoor_sim_run.sh {{RVIZ}} {{ARGS}}

# The bag path is GOLFCART_INDOOR_BAG, defaulting to the NAS copy of vlp32_1.
# just --list shows only the LAST comment line, so the description goes here.
# 1. Start the basement bag PAUSED, publishing /clock only.
bag ARGS="":
    ./scripts/rosbag/indoor_sim_bag.sh {{ARGS}}

# play_launch with its Python parser, as the rest of the repo runs. Two things
# to know before changing either half. The parser: at 0.10.0 the Rust one dies
# on this stack with `KeyError: 'rear_overhang'` from an Autoware .launch.py
# (play_launch issue #0028; the older refusal of the repo's escaped-quote
# `$(eval ...)` conditions was #0027, fixed in 0.10.0), so Python it is. The
# version: play_launch 0.8.2 rendered the pose
# initializer's array parameters (output_pose_covariance and friends, loaded
# with allow_substs) as STRINGS, autoware_pose_initializer_node died at
# startup with InvalidParameterTypeException, and /localization/initialize,
# the one service this replay exists to call, never appeared. Fixed in
# play_launch 0.10.0 (f78745da, pinned by tests in cdffdc43); measured on
# this launch 2026-09-11. Below that version, use stock ros2 launch:
#
#   ros2 launch golfcart_launch indoor_logging_sim.launch.xml rviz:=false
#
# Pass launch arguments through ARGS, e.g. "pose_initializer:=gnss" to check
# that the default starts neither board node.
# 2. Bring up the indoor logging simulation (sensor drivers off, no RViz).
up ARGS="":
    play_launch launch --parser python --web-addr 0.0.0.0:8081 \
        --container-mode "${GOLFCART_CONTAINER_MODE:-observable}" \
        golfcart_launch indoor_logging_sim.launch.xml rviz:=false {{ARGS}}

# 3. RViz with the point cloud map rendered visibly, on bag time.
rviz:
    ./scripts/rosbag/indoor_sim_rviz.sh

# 4. Release the paused player so the scans start flowing.
resume:
    ros2 service call /rosbag2_player/resume rosbag2_interfaces/srv/Resume

# Pause playback again (to inspect a frame).
pause:
    ros2 service call /rosbag2_player/pause rosbag2_interfaces/srv/Pause

# Static base_link -> velodyne from sensor_kit_calibration.yaml, for running
# the detector ALONE against the bag (ros2 launch reflective_pose_ros
# board_detector.launch.xml input_topic:=/sensing/lidar/vlp32/velodyne_points).
# Do NOT run it beside `up`: the vehicle description already publishes this
# transform, and two authorities on one parent/child pair is a silent fault.
# Publish base_link -> velodyne for the standalone detector check (not with `up`)
fake-tf:
    ros2 run tf2_ros static_transform_publisher \
        --x 0.46 --y 0.0 --z 1.96 \
        --roll 0.0 --pitch 0.0 --yaw -0.05 \
        --frame-id base_link --child-frame-id velodyne

# Stop the replay stack, the player, RViz and a fake-tf if one is running.
down:
    ./scripts/rosbag/indoor_sim_down.sh
