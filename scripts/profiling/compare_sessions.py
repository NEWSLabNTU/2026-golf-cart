#!/usr/bin/env python3
"""Overlay two or more play_launch sessions on one set of axes.

play_launch's own analyzer plots exactly one log directory, so an A/B --
before and after a change -- means flipping between two browser tabs whose
axes do not even share a scale. This puts the runs on top of each other.

Time is normalised to seconds since each session's first sample, because
sessions differ in wall-clock length and start time; the point is the shape
of the load, not when it happened.

Two of the six panels come from per-process metrics.csv rather than
system_stats.csv, and they are the ones to read with care: play_launch 0.9.0
samples only the processes it spawned, and in `--container-mode isolated`
every composable node is clone()d by its container and is NOT sampled. The
tracked-CPU and thread sums therefore UNDERCOUNT an isolated run and are not
comparable to an observable one. Host CPU (panel 1) is the honest comparison.

Usage:
    compare_sessions.py DIR[=LABEL] DIR[=LABEL] ... [-o OUT.html]
"""

import argparse
import csv
import sys
from collections import defaultdict
from datetime import datetime
from pathlib import Path

import plotly.graph_objects as go
from plotly.subplots import make_subplots

COLORS = ["#d62728", "#1f77b4", "#2ca02c", "#9467bd", "#ff7f0e"]
GIB = 1024**3
MB = 1e6


def parse_ts(s: str) -> datetime:
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def read_system_stats(session: Path) -> dict:
    """Host-wide series from system_stats.csv, x in seconds since first sample."""
    path = session / "system_stats.csv"
    with path.open() as fh:
        rows = [r for r in csv.DictReader(fh) if r.get("timestamp")]
    if not rows:
        raise SystemExit(f"{path}: no samples")

    t0 = parse_ts(rows[0]["timestamp"])
    out = defaultdict(list)
    for r in rows:
        # A truncated final row is normal when a session is killed mid-write.
        try:
            t = (parse_ts(r["timestamp"]) - t0).total_seconds()
        except ValueError:
            continue
        out["t"].append(t)
        out["cpu"].append(float(r["cpu_percent"]) if r.get("cpu_percent") else None)
        out["mem"].append(float(r["used_memory_bytes"]) / GIB if r.get("used_memory_bytes") else None)
        rx = float(r["network_rx_rate_bps"] or 0) if r.get("network_rx_rate_bps") else None
        tx = float(r["network_tx_rate_bps"] or 0) if r.get("network_tx_rate_bps") else None
        out["net"].append((rx + tx) / MB if rx is not None and tx is not None else None)
        out["disk"].append(
            float(r["disk_write_rate_bps"]) / MB if r.get("disk_write_rate_bps") else None
        )
    return out


def read_process_sums(session: Path, bin_secs: float = 2.0) -> dict:
    """Sum cpu_percent and num_threads over every sampled process, binned in time.

    Each process samples on its own clock, so the series are re-binned onto a
    common grid before summing -- without that, the sum is a sawtooth of
    whichever processes happened to report in a given instant.
    """
    files = sorted(session.glob("node/*/metrics.csv"))
    if not files:
        return {}

    t0 = None
    per_bin_cpu = defaultdict(float)
    per_bin_thr = defaultdict(int)
    # Last known value per process, so a bin missing one process does not dip.
    for path in files:
        with path.open() as fh:
            rows = [r for r in csv.DictReader(fh) if r.get("timestamp")]
        if not rows:
            continue
        first = parse_ts(rows[0]["timestamp"])
        t0 = first if t0 is None else min(t0, first)

    for path in files:
        with path.open() as fh:
            rows = [r for r in csv.DictReader(fh) if r.get("timestamp")]
        cpu_seen, thr_seen = {}, {}
        for r in rows:
            try:
                t = (parse_ts(r["timestamp"]) - t0).total_seconds()
            except ValueError:
                continue
            b = int(t // bin_secs)
            # Last sample wins within a bin: a process that reports twice in
            # one bin must still contribute one value to the sum.
            if r.get("cpu_percent"):
                cpu_seen[b] = float(r["cpu_percent"])
            if r.get("num_threads"):
                thr_seen[b] = int(r["num_threads"])
        for b, v in cpu_seen.items():
            per_bin_cpu[b] += v
        for b, v in thr_seen.items():
            per_bin_thr[b] += v

    bins = sorted(per_bin_cpu)
    return {
        "t": [b * bin_secs for b in bins],
        "cpu_sum": [per_bin_cpu[b] for b in bins],
        "thr_sum": [per_bin_thr.get(b, 0) for b in bins],
    }


PANELS = [
    ("Host CPU (system_stats)", "%", "cpu"),
    ("Host memory used", "GiB", "mem"),
    ("Host network rate, rx+tx", "MB/s", "net"),
    ("Host disk write rate", "MB/s", "disk"),
    ("Tracked-process CPU sum &mdash; see caveat", "%", "cpu_sum"),
    ("Tracked-process thread sum &mdash; see caveat", "threads", "thr_sum"),
]


def build(sessions: list[tuple[str, Path]], out: Path) -> None:
    fig = make_subplots(
        rows=3,
        cols=2,
        subplot_titles=[p[0] for p in PANELS],
        vertical_spacing=0.10,
        horizontal_spacing=0.08,
    )

    summary = []
    for i, (label, session) in enumerate(sessions):
        color = COLORS[i % len(COLORS)]
        host = read_system_stats(session)
        proc = read_process_sums(session)

        for n, (title, unit, key) in enumerate(PANELS):
            row, col = n // 2 + 1, n % 2 + 1
            src = host if key in host else proc
            if not src or key not in src:
                continue
            fig.add_trace(
                go.Scatter(
                    x=src["t"],
                    y=src[key],
                    name=label,
                    legendgroup=label,
                    showlegend=(n == 0),
                    line=dict(color=color, width=1.5),
                    hovertemplate=f"{label}<br>%{{x:.0f}}s  %{{y:.1f}} {unit}<extra></extra>",
                ),
                row=row,
                col=col,
            )
            if n < 2:
                fig.update_yaxes(title_text=unit, row=row, col=col)

        cpu = [v for v in host["cpu"] if v is not None]
        summary.append(
            f"{label}: {len(cpu)} host samples, "
            f"{host['t'][-1] / 60:.1f} min, CPU avg {sum(cpu) / len(cpu):.1f}% max {max(cpu):.0f}%"
        )

    for n in range(len(PANELS)):
        fig.update_xaxes(title_text="seconds since session start", row=n // 2 + 1, col=n % 2 + 1)

    fig.update_layout(
        height=1100,
        title="play_launch session comparison<br><sub>" + "  |  ".join(summary) + "</sub>",
        hovermode="x unified",
        template="plotly_white",
        legend=dict(orientation="h", y=1.06, x=0),
    )
    fig.write_html(out, include_plotlyjs=True)
    print(f"wrote {out}")
    for line in summary:
        print(f"  {line}")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("sessions", nargs="+", help="play_log session dir, optionally DIR=LABEL")
    ap.add_argument("-o", "--output", type=Path, default=Path("session_compare.html"))
    args = ap.parse_args()

    parsed = []
    for spec in args.sessions:
        path, _, label = spec.partition("=")
        p = Path(path)
        if not (p / "system_stats.csv").is_file():
            sys.exit(f"{p}: no system_stats.csv -- not a play_launch session dir")
        parsed.append((label or p.name, p))

    build(parsed, args.output)


if __name__ == "__main__":
    main()
