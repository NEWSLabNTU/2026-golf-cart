cmake_minimum_required(VERSION 3.18)
project(golfcart_cuda_preprocessor LANGUAGES CXX)

if(NOT CMAKE_CXX_STANDARD)
  set(CMAKE_CXX_STANDARD 17)
endif()

find_package(ament_cmake_auto REQUIRED)
ament_auto_find_build_dependencies()

# The whole package is CUDA. Without a toolkit there is nothing to build, and a
# hard failure is better than silently installing a package whose nodes cannot
# load -- the same reasoning as the DBC skip in golfcart_vehicle_interface, but
# the opposite answer, because this package has no CPU fallback to offer.
include(CheckLanguage)
check_language(CUDA)
if(NOT CMAKE_CUDA_COMPILER)
  message(WARNING
    "No CUDA toolkit found; skipping ${PROJECT_NAME}. "
    "The CPU localization preprocessing chain is unaffected.")
  ament_auto_package()
  return()
endif()

enable_language(CUDA)
find_package(CUDAToolkit REQUIRED)

if(NOT DEFINED CMAKE_CUDA_ARCHITECTURES)
  # sm_87 is the AGX Orin, the target board. The others cover the desktops this
  # is developed on; PTX for the newest keeps it loadable on cards newer than
  # the toolkit. Override with -DCMAKE_CUDA_ARCHITECTURES to trim build time.
  set(CMAKE_CUDA_ARCHITECTURES 87 86 89)
endif()

ament_auto_add_library(${PROJECT_NAME} SHARED
  src/cuda_crop_box_filter.cu
  src/cuda_crop_box_filter_node.cpp
  src/cuda_random_downsample_filter.cu
  src/cuda_random_downsample_filter_node.cpp
)
target_link_libraries(${PROJECT_NAME} CUDA::cudart)
set_target_properties(${PROJECT_NAME} PROPERTIES CUDA_SEPARABLE_COMPILATION ON)

rclcpp_components_register_node(${PROJECT_NAME}
  PLUGIN "golfcart::cuda_preprocessor::CudaCropBoxFilterNode"
  EXECUTABLE cuda_crop_box_filter_node
)
rclcpp_components_register_node(${PROJECT_NAME}
  PLUGIN "golfcart::cuda_preprocessor::CudaRandomDownsampleFilterNode"
  EXECUTABLE cuda_random_downsample_filter_node
)

if(BUILD_TESTING)
  find_package(ament_lint_auto REQUIRED)
  ament_lint_auto_find_test_dependencies()

  find_package(ament_cmake_gtest REQUIRED)
  ament_add_gtest(test_${PROJECT_NAME}
    test/test_cuda_crop_box_filter.cpp
    test/test_cuda_random_downsample_filter.cpp
  )
  target_link_libraries(test_${PROJECT_NAME} ${PROJECT_NAME} CUDA::cudart)
  target_include_directories(test_${PROJECT_NAME} PRIVATE include)
endif()

ament_auto_package(INSTALL_TO_SHARE config launch schema)
