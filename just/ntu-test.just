# NTU campus NDT replay test
#
# Run these in order, each in its own terminal (bag, up and rviz stay running):
#
#   just ntu-test bag CSIE-1     # 1. bag PAUSED -- publishes /clock only
#   just ntu-test up             # 2. stack, sensor drivers off, no RViz
#   just ntu-test rviz           # 3. RViz on bag time, map visible
#   just ntu-test resume         # 4. let the sensors flow
#   just ntu-test init CSIE-1    # 5. seed NDT, once LiDAR is flowing
#   just ntu-test report         # 6. score it
#   just ntu-test down           # stop everything
#
# The order is not cosmetic. The bag leads so everything after it is born on
# bag time; the pose comes last so NDT has scans to match against. Getting
# either wrong fails silently and still looks like it is working -- see the
# comment at the top of scripts/rosbag/ntu_sim_bag.sh.
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
    @just --list ntu-test

# Runs the five steps below in the one order that works, waiting on each stage
# rather than sleeping: bag (paused, /clock only) -> stack -> RViz -> resume ->
# seed NDT. Holds until Ctrl-C, then tears everything down.
#
#   just ntu-test run              # CSIE-1, with RViz
#   just ntu-test run CSIE-2       # another set
#   just ntu-test run CSIE-1 rviz=off
# Run the whole NDT replay end to end (bag, stack, RViz, init pose)
run SET="CSIE-1" RVIZ="on" ARGS="":
    ./scripts/rosbag/ntu_sim_run.sh {{SET}} {{RVIZ}} {{ARGS}}

# 1. Start a merged NTU bag PAUSED, publishing /clock only.
bag SET="CSIE-1" ARGS="":
    ./scripts/rosbag/ntu_sim_bag.sh {{SET}} {{ARGS}}

# 2. Bring up the logging simulation (sensor drivers off, no RViz).
up ARGS="":
    play_launch launch --web-addr 0.0.0.0:8081 \
        --container-mode "${GOLFCART_CONTAINER_MODE:-observable}" \
        golfcart_launch ntu_logging_sim.launch.xml rviz:=false {{ARGS}}

# 3. RViz with the point cloud map rendered visibly, on bag time.
rviz:
    ./scripts/rosbag/ntu_sim_rviz.sh

# 4. Release the paused player so sensor data starts flowing.
resume:
    ros2 service call /rosbag2_player/resume rosbag2_interfaces/srv/Resume

# Pause playback again (to inspect a frame, or to re-seed the pose).
pause:
    ros2 service call /rosbag2_player/pause rosbag2_interfaces/srv/Pause

# 5. Re-apply a captured initial pose so an NTU replay starts unattended.
init SET="CSIE-1":
    python3 ./scripts/localization/set_initial_pose.py {{SET}}

# Capture the current converged pose for a set, after placing one in RViz.
capture SET="CSIE-1":
    python3 ./scripts/localization/capture_initial_pose.py {{SET}}

# Audit the two signals the EKF prior is built from -- IMU and VelocityReport --
# for coordinates (REP-103 axes, gravity sign, gyro sign), scale (integrated
# against the NDT pose, not the EKF, which is downstream of both) and quality
# (rate, gaps, stationary bias and noise).
# Check IMU and VelocityReport: coordinates, scale and quality
check-inputs ARGS="":
    python3 ./scripts/localization/check_imu_velocity.py {{ARGS}}

# Record NDT's internal signals against bag time and plot them: NVTL, transform
# probability, iteration count, init->result distance, exe time, speed and yaw
# rate on one clock. Built to answer "which signal moved first" when the pose
# walks off the map. Writes <out>.csv, <out>.png and <out>_path.png.
# Plot NDT internals over time (NVTL, iterations, init->result, speed)
timeseries ARGS="":
    python3 ./scripts/localization/ndt_timeseries.py {{ARGS}}

# Measure how well the live scan actually sits on the map (nearest-neighbour
# residual), independently of NDT's own score. Answers "did it converge" and
# "is tracking holding" separately, by splitting stationary from moving frames.
# Score scan-to-map alignment: residual of the live scan against the map
align ARGS="":
    python3 ./scripts/localization/ndt_alignment_report.py {{ARGS}}

# Score a running NDT replay on pose quality (scatter, yaw step), not on NVTL.
report ARGS="":
    python3 ./scripts/localization/ndt_quality_report.py {{ARGS}}

# Stop the replay stack, the player and RViz.
down:
    ./scripts/rosbag/ntu_sim_down.sh
