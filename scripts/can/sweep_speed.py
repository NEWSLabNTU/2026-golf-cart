#!/usr/bin/env python3
"""sweep_speed.py — Ramp Target_Speed and log VCU_ADS_MTR.Vehicle_Speed.

Sends ADS_VCU_MTR with a speed setpoint that traces a triangle wave
(0 → +max → 0 → -max → 0) over `--duration` seconds, while reading the
echoed VCU_ADS_MTR frame and writing `(t, target, measured)` rows to a
CSV file.

For step-response characterization on a real vehicle (HIL rig) or against
`mock_vcu` for offline validation. NOT a hardening test — that's
`fsm_assert` (T-13).

Usage:
    python3 scripts/can/sweep_speed.py [iface] --max 1.0 --duration 20 --out speed.csv
"""
from __future__ import annotations

import argparse
import csv
import os
import socket
import struct
import sys
import time
import threading

# Add this script's directory to sys.path so sibling helpers import.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from static_can_test import (  # noqa: E402  (sibling helper module)
    ADS_VCU_MTR,
    _build_mtr,
    open_can as open_tx,
)

VCU_ADS_MTR = 0x101

CAN_FRAME_FMT = "=IB3x8s"
CAN_FRAME_SZ = struct.calcsize(CAN_FRAME_FMT)


def _i16(b: bytes, off: int) -> int:
    return struct.unpack(">h", bytes(b[off : off + 2]))[0]


def open_rx(iface: str) -> socket.socket:
    s = socket.socket(socket.AF_CAN, socket.SOCK_RAW, socket.CAN_RAW)
    s.bind((iface,))
    s.settimeout(0.05)
    return s


def rx_thread(iface: str, state: dict, stop: threading.Event) -> None:
    s = open_rx(iface)
    try:
        while not stop.is_set():
            try:
                raw = s.recv(CAN_FRAME_SZ)
            except socket.timeout:
                continue
            can_id, dlc, data = struct.unpack(CAN_FRAME_FMT, raw)
            can_id &= 0x7FF
            if can_id == VCU_ADS_MTR and dlc >= 5:
                # bytes [3:5] are speed in raw int16 (0.001 m/s LSB).
                state["measured_mps"] = _i16(data, 3) * 0.001
    finally:
        s.close()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("interface", nargs="?", default="vcan0")
    ap.add_argument("--max", type=float, default=1.0,
                    help="Peak speed magnitude (m/s). Default 1.0.")
    ap.add_argument("--duration", type=float, default=20.0,
                    help="Total sweep duration (s). Default 20.")
    ap.add_argument("--rate", type=float, default=100.0,
                    help="ADS_VCU_MTR TX rate. Default 100 Hz.")
    ap.add_argument("--out", default="speed_sweep.csv",
                    help="Output CSV path. Default speed_sweep.csv.")
    args = ap.parse_args()

    tx = open_tx(args.interface)
    state = {"measured_mps": 0.0}
    stop = threading.Event()
    rx = threading.Thread(target=rx_thread, args=(args.interface, state, stop))
    rx.start()

    period = 1.0 / args.rate
    samples = int(args.duration / period)
    print(f"Sweeping speed 0..±{args.max} m/s over {args.duration}s "
          f"on {args.interface}, writing {args.out}")
    try:
        with open(args.out, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["t", "target_mps", "measured_mps"])
            t0 = time.monotonic()
            for i in range(samples):
                t_rel = i * period
                # Triangle wave: 0 → max → 0 → -max → 0 over duration.
                phase = (t_rel / args.duration) * 4.0  # 0..4
                if phase < 1:
                    target = args.max * phase
                elif phase < 2:
                    target = args.max * (2 - phase)
                elif phase < 3:
                    target = -args.max * (phase - 2)
                else:
                    target = -args.max * (4 - phase)
                tx.send(struct.pack(
                    CAN_FRAME_FMT, ADS_VCU_MTR, 8,
                    _build_mtr(True, 1, target),
                ))
                w.writerow([f"{t_rel:.3f}", f"{target:.3f}",
                            f"{state['measured_mps']:.3f}"])
                # Sleep to keep schedule.
                next_at = t0 + (i + 1) * period
                slack = next_at - time.monotonic()
                if slack > 0:
                    time.sleep(slack)
    except KeyboardInterrupt:
        print("\nInterrupted.")
    finally:
        stop.set()
        rx.join()
        tx.close()

    print(f"Wrote {args.out}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
