#!/usr/bin/env python3
"""Rank the processes in a play_launch session by resource use.

Usage:  scripts/analysis/rank_play_launch.py <session-dir>

A session directory is one timestamped tree under play_log/, or one unpacked
from a capture archive. It must contain node/<name>/{metrics.csv,metadata.json}.

Two things this prints that the bundled analyzer does not:

  * the split between container processes and standalone ones, which is where
    the per-process CPU floor shows up, and
  * whether each standalone node's package registers rclcpp components, i.e.
    whether it could be composed into a container instead of paying that floor.

Component registration is read from the installed Autoware's ament_index, not
guessed from the package name. Point AMENT_PREFIX at another install to check
against a different one.

See docs/research/system/where-the-orin-cpu-goes.md for what the numbers meant
on 2026-08-25.
"""

import csv
import json
import os
import statistics as st
import sys

AMENT_PREFIX = os.environ.get("AMENT_PREFIX", "/opt/autoware/1.5.0")
COMPONENT_INDEX = os.path.join(
    AMENT_PREFIX, "share/ament_index/resource_index/rclcpp_components"
)

# Median of the trivial-node band measured on the master Orin, 2026-08-25.
# Re-derive it from the printout below rather than trusting it on a new machine:
# it is the mode of the standalone column, not a constant of nature.
FLOOR_PERCENT = 4.88


def registered_packages():
    if not os.path.isdir(COMPONENT_INDEX):
        return None
    return set(os.listdir(COMPONENT_INDEX))


def read_process(session, name):
    metrics = os.path.join(session, "node", name, "metrics.csv")
    metadata = os.path.join(session, "node", name, "metadata.json")
    if not (os.path.exists(metrics) and os.path.exists(metadata)):
        return None

    meta = json.load(open(metadata))
    cpu, rss, threads, pids = [], [], [], set()
    with open(metrics) as handle:
        for row in csv.DictReader(handle):
            if row.get("cpu_percent"):
                cpu.append(float(row["cpu_percent"]))
            if row.get("rss_bytes"):
                rss.append(float(row["rss_bytes"]))
            if row.get("num_threads"):
                threads.append(int(row["num_threads"]))
            if row.get("pid"):
                pids.add(row["pid"])
    if not cpu:
        return None

    return {
        "name": name,
        "package": meta.get("package", "?"),
        "is_container": bool(meta.get("is_container")),
        "cpu_avg": st.mean(cpu),
        "cpu_max": max(cpu),
        "rss_mb": st.mean(rss) / 1e6 if rss else 0.0,
        "threads": max(threads) if threads else 0,
        # More than one PID over the run means the process was restarted. A
        # large count is a respawn loop, and every restart is a DDS participant
        # created and destroyed in every other process in the graph.
        "spawns": len(pids),
    }


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    session = sys.argv[1]
    if not os.path.isdir(os.path.join(session, "node")):
        sys.exit(f"{session}: no node/ directory — not a play_launch session")

    registered = registered_packages()
    procs = [
        p
        for p in (read_process(session, n) for n in sorted(os.listdir(os.path.join(session, "node"))))
        if p
    ]

    header = f"{'process':<42}{'cpu_avg':>9}{'cpu_max':>9}{'rss_MB':>9}{'thr':>5}  {'composable?':<12}"
    for label, group in (
        ("CONTAINERS", [p for p in procs if p["is_container"]]),
        ("STANDALONE", [p for p in procs if not p["is_container"]]),
    ):
        print(f"\n=== {label} ({len(group)} processes) ===")
        print(header)
        for p in sorted(group, key=lambda p: -p["cpu_avg"]):
            if p["is_container"]:
                note = "-"
            elif registered is None:
                note = "?"
            else:
                note = "yes" if p["package"] in registered else "no"
            print(
                f"{p['name']:<42}{p['cpu_avg']:>9.2f}{p['cpu_max']:>9.1f}"
                f"{p['rss_mb']:>9.1f}{p['threads']:>5}  {note:<12}"
            )
        print(f"{'subtotal':<42}{sum(p['cpu_avg'] for p in group):>9.2f}")

    restarted = [p for p in procs if p["spawns"] > 1]
    if restarted:
        print("\n=== RESTARTED DURING THE RUN ===")
        for p in sorted(restarted, key=lambda p: -p["spawns"]):
            print(f"{p['name']:<42}{p['spawns']:>5} spawns")

    standalone = [p for p in procs if not p["is_container"]]
    if registered is not None:
        foldable = [p for p in standalone if p["package"] in registered]
        released = len(foldable) * FLOOR_PERCENT
        print(
            f"\n{len(foldable)} of {len(standalone)} standalone processes belong to packages "
            f"that register rclcpp components."
        )
        print(
            f"At a {FLOOR_PERCENT:.2f}% per-process floor, composing them releases "
            f"{released:.0f}% of one core."
        )
    else:
        print(f"\n{COMPONENT_INDEX} not found — composability not checked.")


if __name__ == "__main__":
    main()
