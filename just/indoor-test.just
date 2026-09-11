# Indoor cold-start replay: the reflective board seeds NDT, no GNSS.
#
# D1a of docs/roadmaps/7-reflective-board-cold-start.md. Run these in order,
# each in its own terminal (bag, up and rviz stay running):
#
#   just indoor-test run         # all four, supervised by GNU parallel
#
# or one stage per terminal, in this order:
#
#   just indoor-test bag         # 1. bag PAUSED -- publishes /clock only
#   just indoor-test up          # 2. stack, sensor drivers off, no RViz
#   just indoor-test rviz        # 3. RViz on bag time, map visible
#   just indoor-test resume      # 4. let the scans flow, watch the service call
#   just indoor-test down        # stop everything
#
# `run` is supervised: GNU parallel owns the bag, the stack, RViz and the
# conductor, the first job to finish tears down the rest, and `down` stops that
# supervisor by pid. The staged path has no supervisor, so `down` falls back to
# matching processes by argv, which cannot tell this run from anyone else's.
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

# play_launch, default parser, like every other recipe in the repo. The
# version matters more than usual here. play_launch 0.8.2 rendered the pose
# initializer's array parameters as strings and autoware_pose_initializer_node
# died at startup, taking /localization/initialize with it (fixed in 0.10.0,
# f78745da). A 0.10.0 release build's Rust parser then died on this stack
# with `KeyError: 'rear_overhang'`, global parameters never reaching a
# .launch.py across the loader boundary (play_launch issue #0028, fixed in
# 8adc52ad, 2026-09-11, ABI 4). With that build the Rust parser resolves this
# launch to the same nodes as the Python one and brings the stack up with the
# service served. Below 8adc52ad, `--parser python`; below 0.10.0, stock
# ros2 launch:
#
#   ros2 launch golfcart_launch indoor_logging_sim.launch.xml rviz:=false
#
# The script waits for /clock before launching, so it can be started here in
# its own terminal after `just indoor-test bag`, in either order.
#
# It asks for pose_initializer:=board, which is what this replay is for. The
# launch file itself defaults to gnss, matching golfcart.launch.yaml and the
# cart: a launch file that lies about the vehicle is worse than one that needs
# a flag. pose_source needs no flag, cuda_ndt being the default in both.
# Anything passed through ARGS wins, so "pose_initializer:=gnss" still checks
# that the vehicle default starts neither board node.
# 2. Bring up the indoor logging simulation (sensor drivers off, no RViz).
up ARGS="":
    ./scripts/rosbag/indoor_sim_up.sh {{ARGS}}

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

# Per-process CPU, RSS and block I/O, topic rates and the scan matcher's
# exe_time, sampled while a replay is up. Run it in a second terminal.
# Where the time and the bytes go, while the replay runs
profile SECONDS="60":
    ./scripts/rosbag/indoor_sim_profile.py --seconds {{SECONDS}}

# Record board detections, the initialization state, NDT poses, iteration
# counts and NVTL for a whole replay. Start it before `run`: it subscribes as
# topics appear.
# Record localization events to a JSONL file
record OUT="log/indoor-test/events.jsonl" SECONDS="320":
    ./scripts/rosbag/indoor_sim_record_events.py --out {{OUT}} --seconds {{SECONDS}}

# PYTHONNOUSERSITE, because the apt matplotlib is built against NumPy 1.x and
# the NumPy 2.x in ~/.local breaks its import.
# Draw the timeline from a recorded events file
timeline EVENTS="log/indoor-test/events.jsonl" OUT="docs/research/performance/indoor-replay-timeline.png":
    PYTHONNOUSERSITE=1 ./scripts/rosbag/indoor_sim_plot_timeline.py --events {{EVENTS}} --out {{OUT}}
