cmake_minimum_required(VERSION 3.14)
project(golfcart_domain_bridge)

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

find_package(yaml-cpp REQUIRED)

# ── config parsing, on its own so it can be unit tested without a domain ─────
ament_auto_add_library(${PROJECT_NAME}_config SHARED
  src/config.cpp
)
target_link_libraries(${PROJECT_NAME}_config yaml-cpp)

# ── the bridge ───────────────────────────────────────────────────────────────
ament_auto_add_executable(domain_bridge
  src/domain_bridge.cpp
)
target_link_libraries(domain_bridge ${PROJECT_NAME}_config)

if(BUILD_TESTING)
  find_package(ament_lint_auto REQUIRED)
  ament_lint_auto_find_test_dependencies()

  find_package(ament_cmake_gtest REQUIRED)
  # The one thing worth a test: a topic listed in both directions is refused,
  # and the role-to-direction mapping is the mirror it claims to be.
  ament_add_gtest(test_config test/test_config.cpp)
  target_link_libraries(test_config ${PROJECT_NAME}_config)
endif()

ament_auto_package(
  USE_SCOPED_HEADER_INSTALL_DIR
)
