#!/usr/bin/env python3
"""sweep_brake.py — Ramp Target_Pressure and log VCU_ADS_BRK.Brake_Pressure.

Triangle wave on brake pressure (0 → max → 0) while reading BRK echo.
CSV output for characterization.

Usage:
    python3 scripts/can/sweep_brake.py [iface] --max 4.0 --duration 10
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

from static_can_test import open_can as open_tx, ADS_VCU_BRK  # noqa: E402

VCU_ADS_BRK = 0x100

CAN_FRAME_FMT = "=IB3x8s"
CAN_FRAME_SZ = struct.calcsize(CAN_FRAME_FMT)


def _build_brk_with_pressure(brk_en: bool, pressure_mpa: float) -> bytes:
    flags = (1 if brk_en else 0) | (2 << 1)  # mode = Pressure
    pressure_raw = max(min(int(round(pressure_mpa / 0.05)), 255), 0)
    payload = bytearray(8)
    payload[0] = flags
    payload[2] = pressure_raw
    return bytes(payload)


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
            if can_id == VCU_ADS_BRK and dlc >= 4:
                # byte [3] = pressure (0.05 MPa LSB).
                state["measured_mpa"] = data[3] * 0.05
    finally:
        s.close()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("interface", nargs="?", default="vcan0")
    ap.add_argument("--max", type=float, default=4.0,
                    help="Peak brake pressure (MPa). Default 4.0.")
    ap.add_argument("--duration", type=float, default=10.0)
    ap.add_argument("--rate", type=float, default=100.0)
    ap.add_argument("--out", default="brake_sweep.csv")
    args = ap.parse_args()

    tx = open_tx(args.interface)
    state = {"measured_mpa": 0.0}
    stop = threading.Event()
    rx = threading.Thread(target=rx_thread, args=(args.interface, state, stop))
    rx.start()

    period = 1.0 / args.rate
    samples = int(args.duration / period)
    print(f"Sweeping brake 0..{args.max} MPa over {args.duration}s "
          f"on {args.interface}, writing {args.out}")
    try:
        with open(args.out, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(["t", "target_mpa", "measured_mpa"])
            t0 = time.monotonic()
            for i in range(samples):
                t_rel = i * period
                phase = (t_rel / args.duration) * 2.0  # 0..2
                target = args.max * (phase if phase < 1 else 2 - phase)
                target = max(target, 0.0)
                tx.send(struct.pack(
                    CAN_FRAME_FMT, ADS_VCU_BRK, 8,
                    _build_brk_with_pressure(True, target),
                ))
                w.writerow([f"{t_rel:.3f}", f"{target:.3f}",
                            f"{state['measured_mpa']:.3f}"])
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
