#!/usr/bin/env bash
#
# Measure the diagnostic graph as it arrives over rosbridge: rate, message size,
# bandwidth, and whether both topics deliver in either startup order.
#
# Phase 4-O check O-A2, the rosbridge-or-rclpy decision. See
# docs/roadmaps/4-diagnostics-observability.md.
#
# The point is not that rosbridge works. It is that O-A found the two graph
# topics disagree on QoS, and a subscriber applying one profile to both silently
# receives nothing on one of them. rosbridge derives the profile from the
# publishers per topic (rosbridge_library/internal/subscribers.py), so it cannot
# make that mistake. This script confirms that claim against real traffic rather
# than trusting the source read.
#
# Needs no vehicle. Brings up its own aggregator, AD API diagnostics node and
# rosbridge.
#
# Usage:
#   ./scripts/check/rosbridge_graph_feed.sh            # bandwidth, 15 s
#   ./scripts/check/rosbridge_graph_feed.sh --order    # also test startup order
#
set -o pipefail
set -m

ORDER=0
[ "${1:-}" = "--order" ] && ORDER=1

source /opt/ros/humble/setup.bash
source /opt/autoware/1.5.0/setup.bash
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[ -f "$REPO/install/setup.bash" ] && source "$REPO/install/setup.bash"

GRAPH=/opt/autoware/1.5.0/share/autoware_launch/config/system/diagnostics/autoware-main.yaml
AGGP=/opt/autoware/1.5.0/share/autoware_diagnostic_graph_aggregator/config/default.param.yaml
VEH="$REPO/install/golfcart_vehicle_description/share/golfcart_vehicle_description/config/vehicle_info.param.yaml"
LOG=$(mktemp -d)
PGIDS=()

# PGIDS, not GROUPS: `GROUPS` is a bash special array holding the user's group
# IDs, and assigning to it is a fatal assignment error that silently ABORTS the
# enclosing function. With it named GROUPS this script started the aggregator,
# hit the assignment, and returned from start_stack without ever launching the
# bridge, reporting only "cannot reach rosbridge".
#
# `ros2 run` forks the node, so killing just the PID it returns leaves the node
# alive and still publishing. A first run of this measurement read 173 Hz and
# 1.2 MiB/s because four orphaned aggregators from earlier runs were all
# publishing at once, and a later one reused a stale stack across both cases.
#
# `set -m` above is what makes the fix work: with job control on, each background
# job becomes its own process group whose ID equals $!, so `kill -- -$!` takes
# the node with it. Do NOT reach for setsid here. setsid forks when it is already
# a process group leader, so the new session's ID is the grandchild's PID, not
# $!, and the kill silently matches nothing.
cleanup() { for g in "${PGIDS[@]:-}"; do kill -9 -- "-$g" 2>/dev/null; done; }
trap cleanup EXIT

start_stack() {
    ros2 run autoware_diagnostic_graph_aggregator aggregator_node --ros-args \
        --params-file "$AGGP" --params-file "$VEH" -p graph_file:="$GRAPH" \
        -r __ns:=/system \
        -r '~/struct:=/diagnostics_graph/struct' \
        -r '~/status:=/diagnostics_graph/status' \
        > "$LOG/agg.out" 2> "$LOG/agg.err" &
    PGIDS+=($!)
    ros2 run rclcpp_components component_container \
        --ros-args -r __node:=rb_probe > "$LOG/c.out" 2> "$LOG/c.err" &
    PGIDS+=($!)
    sleep 6
    ros2 component load /rb_probe autoware_default_adapi_universe \
        autoware::default_adapi::DiagnosticsNode > /dev/null 2>&1
}

start_bridge() {
    ros2 launch rosbridge_server rosbridge_websocket_launch.xml \
        > "$LOG/rb.out" 2> "$LOG/rb.err" &
    PGIDS+=($!)
    sleep 6
}

measure() {  # $1 = seconds, $2 = label
python3 - "$1" "$2" <<'PY'
import asyncio, json, sys, time
try:
    import websockets
except ImportError:
    print("   need `pip install websockets`"); sys.exit(1)

SECS, LABEL = float(sys.argv[1]), sys.argv[2]
T = {"/api/system/diagnostics/struct": "autoware_adapi_v1_msgs/msg/DiagGraphStruct",
     "/api/system/diagnostics/status": "autoware_adapi_v1_msgs/msg/DiagGraphStatus"}

async def main():
    n = {t: 0 for t in T}; b = {t: 0 for t in T}; first = {}
    try:
        ws = await websockets.connect("ws://localhost:9090", max_size=None)
    except Exception as e:
        print(f"   cannot reach rosbridge: {e}"); return 1
    async with ws:
        for t, ty in T.items():
            await ws.send(json.dumps({"op": "subscribe", "topic": t, "type": ty}))
        t0 = time.time(); end = t0 + SECS
        while time.time() < end:
            try:
                raw = await asyncio.wait_for(ws.recv(), timeout=1)
            except asyncio.TimeoutError:
                continue
            m = json.loads(raw)
            if m.get("op") == "publish":
                n[m["topic"]] += 1; b[m["topic"]] += len(raw)
                first.setdefault(m["topic"], m["msg"])
        el = time.time() - t0
    print(f"   [{LABEL}]")
    for t in T:
        name = t.rsplit("/", 1)[-1]
        per = b[t] / n[t] if n[t] else 0
        print(f"   {name:<7} {n[t]:>6} msgs {n[t]/el:>7.1f} Hz "
              f"{b[t]/el/1024:>8.1f} KiB/s {per:>7.0f} B/msg")
    print(f"   total {sum(b.values())/el/1024:.1f} KiB/s")
    s = first.get("/api/system/diagnostics/struct")
    if s:
        roots = [x["path"] for x in s.get("nodes", []) if x["path"].startswith("/autoware/modes/")]
        print(f"   struct: {len(s.get('nodes',[]))} nodes, {len(s.get('diags',[]))} leaves, "
              f"{len(roots)} mode roots, id={s.get('id')}")
    missing = [t for t in T if n[t] == 0]
    if missing:
        print("   MISSING:", ", ".join(missing)); return 1
    return 0

sys.exit(asyncio.run(main()))
PY
}

stale=$(pgrep -cf 'aggregator_nod[e]|rosbridge_websocke[t]')
if [ "$stale" -gt 0 ]; then
    echo "WARNING: $stale aggregator/rosbridge process(es) already running." >&2
    echo "They will be counted in these figures. Stop them first." >&2
fi

echo "=== bandwidth: Autoware up first, then bridge, then client ==="
start_stack; start_bridge; sleep 3
measure 15 "steady state"

if [ "$ORDER" -eq 1 ]; then
    cleanup; PGIDS=(); sleep 4
    echo
    echo "=== startup order: client subscribes BEFORE Autoware exists ==="
    echo "    (the monitor-running-before-the-vehicle case)"
    start_bridge
    measure 30 "client first" &
    M=$!
    sleep 5
    echo "    ...starting Autoware now"
    start_stack
    wait $M
fi

echo
echo "logs: $LOG"
