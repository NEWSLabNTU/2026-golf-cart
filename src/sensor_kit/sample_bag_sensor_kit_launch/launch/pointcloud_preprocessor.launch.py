# Copyright 2020 Tier IV, Inc. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Based on sample_sensor_kit_launch/launch/pointcloud_preprocessor.launch.py
# Modified for sample_bag_sensor_kit (3 lidars instead of 4)

import os

from ament_index_python.packages import get_package_share_directory
import launch
from launch.actions import DeclareLaunchArgument
from launch.actions import OpaqueFunction
from launch.actions import SetLaunchConfiguration
from launch.conditions import IfCondition
from launch.conditions import UnlessCondition
from launch.substitutions import LaunchConfiguration
from launch_ros.actions import LoadComposableNodes
from launch_ros.descriptions import ComposableNode
from launch_ros.parameter_descriptions import ParameterFile


# CPU only, deliberately. Unlike golfcart_sensor_kit_launch, this kit does not
# own its preprocessing: crop box, distortion correction and ring outlier
# filtering come from the stock `common_sensor_launch` nebula container, which
# already publishes `pointcloud_before_sync` and hardcodes
# `use_intra_process=true`. A CUDA concatenator needs a CUDA preprocessor
# upstream to produce the cuda_blackboard negotiation topic, so offering a
# `pointcloud_backend` here would be a switch that loads and then receives null
# device pointers. This kit exists to replay the Autoware sample bag, not to
# benchmark GPU preprocessing; the golf cart kit is where that lives.


def launch_setup(context, *args, **kwargs):
    # concatenate node parameters
    concatenate_and_time_sync_node_param = ParameterFile(
        param_file=LaunchConfiguration("concatenate_and_time_sync_node_param_path").perform(
            context
        ),
        allow_substs=True,
    )

    # set concat filter as a component
    concat_component = ComposableNode(
        package="autoware_pointcloud_preprocessor",
        plugin="autoware::pointcloud_preprocessor::PointCloudConcatenateDataSynchronizerComponent",
        name="concatenate_data",
        remappings=[
            ("~/input/twist", "/sensing/vehicle_velocity_converter/twist_with_covariance"),
            ("output", "concatenated/pointcloud"),
            ("output_info", "concatenated/pointcloud_info"),
        ],
        parameters=[concatenate_and_time_sync_node_param],
        extra_arguments=[{"use_intra_process_comms": LaunchConfiguration("use_intra_process")}],
    )

    # load concat or passthrough filter
    concat_loader = LoadComposableNodes(
        composable_node_descriptions=[concat_component],
        target_container=LaunchConfiguration("pointcloud_container_name"),
        condition=IfCondition(LaunchConfiguration("use_concat_filter")),
    )

    return [concat_loader]


def generate_launch_description():
    launch_arguments = []

    def add_launch_arg(name: str, default_value=None):
        launch_arguments.append(DeclareLaunchArgument(name, default_value=default_value))

    sample_bag_sensor_kit_launch_share_dir = get_package_share_directory("sample_bag_sensor_kit_launch")

    add_launch_arg("base_frame", "base_link")
    add_launch_arg("use_multithread", "False")
    add_launch_arg("use_intra_process", "False")
    add_launch_arg("use_concat_filter", "true")
    add_launch_arg("pointcloud_container_name", "pointcloud_container")
    add_launch_arg(
        "concatenate_and_time_sync_node_param_path",
        os.path.join(
            sample_bag_sensor_kit_launch_share_dir,
            "config",
            "concatenate_and_time_sync_node.param.yaml",
        ),
    )

    set_container_executable = SetLaunchConfiguration(
        "container_executable",
        "component_container",
        condition=UnlessCondition(LaunchConfiguration("use_multithread")),
    )

    set_container_mt_executable = SetLaunchConfiguration(
        "container_executable",
        "component_container_mt",
        condition=IfCondition(LaunchConfiguration("use_multithread")),
    )

    return launch.LaunchDescription(
        launch_arguments
        + [set_container_executable, set_container_mt_executable]
        + [OpaqueFunction(function=launch_setup)]
    )
