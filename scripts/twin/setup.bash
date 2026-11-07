# The Isaac twin demo's environment (Phase 10): source it in every terminal.
#
#   source scripts/twin/setup.bash
#
# Then:
#   play_launch launch golfcart_twin twin_world.launch.py route:=1      # Isaac Sim and the cart
#   play_launch launch --web-addr 127.0.0.1:8081 \
#       golfcart_twin twin_autoware.launch.xml                         # the cart's Autoware, RViz
#   ros2 run golfcart_twin twin_go.py 1                                 # or: goal and AUTO in RViz
#
# Each play_launch serves a web UI, on 127.0.0.1:8080 by default; the second one needs its own
# port (--web-addr), or it runs without one.
#
# It sources Autoware, scenario-world-bridge's install (aib: the Isaac runner, the cart's rig)
# and this repository's, and sets the shared ROS domain and DDS profile. Host settings come
# from config/twin.env (git-ignored; docs/guides/isaac_twin_demo.md lists them) or the
# environment:
#   TWIN_SWB      scenario-world-bridge checkout, built (aib: the Isaac runner and its launch)
#   ISAAC_ROOT    Isaac Sim 6.1's install
#   TWIN_MAP      the NTU twin's map directory (lanelet2_map.osm, pointcloud_map/, isaac/)
#   TWIN_DOMAIN   ROS domain (default 1; at most 57)
#   TWIN_GPU, AUTOWARE_DATA, AUTOWARE_TENSORRT_LIB (optional)
_twin_root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
[ -f "$_twin_root/config/twin.env" ] && set -a && source "$_twin_root/config/twin.env" && set +a
: "${TWIN_SWB:=$HOME/repos/carla-scenario-bridge}"
: "${TWIN_DOMAIN:=1}"
# ROS Humble's Python is the system's 3.10: a virtualenv's python3 ahead of it on PATH (an
# activated venv, or a desktop session that inherited one) runs `ros2 run` scripts without
# rclpy. Such directories leave PATH in this terminal.
_twin_path=
while IFS= read -r -d: _d; do
    if [ -n "$_d" ] && [ "$_d" != /usr/bin ] && [ "$_d" != /bin ] && [ -x "$_d/python3" ]; then
        echo "twin: $_d left PATH (its python3 is not ROS's)"
        continue
    fi
    _twin_path="${_twin_path:+$_twin_path:}$_d"
done <<< "$PATH:"
PATH=$_twin_path
unset VIRTUAL_ENV _twin_path _d
source /opt/autoware/1.5.0/setup.bash
source "$TWIN_SWB/install/setup.bash"
source "$_twin_root/install/setup.bash"
export ROS_DOMAIN_ID=$TWIN_DOMAIN
export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp
# The twin's loopback-unicast profile: needs no multicast on lo (which the cart's loopback.xml does)
export CYCLONEDDS_URI="file://$(ros2 pkg prefix golfcart_twin)/share/golfcart_twin/config/cyclonedds-unicast-lo.xml"
# Autoware 1.5.0's TensorRT engines are 10.8's (swb's AUTOWARE_TENSORRT_LIB)
if [ -n "${AUTOWARE_TENSORRT_LIB:-}" ] && [ -d "$AUTOWARE_TENSORRT_LIB" ]; then
    export LD_LIBRARY_PATH="$AUTOWARE_TENSORRT_LIB:$LD_LIBRARY_PATH"
fi
export ISAAC_ROOT TWIN_MAP TWIN_GPU AUTOWARE_DATA
echo "twin: domain $ROS_DOMAIN_ID, map ${TWIN_MAP:-unset}, Isaac ${ISAAC_ROOT:-unset}, display ${DISPLAY:-none}"
unset _twin_root
