cmake_minimum_required(VERSION 3.5)
project(golfcart_launch)

find_package(ament_cmake_auto REQUIRED)
ament_auto_find_build_dependencies()

if(BUILD_TESTING)
  find_package(ament_lint_auto REQUIRED)
  ament_lint_auto_find_test_dependencies()
endif()

# The per-host rosbag recorders that used to be installed here are gone: they are
# no longer package executables launched as `node:` entries, but a standalone
# systemd unit (scripts/recording/record_unit_exec.sh), so nothing needs them in
# lib/. See docs/design/orin_provisioning_implementation_plan.md §4.6.

ament_auto_package(
  INSTALL_TO_SHARE
  config
  launch
  rviz
)
