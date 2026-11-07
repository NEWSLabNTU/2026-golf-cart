cmake_minimum_required(VERSION 3.5)
project(golfcart_twin)

find_package(ament_cmake REQUIRED)

# Data: the cart for Isaac (vehicle/: its spec; isaac/: the ego config, the rig, the body and
# the lidar profiles, with their generators), the body generator, the demo routes, the DDS
# profile, the demo RViz and the launches.
install(
  DIRECTORY body isaac rviz config launch vehicle
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
