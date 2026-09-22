#!/usr/bin/env python3
"""One table across several link_sim runs, both directions, from the files.

    matrix.py RUN_DIR [RUN_DIR ...]

Rows are runs (directory basenames), columns the numbers that matter:
steady-window mean and worst-second in each direction, drops by the token
bucket in each direction, what the master's recorder kept of the Velodyne
scans, and the rate at gyro_odometer. Nothing here is computed from anything
but link.csv, phases.txt, qdisc.txt, consumers.txt and bag_counts.txt.
"""

import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from summarize import read_consumers, read_qdisc, windows  # noqa: E402


def bag_counts(d):
    """velodyne scans recorded on the master, ZED images recorded on the orin."""
    out = {"master_velodyne": "-", "orin_zed_image": "-"}
    path = os.path.join(d, "bag_counts.txt")
    if not os.path.exists(path):
        return out
    who = None
    with open(path) as f:
        for line in f:
            m = re.match(r"^== \S+ (master|orin) bag", line)
            if m:
                who = m.group(1)
                continue
            m = re.search(r"Topic: (\S+) .*Count: (\d+)", line)
            if not m:
                continue
            if who == "master" and m.group(1).endswith("velodyne_points"):
                out["master_velodyne"] = m.group(2)
            if who == "orin" and m.group(1).endswith("image/compressed"):
                out["orin_zed_image"] = m.group(2)
    return out


def kb(b):
    return f"{b / 1000:.1f}"


def main():
    runs = sys.argv[1:]
    print("| run | master->orin mean kB/s (Mbit/s) | master->orin worst s kB/s | drops master->orin | "
          "orin->master mean kB/s (Mbit/s) | orin->master worst s kB/s | drops orin->master | "
          "Velodyne scans kept by master recorder | gyro_odometer twist Hz | imu_corrector Hz |")
    print("|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|")
    for d in runs:
        name = os.path.basename(d.rstrip("/"))
        w = windows(d)["steady"]
        q = read_qdisc(d)
        c = read_consumers(d)
        b = bag_counts(d)
        tx_drop = q.get("master -> orin", {}).get("dropped", "-")
        rx_drop = q.get("orin -> master", {}).get("dropped", "-")
        twist = c.get("hz /localization/twist_estimator/twist_with_covariance", "-").replace(" Hz", "")
        imu = c.get("hz /sensing/imu/imu_data", "-").replace(" Hz", "")
        print(f"| {name} | {kb(w['tx_mean'])} ({w['tx_mean'] * 8 / 1e6:.1f}) | {kb(w['tx_peak'])} | {tx_drop} "
              f"| {kb(w['rx_mean'])} ({w['rx_mean'] * 8 / 1e6:.1f}) | {kb(w['rx_peak'])} | {rx_drop} "
              f"| {b['master_velodyne']} | {twist} | {imu} |")


if __name__ == "__main__":
    main()
