#!/usr/bin/env python3
"""Turn one link_sim run directory into summary.md.

    summarize.py OUT_DIR              # one run
    summarize.py BASELINE_DIR SPLIT_DIR   # side by side

Windows come from phases.txt (second offsets written by run.sh):

    startup   from start to steady_start: the stack coming up, discovery burst
    steady    steady_start to end, minus the echo window: the cart driving
    echo      the seconds the master was echoing the ZED image

Per window and direction: mean and peak kB/s, mean and peak packets/s. Peak
is the worst single second, which is the number a 100 Mb/s link cares about.
"""

import csv
import os
import re
import sys


def read_phases(d):
    ph = {}
    with open(os.path.join(d, "phases.txt")) as f:
        for line in f:
            k, v = line.split()
            ph[k] = int(v)
    return ph


def read_link(d):
    rows = []
    with open(os.path.join(d, "link.csv")) as f:
        for r in csv.DictReader(f):
            rows.append({k: int(v) for k, v in r.items()})
    return rows


def window_stats(rows, lo, hi, exclude=None):
    sel = [r for r in rows if lo < r["t"] <= hi and not (exclude and exclude[0] < r["t"] <= exclude[1])]
    if not sel:
        return None
    n = len(sel)
    def col(k):
        vals = [r[k] for r in sel]
        return sum(vals) / n, max(vals)
    return {
        "seconds": n,
        "tx_mean": col("tx_bytes")[0], "tx_peak": col("tx_bytes")[1],
        "rx_mean": col("rx_bytes")[0], "rx_peak": col("rx_bytes")[1],
        "txp_mean": col("tx_pkts")[0], "txp_peak": col("tx_pkts")[1],
        "rxp_mean": col("rx_pkts")[0], "rxp_peak": col("rx_pkts")[1],
        "tx_total": sum(r["tx_bytes"] for r in sel),
        "rx_total": sum(r["rx_bytes"] for r in sel),
    }


def windows(d):
    ph = read_phases(d)
    rows = read_link(d)
    out = {}
    out["startup"] = window_stats(rows, ph["start"], ph["steady_start"])
    echo = (ph["echo_start"], ph["echo_end"]) if "echo_start" in ph and "echo_end" in ph else None
    out["steady"] = window_stats(rows, ph["steady_start"], ph["end"], exclude=echo)
    out["echo"] = window_stats(rows, echo[0], echo[1]) if echo else None
    return out


def read_kv(path):
    kv = {}
    if not os.path.exists(path):
        return kv
    with open(path) as f:
        for line in f:
            parts = line.split()
            if len(parts) == 2:
                kv[parts[0]] = parts[1]
    return kv


def read_graph(d):
    g = {}
    path = os.path.join(d, "graph.txt")
    if not os.path.exists(path):
        return g
    who = None
    with open(path) as f:
        for line in f:
            m = re.match(r"^(\w+) sees, (.+):$", line.strip())
            if m:
                who = f"{m.group(1)} ({m.group(2)})"
                continue
            if line.startswith("readers"):
                who = "readers"
                continue
            m = re.match(r"^\s+(nodes|topics)\s+(\d+)$", line)
            if m and who and who != "readers":
                g[f"{who} {m.group(1)}"] = int(m.group(2))
                continue
            m = re.match(r"^\s+(/\S+)\s+(.*)$", line)
            if m and who == "readers":
                g[f"readers of {m.group(1)}"] = m.group(2).strip() or "-"
    return g


def read_consumers(d):
    """`ros2 topic hz` / `delay` at the real consumers, from consumers.txt."""
    out = {}
    path = os.path.join(d, "consumers.txt")
    if not os.path.exists(path):
        return out
    key = None
    with open(path) as f:
        for line in f:
            m = re.match(r"^(hz|delay) (\S+)$", line.strip())
            if m:
                key = f"{m.group(1)} {m.group(2)}"
                out[key] = "no messages"
                continue
            m = re.search(r"average (rate|delay): ([0-9.]+)", line)
            if m and key:
                out[key] = m.group(2) + (" Hz" if m.group(1) == "rate" else " s")
    return out


def read_qdisc(d):
    """tbf counters per direction: sent bytes, dropped packets, overlimits."""
    out = {}
    path = os.path.join(d, "qdisc.txt")
    if not os.path.exists(path):
        return out
    which = None
    with open(path) as f:
        for line in f:
            m = re.match(r"^(vm|vo) \((.+)\):", line)
            if m:
                which = m.group(2)
                continue
            m = re.search(r"Sent (\d+) bytes (\d+) pkt \(dropped (\d+), overlimits (\d+)", line)
            if m and which:
                out[which] = {"sent_bytes": int(m.group(1)), "sent_pkts": int(m.group(2)),
                              "dropped": int(m.group(3)), "overlimits": int(m.group(4))}
    return out


def read_bags(d):
    path = os.path.join(d, "bags.txt")
    if not os.path.exists(path):
        return []
    with open(path) as f:
        return [line.strip() for line in f if line.strip()]


def read_classes(d):
    path = os.path.join(d, "classes.txt")
    if not os.path.exists(path):
        return []
    rows = []
    with open(path) as f:
        next(f, None)
        for line in f:
            p = line.split()
            if len(p) >= 4 and p[1] != "TOTAL":
                rows.append((p[0], p[1], p[2], int(p[3]), int(p[4]) if len(p) > 4 else 0))
    return rows


def read_bridge(d):
    """Last forwarded/throttled count per lane from the bridge logs."""
    out = {}
    for host in ("master", "orin"):
        path = os.path.join(d, f"{host}_bridge.log")
        if not os.path.exists(path):
            continue
        with open(path) as f:
            for line in f:
                m = re.search(r"\] (out|in) (\S+) forwarded=(\d+) throttled=(\d+)", line)
                if m:
                    out[f"{host} {m.group(1)} {m.group(2)}"] = (int(m.group(3)), int(m.group(4)))
    return out


def kb(b):
    return f"{b / 1000:.1f}"


def mbit(b):
    return f"{b * 8 / 1e6:.2f}"


def one(d):
    name = os.path.basename(d.rstrip("/"))
    w = windows(d)
    lines = [f"# link_sim: {name}", ""]
    lines.append("| window | s | tx mean kB/s | tx peak kB/s (Mbit/s) | rx mean kB/s | rx peak kB/s (Mbit/s) | tx pkt/s mean/peak | rx pkt/s mean/peak |")
    lines.append("|---|---:|---:|---:|---:|---:|---:|---:|")
    for k in ("startup", "steady", "echo"):
        s = w.get(k)
        if not s:
            continue
        lines.append(
            f"| {k} | {s['seconds']} | {kb(s['tx_mean'])} | {kb(s['tx_peak'])} ({mbit(s['tx_peak'])}) "
            f"| {kb(s['rx_mean'])} | {kb(s['rx_peak'])} ({mbit(s['rx_peak'])}) "
            f"| {s['txp_mean']:.0f} / {s['txp_peak']} | {s['rxp_mean']:.0f} / {s['rxp_peak']} |")
    lines.append("")
    lines.append("tx = master -> orin, rx = orin -> master, as seen at the master's end of the veth.")
    lines.append("")

    q = read_qdisc(d)
    if q:
        lines.append("## The wire's token bucket (100 Mbit/s each way), whole run")
        lines.append("")
        lines.append("| direction | sent bytes | sent packets | dropped packets | overlimits |")
        lines.append("|---|---:|---:|---:|---:|")
        for k, v in q.items():
            lines.append(f"| {k} | {v['sent_bytes']} | {v['sent_pkts']} | {v['dropped']} | {v['overlimits']} |")
        lines.append("")

    c = read_consumers(d)
    if c:
        lines.append("## At the real consumers on the master (mid-run, 20 s windows)")
        lines.append("")
        lines.append("| | |")
        lines.append("|---|---|")
        for k, v in c.items():
            lines.append(f"| {k} | {v} |")
        lines.append("")

    bags = read_bags(d)
    if bags:
        lines.append("## The two recorders")
        lines.append("")
        for b in bags:
            lines.append(f"- {b}")
        lines.append("")

    g = read_graph(d)
    if g:
        lines.append("## Readers, and what a CLI participant discovers")
        lines.append("")
        lines.append("| | |")
        lines.append("|---|---:|")
        for k, v in g.items():
            lines.append(f"| {k} | {v} |")
        lines.append("")

    cls = read_classes(d)
    if cls:
        lines.append("## Bytes by domain and class (raw socket on the veth, whole run)")
        lines.append("")
        lines.append("| direction | domain | class | bytes | packets |")
        lines.append("|---|---|---|---:|---:|")
        for direction, dom, kind, b, p in cls:
            lines.append(f"| {direction} | {dom} | {kind} | {b} | {p} |")
        lines.append("")

    br = read_bridge(d)
    if br:
        lines.append("## Bridge lanes (forwarded / throttled, at the last report)")
        lines.append("")
        lines.append("| lane | forwarded | throttled |")
        lines.append("|---|---:|---:|")
        for k, (f, t) in br.items():
            lines.append(f"| {k} | {f} | {t} |")
        lines.append("")
    return "\n".join(lines)


def compare(a, b):
    wa, wb = windows(a), windows(b)
    na, nb = os.path.basename(a.rstrip("/")), os.path.basename(b.rstrip("/"))
    lines = [f"# link_sim: {na} vs {nb}", ""]
    lines.append("| window | metric | " + na + " | " + nb + " | change |")
    lines.append("|---|---|---:|---:|---:|")
    for k in ("startup", "steady", "echo"):
        sa, sb = wa.get(k), wb.get(k)
        if not sa or not sb:
            continue
        for metric, label, fmt in (
            ("tx_mean", "tx mean kB/s", kb), ("tx_peak", "tx peak kB/s", kb),
            ("rx_mean", "rx mean kB/s", kb), ("rx_peak", "rx peak kB/s", kb),
            ("txp_mean", "tx pkt/s mean", lambda v: f"{v:.0f}"), ("txp_peak", "tx pkt/s peak", str),
            ("rxp_mean", "rx pkt/s mean", lambda v: f"{v:.0f}"), ("rxp_peak", "rx pkt/s peak", str),
            ("tx_total", "tx total bytes", str), ("rx_total", "rx total bytes", str),
        ):
            va, vb = sa[metric], sb[metric]
            change = "n/a" if va == 0 else f"{(vb - va) / va * 100:+.1f}%"
            lines.append(f"| {k} | {label} | {fmt(va)} | {fmt(vb)} | {change} |")
    lines.append("")
    qa, qb = read_qdisc(a), read_qdisc(b)
    if qa or qb:
        lines.append("| token bucket, whole run | " + na + " | " + nb + " |")
        lines.append("|---|---:|---:|")
        for k in sorted(set(qa) | set(qb)):
            for m in ("sent_bytes", "dropped", "overlimits"):
                lines.append(f"| {k} {m} | {qa.get(k, {}).get(m, '-')} | {qb.get(k, {}).get(m, '-')} |")
        lines.append("")
    ca, cb = read_consumers(a), read_consumers(b)
    if ca or cb:
        lines.append("| at the real consumers | " + na + " | " + nb + " |")
        lines.append("|---|---:|---:|")
        for k in sorted(set(ca) | set(cb)):
            lines.append(f"| {k} | {ca.get(k, '-')} | {cb.get(k, '-')} |")
        lines.append("")
    ga, gb = read_graph(a), read_graph(b)
    if ga or gb:
        lines.append("| readers and discovery | " + na + " | " + nb + " |")
        lines.append("|---|---:|---:|")
        for k in sorted(set(ga) | set(gb)):
            lines.append(f"| {k} | {ga.get(k, '-')} | {gb.get(k, '-')} |")
        lines.append("")
    return "\n".join(lines)


if __name__ == "__main__":
    if len(sys.argv) == 2:
        print(one(sys.argv[1]))
    elif len(sys.argv) == 3:
        print(compare(sys.argv[1], sys.argv[2]))
    else:
        sys.exit("usage: summarize.py OUT_DIR | summarize.py BASELINE_DIR SPLIT_DIR")
