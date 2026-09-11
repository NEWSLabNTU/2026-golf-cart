#!/usr/bin/env python3
"""Profile the indoor logging simulation: where the time and the bytes go.

Samples, once a second, for every process in the replay:
  * CPU  from /proc/<pid>/stat  (utime+stime deltas against wall clock)
  * RSS  from /proc/<pid>/statm
  * disk from /proc/<pid>/io    (read_bytes = actual block-layer reads)

and, over the same window, the rate of each topic that matters plus the NDT
scan matcher's own exe_time_ms. Prints a table ranked by CPU.

Run it while the stack is up and the bag is playing; it does not start or stop
anything, so it can be pointed at a run driven by the just recipes.
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
import time

CLK = os.sysconf("SC_CLK_TCK")
PAGE = os.sysconf("SC_PAGE_SIZE")


def ros_processes() -> dict[int, str]:
    """Every process that looks like part of the replay, pid -> short name."""
    found = {}
    for pid in os.listdir("/proc"):
        if not pid.isdigit():
            continue
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as fh:
                cmd = fh.read().decode(errors="replace").replace("\0", " ").strip()
        except OSError:
            continue
        if not cmd:
            continue
        if not re.search(r"--ros-args|ros2 bag play|play_launch|component_container", cmd):
            continue
        name = None
        m = re.search(r"__node:=(\S+)", cmd)
        if m:
            name = m.group(1)
        elif "ros2 bag play" in cmd or "rosbag2" in cmd:
            name = "ros2 bag play"
        else:
            m = re.search(r"([^/\s]+)(?:\s+--ros-args)", cmd)
            name = m.group(1) if m else cmd.split()[0].rsplit("/", 1)[-1]
        found[int(pid)] = name[:44]
    return found


def sample(pid: int) -> tuple[float, int, int] | None:
    """(cpu_seconds, rss_bytes, read_bytes) or None if the process is gone."""
    try:
        with open(f"/proc/{pid}/stat") as fh:
            parts = fh.read().rsplit(") ", 1)[1].split()
        cpu = (int(parts[11]) + int(parts[12])) / CLK      # utime + stime
        with open(f"/proc/{pid}/statm") as fh:
            rss = int(fh.read().split()[1]) * PAGE
        read_bytes = 0
        try:
            with open(f"/proc/{pid}/io") as fh:
                for line in fh:
                    if line.startswith("read_bytes:"):
                        read_bytes = int(line.split()[1])
        except OSError:
            pass
        return cpu, rss, read_bytes
    except (OSError, IndexError, ValueError):
        return None


def topic_rates(topics: list[str], seconds: int) -> dict[str, str]:
    """`ros2 topic hz` for each topic, in parallel, for `seconds`."""
    procs = {
        t: subprocess.Popen(
            ["ros2", "topic", "hz", t, "--window", "50"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
        )
        for t in topics
    }
    time.sleep(seconds)
    out = {}
    for topic, proc in procs.items():
        proc.terminate()
        try:
            text = proc.communicate(timeout=5)[0]
        except subprocess.TimeoutExpired:
            proc.kill()
            text = ""
        rates = re.findall(r"average rate: ([\d.]+)", text or "")
        out[topic] = f"{float(rates[-1]):.2f} Hz" if rates else "silent"
    return out


def exe_times(seconds: int) -> str:
    """Distribution of the scan matcher's own reported execution time."""
    proc = subprocess.Popen(
        ["ros2", "topic", "echo", "--no-arr",
         "/localization/pose_estimator/exe_time_ms"],
        stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
    )
    time.sleep(seconds)
    proc.terminate()
    try:
        text = proc.communicate(timeout=5)[0]
    except subprocess.TimeoutExpired:
        proc.kill()
        text = ""
    values = [float(v) for v in re.findall(r"data:\s*([\d.]+)", text or "")]
    if not values:
        return "no exe_time_ms samples"
    values.sort()
    p = lambda q: values[min(len(values) - 1, int(q * len(values)))]  # noqa: E731
    return (f"n={len(values)}  mean={sum(values)/len(values):.1f} ms  "
            f"p50={p(0.5):.1f}  p95={p(0.95):.1f}  max={values[-1]:.1f}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--seconds", type=int, default=45)
    args = ap.parse_args()

    topics = [
        "/sensing/lidar/vlp32/velodyne_points",
        "/sensing/lidar/concatenated/pointcloud",
        "/localization/util/downsample/pointcloud",
        "/localization/pose_estimator/pose_with_covariance",
        "/localization/kinematic_state",
        "/localization/board_detector/board_pose",
    ]

    start = ros_processes()
    if not start:
        print("No replay processes found. Is the stack up?", file=sys.stderr)
        return 1
    print(f"Watching {len(start)} processes for {args.seconds}s\n")

    first = {pid: s for pid, name in start.items() if (s := sample(pid))}
    t0 = time.time()

    rates = topic_rates(topics, args.seconds // 2)
    exe = exe_times(args.seconds // 2)

    elapsed = time.time() - t0
    rows = []
    for pid, node_name in start.items():
        now = sample(pid)
        if not now or pid not in first:
            continue
        cpu0, _, io0 = first[pid]
        cpu1, rss1, io1 = now
        rows.append((100 * (cpu1 - cpu0) / elapsed, rss1 / 2**20,
                     (io1 - io0) / 2**20 / elapsed, node_name))
    rows.sort(reverse=True)
    cores = os.cpu_count() or 1

    print(f"{'CPU %':>7} {'RSS MB':>8} {'disk MB/s':>10}  node")
    print("-" * 74)
    for cpu, rss, disk, name in rows:
        if cpu < 0.5 and disk < 0.5:
            continue
        print(f"{cpu:7.1f} {rss:8.0f} {disk:10.2f}  {name}")
    print("-" * 74)
    print(f"{sum(r[0] for r in rows):7.1f} {sum(r[1] for r in rows):8.0f} "
          f"{sum(r[2] for r in rows):10.2f}  TOTAL over {elapsed:.0f}s "
          f"({cores} cores = {100 * cores}% budget)")

    print("\nTopic rates")
    for topic, rate in rates.items():
        print(f"  {rate:>10}  {topic}")
    print(f"\nNDT exe_time_ms: {exe}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
