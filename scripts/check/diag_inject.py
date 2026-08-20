#!/usr/bin/env python3
"""Force diagnostic leaves to a chosen level, to exercise the fault path.

Phase 4-O sub-phase O-F. See docs/roadmaps/4-diagnostics-observability.md.

This is what ROADMAP Phase 4 Track A item 3 needs ("test system behavior when
individual sensors drop out, ensure MRM activates correctly"). Unplugging a
sensor is slower, less repeatable, and cannot produce a LATENT_FAULT or a
WARN-then-ERROR sequence on demand.

WHY NOT autoware_dummy_diag_publisher. Autoware ships one, and it is the right
tool when the names are known in advance: it takes a `required_diags` list read
at startup, so a name that is not in that config cannot be faulted at runtime.
This reads the leaf names out of the LIVE graph instead, so it always matches
whatever graph the aggregator actually loaded, including the ArUco variant.

CONFLICTS. This publishes `/diagnostics` under the real leaves' names. When the
real publisher is also running, both write the same name and the aggregator
takes whichever arrived last, which flaps. The tool detects other publishers and
says so rather than producing a quietly meaningless result. On a bench with no
sensors there is no conflict, which is the case it is built for.

Examples:

    # what can be faulted, read from the running graph
    ./scripts/check/diag_inject.py --list

    # hold one leaf at ERROR until Ctrl-C, everything else OK
    ./scripts/check/diag_inject.py --fault 'aeb_emergency_stop=ERROR'

    # substring match, several at once, and a level each
    ./scripts/check/diag_inject.py -f 'ndt_scan_matcher=ERROR' -f 'lane_departure=WARN'

    # timed scenario: healthy, fault at 5 s, recover at 20 s, exit at 30 s
    ./scripts/check/diag_inject.py -f 'aeb_emergency_stop=ERROR' \
        --at 5 --clear-at 20 --stop-at 30
"""

import argparse
import subprocess
import sys
import threading
import time

LEVELS = {"OK": 0, "WARN": 1, "WARNING": 1, "ERROR": 2, "STALE": 3}
LEVEL_NAME = {0: "OK", 1: "WARN", 2: "ERROR", 3: "STALE"}

STRUCT_TOPIC = "/api/system/diagnostics/struct"


def read_graph_leaves(timeout=15):
    """Leaf names from the live graph.

    Read over the AD API struct topic, which is transient_local, so this works
    at any time after the aggregator started rather than only at the moment it
    publishes. The QoS flags are not optional: the publisher is RELIABLE +
    TRANSIENT_LOCAL and the ros2 CLI default is neither, so without them this
    returns nothing at all and looks like an empty graph.
    """
    cmd = [
        "ros2", "topic", "echo", "--once",
        "--qos-durability", "transient_local",
        "--qos-reliability", "reliable",
        STRUCT_TOPIC,
    ]
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout).stdout
    except subprocess.TimeoutExpired:
        return None, f"no message on {STRUCT_TOPIC} within {timeout}s"
    if not out.strip():
        return None, f"no message on {STRUCT_TOPIC}"
    import yaml
    docs = [d for d in yaml.safe_load_all(out) if isinstance(d, dict)]
    if not docs:
        return None, "struct message did not parse"
    g = docs[0]
    return [d["name"] for d in g.get("diags", [])], None


def other_publishers(node):
    """Count /diagnostics publishers.

    MUST be called BEFORE this process creates its own publisher, so that
    anything found is genuinely someone else. Filtering by node name instead
    does not work: two copies of this tool are both called `diag_inject`, so
    each filtered the other out as itself and the conflict guard never fired.
    """
    try:
        return len(node.get_publishers_info_by_topic("/diagnostics"))
    except Exception:
        return 0


def resolve(patterns, leaves):
    """Map `pattern=LEVEL` onto real leaf names by substring match."""
    wanted, problems = {}, []
    for spec in patterns:
        if "=" not in spec:
            problems.append(f"{spec!r}: expected NAME=LEVEL")
            continue
        pat, lvl = spec.rsplit("=", 1)
        key = lvl.strip().upper()
        if key not in LEVELS:
            problems.append(f"{spec!r}: level must be one of {', '.join(sorted(set(LEVELS)))}")
            continue
        hits = [n for n in leaves if pat.strip() in n]
        if not hits:
            problems.append(f"{spec!r}: no leaf in the graph contains {pat.strip()!r}")
            continue
        for h in hits:
            wanted[h] = LEVELS[key]
    return wanted, problems


def main():
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--list", action="store_true",
                    help="print the graph's leaf names and exit")
    ap.add_argument("-f", "--fault", action="append", default=[], metavar="NAME=LEVEL",
                    help="substring of a leaf name, and the level to force it to")
    ap.add_argument("--rate", type=float, default=10.0,
                    help="publish rate in Hz (default 10, matching Autoware)")
    ap.add_argument("--at", type=float, default=0.0, metavar="SEC",
                    help="hold everything healthy for SEC before applying the faults")
    ap.add_argument("--clear-at", type=float, default=None, metavar="SEC",
                    help="clear the faults at SEC, to exercise recovery")
    ap.add_argument("--stop-at", type=float, default=None, metavar="SEC",
                    help="exit at SEC (default: run until Ctrl-C)")
    ap.add_argument("--allow-conflict", action="store_true",
                    help="publish even when something else publishes /diagnostics")
    args = ap.parse_args()

    leaves, err = read_graph_leaves()
    if leaves is None:
        print(f"error: {err}", file=sys.stderr)
        print("Is the diagnostic graph aggregator running? Try "
              "`ros2 topic list | grep diagnostics`.", file=sys.stderr)
        return 1
    if not leaves:
        print("error: the graph reports no diag leaves", file=sys.stderr)
        return 1

    if args.list:
        print(f"{len(leaves)} leaves in the live graph:")
        for n in sorted(leaves):
            print("   ", n)
        return 0

    wanted, problems = resolve(args.fault, leaves)
    for p in problems:
        print(f"error: {p}", file=sys.stderr)
    if problems:
        print("\nRun with --list to see what the graph actually contains.", file=sys.stderr)
        return 1

    import rclpy
    from rclpy.node import Node
    from diagnostic_msgs.msg import DiagnosticArray, DiagnosticStatus

    rclpy.init()
    node = Node("diag_inject")

    # Discovery first, publisher second. Counting after publishing would count
    # ourselves, and the name filter that used to compensate for that broke as
    # soon as two copies of this tool ran at once.
    time.sleep(1.5)
    others = other_publishers(node)
    if others and not args.allow_conflict:
        print(f"error: {others} other node(s) already publish /diagnostics.", file=sys.stderr)
        print("Both would write the same leaf names and the aggregator takes whichever",
              file=sys.stderr)
        print("arrived last, so the result flaps and means nothing. Stop the real",
              file=sys.stderr)
        print("publishers, or pass --allow-conflict if you know what you are doing.",
              file=sys.stderr)
        rclpy.shutdown()
        return 1
    if others:
        print(f"WARNING: publishing alongside {others} other /diagnostics publisher(s). "
              "Levels will flap.", file=sys.stderr)

    pub = node.create_publisher(DiagnosticArray, "/diagnostics", 10)

    state = {"active": args.at <= 0.0}
    t0 = time.time()

    def describe():
        if not wanted:
            return "all %d leaves OK" % len(leaves)
        return ", ".join(f"{n} -> {LEVEL_NAME[v]}" for n, v in sorted(wanted.items()))

    print(f"publishing {len(leaves)} leaves at {args.rate} Hz")
    print(f"  faults: {describe()}")
    if args.at > 0:
        print(f"  applied at t+{args.at}s")
    if args.clear_at is not None:
        print(f"  cleared at t+{args.clear_at}s")
    print(f"  {'stops at t+%ss' % args.stop_at if args.stop_at else 'Ctrl-C to stop'}")
    print(f"  [t+0.0s] {'FAULTED' if state['active'] else 'healthy'}")

    def tick():
        now = time.time() - t0
        if args.clear_at is not None and now >= args.clear_at:
            if state["active"]:
                state["active"] = False
                print(f"  [t+{now:.1f}s] cleared")
        elif now >= args.at:
            if not state["active"]:
                state["active"] = True
                print(f"  [t+{now:.1f}s] FAULTED: {describe()}")

        msg = DiagnosticArray()
        msg.header.stamp = node.get_clock().now().to_msg()
        for name in leaves:
            s = DiagnosticStatus()
            s.name = name
            s.hardware_id = "diag_inject"
            lvl = wanted.get(name, 0) if state["active"] else 0
            # rclpy maps the `byte` field to a length-1 bytes object.
            s.level = bytes([lvl])
            s.message = "forced by diag_inject" if lvl else "OK"
            msg.status.append(s)
        pub.publish(msg)

    node.create_timer(1.0 / args.rate, tick)

    stop = threading.Event()
    if args.stop_at is not None:
        threading.Timer(args.stop_at, stop.set).start()
    try:
        while rclpy.ok() and not stop.is_set():
            rclpy.spin_once(node, timeout_sec=0.05)
    except KeyboardInterrupt:
        pass
    finally:
        print("stopped")
        rclpy.shutdown()
    return 0


if __name__ == "__main__":
    sys.exit(main())
