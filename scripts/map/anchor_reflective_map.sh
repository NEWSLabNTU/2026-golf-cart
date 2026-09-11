#!/usr/bin/env bash
# anchor_reflective_map.sh - rebuild an indoor map anchored to the reflective board.
#
#   scripts/map/anchor_reflective_map.sh                     # dry run, basement
#   scripts/map/anchor_reflective_map.sh --write             # write data/basement-indoor
#   scripts/map/anchor_reflective_map.sh --write --force     # ...even if the anchor moved
#   scripts/map/anchor_reflective_map.sh --cloud X.ply --out DIR --scenario NAME
#   scripts/map/anchor_reflective_map.sh -- --floor-band 0.5 # extra anchor-map-to-board flags
#
# Anchoring moves the origin every other map artifact is relative to, and a
# wrong anchor has no later symptom: the detector confirms its own error at
# startup, because the same code built the map. So this is DRY-RUN by default,
# writes into a scratch directory first, and refuses to replace an existing
# anchor whose transform differs unless told --force.
#
# The detector file is the scenario's falcon_map.yaml, read from the source
# tree by path (it is never launched, so it is not taken from install/). The
# basement one is the configuration the survey team actually anchored with,
# reproduced to five decimals (docs/roadmaps/7-reflective-board-cold-start.md,
# B3), and this script checks every run against that same bar: the transform
# printed by the tool is compared with the existing board_anchor.yaml.
#
# Written beside the map, on --write:
#   pointcloud_map.pcd, board_anchor.yaml (transform, floor tilt, detection),
#   board_polygon.osm, map_projector_info.yaml   - from anchor-map-to-board
#   anchor_run.txt                               - what produced them: config and
#                                                  cloud paths and sha256, repo
#                                                  revisions, the extra flags
# lanelet2_map.osm is seeded from board_polygon.osm only when absent; an
# existing one is the route's vector map and is left for a person to merge.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCENARIO=basement
WRITE=0
FORCE=0
CLOUD=""
OUT=""
EXTRA=()

while [ $# -gt 0 ]; do
    case "$1" in
        --write) WRITE=1 ;;
        --force) FORCE=1 ;;
        --scenario) SCENARIO="$2"; shift ;;
        --cloud) CLOUD="$2"; shift ;;
        --out) OUT="$2"; shift ;;
        --) shift; EXTRA=("$@"); break ;;
        -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1 (see --help)" >&2; exit 2 ;;
    esac
    shift
done

CONFIG="${REPO_ROOT}/src/launcher/golfcart_launch/config/localization/reflective_pose/scenarios/${SCENARIO}/falcon_map.yaml"
[ -f "$CONFIG" ] || { echo "no offline detector file for scenario '${SCENARIO}': ${CONFIG}" >&2; exit 2; }

if [ -z "$CLOUD" ]; then
    case "$SCENARIO" in
        basement) CLOUD="${GOLFCART_BASEMENT_CLOUD:-/home/aeon/nas/autoveh/dataset/2026-08-20 GLIM pointcloud mapping bags/glim_falcon_map/basement_voxel_resol_0.15.ply}" ;;
        *) echo "scenario '${SCENARIO}' has no default cloud; pass --cloud" >&2; exit 2 ;;
    esac
fi
[ -f "$CLOUD" ] || { echo "no cloud at: ${CLOUD}" >&2; exit 2; }
OUT="${OUT:-${REPO_ROOT}/data/${SCENARIO}-indoor}"

set +u
# shellcheck source=/dev/null
source "${REPO_ROOT}/scripts/env.sh" >/dev/null
set -u

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/anchor_reflective_map.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

anchor() {  # $@ = extra flags for the tool
    ros2 run reflective_pose_cli anchor-map-to-board "$CLOUD" -o "$SCRATCH/map" \
        --config "$CONFIG" "${EXTRA[@]}" "$@"
}

# The transform the tool printed vs the one board_anchor.yaml holds, to 1e-4.
# Prints "match", "moved" or "none" (no existing anchor).
compare_transform() {  # $1 = tool output file
    python3 - "$1" "$OUT/board_anchor.yaml" <<'PY'
import re, sys, pathlib
out = pathlib.Path(sys.argv[1]).read_text().splitlines()
i = next(n for n, l in enumerate(out) if l.startswith("transform (map <- cloud)"))
new = [[float(v) for v in out[i + 1 + r].split()] for r in range(3)]
ref = pathlib.Path(sys.argv[2])
if not ref.is_file():
    print("none"); sys.exit()
rows = re.findall(r"^\s*- \[([^\]]*)\]", ref.read_text(), re.M)[:3]
old = [[float(v) for v in r.split(",")] for r in rows]
d = max(abs(a - b) for rn, ro in zip(new, old) for a, b in zip(rn, ro))
print("match" if d <= 1e-4 else f"moved (max element difference {d:.6f})")
PY
}

echo "cloud:    $CLOUD"
echo "config:   $CONFIG"
echo "output:   $OUT$([ $WRITE = 1 ] || echo '   (dry run)')"
echo

if [ "$WRITE" = 0 ]; then
    anchor --dry-run | tee "$SCRATCH/tool.txt"
    echo
    echo "against ${OUT}/board_anchor.yaml: $(compare_transform "$SCRATCH/tool.txt")"
    echo "dry run: nothing written. Re-run with --write to build the map."
    exit 0
fi

anchor | tee "$SCRATCH/tool.txt"
verdict="$(compare_transform "$SCRATCH/tool.txt")"
echo
echo "against ${OUT}/board_anchor.yaml: ${verdict}"
case "$verdict" in
    match|none) ;;
    *)
        if [ "$FORCE" = 0 ]; then
            echo "REFUSED: the anchor moved. Every artifact relative to the old origin" >&2
            echo "(lanelet2_map.osm, recorded initial poses, tag maps) would silently" >&2
            echo "shift with it. Re-run with --force if that is the intent." >&2
            exit 3
        fi
        echo "--force: replacing an anchor that moved" >&2 ;;
esac

mkdir -p "$OUT"
for f in pointcloud_map.pcd board_anchor.yaml board_polygon.osm map_projector_info.yaml; do
    cp "$SCRATCH/map/$f" "$OUT/$f"
done
if [ ! -f "$OUT/lanelet2_map.osm" ]; then
    cp "$SCRATCH/map/board_polygon.osm" "$OUT/lanelet2_map.osm"
    echo "seeded lanelet2_map.osm from board_polygon.osm"
else
    echo "kept existing lanelet2_map.osm; merge board_polygon.osm into it if the board moved"
fi
{
    echo "# Written by scripts/map/anchor_reflective_map.sh; what produced this map."
    echo "date: $(date -Iseconds)"
    echo "cloud: $CLOUD"
    echo "cloud_sha256: $(sha256sum "$CLOUD" | cut -d' ' -f1)"
    echo "config: ${CONFIG#"$REPO_ROOT"/}"
    echo "config_sha256: $(sha256sum "$CONFIG" | cut -d' ' -f1)"
    echo "golf_cart_rev: $(git -C "$REPO_ROOT" rev-parse --short HEAD)"
    echo "reflective_pose_detector_rev: $(git -C "$REPO_ROOT/src/localization/reflective_pose_detector" rev-parse --short HEAD)"
    echo "extra_flags: ${EXTRA[*]:-none}"
    echo "anchor_verdict: $verdict"
} > "$OUT/anchor_run.txt"
echo "wrote $OUT"
