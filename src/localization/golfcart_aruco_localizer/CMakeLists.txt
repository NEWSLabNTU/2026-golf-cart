cmake_minimum_required(VERSION 3.14)
project(golfcart_aruco_localizer)

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
find_package(yaml-cpp REQUIRED)

# ── tag map library ──────────────────────────────────────────────────────────
ament_auto_add_library(${PROJECT_NAME}_core SHARED
  src/tag_map.cpp
  src/solver.cpp
)
target_link_libraries(${PROJECT_NAME}_core Eigen3::Eigen yaml-cpp)

# ── node ─────────────────────────────────────────────────────────────────────
ament_auto_add_executable(aruco_localizer_node
  src/aruco_localizer_node.cpp
)
target_link_libraries(aruco_localizer_node ${PROJECT_NAME}_core)

# ── tests ────────────────────────────────────────────────────────────────────
if(BUILD_TESTING)
  find_package(ament_lint_auto REQUIRED)
  ament_lint_auto_find_test_dependencies()

  find_package(ament_cmake_gtest REQUIRED)
  find_package(OpenCV REQUIRED COMPONENTS core calib3d aruco)

  ament_add_gtest(test_tag_map test/test_tag_map.cpp)
  target_link_libraries(test_tag_map ${PROJECT_NAME}_core Eigen3::Eigen)

  # Synthetic constellations with known ground truth: the geometry chain, the
  # covariance behaviour under degeneracy, and the per-board robust kernel.
  ament_add_gtest(test_solver test/test_solver.cpp)
  target_link_libraries(test_solver ${PROJECT_NAME}_core Eigen3::Eigen)

  # Pins our corner-order convention against OpenCV's own object points. A
  # permutation here is a silent multiple-of-90-degree pose error that still
  # converges, so it needs a test that fails loudly rather than a comment.
  ament_add_gtest(test_tag_frame test/test_tag_frame.cpp)
  target_link_libraries(test_tag_frame
    ${PROJECT_NAME}_core
    Eigen3::Eigen
    opencv_core
    opencv_calib3d
    opencv_aruco
  )
endif()

ament_auto_package(
  USE_SCOPED_HEADER_INSTALL_DIR
  INSTALL_TO_SHARE
    config
)
