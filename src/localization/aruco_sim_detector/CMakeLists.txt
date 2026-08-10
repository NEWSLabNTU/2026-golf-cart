cmake_minimum_required(VERSION 3.14)
project(aruco_sim_detector)

if(NOT CMAKE_CXX_STANDARD)
  set(CMAKE_CXX_STANDARD 17)
  set(CMAKE_CXX_STANDARD_REQUIRED ON)
  set(CMAKE_CXX_EXTENSIONS OFF)
endif()

if(CMAKE_COMPILER_IS_GNUCXX OR CMAKE_CXX_COMPILER_ID MATCHES "Clang")
  add_compile_options(-Wall -Wextra -Wpedantic)
endif()

find_package(ament_cmake_auto REQUIRED)
ament_auto_find_build_dependencies()

find_package(Eigen3 REQUIRED)
find_package(OpenCV REQUIRED COMPONENTS core calib3d)

ament_auto_add_executable(aruco_sim_detector_node src/aruco_sim_detector_node.cpp)
target_link_libraries(aruco_sim_detector_node Eigen3::Eigen opencv_core opencv_calib3d)

ament_auto_add_executable(sim_trajectory_publisher_node src/trajectory_publisher_node.cpp)
target_link_libraries(sim_trajectory_publisher_node Eigen3::Eigen)

if(BUILD_TESTING)
  find_package(ament_lint_auto REQUIRED)
  ament_lint_auto_find_test_dependencies()

  find_package(ament_cmake_gtest REQUIRED)

  # The round-trip test: synthesise detections from a known pose, then recover
  # that pose from them. With zero noise it must close to numerical tolerance.
  # This is the single test that covers the whole geometry chain — map
  # convention, corner order, TF composition, optical frame and solve direction
  # — every one of which fails silently and plausibly on its own.
  ament_add_gtest(test_sim_roundtrip test/test_sim_roundtrip.cpp)
  target_link_libraries(test_sim_roundtrip
    Eigen3::Eigen opencv_core opencv_calib3d)
  target_include_directories(test_sim_roundtrip PRIVATE include)
  ament_target_dependencies(test_sim_roundtrip golfcart_aruco_localizer)
endif()

ament_auto_package(
  USE_SCOPED_HEADER_INSTALL_DIR
  INSTALL_TO_SHARE
    config
    launch
)
