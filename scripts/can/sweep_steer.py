#!/usr/bin/env python3
"""sweep_steer.py — Ramp Target_Tire_Angle and log VCU_ADS_EPS.Tire_Angle.

Triangle wave on tire angle while reading EPS echo. CSV output for
characterization. See sweep_speed.py for the same pattern.

Usage:
    python3 scripts/can/sweep_steer.py [iface] --max 15 --duration 20 --out steer.csv
"""
from __future__ import annotations

import argparse
import csv
import os
import socket
import struct
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from static_can_test import ADS_VCU_EPS, _build_eps, open_can as open_tx  # noqa: E402

VCU_ADS_EPS = 0x102

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
            if can_id == VCU_ADS_EPS and dlc >= 3:
                # bytes [1:3] = tire_angle int16 (0.002 deg LSB).
                state["measured_deg"] = _i16(data, 1) * 0.002
    finally:
        s.close()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("interface", nargs="?", default="vcan0")
    ap.add_argument("--max", type=float, default=15.0,
                    help="Peak tire-angle magnitude (degrees). Default 15°.")
    ap.add_argument("--duration", type=float, default=20.0,
                    help="Total sweep duration (s). Default 20.")
    ap.add_argument("--rate", type=float, default=100.0,
                    help="ADS_VCU_EPS TX rate. Default 100 Hz.")
    ap.add_argument("--out", default="steer_sweep.csv")
    args = ap.parse_args()

    tx = open_tx(args.interface)
    state = {"measured_deg": 0.0}
    stop = threading.Event()
    rx = threading.Thread(target=rx_thread, args=(args.interface, state, stop))
    rx.start()

    period = 1.0 / args.rate
    samples = int(args.duration / period)
    print(f"Sweeping tire angle 0..±{args.max}° over {args.duration}s "
          f"on {args.interface}, writing {args.out}")
    try:
        with open(args.out, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["t", "target_deg", "measured_deg"])
            t0 = time.monotonic()
            for i in range(samples):
                t_rel = i * period
                phase = (t_rel / args.duration) * 4.0
                if phase < 1:
                    target = args.max * phase
                elif phase < 2:
                    target = args.max * (2 - phase)
                elif phase < 3:
                    target = -args.max * (phase - 2)
                else:
                    target = -args.max * (4 - phase)
                tx.send(struct.pack(
                    CAN_FRAME_FMT, ADS_VCU_EPS, 8,
                    _build_eps(True, target),
                ))
                w.writerow([f"{t_rel:.3f}", f"{target:.3f}",
                            f"{state['measured_deg']:.3f}"])
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
