"""The golf cart in the NTU twin on Isaac Sim, the whole stack in one launch (Phase 10):
scenario-world-bridge's `swb_launch isaac.launch.xml` with this package's car, world and
Autoware.

    play_launch launch golfcart_twin twin.launch.py route:=1          # free drive: RViz drives
    play_launch launch golfcart_twin twin.launch.py scenario:=route1  # SSv2 runs a scenario

- route:=N (config/routes.yaml): free drive. The cart is put at the route's start and time
  runs (synchronously, paced to the wall clock; realtime:=false for as fast as it goes). Set
  the goal and press AUTO in RViz, or `ros2 run golfcart_twin twin_go.py N`.
- scenario:=<name>|<path>: scenarios/<name>.xosc of this package (route1..route4, made by
  scripts/make_scenarios.py), or any .xosc. SSv2 places the cart, routes it and judges it.
  Another scenario on the live stack, from a second terminal (scenario domain):
      play_launch launch swb_launch scenario.launch.xml scenario:=<path> port:=$SSV2_PORT

The stack: Isaac's world server with isaac/ego.yaml and $TWIN_MAP/isaac/world.yaml; swb's
bridge and relay, with this package's catalog (catalogs/vehicles.xosc); the cart's own
Autoware (twin_autoware.launch.xml) and swb's vehicle agent with isaac/spec_hash.yaml.
Domains and ports are the environment's (scripts/twin/setup.bash: EGO_ROS_DOMAIN_ID,
SCENARIO_ROS_DOMAIN_ID, SSV2_PORT, AGENT_PORT, ISAAC_PORT).
"""
import os

import yaml
from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, IncludeLaunchDescription, OpaqueFunction
from launch.launch_description_sources import AnyLaunchDescriptionSource
from launch.substitutions import LaunchConfiguration


def _setup(context):
    get = lambda n: LaunchConfiguration(n).perform(context)  # noqa: E731
    share = get_package_share_directory("golfcart_twin")
    map_dir = get("map_path")
    if not map_dir:
        raise RuntimeError("twin: no map: set TWIN_MAP or map_path:=<twin map dir>")
    scenario, spawn = get("scenario"), ""
    if scenario:
        if not scenario.endswith(".xosc"):
            scenario = os.path.join(share, "scenarios", f"{scenario}.xosc")
        if not os.path.isfile(scenario):
            raise RuntimeError(f"twin: no scenario {scenario}")
    else:
        routes = yaml.safe_load(open(os.path.join(share, "config", "routes.yaml")))["routes"]
        route = get("route")
        if route not in routes:
            raise RuntimeError(f"twin: no route {route!r}; the routes are {', '.join(routes)}")
        s = routes[route]["start"]
        spawn = f"{s['x']},{s['y']},{s['z']},{s['yaw']}"
    gpu = get("gpu")
    os.environ.setdefault("ISAAC_KIT_ARGS",
                          f"--/renderer/multiGpu/enabled=false --/renderer/activeGpu={gpu}")
    os.environ.setdefault("TWIN_MAP", map_dir)  # the scenarios' LogicFile

    stack = os.path.join(get_package_share_directory("swb_launch"), "launch", "isaac.launch.xml")
    return [IncludeLaunchDescription(AnyLaunchDescriptionSource(stack), launch_arguments={
        "ego": os.path.join(share, "isaac", "ego.yaml"),
        "world": os.path.join(map_dir, "isaac", "world.yaml"),
        "render": get("render"),
        "follow": get("follow"),
        "map_path": map_dir,
        "ego_launch": "golfcart_twin twin_autoware.launch.xml",
        "ego_launch_args": f"map_path:={map_dir} demo_rviz:={get('rviz')} launch_perception:={get('perception')}",
        "vehicle_model": "golfcart_vehicle",
        "vehicle": "newslab_golfcart",
        "spec_hash_file": os.path.join(share, "isaac", "spec_hash.yaml"),
        "vehicle_catalogs": os.path.join(share, "catalogs", "vehicles.xosc"),
        "scenario": scenario,
        "scenario_args": get("scenario_args"),
        "exit_on_scenario_end": get("exit_on_scenario_end"),
        "spawn": spawn,
        "realtime": get("realtime"),
    }.items())]


def generate_launch_description():
    arg = DeclareLaunchArgument
    return LaunchDescription([
        arg("route", default_value="1", description="free drive from this route's start (config/routes.yaml)"),
        arg("scenario", default_value="", description="a scenario: route1..route4 (scenarios/) or a path to an .xosc; empty: free drive"),
        arg("scenario_args", default_value="", description="name:=value ... for swb's scenario.launch.xml (global_real_time_factor, global_timeout, output_directory, ...)"),
        arg("exit_on_scenario_end", default_value="false", description="true: everything ends with the scenario"),
        arg("realtime", default_value="true", description="free drive: pace to the wall clock; false: as fast as it goes (synchronous either way)"),
        arg("map_path", default_value=os.environ.get("TWIN_MAP", ""), description="the NTU twin's map directory (default $TWIN_MAP)"),
        arg("render", default_value="auto", description="auto (a window on $DISPLAY), window or headless"),
        arg("rviz", default_value="true", description="the demo RViz"),
        arg("perception", default_value="true", description="the cart's perception (CenterPoint on the lidars, tracking, prediction): what makes it stop for pedestrians and follow cars. The cart's own golfcart.launch.yaml defaults it to false"),
        arg("follow", default_value="editor", description="editor: Isaac's editor UI, the viewport chasing the cart; true: the chase without the UI; false: the editor's own camera"),
        arg("gpu", default_value=os.environ.get("TWIN_GPU", "0"), description="the GPU Isaac renders on"),
        OpaqueFunction(function=_setup),
    ])
