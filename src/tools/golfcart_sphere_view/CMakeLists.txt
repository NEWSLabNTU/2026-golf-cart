cmake_minimum_required(VERSION 3.8)
project(golfcart_sphere_view)

if(NOT CMAKE_CXX_STANDARD)
  set(CMAKE_CXX_STANDARD 17)
endif()

if(CMAKE_COMPILER_IS_GNUCXX OR CMAKE_CXX_COMPILER_ID MATCHES "Clang")
  add_compile_options(-Wall -Wextra -Wpedantic)
endif()

find_package(ament_cmake REQUIRED)
find_package(pluginlib REQUIRED)
find_package(rclcpp REQUIRED)
find_package(rviz_common REQUIRED)
find_package(rviz_default_plugins REQUIRED)
find_package(rviz_rendering REQUIRED)
find_package(sensor_msgs REQUIRED)
find_package(Qt5 COMPONENTS Widgets REQUIRED)

set(CMAKE_AUTOMOC ON)

add_library(${PROJECT_NAME} SHARED
  src/camera_layer.cpp
  src/cloud_layer.cpp
  src/cloud_projection.cpp
  src/sphere_mesh.cpp
  src/sphere_view_display.cpp
  src/textured_patch.cpp
)

target_include_directories(${PROJECT_NAME} PRIVATE src)
target_link_libraries(${PROJECT_NAME}
  PUBLIC
  Qt5::Widgets
  pluginlib::pluginlib
  rclcpp::rclcpp
  rviz_common::rviz_common
  rviz_default_plugins::rviz_default_plugins
  rviz_rendering::rviz_rendering
  ${sensor_msgs_TARGETS}
)

# pluginlib's boost path is not needed and pulls in a dependency we do not have.
target_compile_definitions(${PROJECT_NAME} PUBLIC "PLUGINLIB__DISABLE_BOOST_FUNCTIONS")

if(BUILD_TESTING)
  find_package(ament_cmake_gtest REQUIRED)
  ament_add_gtest(test_sphere_mesh test/test_sphere_mesh.cpp src/sphere_mesh.cpp
    src/cloud_projection.cpp)
  target_include_directories(test_sphere_mesh PRIVATE src)
  target_link_libraries(test_sphere_mesh
    rviz_rendering::rviz_rendering
    ${sensor_msgs_TARGETS}
  )
endif()

ament_export_dependencies(
  pluginlib rclcpp rviz_common rviz_default_plugins rviz_rendering sensor_msgs)
ament_export_libraries(${PROJECT_NAME})
ament_export_targets(${PROJECT_NAME} HAS_LIBRARY_TARGET)

install(TARGETS ${PROJECT_NAME} EXPORT ${PROJECT_NAME}
  ARCHIVE DESTINATION lib
  LIBRARY DESTINATION lib
  RUNTIME DESTINATION bin
)

# The synthetic camera and its RViz config, so the display can be exercised
# without the vehicle.
install(PROGRAMS test/fake_camera.py test/fake_lidar.py DESTINATION lib/${PROJECT_NAME})
install(FILES test/sphere_view_demo.rviz DESTINATION share/${PROJECT_NAME}/rviz)

pluginlib_export_plugin_description_file(rviz_common plugin_description.xml)
ament_package()
