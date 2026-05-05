#!/usr/bin/env python3
"""static_can_test.py — Send constant ADS_VCU_* frames at 100 Hz.

Bringup smoke test: emit a known-safe heartbeat (engaged / gear=Drive but
all setpoints zero) for N seconds. Useful to verify the bus is live and
the VCU echoes anything back. NOT a full FSM exerciser — for that, use
the real `golfcart_vehicle_interface` against `mock_vcu`.

Usage:
    python3 scripts/can/static_can_test.py [iface] [--seconds N]

Field layouts come from `CAX_ADS_CAN.dbc`. Big-endian throughout.
"""
from __future__ import annotations

import argparse
import socket
import struct
import sys
import time

ADS_VCU_MTR = 0x075
ADS_VCU_BRK = 0x068
ADS_VCU_EPS = 0x065
ADS_VCU_VEHICLE = 0x43F


def _build_mtr(motor_en: bool, gear: int, speed_mps: float) -> bytes:
    flags = (
        (1 if motor_en else 0)
        | (1 << 1)               # gear_en
        | (1 << 2)               # mode = Speed
        | ((gear & 0x3) << 3)
    )
    speed_raw = max(min(int(round(speed_mps * 1000)), 32767), -32768)
    payload = bytearray(8)
    payload[0] = flags
    payload[1] = 0               # throttle (unsigned, 0.4 % LSB)
    struct.pack_into(">H", payload, 2, 0)         # accel = 0 m/s²
    struct.pack_into(">h", payload, 4, speed_raw)
    payload[6] = 0
    payload[7] = 0               # checksum stub
    return bytes(payload)


def _build_brk(brk_en: bool) -> bytes:
    flags = (1 if brk_en else 0) | (2 << 1)  # mode = Pressure
    payload = bytearray(8)
    payload[0] = flags
    return bytes(payload)


def _build_eps(eps_en: bool, tire_deg: float) -> bytes:
    flags = (1 if eps_en else 0) | (1 << 1)  # mode = FrontWheel
    tire_raw = max(min(int(round(tire_deg / 0.002)), 32767), -32768)
    rate_raw = 0
    payload = bytearray(8)
    payload[0] = flags
    struct.pack_into(">h", payload, 1, tire_raw)
    payload[3] = rate_raw & 0xFF
    return bytes(payload)


def _build_vehicle(auto_en: bool, gear: int, rolling: int) -> bytes:
    flags0 = (
        (1 if auto_en else 0)
        | (1 << 1)               # ads_status = Running
        | (0 << 5)               # blinker = Off
    )
    flags1 = 0
    if gear == 3:                # Reverse
        flags1 |= 1 << 2
    payload = bytearray(8)
    payload[0] = flags0
    payload[1] = flags1
    payload[6] = rolling & 0xFF
    return bytes(payload)


CAN_FRAME_FMT = "=IB3x8s"


def open_can(iface: str) -> socket.socket:
    s = socket.socket(socket.AF_CAN, socket.SOCK_RAW, socket.CAN_RAW)
    s.bind((iface,))
    return s


def send(s: socket.socket, can_id: int, payload: bytes) -> None:
    assert len(payload) == 8
    frame = struct.pack(CAN_FRAME_FMT, can_id, 8, payload)
    s.send(frame)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("interface", nargs="?", default="vcan0")
    ap.add_argument("--seconds", type=float, default=10.0,
                    help="Run duration. Default 10s.")
    ap.add_argument("--rate", type=float, default=100.0,
                    help="TX rate per frame. Default 100 Hz.")
    ap.add_argument("--gear", type=int, default=1,
                    help="Target gear (0=Park, 1=Drive, 2=Neutral, 3=Reverse). Default Drive.")
    ap.add_argument("--speed", type=float, default=0.0,
                    help="Target speed m/s. Default 0.0 (heartbeat only).")
    args = ap.parse_args()

    try:
        s = open_can(args.interface)
    except OSError as e:
        print(f"open CAN '{args.interface}' failed: {e}", file=sys.stderr)
        return 1

    period = 1.0 / args.rate
    end = time.monotonic() + args.seconds
    rolling = 0
    print(f"Sending heartbeat to {args.interface} for {args.seconds}s "
          f"(rate={args.rate}Hz, gear={args.gear}, speed={args.speed} m/s)")
    try:
        while time.monotonic() < end:
            send(s, ADS_VCU_MTR, _build_mtr(True, args.gear, args.speed))
            send(s, ADS_VCU_BRK, _build_brk(True))
            send(s, ADS_VCU_EPS, _build_eps(True, 0.0))
            send(s, ADS_VCU_VEHICLE, _build_vehicle(True, args.gear, rolling))
            rolling = (rolling + 1) & 0xFF
            time.sleep(period)
    except KeyboardInterrupt:
        pass
    finally:
        s.close()
    print("Done.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
