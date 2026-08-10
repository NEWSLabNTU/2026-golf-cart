cmake_minimum_required(VERSION 3.14)
project(aruco_detection_msgs)

find_package(ament_cmake_auto REQUIRED)
ament_auto_find_build_dependencies()

rosidl_generate_interfaces(${PROJECT_NAME}
  "msg/ArucoDetection.msg"
  "msg/ArucoDetectionArray.msg"
  "msg/ArucoLocalizerStatus.msg"
  DEPENDENCIES
    std_msgs
    geometry_msgs
)

if(BUILD_TESTING)
  find_package(ament_lint_auto REQUIRED)
  ament_lint_auto_find_test_dependencies()
endif()

ament_auto_package()
