cmake_minimum_required(VERSION 3.5)
project(golfcart_twin)

find_package(ament_cmake REQUIRED)

# Data: the body generator and its README, the Isaac-side lidar profiles, the configs (aib's
# ego config, the demo routes), the demo RViz, the Autoware-side launch.
install(
  DIRECTORY body isaac rviz config launch
  DESTINATION share/${PROJECT_NAME}
  PATTERN "__pycache__" EXCLUDE
)

# scripts/twin_go.py: drives a route as a presenter would (`just twin go`)
install(
  PROGRAMS scripts/twin_go.py
  DESTINATION lib/${PROJECT_NAME}
)
install(
  DIRECTORY scripts
  DESTINATION share/${PROJECT_NAME}
  USE_SOURCE_PERMISSIONS
)

ament_package()
