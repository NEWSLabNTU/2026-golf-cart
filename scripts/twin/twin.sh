#!/usr/bin/env bash
# The cart in the NTU twin on Isaac Sim (docs/guides/isaac_twin_demo.md), behind `just twin`.
# `scripts/twin/twin.sh help` for the commands and options.
set -eo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
pkg="$root/src/simulation/golfcart_twin"
[ -f "$root/config/twin.env" ] && set -a && source "$root/config/twin.env" && set +a
TWIN_SWB=${TWIN_SWB:-$HOME/repos/scenario-world-bridge}
TWIN_DOMAIN=${TWIN_DOMAIN:-1}
TWIN_DISPLAY=${TWIN_DISPLAY-${DISPLAY:-}}
TWIN_GPU=${TWIN_GPU:-0}
AUTOWARE_DATA=${AUTOWARE_DATA:-$HOME/autoware_data}
SWB_URL=https://github.com/NEWSLabNTU/scenario-world-bridge.git
AUTOWARE=/opt/autoware/1.5.0
run="$root/log/twin"
mkdir -p "$run"
dds="file://$pkg/config/cyclonedds-unicast-lo.xml"

die() { echo "twin: $*" >&2; exit 1; }
need() { [ -n "${!1:-}" ] || die "$1 is not set (config/twin.env; twin.sh doctor)"; }
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

usage() {
    cat <<'USAGE'
The golf cart in the NTU twin on Isaac Sim: the whole demo from a clone of this repository.

Usage: scripts/twin/twin.sh COMMAND [OPTIONS]        (or: just twin COMMAND [OPTIONS])

First time on a host:
  setup                 config/twin.env from config/twin.env.example (fill it in, run again),
                        scenario-world-bridge cloned and built when absent, this repository built
  doctor                what this host still lacks for the demo, and how to get it

Run the demo (in the foreground; Ctrl-C ends everything it started):
  run [OPTIONS]         free drive by default; a scenario with --scenario
    -r, --route N         free drive from route N's start (default 1); drive it with RViz's goal
                          and AUTO, or `twin.sh go N` in a second terminal
    -s, --scenario NAME   run scenario NAME instead (see `list`; or a path to an .xosc): SSv2
                          places, routes and judges the cart, and the run ends with a verdict
        --showcase        every showcase_* scenario in turn, then their verdicts
        --no-perception   the cart without perception (it will not see the NPCs)
        --no-rviz         no RViz window
        --headless        Isaac without a window
        --fast            free drive as fast as the sim goes, not paced to the wall clock
        --follow MODE     Isaac's view: editor (default, the editor chasing the cart), true
                          (the chase without the editor UI), false (the editor's own camera)
    -- NAME:=VALUE ...    passed on to twin.launch.py as they are
  go [ROUTE]            set ROUTE's goal and engage (free drive), report until it arrives
  list                  the routes and scenarios
  status | stop         what twin.sh started; stop it (if a terminal was lost)

Shortcuts: drive [N] = run --route N; scenario NAME = run --scenario NAME;
           showcase [NAME..] = run --showcase (or just those)

Maintenance:
  generate [--check]    regenerate the cart's spec-derived files (rig, catalog, scenarios)
  world [N] | autoware  the parts apart: Isaac's stand-alone runner, the cart's Autoware

Examples:
  scripts/twin/twin.sh run                               # free drive, route 1
  scripts/twin/twin.sh run --route 2 --no-perception     # free drive, route 2, no perception
  scripts/twin/twin.sh run --scenario showcase_pedestrian
  scripts/twin/twin.sh run --showcase

Settings: config/twin.env (host paths, domains, display); logs: play_log/, log/twin/;
verdicts: log/twin/scenario/<name>/. Guide: docs/guides/isaac_twin_demo.md
USAGE
}

list_() {
    echo "Routes (free drive: run --route N):"
    python3 - "$pkg/config/routes.yaml" <<'PY'
import sys, yaml
for k, v in yaml.safe_load(open(sys.argv[1]))["routes"].items():
    print(f"  {k}  {v.get('title', '')}")
PY
    echo "Scenarios (run --scenario NAME):"
    local f d
    for f in "$pkg"/scenarios/*.xosc; do
        d=$(grep -o 'description="[^"]*' "$f" | head -1 | cut -c14- | sed 's/^NTU twin, //')
        printf '  %-24s %s\n' "$(basename "$f" .xosc)" "${d:0:90}"
    done
}

run_() {
    local route= scen= showcase=0 extra=()
    while [ $# -gt 0 ]; do
        case "$1" in
            -r|--route) route=${2:?--route N}; shift 2 ;;
            -s|--scenario) scen=${2:?--scenario NAME}; shift 2 ;;
            --showcase) showcase=1; shift ;;
            --no-perception) extra+=(perception:=false); shift ;;
            --no-rviz) extra+=(rviz:=false); shift ;;
            --headless) extra+=(render:=headless); shift ;;
            --fast) extra+=(realtime:=false); shift ;;
            --follow) extra+=(follow:="${2:?--follow editor|true|false}"); shift 2 ;;
            -h|--help) usage; return ;;
            --) shift; extra+=("$@"); break ;;
            *:=*) extra+=("$1"); shift ;;
            *) die "run: unknown option $1 (twin.sh help)" ;;
        esac
    done
    [ $(( ${route:+1} + ${scen:+1} + showcase )) -le 1 ] \
        || die "run: --route, --scenario and --showcase exclude one another"
    if [ "$showcase" = 1 ]; then showcase_run "" "${extra[@]}"
    elif [ -n "$scen" ]; then scenario "$scen" "${extra[@]}"
    else drive "${route:-1}" "${extra[@]}"; fi
}

# --- a fresh clone -------------------------------------------------------------------------

setup() {
    # Idempotent: each step is skipped when already done. What it cannot do for you (Isaac
    # Sim, the map, the assets) `doctor` names at the end.
    [ -f "$AUTOWARE/setup.bash" ] || die "Autoware 1.5.0 is not at $AUTOWARE: install it first (just setup)"
    if [ ! -f "$root/config/twin.env" ]; then
        cp "$root/config/twin.env.example" "$root/config/twin.env"
        die "wrote config/twin.env from the example: fill in this host's paths, then run setup again"
    fi
    echo "twin: submodules"
    git -C "$root" submodule update --init --recursive
    if [ ! -d "$TWIN_SWB/.git" ]; then
        echo "twin: cloning scenario-world-bridge into $TWIN_SWB"
        git clone --recursive "$SWB_URL" "$TWIN_SWB"
    fi
    if [ ! -f "$TWIN_SWB/install/swb_launch/share/swb_launch/launch/isaac.launch.xml" ]; then
        echo "twin: building scenario-world-bridge (its own just setup, then just build; long, once)"
        (cd "$TWIN_SWB" && just setup && just build)
    fi
    echo "twin: building this repository (just build)"
    (cd "$root" && just build)
    command -v play_launch > /dev/null || pip install --user play_launch
    doctor
}

doctor() {
    local bad=0 m=${TWIN_MAP:-} f miss=
    ok() { printf '  ok    %s\n' "$1"; }
    no() { printf '  MISS  %s\n        %s\n' "$1" "$2"; bad=1; }
    warn() { printf '  warn  %s\n        %s\n' "$1" "$2"; }
    echo "twin doctor ($root)"
    [ -f "$root/config/twin.env" ] && ok "config/twin.env" \
        || no "config/twin.env" "cp config/twin.env.example config/twin.env, and fill it in"
    [ -f "$AUTOWARE/setup.bash" ] && ok "Autoware 1.5.0" || no "Autoware 1.5.0 at $AUTOWARE" "just setup"
    if command -v play_launch > /dev/null; then ok "$(play_launch --version 2>&1 | head -1)"
    else no "play_launch" "pip install --user play_launch"; fi
    [ -f "$TWIN_SWB/install/setup.bash" ] && [ -d "$TWIN_SWB/install/swb_launch" ] \
        && ok "scenario-world-bridge built ($TWIN_SWB)" \
        || no "scenario-world-bridge built at TWIN_SWB=$TWIN_SWB" "twin.sh setup (clones and builds it)"
    [ -d "$root/install/golfcart_twin" ] && ok "this repository built" || no "this repository built" "just build"
    if [ -n "${ISAAC_ROOT:-}" ] && [ -x "$ISAAC_ROOT/venv/bin/python" ]; then ok "Isaac Sim ($ISAAC_ROOT)"
    else no "Isaac Sim 6.1 at ISAAC_ROOT=${ISAAC_ROOT:-unset}" \
        "ISAAC_ROOT=<dir> $TWIN_SWB/src/swb_isaac_world/scripts/install_isaac.sh"; fi
    for f in lanelet2_map.osm pointcloud_map map_projector_info.yaml isaac/world.yaml; do
        [ -n "$m" ] && [ -e "$m/$f" ] || miss="$miss $f"
    done
    [ -z "$miss" ] && ok "the twin's map ($m)" \
        || no "the twin's map at TWIN_MAP=${m:-unset} (lacks:$miss)" "copy the map directory to a local disk (not the NAS)"
    [ -n "${SWB_VEHICLE_USD:-}" ] && [ -d "$SWB_VEHICLE_USD/walkers" ] && ok "NPC assets ($SWB_VEHICLE_USD)" \
        || no "NPC assets at SWB_VEHICLE_USD=${SWB_VEHICLE_USD:-unset} (vehicles and walkers)" \
              "swb's Isaac asset set, carla-usd/vehicles (swb docs/design/isaac-assets.md)"
    compgen -G "$AUTOWARE_DATA/lidar_centerpoint/pts_backbone_neck_head_centerpoint_tiny.onnx" > /dev/null \
        && ok "CenterPoint tiny ($AUTOWARE_DATA)" \
        || no "CenterPoint tiny in AUTOWARE_DATA=$AUTOWARE_DATA" "Autoware's model download (just setup), or point AUTOWARE_DATA at a copy"
    [ -n "${AUTOWARE_TENSORRT_LIB:-}" ] && [ -d "$AUTOWARE_TENSORRT_LIB" ] && ok "TensorRT 10.8 ($AUTOWARE_TENSORRT_LIB)" \
        || warn "no TensorRT 10.8 runtime (AUTOWARE_TENSORRT_LIB)" "CenterPoint's engine rebuilds at every start; swb: just setup-tensorrt"
    if [ -z "$TWIN_DISPLAY" ]; then warn "no display (TWIN_DISPLAY)" "Isaac runs headless and RViz cannot open"
    elif DISPLAY=$TWIN_DISPLAY xset q > /dev/null 2>&1; then ok "display $TWIN_DISPLAY"
    else no "display $TWIN_DISPLAY" "an X server you own, e.g. TurboVNC: Xvnc :9"; fi
    if [ -d "$TWIN_SWB/src/sim_vehicle_spec" ]; then
        ( generate --check ) > "$run/generate-check.log" 2>&1 && ok "generated files current" \
            || no "generated files stale ($run/generate-check.log)" "twin.sh generate, rebuild, commit"
    fi
    if [ "$bad" = 0 ]; then echo "twin: ready: twin.sh drive 1, or twin.sh showcase"
    else echo "twin: not ready"; return 1; fi
}

# --- the demo: swb's whole stack in one launch (twin.launch.py) ----------------------------

launch() {  # launch NAME ARGS...: twin.launch.py in its own process group, waited on here
    local name=$1 pid; shift
    alive stack && die "the demo is already up (pgid $(cat "$run/stack.pgid")); twin.sh stop first"
    [ -d "$root/install/golfcart_twin" ] || die "build first (twin.sh setup)"
    need TWIN_MAP
    rm -f "$run/stack.pgid"
    # The subshell writes its own pid, then becomes play_launch: setsid (not a group leader
    # here, so it does not fork) makes that pid the new process group's, which stop signals.
    (
        export DISPLAY="$TWIN_DISPLAY"
        source "$root/scripts/twin/setup.bash" > /dev/null
        cd "$root"
        echo "$BASHPID" > "$run/stack.pgid"
        exec setsid play_launch launch golfcart_twin twin.launch.py "$@" < /dev/null
    ) > >(tee "$run/$name.log") 2>&1 &
    for _ in $(seq 1 50); do [ -s "$run/stack.pgid" ] && break; sleep 0.2; done
    pid=$(cat "$run/stack.pgid")
    trap 'echo; echo "twin: stopping"; kill -TERM -"$pid" 2>/dev/null' INT TERM
    while kill -0 "$pid" 2>/dev/null; do sleep 1; done
    trap - INT TERM
    rm -f "$run/stack.pgid"
}

drive() {
    local route=${1:-1}; shift || true
    route_field "$route" start > /dev/null
    echo "twin: free drive from route $route's start; in another terminal: scripts/twin/twin.sh go $route"
    launch "drive" route:="$route" "$@"
}

verdict() {  # verdict OUTDIR NAME: prints one line, returns 0 on a pass
    local j="$1/scenario_test_runner/result.junit.xml"
    [ -f "$j" ] || { echo "$2: NO RESULT (no $j)"; return 1; }
    if grep -q '<testsuite [^>]*failures="0" errors="0"' "$j"; then echo "$2: PASS"; return 0; fi
    echo "$2: FAIL: $(grep -o 'message="[^"]*' "$j" | head -1 | cut -c10-300 | sed 's/&quot;/"/g')"
    return 1
}

scenario() {
    local name=${1:?scenario NAME: route1..route4, showcase_pedestrian, ..., or an .xosc} base out
    shift
    base=$(basename "$name" .xosc)
    [ "${name%.xosc}" != "$name" ] || [ -f "$pkg/scenarios/$name.xosc" ] \
        || die "no scenario $name; the package has: $(ls "$pkg/scenarios" | sed 's/\.xosc$//' | tr '\n' ' ')"
    out="$run/scenario/$base"
    rm -rf "${out:?}"; mkdir -p "$out"
    launch "scenario-$base" scenario:="$name" exit_on_scenario_end:=true \
        scenario_args:=output_directory:="$out" "$@"
    verdict "$out" "$base"
}

showcase() {  # showcase [NAME ...]
    showcase_run "$*"
}

showcase_run() {  # showcase_run "NAMES" [NAME:=VALUE ...]; no NAMES: every showcase_*
    local names=() n line rc=0 results=()
    read -r -a names <<< "$1"; shift
    [ ${#names[@]} -gt 0 ] || mapfile -t names < <(ls "$pkg/scenarios" | sed -n 's/^\(showcase_.*\)\.xosc$/\1/p')
    for n in "${names[@]}"; do
        echo "twin: === $n ==="
        line=$(scenario "$n" "$@" | tee /dev/stderr | tail -1) || true
        results+=("$line")
        [[ "$line" == *": PASS" ]] || rc=1
    done
    echo "twin: showcase results"
    printf '  %s\n' "${results[@]}"
    return $rc
}

go() {
    local route=${1:-1}
    ( source "$AUTOWARE/setup.bash"; dds_env
      python3 "$pkg/scripts/twin_go.py" "$route" --routes "$pkg/config/routes.yaml" "${@:2}" )
}

# --- the parts apart: Isaac's stand-alone runner and the cart's Autoware -------------------

world() {
    local route=${1:-1}
    need ISAAC_ROOT; need TWIN_MAP
    route_field "$route" start > /dev/null
    alive world && die "the world is already up (pgid $(cat "$run/world.pgid")); twin stop first"
    echo "twin: Isaac Sim, route $route's start, domain $TWIN_DOMAIN, window ${TWIN_DISPLAY:-none};" \
         "log $run/world.log"
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

status() {
    for s in stack world autoware; do
        if alive $s; then echo "$s: up (pgid $(cat "$run/$s.pgid"))"; else echo "$s: down"; fi
    done
}

stop() {
    for s in stack autoware world; do
        if alive $s; then kill -TERM -"$(cat "$run/$s.pgid")"; echo "twin: stopping $s"; fi
        rm -f "$run/$s.pgid"
    done
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

cmd=${1:-}; shift || true
case "$cmd" in
    run) run_ "$@" ;;
    list) list_ ;;
    help|-h|--help|"") usage ;;
    setup|doctor|drive|go|scenario|showcase|status|stop|generate|world|autoware) "$cmd" "$@" ;;
    *) echo "twin: unknown command $cmd" >&2; usage >&2; exit 2 ;;
esac
