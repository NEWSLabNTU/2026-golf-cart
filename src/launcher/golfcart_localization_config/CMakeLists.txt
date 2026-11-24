cmake_minimum_required(VERSION 3.5)
project(golfcart_localization_config)

find_package(ament_cmake REQUIRED)

install(DIRECTORY config DESTINATION share/${PROJECT_NAME})

if(BUILD_TESTING)
  find_package(ament_cmake_pytest REQUIRED)
  ament_add_pytest_test(
    test_matches_upstream
    test/test_matches_upstream.py
  )
endif()

ament_package()
