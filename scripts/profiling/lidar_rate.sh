#!/usr/bin/env bash
#
# LiDAR frame rate, measured losslessly.
#
# Records the cloud topics for a fixed window and counts what landed in the bag.
# Do NOT substitute `ros2 topic hz` here: it is a Python node, it cannot keep up
# with a 1.4 MB PointCloud2 at 10 Hz, and it reports the rate it managed to
# receive as though it were the publish rate. It under-reads into exactly the
# 2-4 Hz range that looks like the send-buffer fault this script exists to
# detect. See docs/research/sensing/lidar-pipeline-starvation.md.
#
# Usage:  scripts/profiling/lidar_rate.sh [seconds]        (default 60)
#
# Needs the stack up (`just run`) and `source scripts/env.sh` already done.

set -u

SECS="${1:-60}"
OUT="$(mktemp -d "${TMPDIR:-/tmp}/lidar_rate.XXXXXX")"
BAG="$OUT/bag"
trap 'rm -rf "$OUT"' EXIT

TOPICS=(
  /sensing/lidar/vlp32/velodyne_points
  /sensing/lidar/falcon/iv_points
  /sensing/lidar/concatenated/pointcloud
)

if ! command -v ros2 >/dev/null 2>&1; then
  echo "ros2 not on PATH - run: source scripts/env.sh" >&2
  exit 1
fi

echo "recording ${SECS}s ..." >&2
ros2 bag record -o "$BAG" "${TOPICS[@]}" \
  --max-cache-size 2147483648 >"$OUT/rec.log" 2>&1 &
RPID=$!

# If the recorder died immediately (bad topic name, no daemon), say so rather
# than sleeping out the full window and printing an empty table.
sleep 3
if ! kill -0 "$RPID" 2>/dev/null; then
  echo "recorder exited early:" >&2
  tail -5 "$OUT/rec.log" >&2
  exit 1
fi

sleep "$SECS"
kill -INT "$RPID" 2>/dev/null
wait "$RPID" 2>/dev/null
sleep 2

DB=$(find "$BAG" -name '*.db3' | head -1)
if [ -z "$DB" ]; then
  echo "no bag written - is the stack up?" >&2
  exit 1
fi

# Count straight out of sqlite rather than parsing `ros2 bag info` text, and use
# each topic's OWN first/last stamp rather than the bag duration: a topic that
# starts late or dies early then reports its real rate instead of an average
# smeared over a window it was not publishing in.
python3 - "$DB" <<'PY'
import sqlite3, sys

con = sqlite3.connect(sys.argv[1])
rows = con.execute("""
    SELECT t.name, COUNT(m.timestamp), MIN(m.timestamp), MAX(m.timestamp)
    FROM messages m JOIN topics t ON m.topic_id = t.id
    GROUP BY t.name
""").fetchall()

out = []
for name, n, lo, hi in rows:
    span = (hi - lo) / 1e9
    # n-1 intervals between n messages; span of 0 means a single message.
    rate = f"{(n - 1) / span:.2f} Hz" if n > 1 and span > 0 else "n/a"
    out.append((name.removeprefix("/sensing/lidar/"), rate, n))

if not out:
    print("no messages recorded")
    raise SystemExit(1)

order = {"vlp32/velodyne_points": 0, "falcon/iv_points": 1,
         "concatenated/pointcloud": 2}
out.sort(key=lambda r: order.get(r[0], 99))

w1 = max(len("topic"), *(len(r[0]) for r in out))
w2 = max(len("rate"),  *(len(r[1]) for r in out))
bar = lambda l, m, r: l + "─" * (w1 + 2) + m + "─" * (w2 + 2) + r

print(bar("┌", "┬", "┐"))
print(f"│ {'topic'.center(w1)} │ {'rate'.center(w2)} │")
for name, rate, n in out:
    print(bar("├", "┼", "┤"))
    print(f"│ {name.ljust(w1)} │ {rate.rjust(w2)} │")
print(bar("└", "┴", "┘"))
PY
