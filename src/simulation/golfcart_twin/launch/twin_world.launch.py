"""Isaac Sim with the NTU campus twin and the golf cart at a demo route's start (Phase 10).

    play_launch launch golfcart_twin twin_world.launch.py route:=1

aib's stand-alone runner (scenario-world-bridge's aib_launch isaac_vehicle.launch.xml) with:
- the cart's rig, generated in swb from sim_vehicle_spec's newslab_golfcart;
- this package's body and lidar profiles. They are built on first use into `assets` (default
  $TWIN_ASSETS, else ~/.cache/golfcart_twin) with Isaac's own Python, and rebuilt when
  make_body.py or make_lidars.py is newer than them;
- the twin's world, $TWIN_MAP/isaac/world.yaml;
- the route's start from config/routes.yaml.

It runs on the terminal's ROS_DOMAIN_ID and DDS profile, which Autoware must share
(scripts/twin/setup.bash sets both). The Isaac window opens on $DISPLAY and follows the cart.
"""
import os
import subprocess

import yaml
from ament_index_python.packages import get_package_share_directory
from launch import LaunchDescription
from launch.actions import DeclareLaunchArgument, IncludeLaunchDescription, OpaqueFunction
from launch.launch_description_sources import AnyLaunchDescriptionSource
from launch.substitutions import LaunchConfiguration


def _stale(products, sources):
    """True when a product is missing or older than a source."""
    if not all(os.path.exists(p) for p in products):
        return True
    newest = max(os.path.getmtime(s) for s in sources)
    return any(os.path.getmtime(p) < newest for p in products)


def _setup(context):
    share = get_package_share_directory("golfcart_twin")
    route = LaunchConfiguration("route").perform(context)
    map_dir = LaunchConfiguration("map_path").perform(context)
    assets = os.path.expanduser(LaunchConfiguration("assets").perform(context))
    isaac = os.environ.get("ISAAC_ROOT", "")
    if not map_dir:
        raise RuntimeError("twin_world: no map: set TWIN_MAP or map_path:=<twin map dir>")
    if not isaac:
        raise RuntimeError("twin_world: ISAAC_ROOT is not set (Isaac Sim 6.1's install)")

    routes = yaml.safe_load(open(os.path.join(share, "config", "routes.yaml")))["routes"]
    if route not in routes:
        raise RuntimeError(f"twin_world: no route {route!r}; the routes are {', '.join(routes)}")
    s = routes[route]["start"]

    # Isaac's own Python has pxr; the system one does not.
    py = os.path.join(isaac, "venv", "bin", "python")
    lidars = os.path.join(assets, "lidars")
    body = os.path.join(assets, "vehicles")
    jobs = (
        ([os.path.join(lidars, "VLP32C.usda"), os.path.join(lidars, "Falcon.usda")],
         os.path.join(share, "isaac", "make_lidars.py"), lidars),
        ([os.path.join(body, "vehicle.newslab.golfcart", "entry.json")],
         os.path.join(share, "body", "make_body.py"), body),
    )
    for products, script, out in jobs:
        if _stale(products, [script]):
            print(f"twin_world: building {out} ({os.path.basename(script)})", flush=True)
            subprocess.run([py, script, out], check=True)

    # The ego config: this package's, on the terminal's ROS domain.
    domain = int(os.environ.get("ROS_DOMAIN_ID", "0") or 0)
    ego = yaml.safe_load(open(os.path.join(share, "config", "ego_golfcart.yaml")))
    ego["domain"] = domain
    os.makedirs(assets, exist_ok=True)
    ego_path = os.path.join(assets, f"ego_golfcart_domain{domain}.yaml")
    with open(ego_path, "w") as f:
        yaml.safe_dump(ego, f)
    os.environ["GOLFCART_LIDARS"] = lidars
    os.environ["GOLFCART_BODY"] = body
    os.environ.setdefault("AIB_CONFIG", os.path.join(get_package_share_directory("aib"), "config"))
    gpu = LaunchConfiguration("gpu").perform(context)
    os.environ.setdefault("ISAAC_KIT_ARGS",
                          f"--/renderer/multiGpu/enabled=false --/renderer/activeGpu={gpu}")

    aib = os.path.join(get_package_share_directory("aib_launch"), "launch", "isaac_vehicle.launch.xml")
    return [IncludeLaunchDescription(AnyLaunchDescriptionSource(aib), launch_arguments={
        "ego": ego_path,
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
        DeclareLaunchArgument("assets", default_value=os.environ.get("TWIN_ASSETS", "~/.cache/golfcart_twin"),
                              description="where the body and the lidar profiles are built"),
        DeclareLaunchArgument("render", default_value="auto",
                              description="auto (a window on $DISPLAY), window or headless"),
        DeclareLaunchArgument("gpu", default_value=os.environ.get("TWIN_GPU", "0"),
                              description="the GPU Isaac renders on"),
        OpaqueFunction(function=_setup),
    ])
