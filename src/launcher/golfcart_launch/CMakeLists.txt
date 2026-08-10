cmake_minimum_required(VERSION 3.5)
project(golfcart_launch)

find_package(ament_cmake_auto REQUIRED)
ament_auto_find_build_dependencies()

if(BUILD_TESTING)
  find_package(ament_lint_auto REQUIRED)
  ament_lint_auto_find_test_dependencies()
endif()

# Per-host rosbag recorders. Installed into lib/ so they are package executables
# and can be launched as `node:` entries - play_launch 0.5.1 drops `executable:`
# entries from its replay, so a recorder declared that way would never run under
# supervision. See docs/design/multi_machine_deployment.md (Amendments).
install(PROGRAMS
  scripts/record_master.sh
  scripts/record_orin.sh
  DESTINATION lib/${PROJECT_NAME}
)

ament_auto_package(
  INSTALL_TO_SHARE
  config
  launch
  rviz
)
