#!/usr/bin/env python3
"""One-shot GNSS / RTK test: bring the receiver up, measure it, say what is wrong.

Answers one question -- is the F9P chain working, and if not, which link is
broken -- by counting messages over a fixed window on the four topics that
carry the answer:

    ntrip/rtcm          corrections arriving from the caster
    ublox/rxmrtcm       corrections the RECEIVER accepted (flags 0 = CRC pass)
    ublox/nmea_sentence GGA and friends; the NTRIP client uplinks these
    ublox/nav_sat_fix   the fix itself

Counting, not `ros2 topic hz`. The RTCM stream is bursty (one epoch per second
delivering 4-20 messages a few ms apart), so a short hz window misreads it
badly -- see SETUP_LOG.md section 10, where a `window: 5` sample reported ~5 Hz
for a 7.8 Hz stream. Worse, hz prints 0 Hz identically whether the caster is
silent or the topic does not exist, which is the single most important
distinction this test has to make.

The chain fails from the bottom up, so the diagnosis follows it in that order:
no satellites gives a position-less GGA, a position-less GGA makes a network
VRS caster hang up, and a caster that hung up delivers no RTCM. Reporting "0
RTCM" without that context sends people looking at the network when the real
answer is a roof. See docs/handover/2026-09-21-f9p-ntrip-bringup.md.

Exit codes are meant for CI and for a human in a hurry:

    0   RTK converged -- corrections flowing and accepted, fix is RTK
    1   the wiring is broken: a node, a topic or the caster login
    2   wiring is fine, the sky is not: no satellites, so no corrections
    3   could not run the test at all (no receiver, bad environment)

2 is the expected indoor result and is NOT a code fault.
"""
from __future__ import annotations

import argparse
import collections
import os
import re
import signal
import subprocess
import sys
import time

REPO = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__)))))

# NavSatFix.status.status, sensor_msgs/NavSatStatus
FIX_STATUS = {-1: "NO FIX", 0: "fix (SPS)", 1: "SBAS", 2: "GBAS / RTK"}


def die(msg: str, code: int = 3) -> None:
    print(f"\n  cannot run: {msg}", file=sys.stderr)
    sys.exit(code)


try:
    import rclpy
    from rclpy.node import Node
    from rclpy.qos import (DurabilityPolicy, HistoryPolicy, QoSProfile,
                           ReliabilityPolicy)
    from sensor_msgs.msg import NavSatFix
except ImportError as exc:  # noqa: BLE001
    die(f"{exc}. Source the workspace first (direnv, or `source scripts/env.sh`).")

# These three are not in a bare Autoware install: mavros_msgs comes from apt,
# ublox_msgs and the driver from the ublox_f9p_ws submodule. Name the fix
# rather than letting the traceback do it.
try:
    from mavros_msgs.msg import RTCM
    from nmea_msgs.msg import Sentence
    from ublox_msgs.msg import RxmRTCM
except ImportError as exc:  # noqa: BLE001
    die(f"{exc}. Run scripts/testing/ntrip/check_ntrip_setup.sh, which names "
        "the missing piece.")


def find_namespace(node: Node, explicit: str | None) -> str:
    """Where the driver's topics live: /gnss standalone, /sensing/gnss in the stack.

    The sensing prefix is added by the Autoware chain above gnss.launch.xml, so
    it depends on how the stack was started, not on configuration.
    """
    if explicit:
        return explicit.rstrip("/")
    names = [n for n, _ in node.get_topic_names_and_types()]
    for candidate in ("/sensing/gnss", "/gnss"):
        if f"{candidate}/ublox/nav_sat_fix" in names:
            return candidate
    return ""


class Probe(Node):
    def __init__(self, ns: str):
        super().__init__("gnss_test_probe")
        q = QoSProfile(history=HistoryPolicy.KEEP_LAST, depth=500,
                       reliability=ReliabilityPolicy.RELIABLE,
                       durability=DurabilityPolicy.VOLATILE)
        self.rtcm_t: list[float] = []
        self.rxm_types: collections.Counter = collections.Counter()
        self.rxm_flags: collections.Counter = collections.Counter()
        self.nmea: collections.Counter = collections.Counter()
        self.gga: list[str] = []
        self.fix: NavSatFix | None = None
        self.fix_n = 0
        self.create_subscription(RTCM, f"{ns}/ntrip/rtcm", self._rtcm, q)
        self.create_subscription(RxmRTCM, f"{ns}/ublox/rxmrtcm", self._rxm, q)
        self.create_subscription(Sentence, f"{ns}/ublox/nmea_sentence", self._nmea, q)
        self.create_subscription(NavSatFix, f"{ns}/ublox/nav_sat_fix", self._fix, q)

    def _rtcm(self, _m) -> None:
        self.rtcm_t.append(time.time())

    def _rxm(self, m) -> None:
        self.rxm_types[int(m.msg_type)] += 1
        self.rxm_flags[int(m.flags)] += 1

    def _nmea(self, m) -> None:
        talker = m.sentence.split(",")[0]
        self.nmea[talker] += 1
        if talker.endswith("GGA") and len(self.gga) < 200:
            self.gga.append(m.sentence)

    def _fix(self, m) -> None:
        self.fix = m
        self.fix_n += 1


def gga_has_position(sentence: str) -> bool:
    """A GGA the VRS can place a virtual base from.

    $GNGGA,time,lat,NS,lon,EW,quality,numSV,HDOP,...  -- quality 0 means no fix
    and the lat/lon fields are empty, which is what a caster hangs up over.
    """
    f = sentence.split(",")
    return len(f) > 6 and f[2] != "" and f[4] != "" and f[6] not in ("", "0")


def launch(use_ntrip: bool, logfile: str) -> subprocess.Popen:
    cmd = ["ros2", "launch", "golfcart_sensor_kit_launch", "gnss.launch.xml",
           f"use_ntrip:={'true' if use_ntrip else 'false'}"]
    print(f"  $ {' '.join(cmd)}")
    with open(logfile, "wb") as fh:
        # Own process group, so teardown can signal the whole tree at once.
        return subprocess.Popen(cmd, stdout=fh, stderr=subprocess.STDOUT,
                                start_new_session=True)


def teardown(proc: subprocess.Popen | None) -> None:
    """Stop the launch and the nodes it orphans.

    SIGINT to the group, then kill what survives BY PID. Matching on argv is
    not enough: killing the launch parent leaves ublox_gps_node holding
    /dev/ttyACM0, and the next run fails to open the port. The NTRIP client
    ignores SIGTERM while blocked on its socket, so it needs SIGKILL.
    """
    if proc is None:
        return
    print("\n  stopping...")
    try:
        os.killpg(os.getpgid(proc.pid), signal.SIGINT)
        proc.wait(timeout=10)
    except (ProcessLookupError, subprocess.TimeoutExpired):
        pass
    for pattern in ("ublox_gps_node", "ntrip_ros.py", "gnss_poser"):
        out = subprocess.run(["pgrep", "-f", pattern], capture_output=True,
                             text=True).stdout.split()
        for pid in out:
            try:
                os.kill(int(pid), signal.SIGKILL)
            except (ProcessLookupError, ValueError):
                pass
    time.sleep(2)
    held = subprocess.run(["fuser", "/dev/ttyACM0"], capture_output=True,
                          text=True).stdout.strip()
    print(f"  port still held by {held}" if held else "  stopped, port free")


def report(p: Probe, span: float, log: str | None, use_ntrip: bool) -> int:
    rtcm, rxm = len(p.rtcm_t), sum(p.rxm_types.values())
    gga = sum(v for k, v in p.nmea.items() if k.endswith("GGA"))
    positioned = sum(1 for s in p.gga if gga_has_position(s))
    status = p.fix.status.status if p.fix else None

    print(f"\n{'=' * 62}\n  {span:.0f}s capture\n{'=' * 62}\n")

    print(f"  NMEA          {sum(p.nmea.values()):5d} sentences"
          f"   {dict(sorted(p.nmea.items()))}")
    if gga:
        print(f"  GGA           {gga:5d}  ({gga / span:.2f} Hz, "
              f"{positioned} carrying a position)")
    print(f"  NavSatFix     {p.fix_n:5d}  status "
          f"{FIX_STATUS.get(status, status)}")
    if p.fix and status is not None and status >= 0:
        print(f"                       lat {p.fix.latitude:.7f}  "
              f"lon {p.fix.longitude:.7f}  alt {p.fix.altitude:.2f}")
    print(f"  RTCM in       {rtcm:5d}  ({rtcm / span:.2f} Hz mean)")
    if rtcm > 1:
        gaps = [(b - a) * 1000 for a, b in zip(p.rtcm_t, p.rtcm_t[1:])]
        bursts = 1 + sum(1 for g in gaps if g > 150)
        print(f"                       {bursts} bursts -> {bursts / span:.2f} Hz epochs")
    print(f"  RTCM accepted {rxm:5d}  flags {dict(p.rxm_flags) or '-'}"
          "   (0 = CRC pass)")
    if p.rxm_types:
        print(f"                       types {dict(sorted(p.rxm_types.items()))}")

    caster = ""
    if log and os.path.exists(log):
        text = open(log, errors="replace").read()
        if "Broken pipe" in text or "Unable to send NMEA" in text:
            caster = "connected, then hung up"
        elif re.search(r"Connected to http", text):
            caster = "connected"
        elif "Unable to connect socket" in text:
            caster = "unreachable"
        elif use_ntrip:
            caster = "no connection logged"

    print(f"\n{'-' * 62}\n  verdict\n{'-' * 62}")

    if p.fix_n == 0:
        print("\n  FAIL: the driver published no NavSatFix.")
        print("  The node is not running, or not talking to the receiver.")
        print("  Check: fuser /dev/ttyACM0 (an orphan from a previous run holds")
        print("  the port), and allow 15-20s after a kill before relaunching.")
        return 1

    if not use_ntrip:
        print(f"\n  Driver OK, NTRIP not requested. Fix: "
              f"{FIX_STATUS.get(status, status)}.")
        return 0 if status is not None and status >= 0 else 2

    if rtcm > 0 and rxm > 0 and 0 in p.rxm_flags:
        print(f"\n  PASS: corrections flowing and accepted "
              f"({rtcm} in, {rxm} accepted).")
        if status == 2:
            print("  RTK converged.")
            return 0
        print(f"  Fix is {FIX_STATUS.get(status, status)}, not yet RTK -- "
              "give it time to converge.")
        return 0

    if rtcm > 0 and rxm == 0:
        print(f"\n  FAIL: {rtcm} RTCM arrived but the receiver accepted none.")
        print("  The corrections are not reaching the device. Most likely the")
        print("  apt ros-humble-ublox-gps is being used instead of the")
        print("  submodule build: it takes rtcm_msgs/Message where this NTRIP")
        print("  client publishes mavros_msgs/RTCM. Remove the apt packages.")
        return 1

    # No RTCM at all. Walk down the chain to the first thing actually missing.
    if gga == 0:
        print("\n  FAIL: no RTCM, and the driver emitted no GGA to uplink.")
        print("  Without GGA a network VRS has nothing to place a base from.")
        return 1

    if positioned == 0:
        print(f"\n  NO SKY: no RTCM, because all {gga} GGA sentences are")
        print("  position-less -- the receiver has no satellites.")
        if p.gga:
            print(f"    {p.gga[0].strip()}")
        print("\n  A network VRS cannot place a virtual base without a rover")
        print("  position, so it accepts the login and hangs up"
              f"{' (' + caster + ')' if caster else ''}.")
        print("  This is environmental. Move to open sky and run again.")
        return 2

    print(f"\n  FAIL: no RTCM, though {positioned} GGA carried a position.")
    print(f"  The receiver has a fix, so this is the caster or the account"
          f"{' -- ' + caster if caster else ''}.")
    print("  Check credentials and mountpoint in config/ntrip.param.yaml;")
    print("  scripts/testing/ntrip/check_ntrip_setup.sh verifies both.")
    return 1


def main() -> int:
    ap = argparse.ArgumentParser(
        description="One-shot GNSS / RTK test.",
        epilog="Exit: 0 working, 1 wiring broken, 2 no satellites, 3 cannot run.")
    ap.add_argument("--seconds", type=float, default=60.0,
                    help="measurement window (default 60; RTCM epochs are 1 Hz, "
                         "so shorter than ~30 is noise)")
    ap.add_argument("--attach", action="store_true",
                    help="measure a stack that is already running instead of "
                         "starting one (the only way to test the full launch)")
    ap.add_argument("--no-ntrip", action="store_true",
                    help="driver only, no corrections -- isolates the receiver "
                         "from the caster")
    ap.add_argument("--namespace", default=None,
                    help="topic namespace (default: autodetect /gnss or "
                         "/sensing/gnss)")
    args = ap.parse_args()

    use_ntrip = not args.no_ntrip
    proc, log = None, None

    if not args.attach:
        held = subprocess.run(["fuser", "/dev/ttyACM0"], capture_output=True,
                              text=True).stdout.strip()
        if held:
            die(f"/dev/ttyACM0 is held by pid {held}. An orphan from an earlier "
                "run, or a stack already up -- use --attach for the latter.")
        if not os.path.exists("/dev/ublox-gps"):
            die("no /dev/ublox-gps. Receiver unplugged, or the udev rule is "
                "missing (./setup.sh --only ublox-udev).")
        os.makedirs(f"{REPO}/log/gnss-test", exist_ok=True)
        log = f"{REPO}/log/gnss-test/launch.log"
        print(f"\n  starting the receiver (ntrip {'on' if use_ntrip else 'off'})")
        proc = launch(use_ntrip, log)
        print("  waiting 15s for the driver to configure the receiver")
        time.sleep(15)

    rclpy.init()
    code = 3
    try:
        finder = rclpy.create_node("gnss_test_finder")
        # Discovery is not instant; give it a moment before deciding.
        for _ in range(20):
            rclpy.spin_once(finder, timeout_sec=0.1)
        ns = find_namespace(finder, args.namespace)
        finder.destroy_node()
        if not ns:
            die("no */ublox/nav_sat_fix topic found. The driver is not running; "
                "with --attach, start the stack first.", 1)

        print(f"  measuring {ns}/* for {args.seconds:.0f}s")
        probe = Probe(ns)
        t0 = time.time()
        while time.time() - t0 < args.seconds:
            rclpy.spin_once(probe, timeout_sec=0.1)
        span = time.time() - t0
        code = report(probe, span, log, use_ntrip)
        probe.destroy_node()
    except KeyboardInterrupt:
        print("\n  interrupted")
    finally:
        rclpy.shutdown()
        teardown(proc)
        if log:
            print(f"  launch log: {log}")

    return code


if __name__ == "__main__":
    sys.exit(main())
