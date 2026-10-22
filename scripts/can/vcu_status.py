#!/usr/bin/env python3
"""vcu_status.py - receive-only live readout of the VCU and our ADS commands.

Decodes the eight Turing Drive frames with cantools and the vendor DBC, and
shows them side by side: what the VCU reports (0x100 brake, 0x101 motor,
0x102 EPS, 0x103 vehicle) and what the vehicle interface is commanding
(0x065 EPS, 0x068 brake, 0x075 motor, 0x43F vehicle), with per-ID rates and
the controller's state and error counters.

It only LISTENS. The VCU's bus is the orin's can0 (setup step orin-can0), so
by default it runs `candump -L` there over ssh, in its own session; nothing
here touches the vehicle interface's process or tmux. CAN_HOST=local reads a
local interface with python-can instead. Neither path opens a socket that can
send: candump has no transmit side, and the python-can bus is only recv()'d.

Usage:
    scripts/can/vcu_status.py              # live, ~2 Hz, until Ctrl-C
    scripts/can/vcu_status.py --once       # listen 2 s, print one snapshot
    scripts/can/vcu_status.py --seconds 5  # listen 5 s, print one snapshot
    CAN_HOST=local CAN_IFACE=vcan0 scripts/can/vcu_status.py

Environment: CAN_HOST (orin|local, default orin), CAN_IFACE (can0),
CAX_ADS_DBC (the DBC; default the vehicle interface crate root),
ORIN_SSH / ORIN_SSH_KEY (default: config/multi_machine.conf).
"""
from __future__ import annotations

import argparse
import math
import os
import shlex
import subprocess
import sys
import threading
import time
from collections import defaultdict, deque
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
DEFAULT_DBC = REPO / "src/vehicle/golfcart_vehicle_launch/golfcart_vehicle_interface/CAX_ADS_CAN.dbc"

VCU_IDS = (0x100, 0x101, 0x102, 0x103)
ADS_IDS = (0x065, 0x068, 0x075, 0x43F)
RATE_WINDOW_S = 2.0


def orin_ssh_settings() -> tuple[str, str]:
    """ORIN_SSH and ORIN_SSH_KEY from the env, else from config/multi_machine.conf."""
    ssh, key = os.environ.get("ORIN_SSH"), os.environ.get("ORIN_SSH_KEY")
    if ssh and key is not None:
        return ssh, key
    conf = REPO / "config/multi_machine.conf"
    out = subprocess.run(
        ["bash", "-c", f'source {shlex.quote(str(conf))} >/dev/null 2>&1; '
                       'printf "%s\\n%s\\n" "$ORIN_SSH" "$ORIN_SSH_KEY"'],
        capture_output=True, text=True).stdout.splitlines() + ["", ""]
    return ssh or out[0], key if key is not None else out[1]


class State:
    """Latest decoded frame per ID, plus receive times for the rates."""

    def __init__(self):
        self.lock = threading.Lock()
        self.latest: dict[int, dict] = {}
        self.raw: dict[int, str] = {}
        self.stamps: dict[int, deque] = defaultdict(lambda: deque(maxlen=2000))
        self.link = "(not read yet)"
        self.reader_error = ""
        self.frames = 0

    def rate(self, can_id: int, now: float) -> float:
        st = self.stamps.get(can_id)
        if not st:
            return 0.0
        recent = [t for t in st if now - t <= RATE_WINDOW_S]
        # Over ssh the first frames land in a burst; measure the span actually
        # seen rather than assume the window was full.
        span = min(RATE_WINDOW_S, now - st[0]) if len(st) > 1 else RATE_WINDOW_S
        return len(recent) / max(span, 0.2)


def decode_into(state: State, db, can_id: int, data: bytes, t: float):
    try:
        msg = db.get_message_by_frame_id(can_id)
    except KeyError:
        return
    try:
        sig = msg.decode(data, decode_choices=True, scaling=True)
    except Exception as e:  # truncated or malformed frame: keep the raw bytes
        sig = {"<decode error>": str(e)}
    with state.lock:
        state.latest[can_id] = sig
        state.raw[can_id] = data.hex()
        state.stamps[can_id].append(t)
        state.frames += 1


def reader_candump(state: State, db, cmd: list[str]):
    """Parse `candump -L` lines: (ts) iface ID#DATA."""
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, bufsize=1)
    for line in proc.stdout:
        parts = line.split()
        if len(parts) < 3 or "#" not in parts[2]:
            continue
        ident, _, payload = parts[2].partition("#")
        try:
            can_id = int(ident, 16)
            data = bytes.fromhex(payload.lstrip("R"))
        except ValueError:
            continue
        # Receive time on this host, not candump's stamp: the orin's clock and
        # timestamp source are not ours, and the rate only needs one clock.
        decode_into(state, db, can_id, data, time.monotonic())
    err = proc.stderr.read().strip()
    state.reader_error = f"candump exited ({proc.wait()}): {err or 'no message'}"


def reader_python_can(state: State, db, iface: str):
    import can  # local only; the orin path does not need it here
    # receive_own_messages=False is irrelevant to sending: this bus is never
    # given a frame. Our ADS frames arrive through SocketCAN's loopback to
    # other sockets, exactly as candump sees them.
    bus = can.interface.Bus(channel=iface, interface="socketcan")
    try:
        while True:
            m = bus.recv(1.0)
            if m is not None and not m.is_error_frame:
                decode_into(state, db, m.arbitration_id, bytes(m.data), time.monotonic())
    finally:
        bus.shutdown()


def read_link(remote: list[str] | None, iface: str) -> str:
    cmd = f"ip -details -statistics link show {shlex.quote(iface)}"
    argv = remote + [cmd] if remote else ["bash", "-c", cmd]
    try:
        out = subprocess.run(argv, capture_output=True, text=True, timeout=8)
    except subprocess.TimeoutExpired:
        return "ip link: timed out"
    if out.returncode != 0:
        return f"ip link: {out.stderr.strip() or 'failed'}"
    lines = [ln.strip() for ln in out.stdout.splitlines()]
    keep = []
    for i, ln in enumerate(lines):
        if ln.startswith("can state") or ln.startswith("bitrate"):
            keep.append(ln)
        elif ln.startswith("re-started") and i + 1 < len(lines):
            keep.append("  ".join(f"{k}={v}" for k, v in zip(ln.split(), lines[i + 1].split())))
        elif ln.startswith(("RX:", "TX:")) and i + 1 < len(lines):
            k = ln.split()[1:]
            keep.append(ln.split()[0] + " " + " ".join(f"{a}={b}" for a, b in zip(k, lines[i + 1].split())))
    return "\n".join(keep) or out.stdout.strip()


def link_poller(state: State, remote, iface: str, period: float):
    while True:
        s = read_link(remote, iface)
        with state.lock:
            state.link = s
        time.sleep(period)


def g(d: dict | None, key: str, default="-"):
    if d is None:
        return default
    v = d.get(key, default)
    return v


def num(v, fmt="{:.2f}"):
    return fmt.format(float(v)) if isinstance(v, (int, float)) else str(v)


def render(state: State, host: str, iface: str) -> str:
    now = time.monotonic()
    with state.lock:
        L = dict(state.latest)
        raw = dict(state.raw)
        link = state.link
        rates = {i: state.rate(i, now) for i in VCU_IDS + ADS_IDS}
        frames = state.frames
    brk, mtr, eps, veh = (L.get(i) for i in VCU_IDS)
    c_eps, c_brk, c_mtr, c_veh = (L.get(i) for i in ADS_IDS)

    out = [f"VCU status - {iface} on {host} - receive only - {time.strftime('%H:%M:%S')}"
           f" - {frames} frames decoded", ""]

    out.append("VCU -> ADS")
    out.append(f"  0x103 vehicle  driving={g(veh, 'Vcu_Ads_Driving_State')}  "
               f"estop={g(veh, 'Vcu_Ads_Estop')}  counter={g(veh, 'Vcu_Ads_Rolling_Counter')}  "
               f"doors={g(veh, 'Vcu_Ads_Doors')}")
    out.append(f"                 errors sys={g(veh, 'Vcu_Ads_Error_Code_Sys')}  "
               f"mtr={g(veh, 'Vcu_Ads_Error_Code_Mtr')}  eps={g(veh, 'Vcu_Ads_Error_Code_Eps')}  "
               f"brk={g(veh, 'Vcu_Ads_Error_Code_Brk')}")
    out.append(f"  0x101 motor    state={g(mtr, 'Vcu_Ads_Motor_State')}  "
               f"gear={g(mtr, 'Vcu_Ads_Gear_Position')}  "
               f"speed={num(g(mtr, 'Vcu_Ads_Vehicle_Speed'))} m/s  "
               f"throttle={num(g(mtr, 'Vcu_Ads_Throttle_Position'), '{:.1f}')} %")
    ang = g(eps, "Vcu_Ads_Tire_Angle")
    aw = f"{-math.radians(ang):+.4f} rad (Autoware sign)" if isinstance(ang, (int, float)) else "-"
    out.append(f"  0x102 EPS      state={g(eps, 'Vcu_Ads_EPS_State')}  "
               f"tire_angle={num(ang, '{:+.2f}')} deg = {aw}  "
               f"rate={num(g(eps, 'Vcu_Ads_Tire_Angular_Speed'), '{:.1f}')} deg/s")
    out.append(f"  0x100 brake    state={g(brk, 'Vcu_Ads_Brake_State')}  "
               f"pos={num(g(brk, 'Vcu_Ads_Brake_Position'), '{:.1f}')} %  "
               f"stroke={num(g(brk, 'Vcu_Ads_Brake_Stroke'))} mm  "
               f"pressure={num(g(brk, 'Vcu_Ads_Brake_Pressure'))} MPa")
    out.append("")
    out.append("ADS -> VCU (our commands)")
    out.append(f"  0x43F vehicle  auto_en={g(c_veh, 'Ads_Vcu_Veh_Auto_En')}  "
               f"estop={g(c_veh, 'Ads_Vcu_Veh_Estop')}  ads={g(c_veh, 'Ads_Vcu_Ads_Status')}  "
               f"counter={g(c_veh, 'Ads_Vcu_Rolling_Counter')}")
    tgt = g(c_eps, "Ads_Vcu_Target_Tire_Angle")
    tgt_aw = f"{-math.radians(tgt):+.4f} rad" if isinstance(tgt, (int, float)) else "-"
    out.append(f"  0x065 EPS      en={g(c_eps, 'Ads_Vcu_Eps_En')}  "
               f"target={num(tgt, '{:+.2f}')} deg = {tgt_aw}  "
               f"ang_speed={num(g(c_eps, 'Ads_Vcu_Target_Tire_Ang_Speed'), '{:.1f}')} deg/s")
    out.append(f"  0x068 brake    en={g(c_brk, 'Ads_Vcu_Brk_En')}  mode={g(c_brk, 'Ads_Vcu_Brk_Mode')}  "
               f"target_pedal={num(g(c_brk, 'Ads_Vcu_Brake_Pedal_Target_Pos'), '{:.1f}')} %  "
               f"stroke={num(g(c_brk, 'Ads_Vcu_Target_Stroke'))} mm")
    out.append(f"  0x075 motor    en={g(c_mtr, 'Ads_Vcu_Motor_En')}  gear_en={g(c_mtr, 'Ads_Vcu_Gear_En')}  "
               f"gear={g(c_mtr, 'Ads_Vcu_Target_Gear')}  mode={g(c_mtr, 'Ads_Vcu_Mtr_Mode')}  "
               f"target_speed={num(g(c_mtr, 'Ads_Vcu_Target_Speed'))} m/s")
    out.append("")
    out.append(f"Rates (Hz, last {RATE_WINDOW_S:.0f} s)  " + "  ".join(
        f"{i:03X}={rates[i]:.0f}" for i in VCU_IDS + ADS_IDS))
    out.append("Raw  " + "  ".join(f"{i:03X}#{raw[i]}" for i in VCU_IDS + ADS_IDS if i in raw))
    out.append("")
    out.append(f"{iface} controller")
    out.extend("  " + ln for ln in link.splitlines())

    notes = []
    if not any(rates[i] for i in VCU_IDS):
        notes.append("no VCU frames: the cart is off, or the bus is on the other host (CAN_HOST)")
    if not any(rates[i] for i in ADS_IDS):
        notes.append("none of our ADS frames on the bus: the vehicle interface is not running"
                     " (or not on this bus); without our rolling counter the VCU reports zeros")
    if veh is not None and raw.get(0x103, "").strip("0") == "" and raw.get(0x101, "").strip("0") == "":
        notes.append("VCU frames are all zero (state Invalid): it has not heard our 0x43F rolling"
                     " counter, so VelocityReport and the control mode are meaningless")
    if eps is not None and str(g(eps, "Vcu_Ads_EPS_State")) == "Manual":
        notes.append("EPS state Manual: VCU quirk - the reported tire angle is frozen in Manual"
                     " and does not follow the wheel")
    if (isinstance(tgt, (int, float)) and tgt < -0.5 and isinstance(ang, (int, float))
            and ang == 0 and str(g(c_eps, "Ads_Vcu_Eps_En")) == "enable"):
        notes.append("left (negative) target but tire angle reads 0: VCU quirk - left angles"
                     " are reported as 0")
    if str(g(veh, "Vcu_Ads_Estop")) == "Pressed":
        notes.append("the cart's E-stop is pressed")
    if notes:
        out.append("")
        out.append("Notes")
        out.extend("  - " + n for n in notes)
    return "\n".join(out)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--once", action="store_true", help="listen 2 s (one rate window), print one snapshot, exit")
    ap.add_argument("--seconds", type=float, default=None, help="listen N s, print one snapshot, exit")
    ap.add_argument("--host", default=os.environ.get("CAN_HOST", "orin"), choices=("orin", "local"))
    ap.add_argument("--iface", default=os.environ.get("CAN_IFACE", "can0"))
    ap.add_argument("--dbc", default=os.environ.get("CAX_ADS_DBC") or str(DEFAULT_DBC))
    args = ap.parse_args()

    dbc = Path(args.dbc)
    if not dbc.is_file():
        print(f"vcu_status: no DBC at {dbc}\n  The vendor CAX_ADS_CAN.dbc is proprietary and gitignored."
              " Copy it to the vehicle interface crate root, or set CAX_ADS_DBC.", file=sys.stderr)
        return 2
    try:
        import cantools
    except ImportError:
        print("vcu_status: python3 cantools is not installed (pip install cantools)", file=sys.stderr)
        return 2
    db = cantools.database.load_file(str(dbc))

    state = State()
    remote = None
    if args.host == "orin":
        ssh, key = orin_ssh_settings()
        remote = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5"]
        if key and Path(os.path.expanduser(key)).is_file():
            remote += ["-i", os.path.expanduser(key)]
        remote.append(ssh)
        # -T: no tty, so ssh's exit on Ctrl-C closes the pipe and candump dies
        # with SIGPIPE on its next write rather than lingering on the orin.
        cmd = remote[:1] + ["-T"] + remote[1:] + [f"exec candump -L {shlex.quote(args.iface)}"]
        target = threading.Thread(target=reader_candump, args=(state, db, cmd), daemon=True)
    else:
        target = threading.Thread(target=reader_python_can, args=(state, db, args.iface), daemon=True)
    target.start()

    snapshot = args.once or args.seconds is not None
    if snapshot:
        time.sleep(args.seconds if args.seconds is not None else RATE_WINDOW_S)
        state.link = read_link(remote, args.iface)
        text = render(state, args.host, args.iface)
        print(text)
        if state.reader_error:
            print(state.reader_error, file=sys.stderr)
        return 0 if state.frames else 1

    threading.Thread(target=link_poller, args=(state, remote, args.iface, 2.0), daemon=True).start()
    tty = sys.stdout.isatty()
    try:
        while True:
            text = render(state, args.host, args.iface)
            if state.reader_error:
                text += "\n\n" + state.reader_error
            sys.stdout.write(("\033[H\033[2J" if tty else "\n") + text + "\n")
            sys.stdout.flush()
            if state.reader_error:
                return 1
            time.sleep(0.5)
    except KeyboardInterrupt:
        return 0


if __name__ == "__main__":
    sys.exit(main())
