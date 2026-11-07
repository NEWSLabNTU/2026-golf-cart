"""Isaac Sim with the NTU campus twin and the golf cart at a demo route's start (Phase 10).

    play_launch launch golfcart_twin twin_world.launch.py route:=1

scenario-world-bridge's generic aib_launch isaac_vehicle.launch.xml with this package's car:
isaac/ego.yaml, which names the rig (generated from vehicle/newslab_golfcart.yaml), the body
and the lidar profiles beside it; the twin's world, map_path/isaac/world.yaml; and the route's
start from config/routes.yaml.

It runs on the terminal's ROS_DOMAIN_ID and DDS profile, which Autoware must share
(scripts/twin/setup.bash sets both). The Isaac window opens on $DISPLAY and follows the cart.
"""
import os

import yaml
from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, IncludeLaunchDescription, OpaqueFunction
from launch.launch_description_sources import AnyLaunchDescriptionSource
from launch.substitutions import LaunchConfiguration


def _setup(context):
    share = get_package_share_directory("golfcart_twin")
    route = LaunchConfiguration("route").perform(context)
    map_dir = LaunchConfiguration("map_path").perform(context)
    if not map_dir:
        raise RuntimeError("twin_world: no map: set TWIN_MAP or map_path:=<twin map dir>")
    routes = yaml.safe_load(open(os.path.join(share, "config", "routes.yaml")))["routes"]
    if route not in routes:
        raise RuntimeError(f"twin_world: no route {route!r}; the routes are {', '.join(routes)}")
    s = routes[route]["start"]
    gpu = LaunchConfiguration("gpu").perform(context)
    os.environ.setdefault("ISAAC_KIT_ARGS",
                          f"--/renderer/multiGpu/enabled=false --/renderer/activeGpu={gpu}")

    aib = os.path.join(get_package_share_directory("aib_launch"), "launch", "isaac_vehicle.launch.xml")
    return [IncludeLaunchDescription(AnyLaunchDescriptionSource(aib), launch_arguments={
        "ego": os.path.join(share, "isaac", "ego.yaml"),
        "world": os.path.join(map_dir, "isaac", "world.yaml"),
        "map_pose": f"{s['x']},{s['y']},{s['z']},{s['yaw']}",
        "render": LaunchConfiguration("render").perform(context),
        "view": "chase",
        "realtime": "true",
    }.items())]


def generate_launch_description():
    return LaunchDescription([
        DeclareLaunchArgument("route", default_value="1",
                              description="the demo route whose start the cart is put at (config/routes.yaml)"),
        DeclareLaunchArgument("map_path", default_value=os.environ.get("TWIN_MAP", ""),
                              description="the NTU twin's map directory (default $TWIN_MAP)"),
        DeclareLaunchArgument("render", default_value="auto",
                              description="auto (a window on $DISPLAY), window or headless"),
        DeclareLaunchArgument("gpu", default_value=os.environ.get("TWIN_GPU", "0"),
                              description="the GPU Isaac renders on"),
        OpaqueFunction(function=_setup),
    ])
