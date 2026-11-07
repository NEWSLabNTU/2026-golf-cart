#!/usr/bin/env bash
# The cart in the NTU twin on Isaac Sim (docs/roadmaps/10-isaac-twin-demo.md), behind `just twin`.
#
#   twin.sh generate [--check]  regenerate the cart's files into the package: the Isaac rig, its
#                             SSv2 catalog and spec_hash, the route scenarios, the lidar profiles,
#                             the body; --check: the spec-derived ones only, exit 1 if stale
#   twin.sh world [ROUTE]     Isaac Sim with the twin and the cart at ROUTE's start (default 1)
#   twin.sh autoware          the cart's own Autoware on the twin's map, with RViz
#   twin.sh go [ROUTE]        set ROUTE's goal and engage, then report until it arrives
#   twin.sh status | stop
#
# Host settings come from the environment, or from config/twin.env (git-ignored) when it
# exists:
#   TWIN_SWB      scenario-world-bridge checkout, built (Isaac side: aib's runner)
#   ISAAC_ROOT    Isaac Sim 6.1's install (swb's install_isaac.sh)
#   TWIN_MAP      the NTU twin's map directory: lanelet2_map.osm, pointcloud_map/,
#                 map_projector_info.yaml, isaac/world.yaml
#   TWIN_DOMAIN   ROS domain for both sides (default 1; at most 57)
#   TWIN_DISPLAY  X display for Isaac's window (default $DISPLAY; empty: headless)
#   TWIN_GPU      the GPU Isaac renders on (default 0)
#   AUTOWARE_DATA Autoware's model data (default ~/autoware_data)
#   AUTOWARE_TENSORRT_LIB  a TensorRT 10.8 runtime put first for Autoware (swb's setting:
#                 Autoware 1.5.0's engines must be built by 10.8, or they rebuild at every start)
#
# Both sides use the package's loopback-unicast Cyclone profile (config/cyclonedds-unicast-lo.xml):
# it needs no multicast on lo, which the cart's loopback.xml does.
set -eo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
pkg="$root/src/simulation/golfcart_twin"
[ -f "$root/config/twin.env" ] && source "$root/config/twin.env"
TWIN_SWB=${TWIN_SWB:-$HOME/repos/carla-scenario-bridge}
TWIN_DOMAIN=${TWIN_DOMAIN:-1}
TWIN_DISPLAY=${TWIN_DISPLAY-${DISPLAY:-}}
TWIN_GPU=${TWIN_GPU:-0}
AUTOWARE_DATA=${AUTOWARE_DATA:-$HOME/autoware_data}
run="$root/log/twin"
mkdir -p "$run"
dds="file://$pkg/config/cyclonedds-unicast-lo.xml"

die() { echo "twin: $*" >&2; exit 1; }
need() { [ -n "${!1:-}" ] || die "$1 is not set (environment or config/twin.env)"; }
dds_env() {
    export RMW_IMPLEMENTATION=rmw_cyclonedds_cpp ROS_DOMAIN_ID=$TWIN_DOMAIN CYCLONEDDS_URI=$dds
}
alive() { [ -f "$run/$1.pgid" ] && kill -0 -"$(cat "$run/$1.pgid")" 2>/dev/null; }
route_field() {  # route_field ROUTE start|goal -> "x y z yaw"
    python3 - "$pkg/config/routes.yaml" "$1" "$2" <<'EOF'
import sys, yaml
r = yaml.safe_load(open(sys.argv[1]))["routes"]
if sys.argv[2] not in r:
    sys.exit(f"twin: no route {sys.argv[2]!r}; the routes are {', '.join(r)}")
p = r[sys.argv[2]][sys.argv[3]]
print(p["x"], p["y"], p["z"], p["yaw"])
EOF
}

generate() {
    # The rig is swb's aib.gen on this package's spec; the lidar profiles and the body need
    # Isaac's own Python (pxr). All of them are committed: run this after changing the spec,
    # make_lidars.py or the body tools, and commit what it writes.
    local aib="$TWIN_SWB/src/autoware_isaac_bridge/src/aib"
    [ -d "$aib" ] || die "no $aib (TWIN_SWB)"
    local gen=(env PYTHONPATH="$aib" python3 -m aib.gen --spec "$pkg/vehicle/newslab_golfcart.yaml"
               -o "$pkg/isaac/newslab_golfcart.rig.yaml")
    # The cart's SSv2 catalog entry and its spec_hash file: swb's sim_vehicle_spec on this spec
    local svs="$TWIN_SWB/src/sim_vehicle_spec"
    [ -d "$svs" ] || die "no $svs (TWIN_SWB)"
    local cat=(env PYTHONPATH="$svs" python3 -m sim_vehicle_spec.gen
               --spec "$pkg/vehicle/newslab_golfcart.yaml"
               --catalog "$pkg/catalogs/vehicles.xosc" --spec-hash "$pkg/isaac/spec_hash.yaml")
    if [ "${1:-}" = --check ]; then "${gen[@]}" --check && "${cat[@]}" --check && python3 "$pkg/scripts/make_scenarios.py" --check && python3 "$pkg/scripts/make_showcase.py" --check; return; fi
    "${gen[@]}"
    "${cat[@]}"
    python3 "$pkg/scripts/make_scenarios.py"
    python3 "$pkg/scripts/make_showcase.py"
    need ISAAC_ROOT
    py="$ISAAC_ROOT/venv/bin/python"
    [ -x "$py" ] || die "no $py (ISAAC_ROOT: swb's install_isaac.sh)"
    "$py" "$pkg/isaac/make_lidars.py" "$pkg/isaac/lidars"
    "$py" "$pkg/body/make_body.py" "$pkg/isaac/body"
    echo "twin: generated into $pkg/isaac; commit the changes"
}

world() {
    local route=${1:-1}
    need ISAAC_ROOT; need TWIN_MAP
    route_field "$route" start > /dev/null
    alive world && die "the world is already up (pgid $(cat "$run/world.pgid")); twin stop first"
    echo "twin: Isaac Sim, route $route's start, domain $TWIN_DOMAIN, window ${TWIN_DISPLAY:-none};" \
         "log $run/world.log"
    # The launch a person types (docs/guides/isaac_twin_demo.md), in its own process group
    # (setsid), whose leader's pid is the one written: `stop` signals the group.
    rm -rf "${run:?}/play_log_world"
    ( export DISPLAY="$TWIN_DISPLAY"; source "$root/scripts/twin/setup.bash" > /dev/null
      setsid play_launch launch --web-addr 127.0.0.1:${TWIN_WORLD_WEB_PORT:-8095} \
          --log-dir "$run/play_log_world" golfcart_twin twin_world.launch.py route:="$route" \
          > "$run/world.log" 2>&1 < /dev/null &
      echo $! > "$run/world.pgid" )
    for _ in $(seq 1 120); do
        grep -rqs 'sensors warm' "$run/play_log_world" && { echo "twin: the world is up"; return; }
        alive world || { tail -20 "$run/world.log"; die "the world exited"; }
        sleep 5
    done
    die "the world is not up after 10 min; see $run/world.log and $run/play_log_world"
}

autoware() {
    need TWIN_MAP
    alive autoware && die "Autoware is already up (pgid $(cat "$run/autoware.pgid")); twin stop first"
    [ -f "$root/install/setup.bash" ] || die "build first (just build)"
    echo "twin: the cart's Autoware on $TWIN_MAP, domain $TWIN_DOMAIN; log $run/autoware.log"
    ( source "$root/scripts/env.sh" > /dev/null 2>&1; source "$root/install/setup.bash"; dds_env
      if [ -n "${AUTOWARE_TENSORRT_LIB:-}" ] && [ -d "$AUTOWARE_TENSORRT_LIB" ]; then
          export LD_LIBRARY_PATH="$AUTOWARE_TENSORRT_LIB:${LD_LIBRARY_PATH:-}"
      fi
      export DISPLAY="${DISPLAY:-$TWIN_DISPLAY}"
      setsid play_launch launch --web-addr 0.0.0.0:${TWIN_WEB_PORT:-8096} \
          --log-dir "$run/play_log" golfcart_twin twin_autoware.launch.xml \
          map_path:="$TWIN_MAP" data_path:="$AUTOWARE_DATA" > "$run/autoware.log" 2>&1 < /dev/null &
      echo $! > "$run/autoware.pgid" )
    echo "twin: starting (about a minute); web UI on port ${TWIN_WEB_PORT:-8096}"
}

go() {
    local route=${1:-1}
    ( source /opt/autoware/1.5.0/setup.bash; dds_env
      python3 "$pkg/scripts/twin_go.py" "$route" --routes "$pkg/config/routes.yaml" "${@:2}" )
}

status() {
    for s in world autoware; do
        if alive $s; then echo "$s: up (pgid $(cat "$run/$s.pgid"))"; else echo "$s: down"; fi
    done
}

stop() {
    for s in autoware world; do
        if alive $s; then kill -TERM -"$(cat "$run/$s.pgid")"; echo "twin: stopping $s"; fi
        rm -f "$run/$s.pgid"
    done
}

cmd=${1:-}; shift || true
case "$cmd" in
    generate|world|autoware|go|status|stop) "$cmd" "$@" ;;
    *) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
esac
