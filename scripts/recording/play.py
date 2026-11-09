#!/usr/bin/env python3
"""Play a bag into a running stack, without the topics the stack computes itself.

    play.py [--computed] [--dry-run] BAG [ros2 bag play options...]

Every replay path that feeds a logging simulation goes through here: `just bag
play`, `just bag play-ntu`, `just ntu-test bag`, `just indoor-test bag`,
scripts/testing/board_check.sh. `just bag replay` does not: it runs no stack,
only RViz, so the recorded localization is the only localization there is.

What it leaves out: every topic of a `kind: computed` class in
config/recording/topics.yaml (localization, diagnostics, the commands the gate
sends, the concatenator's synchronized cloud, gnss_poser...), and every topic in
no class that matches replay.stack_patterns there (a bag of scope `all` is
mostly the stack's own topics). The logging simulation recomputes those; played
as well, each would have two publishers, the bag's frozen one and the stack's.

rosbag2 in Humble has `--topics` (an include list) and no exclude, so the
include list is the bag's own topics (metadata.yaml) minus the computed ones.
A bag with no computed topic in it plays exactly as before, without --topics.

/tf cannot be split by topic: in a master bag it carries the stack's own
map -> base_link (EKF) and map -> ndt_base_link (NDT) beside the ZED's
zed_left_camera_frame -> zed_imu_link, which the logging simulation does not
reproduce and gyro_odometer needs. So /tf is played remapped to
/replay/tf_recorded, and this process republishes it on /tf without the frames
listed under replay.tf_computed. Only when the bag has a /tf and the computed
topics are excluded; otherwise ros2 bag play is exec'd directly.

--computed plays everything, as recorded (for looking at a drive in RViz with
no stack running). GOLFCART_REPLAY_COMPUTED=on does the same for the wrappers.
--dry-run prints what would play and what would not, and plays nothing.
"""

from __future__ import annotations

import argparse
import importlib.util
import os
import signal
import subprocess
import sys
import time
from pathlib import Path

_SESSION = Path(__file__).resolve().with_name("session.py")
_spec = importlib.util.spec_from_file_location("golfcart_session", _SESSION)
assert _spec is not None and _spec.loader is not None
session = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(session)

TF_RECORDED = "/replay/tf_recorded"
SIGINT_GRACE_S = 2.0


def build(bag: Path, computed: bool, extra: list[str]) -> tuple[list[str], dict, list[dict]]:
    topics = session.load_topics()
    plan = session.replay_plan(session.bag_topics(bag), topics, computed)
    cmd = ["ros2", "bag", "play", str(bag)]
    if plan["include"] is not None:
        cmd += ["--topics", *plan["include"]]
    if plan["tf_filter"]:
        cmd += ["--remap", f"/tf:={TF_RECORDED}"]
    cmd += extra
    drop = (topics.get("replay") or {}).get("tf_computed") or []
    return cmd, plan, drop


def relay(cmd: list[str], drop: list[dict]) -> int:
    """Run the player as a child; republish its /tf minus the computed frames."""
    import rclpy
    from rclpy.qos import (DurabilityPolicy, HistoryPolicy, QoSProfile,
                           ReliabilityPolicy)
    from rclpy.signals import SignalHandlerOptions
    from tf2_msgs.msg import TFMessage

    child = subprocess.Popen(cmd)
    stop = {"sig": None, "t": 0.0}

    def on_signal(signum, _frame):
        if signum == signal.SIGINT:
            # A terminal Ctrl-C reaches the player too (same process group);
            # forward only if it is still alive after a grace.
            if stop["sig"] is None:
                stop.update(sig=signum, t=time.monotonic())
        else:
            child.send_signal(signal.SIGTERM)
    for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(s, on_signal)

    rclpy.init(signal_handler_options=SignalHandlerOptions.NO)
    node = rclpy.create_node("replay_tf_filter")
    pub = node.create_publisher(TFMessage, "/tf", QoSProfile(
        depth=100, history=HistoryPolicy.KEEP_LAST,
        reliability=ReliabilityPolicy.RELIABLE, durability=DurabilityPolicy.VOLATILE))
    pairs = {(d["parent"].lstrip("/"), d["child"].lstrip("/")) for d in drop}
    counts = {"in": 0, "dropped": 0}

    def on_tf(msg: TFMessage) -> None:
        counts["in"] += len(msg.transforms)
        keep = [t for t in msg.transforms
                if (t.header.frame_id.lstrip("/"), t.child_frame_id.lstrip("/")) not in pairs]
        counts["dropped"] += len(msg.transforms) - len(keep)
        if keep:
            msg.transforms = keep
            pub.publish(msg)
    # Best effort subscribes to the player whatever QoS it offers.
    node.create_subscription(TFMessage, TF_RECORDED, on_tf, QoSProfile(
        depth=1000, history=HistoryPolicy.KEEP_LAST,
        reliability=ReliabilityPolicy.BEST_EFFORT, durability=DurabilityPolicy.VOLATILE))
    try:
        while child.poll() is None:
            rclpy.spin_once(node, timeout_sec=0.1)
            if stop["sig"] is not None and time.monotonic() - stop["t"] > SIGINT_GRACE_S:
                child.send_signal(signal.SIGINT)
                stop["t"] = float("inf")
    finally:
        print(f"play.py: /tf filter passed {counts['in'] - counts['dropped']} transforms, "
              f"dropped {counts['dropped']} computed", file=sys.stderr, flush=True)
        node.destroy_node()
        rclpy.try_shutdown()
    return child.returncode


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0], allow_abbrev=False)
    ap.add_argument("--computed", action="store_true",
                    help="play the computed classes too (everything, as recorded)")
    ap.add_argument("--dry-run", action="store_true", help="print the plan, play nothing")
    ap.add_argument("--verbose", action="store_true", help="list every topic left out")
    ap.add_argument("bag", type=Path)
    a, extra = ap.parse_known_args(argv)
    computed = a.computed or os.environ.get("GOLFCART_REPLAY_COMPUTED", "") in ("on", "1", "true")
    if not (a.bag / "metadata.yaml").is_file():
        # A single .mcap/.db3 file, or an unfinalized bag: no topic list to
        # filter by. ros2 bag play decides whether it can open it.
        print(f"play.py: WARNING: {a.bag} has no metadata.yaml; playing every topic "
              "unfiltered", file=sys.stderr)
        cmd = ["ros2", "bag", "play", str(a.bag), *extra]
        if a.dry_run:
            print("play.py: would run: " + " ".join(cmd))
            return 0
        os.execvp(cmd[0], cmd)
    try:
        cmd, plan, drop = build(a.bag, computed, extra)
    except (ValueError, OSError, KeyError) as e:
        print(f"play.py: {e}", file=sys.stderr)
        return 2
    if plan["include"] == []:
        print("play.py: every topic in this bag is computed; nothing to play "
              "(--computed plays it anyway)", file=sys.stderr)
        return 1
    if computed:
        print("play.py: playing every topic as recorded (computed on)")
    else:
        n = len(plan["include"]) if plan["include"] is not None else "all"
        print(f"play.py: playing {n} topics; leaving out {len(plan['exclude'])} the stack computes")
        if plan["exclude_computed"]:
            print(f"play.py:   computed classes ({len(plan['exclude_computed'])}): "
                  + " ".join(sorted(plan["exclude_computed"])))
        if plan["exclude_pattern"]:
            ex = sorted(plan["exclude_pattern"])
            print(f"play.py:   unclassified, replay.stack_patterns ({len(ex)}): "
                  + " ".join(ex if a.verbose or len(ex) <= 12 else ex[:12] + ["..."]))
        if plan["tf_filter"]:
            print("play.py: /tf through the filter, without "
                  + ", ".join(f"{d['parent']}->{d['child']}" for d in drop))
        print("play.py: computed=on (or --computed) plays everything")
    if a.dry_run:
        print("play.py: would run: " + " ".join(cmd))
        return 0
    sys.stdout.flush()
    if not plan["tf_filter"]:
        os.execvp(cmd[0], cmd)
    return relay(cmd, drop)


if __name__ == "__main__":
    sys.exit(main())
