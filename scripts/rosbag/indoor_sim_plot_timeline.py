#!/usr/bin/env python3
"""Draw the indoor replay's localization timeline from recorded events.

    PYTHONNOUSERSITE=1 scripts/rosbag/indoor_sim_plot_timeline.py \
        --events events.jsonl --out docs/research/performance/indoor-replay-timeline.png

PYTHONNOUSERSITE matters: the apt matplotlib is built against NumPy 1.x and
fails to import with the NumPy 2.x in ~/.local. Ignoring user site-packages is
cheaper than maintaining a second environment for one plot.

The x axis is simulation time, because that is where in the RECORDING an event
happened; wall time only says how fast this machine replayed it, and is
reported in the subtitle rather than plotted.
"""
from __future__ import annotations

import argparse
import json
import sys
from collections import defaultdict

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

BOARD = "/localization/board_detector/board_pose"
NDT = "/localization/pose_estimator/pose_with_covariance"
EXE = "/localization/pose_estimator/exe_time_ms"
EKF = "/localization/kinematic_state"
ITER = "/localization/pose_estimator/iteration_num"
NVTL = "/localization/pose_estimator/nearest_voxel_transformation_likelihood"
# From cuda_scan_matcher.param.yaml. Both are thresholds the matcher itself
# acts on, so a plot that does not draw them cannot say whether a scan
# converged or was merely allowed through.
MAX_ITERATIONS = 30
NVTL_GATE = 2.0
INIT3D = "/initialpose3d"
STATE = ("/api/localization/initialization_state",
         "/localization/initialization_state")
# autoware_adapi_v1_msgs/msg/LocalizationInitializationState. The constants
# start at UNKNOWN=0, so the states this plot cares about are 1, 2, 3 and not
# 0, 1, 2: reading them off by one turns "INITIALIZED at 9 s" into a plot that
# claims localization was ready before the first detection arrived.
STATE_NAME = {0: "UNKNOWN", 1: "UNINITIALIZED", 2: "INITIALIZING",
              3: "INITIALIZED"}


def load(path: str):
    events = defaultdict(list)
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        e = json.loads(line)
        if e.get("sim") is None:          # before the clock existed
            continue
        events[e["topic"]].append(e)
    return events


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--events", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--title", default="Indoor replay: board cold start into cuda_ndt")
    args = ap.parse_args()

    ev = load(args.events)
    if not ev:
        print("no events with a clock; was the bag running?", file=sys.stderr)
        return 1

    # Sim time relative to the first event of any kind, so the axis reads as
    # "seconds into the recording" rather than as an epoch.
    t_zero = min(e["sim"] for es in ev.values() for e in es)
    rel = lambda es: [e["sim"] - t_zero for e in es]          # noqa: E731

    board = ev.get(BOARD, [])
    ndt = ev.get(NDT, [])
    exe = ev.get(EXE, [])
    ekf = ev.get(EKF, [])
    init3d = ev.get(INIT3D, [])
    iters = ev.get(ITER, [])
    nvtl = ev.get(NVTL, [])
    states = next((ev[t] for t in STATE if ev.get(t)), [])

    span = max((e["sim"] - t_zero for es in ev.values() for e in es), default=1)
    wall = max((e["wall"] for es in ev.values() for e in es), default=0)

    fig = plt.figure(figsize=(13, 11.6))
    grid = fig.add_gridspec(5, 1, height_ratios=[2.4, 2.4, 1.3, 1.3, 1.6],
                            hspace=0.5)
    ax_zoom = fig.add_subplot(grid[0])
    ax = fig.add_subplot(grid[1])
    ax_rate = fig.add_subplot(grid[2], sharex=ax)
    ax_exe = fig.add_subplot(grid[3], sharex=ax)
    ax_fit = fig.add_subplot(grid[4], sharex=ax)

    lanes = [("bag playback", "#8899aa"), ("board detections", "#d1495b"),
             ("initialization state", "#3f8f5b"), ("cuda_ndt pose", "#2a6f97"),
             ("EKF kinematic_state", "#7a5195")]
    ypos = {name: len(lanes) - 1 - i for i, (name, _) in enumerate(lanes)}
    colour = dict(lanes)

    def draw_lanes(axis, annotate: bool) -> None:
        axis.barh(ypos["bag playback"], span, left=0, height=0.34,
                  color=colour["bag playback"], alpha=0.35)

        # Streams as dense tick marks: what matters is where they start, stop
        # and gap, not the individual samples.
        for name, series in (("cuda_ndt pose", ndt), ("EKF kinematic_state", ekf)):
            if not series:
                continue
            xs = rel(series)
            axis.plot(xs, [ypos[name]] * len(xs), "|", color=colour[name],
                      markersize=9, alpha=0.55)
            if annotate:
                axis.annotate(f"first at {xs[0]:.1f} s ({len(series)} msgs)",
                              (xs[0], ypos[name]), textcoords="offset points",
                              xytext=(6, 9), fontsize=8, color=colour[name])

        if board:
            xs = rel(board)
            axis.plot(xs, [ypos["board detections"]] * len(xs), "o",
                      color=colour["board detections"], markersize=7)
            if annotate:
                axis.annotate(f"{len(board)} detections, first at {xs[0]:.1f} s",
                              (xs[0], ypos["board detections"]),
                              textcoords="offset points", xytext=(6, 9),
                              fontsize=8, color=colour["board detections"])

        # Initialization state as spans between transitions. The labels go on
        # the zoom only: every transition happens inside the first seconds, so
        # on the full axis they would print on top of each other.
        if states:
            xs = rel(states)
            for i, e in enumerate(states):
                end = xs[i + 1] if i + 1 < len(xs) else span
                value = e["value"]
                axis.barh(ypos["initialization state"], end - xs[i], left=xs[i],
                          height=0.34, alpha=0.12 + 0.16 * (value or 0),
                          color=colour["initialization state"])
            if annotate:
                for i, e in enumerate(states):
                    if i and e["value"] == states[i - 1]["value"]:
                        continue
                    axis.annotate(f"{STATE_NAME.get(e['value'], e['value'])}",
                                  (xs[i], ypos["initialization state"]),
                                  textcoords="offset points",
                                  xytext=(4, 13 + 11 * (i % 2)), fontsize=7.5,
                                  color="#2f6b46",
                                  arrowprops=dict(arrowstyle="-", lw=0.6,
                                                  color="#2f6b46"))

        for e in init3d:
            x = e["sim"] - t_zero
            axis.axvline(x, color="#c77d00", ls="--", lw=1, alpha=0.8)
            if annotate:
                axis.annotate("/initialpose3d", (x, len(lanes) - 1.35),
                              textcoords="offset points", xytext=(5, 0),
                              fontsize=7.5, color="#c77d00")

        axis.set_yticks(list(ypos.values()))
        axis.set_yticklabels(list(ypos.keys()), fontsize=9)
        axis.set_ylim(-1.2, len(lanes) - 0.3)
        axis.grid(axis="x", alpha=0.25)

    # The cold start is over in seconds, so it gets its own axis; the full run
    # below it is where the gaps and the drift show.
    zoom_end = max(12.0, (rel(ndt)[0] if ndt else 10) + 6)
    draw_lanes(ax_zoom, annotate=True)
    ax_zoom.set_xlim(0, zoom_end)
    ax_zoom.set_title(f"{args.title}\ncold start, first {zoom_end:.0f} s "
                      f"({span:.0f} s of bag replayed in {wall:.0f} s wall)",
                      fontsize=11, loc="left")
    ax_zoom.set_xlabel("simulation time (s)", fontsize=8.5)

    draw_lanes(ax, annotate=False)
    ax.set_xlim(0, span)
    ax.set_title("the whole replay", fontsize=10, loc="left", color="#44505c")

    # Pose rate, binned per second: the flat line is the claim that
    # localization kept up, and any notch in it is the interesting part.
    if ndt:
        xs = rel(ndt)
        bins = defaultdict(int)
        for x in xs:
            bins[int(x)] += 1
        ks = sorted(bins)
        ax_rate.plot(ks, [bins[k] for k in ks], color=colour["cuda_ndt pose"], lw=1.2)
        ax_rate.axhline(10, color="#999", ls=":", lw=1)
        ax_rate.text(span, 10.4, "10 Hz", fontsize=7.5, ha="right", color="#777")
        ax_rate.set_ylabel("pose rate\n(msgs/s)", fontsize=8.5)
        ax_rate.set_ylim(0, max(12, max(bins.values()) + 1))
        ax_rate.grid(alpha=0.25)

    if exe:
        xs, ys = rel(exe), [e["value"] for e in exe]
        ax_exe.plot(xs, ys, color="#2a6f97", lw=0.9, alpha=0.85)
        ordered = sorted(ys)
        p50 = ordered[len(ordered) // 2]
        p95 = ordered[int(0.95 * (len(ordered) - 1))]
        ax_exe.axhline(p95, color="#d1495b", ls="--", lw=1)
        ax_exe.text(span, p95, f" p95 {p95:.1f} ms", fontsize=7.5,
                    va="bottom", ha="right", color="#d1495b")
        ax_exe.set_ylabel("NDT exe_time\n(ms)", fontsize=8.5)
        ax_exe.set_title(f"mean {sum(ys)/len(ys):.1f} ms, p50 {p50:.1f}, "
                         f"p95 {p95:.1f}, max {max(ys):.1f}",
                         fontsize=8.5, loc="left", color="#44505c")
        ax_exe.grid(alpha=0.25)

    # Did it converge, and how well did it fit? The two questions the pose
    # stream cannot answer on its own: a matcher that hits max_iterations every
    # scan is not converging, it is being cut off, and NVTL under its gate is a
    # fit the matcher itself would reject.
    if iters or nvtl:
        if iters:
            xs, ys = rel(iters), [e["value"] for e in iters]
            ax_fit.plot(xs, ys, color="#b5651d", lw=0.9, alpha=0.9,
                        label="iterations")
            ax_fit.axhline(MAX_ITERATIONS, color="#b5651d", ls="--", lw=1)
            ax_fit.text(span, MAX_ITERATIONS, f" max {MAX_ITERATIONS}",
                        fontsize=7.5, va="bottom", ha="right", color="#b5651d")
            capped = sum(1 for v in ys if v >= MAX_ITERATIONS)
            ax_fit.set_ylabel("NDT iterations", fontsize=8.5, color="#b5651d")
            ax_fit.set_ylim(0, max(MAX_ITERATIONS * 1.15, max(ys) * 1.1))
            ax_fit.tick_params(axis="y", colors="#b5651d")
            iter_note = (f"iterations: mean {sum(ys)/len(ys):.1f}, max {max(ys)}, "
                         f"{capped} of {len(ys)} scans at the cap "
                         f"({100*capped/len(ys):.1f}%)")
        else:
            iter_note = "no iteration_num"

        if nvtl:
            xn, yn = rel(nvtl), [e["value"] for e in nvtl]
            ax_nvtl = ax_fit.twinx()
            ax_nvtl.plot(xn, yn, color="#2a6f97", lw=0.9, alpha=0.75)
            ax_nvtl.axhline(NVTL_GATE, color="#d1495b", ls="--", lw=1)
            ax_nvtl.text(0, NVTL_GATE, f" gate {NVTL_GATE}", fontsize=7.5,
                         va="bottom", color="#d1495b")
            ax_nvtl.set_ylabel("NVTL", fontsize=8.5, color="#2a6f97")
            ax_nvtl.tick_params(axis="y", colors="#2a6f97")
            below = sum(1 for v in yn if v < NVTL_GATE)
            ordered = sorted(yn)
            nvtl_note = (f"NVTL: p50 {ordered[len(ordered)//2]:.2f}, "
                         f"min {ordered[0]:.2f}, {below} scan(s) under the gate")
        else:
            nvtl_note = "no NVTL"

        ax_fit.set_title(f"{iter_note}   |   {nvtl_note}", fontsize=8.5,
                         loc="left", color="#44505c")
        ax_fit.grid(alpha=0.25)

    ax_fit.set_xlabel("simulation time (s from the first recorded message)", fontsize=9)
    for a in (ax, ax_rate, ax_exe):
        plt.setp(a.get_xticklabels(), visible=False)

    fig.savefig(args.out, dpi=150, bbox_inches="tight", facecolor="white")
    print(f"wrote {args.out}")
    print(f"  board detections: {len(board)}   ndt poses: {len(ndt)}   "
          f"ekf: {len(ekf)}   state changes: {len(states)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
