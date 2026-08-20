#!/usr/bin/env bash
#
# Acceptance test for the mode availability strip (Phase 4-O sub-phase O-C).
# See docs/roadmaps/4-diagnostics-observability.md.
#
# Brings up the diagnostic graph aggregator, the AD API diagnostics node and
# rosbridge, publishes a synthetic healthy /diagnostics for every leaf in the
# graph, then forces ONE leaf to ERROR and checks that the right mode chips turn
# red and the unrelated ones do not.
#
# It replicates the page's join logic rather than driving a browser, because
# that join is the part that can be wrong: status.nodes[i] corresponds to
# struct.nodes[i], and DiagNodeStatus carries no path, so an off-by-one
# mislabels every chip and still looks plausible.
#
# Needs no vehicle, no sensors and no map.
#
set -o pipefail
set -m

source /opt/ros/humble/setup.bash
source /opt/autoware/1.5.0/setup.bash
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[ -f "$REPO/install/setup.bash" ] && source "$REPO/install/setup.bash"

GRAPH=/opt/autoware/1.5.0/share/autoware_launch/config/system/diagnostics/autoware-main.yaml
AGGP=/opt/autoware/1.5.0/share/autoware_diagnostic_graph_aggregator/config/default.param.yaml
VEH="$REPO/install/golfcart_vehicle_description/share/golfcart_vehicle_description/config/vehicle_info.param.yaml"
LOG=$(mktemp -d)

# PGIDS, not GROUPS: GROUPS is a bash special array and assigning to it silently
# aborts the enclosing function. `set -m` puts each background job in its own
# process group so `kill -- -$!` takes the forked node with it; setsid does not
# work here, see scripts/check/rosbridge_graph_feed.sh.
PGIDS=()
cleanup() { for g in "${PGIDS[@]:-}"; do kill -9 -- "-$g" 2>/dev/null; done; }
trap cleanup EXIT

stale=$(pgrep -cf 'aggregator_nod[e]|rosbridge_websocke[t]')
if [ "$stale" -gt 0 ]; then
    echo "WARNING: $stale aggregator/rosbridge already running; results will be wrong." >&2
fi

ros2 run autoware_diagnostic_graph_aggregator aggregator_node --ros-args \
    --params-file "$AGGP" --params-file "$VEH" -p graph_file:="$GRAPH" \
    -r __ns:=/system -r '~/struct:=/diagnostics_graph/struct' \
    -r '~/status:=/diagnostics_graph/status' > "$LOG/agg.out" 2> "$LOG/agg.err" &
PGIDS+=($!)
ros2 run rclcpp_components component_container --ros-args -r __node:=oc_probe \
    > "$LOG/c.out" 2> "$LOG/c.err" &
PGIDS+=($!)
sleep 6
ros2 component load /oc_probe autoware_default_adapi_universe \
    autoware::default_adapi::DiagnosticsNode > /dev/null 2>&1
ros2 launch rosbridge_server rosbridge_websocket_launch.xml \
    > "$LOG/rb.out" 2> "$LOG/rb.err" &
PGIDS+=($!)
sleep 7

python3 - "$LOG" <<'PY'
import asyncio, json, sys, threading, time
import rclpy
from rclpy.node import Node
from diagnostic_msgs.msg import DiagnosticArray, DiagnosticStatus
import websockets

LOG = sys.argv[1]
STRUCT = "/api/system/diagnostics/struct"
STATUS = "/api/system/diagnostics/status"
# One leaf under /autoware/control/emergency_braking. Chosen because it feeds
# some modes and not others, so the test can prove the strip is selective rather
# than just turning everything red.
VICTIM = "autonomous_emergency_braking: aeb_emergency_stop"

class Injector(Node):
    """Publish a synthetic /diagnostics for every leaf the graph expects."""
    def __init__(self, names):
        super().__init__("oc_injector")
        self.pub = self.create_publisher(DiagnosticArray, "/diagnostics", 10)
        self.names = names
        self.bad = set()
        self.create_timer(0.1, self.tick)

    def tick(self):
        msg = DiagnosticArray()
        msg.header.stamp = self.get_clock().now().to_msg()
        for n in self.names:
            s = DiagnosticStatus()
            s.name = n
            s.hardware_id = "oc_test"
            s.level = bytes([2]) if n in self.bad else bytes([0])
            s.message = "forced ERROR" if n in self.bad else "OK"
            msg.status.append(s)
        self.pub.publish(msg)

async def run():
    ws = await websockets.connect("ws://localhost:9090", max_size=None)
    await ws.send(json.dumps({"op": "subscribe", "topic": STRUCT,
                              "type": "autoware_adapi_v1_msgs/msg/DiagGraphStruct"}))
    await ws.send(json.dumps({"op": "subscribe", "topic": STATUS,
                              "type": "autoware_adapi_v1_msgs/msg/DiagGraphStatus"}))

    graph = None
    async def pump(deadline):
        """Drain the socket until deadline, returning the newest status."""
        nonlocal graph
        latest = None
        while time.time() < deadline:
            try:
                raw = await asyncio.wait_for(ws.recv(), timeout=0.2)
            except asyncio.TimeoutError:
                continue
            m = json.loads(raw)
            if m.get("op") != "publish":
                continue
            if m["topic"] == STRUCT:
                graph = m["msg"]
            elif m["topic"] == STATUS:
                latest = m["msg"]
        return latest

    await pump(time.time() + 6)
    if graph is None:
        print("FAIL: no struct received"); return 1

    modes = {i: n["path"].rsplit("/", 1)[-1]
             for i, n in enumerate(graph["nodes"])
             if n["path"].startswith("/autoware/modes/")}
    leaves = [d["name"] for d in graph["diags"]]
    print(f"graph: {len(graph['nodes'])} nodes, {len(leaves)} leaves, {len(modes)} mode roots")
    if VICTIM not in leaves:
        print(f"FAIL: victim leaf not in graph: {VICTIM}"); return 1

    # rclpy spins on its own thread. Interleaving spin_once with the websocket
    # drain in one thread stops /diagnostics while sampling, the aggregator ages
    # every leaf out, and the baseline reads all-ERROR: the test then measures
    # its own starvation instead of the injected fault.
    rclpy.init()
    inj = Injector(leaves)
    stop = threading.Event()
    def spin_forever():
        while not stop.is_set():
            rclpy.spin_once(inj, timeout_sec=0.05)
    threading.Thread(target=spin_forever, daemon=True).start()
    def spin(sec):
        time.sleep(sec)

    def chips(status):
        return {modes[i]: status["nodes"][i]["level"] for i in modes}

    # --- 1. everything healthy -------------------------------------------
    spin(3)
    healthy = await pump(time.time() + 2)
    if healthy is None:
        print("FAIL: no status received"); rclpy.shutdown(); return 1
    before = chips(healthy)
    print("all leaves OK      ->", before)
    if any(v != 0 for v in before.values()):
        print("FAIL: baseline is not healthy. Every leaf is being published OK, so "
              "a non-zero chip here means the graph never converged, not that the "
              "test found a fault.")
        stop.set(); rclpy.shutdown(); await ws.close(); return 1

    # --- 2. force one leaf to ERROR, time the reaction --------------------
    inj.bad.add(VICTIM)
    t0 = time.time()
    after = before
    while time.time() - t0 < 5:
        spin(0.3)
        s = await pump(time.time() + 0.3)
        if s is None:
            continue
        after = chips(s)
        if any(after[k] != before[k] for k in before):
            break
    dt = time.time() - t0
    print(f"{VICTIM} -> ERROR ->", after)
    print(f"reaction time: {dt:.2f}s")

    changed = sorted(k for k in before if after[k] != before[k])
    same = sorted(k for k in before if after[k] == before[k])

    stop.set(); time.sleep(0.2); rclpy.shutdown()
    await ws.close()

    ok = True
    if not changed:
        print("FAIL: no mode chip reacted to the injected fault"); ok = False
    else:
        print(f"PASS: chips that went bad: {changed}")
    if dt > 1.0:
        print(f"FAIL: reaction took {dt:.2f}s, budget is 1.0s"); ok = False
    else:
        print(f"PASS: reacted within 1s ({dt:.2f}s)")
    if not same:
        print("FAIL: every chip changed, so the strip is not selective"); ok = False
    else:
        print(f"PASS: unaffected chips stayed put: {same}")
    return 0 if ok else 1

sys.exit(asyncio.run(run()))
PY
rc=$?
echo
echo "logs: $LOG"
exit $rc
