#!/usr/bin/env bash
#
# Report the QoS of every diagnostic-graph topic a monitor would subscribe, and
# prove whether a late-joining subscriber can interpret the graph at all.
#
# Phase 4-O check O-A. See docs/roadmaps/4-diagnostics-observability.md.
#
# Why this exists. `struct` and `status` are separate messages joined by array
# index: DiagLinkStruct carries parent and child as indices into the struct's
# nodes array, and DiagNodeStatus has no path field. A subscriber holding only
# status has a list of levels it cannot name. So whether struct is published
# transient_local decides whether a monitor started after Autoware can show
# anything, and that question blocks the whole design.
#
# It needs no vehicle and no sensors. QoS is declared by the publisher's code,
# so running the same binaries anywhere gives the same answer. Run it against a
# live stack too if you want to confirm nothing in the launch overrides it.
#
# Usage:
#   ./scripts/check/diag_graph_qos.sh            # brings up its own aggregator
#   ./scripts/check/diag_graph_qos.sh --attach   # probe an already-running stack
#
set -o pipefail

ATTACH=0
[ "${1:-}" = "--attach" ] && ATTACH=1

source /opt/ros/humble/setup.bash
source /opt/autoware/1.5.0/setup.bash
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[ -f "$REPO/install/setup.bash" ] && source "$REPO/install/setup.bash"

GRAPH=/opt/autoware/1.5.0/share/autoware_launch/config/system/diagnostics/autoware-main.yaml
AGGP=/opt/autoware/1.5.0/share/autoware_diagnostic_graph_aggregator/config/default.param.yaml
VEH="$REPO/install/golfcart_vehicle_description/share/golfcart_vehicle_description/config/vehicle_info.param.yaml"
LOG=$(mktemp -d)
PIDS=()

cleanup() { for p in "${PIDS[@]:-}"; do kill -9 "$p" 2>/dev/null; done; }
trap cleanup EXIT

if [ "$ATTACH" -eq 0 ]; then
    for f in "$GRAPH" "$AGGP" "$VEH"; do
        [ -f "$f" ] || { echo "missing: $f" >&2; exit 1; }
    done

    # The remaps MUST stay quoted. `~/struct` at the start of a word is a bash
    # tilde expansion, so unquoted it becomes /home/<user>/struct and the
    # aggregator publishes to a topic nobody is looking at, with no error.
    ros2 run autoware_diagnostic_graph_aggregator aggregator_node --ros-args \
        --params-file "$AGGP" --params-file "$VEH" -p graph_file:="$GRAPH" \
        -r __ns:=/system \
        -r '~/struct:=/diagnostics_graph/struct' \
        -r '~/status:=/diagnostics_graph/status' \
        -r '~/reset:=/diagnostics_graph/reset' \
        > "$LOG/agg.out" 2> "$LOG/agg.err" &
    PIDS+=($!)

    ros2 run rclcpp_components component_container \
        --ros-args -r __node:=diag_qos_probe \
        > "$LOG/cont.out" 2> "$LOG/cont.err" &
    PIDS+=($!)

    sleep 6
    ros2 component load /diag_qos_probe autoware_default_adapi_universe \
        autoware::default_adapi::DiagnosticsNode > "$LOG/load.out" 2>&1 \
        || { echo "failed to load DiagnosticsNode:"; cat "$LOG/load.out"; }
    sleep 5
fi

echo "=== publisher QoS ==="
printf '%-38s %-12s %s\n' TOPIC RELIABILITY DURABILITY
for t in /diagnostics_graph/struct /diagnostics_graph/status \
         /api/system/diagnostics/struct /api/system/diagnostics/status; do
    info=$(timeout 10 ros2 topic info -v "$t" 2>/dev/null \
        | awk '/Endpoint type: PUBLISHER/{p=1} p&&/Reliability:|Durability:/{print $2} /^$/{p=0}' \
        | head -2)
    rel=$(echo "$info" | sed -n 1p); dur=$(echo "$info" | sed -n 2p)
    printf '%-38s %-12s %s\n' "$t" "${rel:-<no publisher>}" "${dur:-}"
done

echo
echo "=== late join: can a monitor starting now read the graph? ==="
timeout 12 ros2 topic echo --once \
    --qos-durability transient_local --qos-reliability reliable \
    /api/system/diagnostics/struct > "$LOG/struct.yaml" 2>&1

python3 - "$LOG/struct.yaml" <<'PY'
import sys, yaml
try:
    docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if isinstance(d, dict)]
except Exception as e:
    print("   FAILED to parse:", e); sys.exit(1)
if not docs:
    print("   NOTHING RECEIVED. A late joiner cannot interpret status.")
    sys.exit(1)
d = docs[0]
roots = [n["path"] for n in d.get("nodes", []) if n["path"].startswith("/autoware/modes/")]
print(f"   RECEIVED. graph id {d.get('id')}")
print(f"   {len(d.get('nodes', []))} nodes, {len(d.get('diags', []))} leaves, "
      f"{len(d.get('links', []))} links, {len(roots)} mode roots")
for r in sorted(roots):
    print("     ", r)
PY

echo
echo "=== the QoS-match trap ==="
echo "status is BEST_EFFORT. A RELIABLE subscriber will match nothing:"
timeout 8 ros2 topic echo --once --qos-reliability reliable \
    /api/system/diagnostics/status > "$LOG/rel.yaml" 2>&1
if [ -s "$LOG/rel.yaml" ] && grep -q 'stamp' "$LOG/rel.yaml"; then
    echo "   received (unexpected: re-check the publisher QoS above)"
else
    echo "   nothing in 8s, as expected. Subscribe status BEST_EFFORT."
fi

echo
echo "logs: $LOG"
