#!/usr/bin/env python3
"""monitor_can.py — Decoded live view of Turing Drive CAN traffic.

Reads frames off a SocketCAN interface and prints the most recent value of
each protocol message in a fixed-width table that updates in place. Color
highlights changed fields. Use during bringup as a faster alternative to
`candump | grep`.

Field layouts cribbed from `CAX_ADS_CAN.dbc`. Big-endian throughout.

Usage:
    python3 scripts/can/monitor_can.py [iface]    # default vcan0

Requires: only the standard library and python-can. Falls back to raw
SocketCAN via `socket` if python-can isn't installed.
"""
from __future__ import annotations

import argparse
import socket
import struct
import sys
import time
from dataclasses import dataclass, field
from typing import Callable, Dict, Tuple

# ---------------------------------------------------------------------------
# CAN ID map. (id, name, decoder).
# ---------------------------------------------------------------------------

ADS_VCU_MTR = 0x075
ADS_VCU_BRK = 0x068
ADS_VCU_EPS = 0x065
ADS_VCU_VEHICLE = 0x43F
VCU_ADS_BRK = 0x100
VCU_ADS_MTR = 0x101
VCU_ADS_EPS = 0x102
VCU_ADS_VEHICLE = 0x103


def _i16(b: bytes, off: int) -> int:
    return struct.unpack(">h", bytes(b[off : off + 2]))[0]


def _u16(b: bytes, off: int) -> int:
    return struct.unpack(">H", bytes(b[off : off + 2]))[0]


def _decode_ads_vcu_mtr(d: bytes) -> Dict[str, str]:
    flags = d[0]
    return {
        "motor_en": str(bool(flags & 0x01)),
        "gear_en": str(bool(flags & 0x02)),
        "mode": "Speed" if (flags & 0x04) else "Pedal",
        "gear": ["Park", "Drive", "Neutral", "Reverse"][(flags >> 3) & 0x3],
        "throttle_pct": f"{d[1] * 0.4:.1f}",
        "accel_mps2": f"{_u16(d, 2) * 0.001:.3f}",
        "speed_mps": f"{_i16(d, 4) * 0.001:.3f}",
    }


def _decode_ads_vcu_brk(d: bytes) -> Dict[str, str]:
    return {
        "brk_en": str(bool(d[0] & 0x01)),
        "mode": ["Invalid", "Stroke", "Pressure"][min((d[0] >> 1) & 0x3, 2)],
        "stroke_mm": f"{d[1] * 0.1:.2f}",
        "pressure_mpa": f"{d[2] * 0.05:.3f}",
        "decel_mps2": f"{d[3] * 0.05:.3f}",
    }


def _decode_ads_vcu_eps(d: bytes) -> Dict[str, str]:
    return {
        "eps_en": str(bool(d[0] & 0x01)),
        "mode": ["Invalid", "FrontWheel", "OppositePhase", "InPhase"][(d[0] >> 1) & 0x3],
        "tire_deg": f"{_i16(d, 1) * 0.002:.3f}",
        "tire_rate_dps": f"{struct.unpack('b', bytes([d[3]]))[0] * 0.2:.2f}",
    }


def _decode_ads_vcu_vehicle(d: bytes) -> Dict[str, str]:
    flags0 = d[0]
    return {
        "auto_en": str(bool(flags0 & 0x01)),
        "ads_status": ["Init", "Running", "Reserved", "Reserved2"][(flags0 >> 1) & 0x3],
        "estop": str(bool(flags0 & 0x10)),
        "blinker": ["Off", "Left", "Right", "Hazard"][(flags0 >> 5) & 0x3],
        "headlight": str(bool(flags0 & 0x80)),
        "rolling": str(d[6]),
    }


def _decode_vcu_ads_mtr(d: bytes) -> Dict[str, str]:
    return {
        "motor_state": str(d[0] & 0x3),
        "throttle_pct": str(d[1]),
        "gear_pos": ["Park", "Drive", "Neutral", "Reverse"][d[2] & 0x3],
        "speed_mps": f"{_i16(d, 3) * 0.001:.3f}",
    }


def _decode_vcu_ads_eps(d: bytes) -> Dict[str, str]:
    return {
        "eps_state": str(d[0] & 0x3),
        "tire_deg": f"{_i16(d, 1) * 0.002:.3f}",
    }


def _decode_vcu_ads_brk(d: bytes) -> Dict[str, str]:
    return {
        "brake_state": str(d[0] & 0x3),
        "position_pct": str(d[1]),
        "stroke_mm": str(d[2]),
        "pressure_mpa": f"{d[3] * 0.05:.3f}",
    }


def _decode_vcu_ads_vehicle(d: bytes) -> Dict[str, str]:
    flags1 = d[1]
    return {
        "rolling": str(d[0]),
        "driving_state": ["Invalid", "Manual", "Autonomous", "RemoteControl"][flags1 & 0x3],
        "estop": str(bool(flags1 & 0x04)),
        "blinker": ["Off", "Left", "Right", "Hazard"][(flags1 >> 3) & 0x3],
        "err_sys": str(bool(flags1 & 0x80)),
        "err_mtr": str(bool(d[2] & 0x01)),
        "err_eps": str(bool(d[2] & 0x02)),
        "err_brk": str(bool(d[2] & 0x04)),
    }


DECODERS: Dict[int, Tuple[str, Callable[[bytes], Dict[str, str]]]] = {
    ADS_VCU_MTR: ("ADS_VCU_MTR", _decode_ads_vcu_mtr),
    ADS_VCU_BRK: ("ADS_VCU_BRK", _decode_ads_vcu_brk),
    ADS_VCU_EPS: ("ADS_VCU_EPS", _decode_ads_vcu_eps),
    ADS_VCU_VEHICLE: ("ADS_VCU_VEHICLE", _decode_ads_vcu_vehicle),
    VCU_ADS_MTR: ("VCU_ADS_MTR", _decode_vcu_ads_mtr),
    VCU_ADS_BRK: ("VCU_ADS_BRK", _decode_vcu_ads_brk),
    VCU_ADS_EPS: ("VCU_ADS_EPS", _decode_vcu_ads_eps),
    VCU_ADS_VEHICLE: ("VCU_ADS_VEHICLE", _decode_vcu_ads_vehicle),
}

# ---------------------------------------------------------------------------
# SocketCAN read using only stdlib.
# ---------------------------------------------------------------------------

CAN_FRAME_FMT = "=IB3x8s"  # id, dlc, pad, data
CAN_FRAME_SZ = struct.calcsize(CAN_FRAME_FMT)


def open_can(iface: str) -> socket.socket:
    s = socket.socket(socket.AF_CAN, socket.SOCK_RAW, socket.CAN_RAW)
    s.bind((iface,))
    s.settimeout(0.2)
    return s


def read_frame(s: socket.socket) -> Tuple[int, bytes]:
    raw = s.recv(CAN_FRAME_SZ)
    can_id, dlc, _data = struct.unpack(CAN_FRAME_FMT, raw)
    # Mask flag bits: keep just the standard 11-bit ID for SFF frames.
    can_id &= 0x7FF
    return can_id, _data[:dlc]


# ---------------------------------------------------------------------------
# Display
# ---------------------------------------------------------------------------

CSI = "\x1b["
GREEN = CSI + "32m"
YELLOW = CSI + "33m"
DIM = CSI + "2m"
RESET = CSI + "0m"
CLEAR = CSI + "2J" + CSI + "H"
HIDE = CSI + "?25l"
SHOW = CSI + "?25h"


@dataclass
class FrameState:
    name: str
    last_seen: float = 0.0
    fields: Dict[str, str] = field(default_factory=dict)
    prev_fields: Dict[str, str] = field(default_factory=dict)
    count: int = 0


def render(state: Dict[int, FrameState], iface: str) -> None:
    sys.stdout.write(CLEAR)
    sys.stdout.write(f"monitor_can — iface={iface}  (Ctrl-C to exit)\n\n")
    now = time.monotonic()
    for can_id in sorted(state.keys()):
        fs = state[can_id]
        age = now - fs.last_seen if fs.last_seen else float("inf")
        age_str = f"{age * 1000:.0f}ms" if age < 60 else "stale"
        head_color = GREEN if age < 1.0 else (YELLOW if age < 5.0 else DIM)
        sys.stdout.write(
            f"{head_color}0x{can_id:03x}  {fs.name:<18}{RESET} "
            f"  age={age_str:<7} count={fs.count}\n"
        )
        for k, v in fs.fields.items():
            changed = fs.prev_fields.get(k) != v
            color = YELLOW if changed else ""
            sys.stdout.write(f"    {k:<16} = {color}{v}{RESET}\n")
        sys.stdout.write("\n")
    sys.stdout.flush()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("interface", nargs="?", default="vcan0")
    ap.add_argument(
        "--rate", type=float, default=10.0,
        help="Render rate (Hz). Default 10.",
    )
    args = ap.parse_args()

    try:
        s = open_can(args.interface)
    except OSError as e:
        print(f"open CAN '{args.interface}' failed: {e}", file=sys.stderr)
        return 1

    state: Dict[int, FrameState] = {
        cid: FrameState(name=name) for cid, (name, _) in DECODERS.items()
    }
    last_render = 0.0
    render_period = 1.0 / args.rate

    sys.stdout.write(HIDE)
    try:
        while True:
            try:
                can_id, data = read_frame(s)
            except socket.timeout:
                pass
            else:
                if can_id in DECODERS:
                    _name, decoder = DECODERS[can_id]
                    fs = state[can_id]
                    new_fields = decoder(data)
                    fs.prev_fields = fs.fields
                    fs.fields = new_fields
                    fs.last_seen = time.monotonic()
                    fs.count += 1

            now = time.monotonic()
            if now - last_render >= render_period:
                render(state, args.interface)
                last_render = now
    except KeyboardInterrupt:
        return 0
    finally:
        sys.stdout.write(SHOW + "\n")
        s.close()


if __name__ == "__main__":
    sys.exit(main())
