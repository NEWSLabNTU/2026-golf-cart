#!/usr/bin/env python3
"""Fit dead time, first-order lag and rate limit to the cart's step responses.

    python3 scripts/testing/sysid/sysid_fit.py BAG                 # a rosbag2 directory
    python3 scripts/testing/sysid/sysid_fit.py --can LOG           # a candump -L log
    python3 scripts/testing/sysid/sysid_fit.py BAG --can LOG       # both, side by side

Phase 8, V4 (desk half). The vehicle day records steps with sysid_steps.py and
sysid_record.sh; this turns the recording into the numbers Autoware's lateral
MPC, longitudinal PID and simple_planning_simulator take, and prints them as
YAML lines to paste.

Two forms of one model are fitted, because the plant may be either:

    parallel  dy/dt = clip((u(t - delay) - y) / tau, -rate, +rate)
              a rate-limited servo; simple_planning_simulator's DELAY_STEER_*
              (universe 0.48.0) is exactly this
    series    r = u rate-limited at `rate`; dy/dt = (r(t - delay) - y) / tau
              a slewed command into a lag; the vehicle interface's steering
              slew is this shape, and so is MPC's view (steer_rate_lim bounds
              its own command, input_delay + vehicle_model_steer_tau follow)

Fitting a plant with the wrong form trades delay for ramp: on Autoware's own
simulator (parallel, 0.30 s delay) the series fit reads 0.03 s, and on the
interface + mock_vcu (series, ~0 s) the parallel fit reads 0.13 s. So both are
fitted, the one with the smaller error is printed per step and feeds MPC and
the PID, and the simulator always gets the parallel fit, its own form.

u is the command held between samples, y the report. Each step event gets its
own gain and offset from its settled levels (so a report that reads 22 deg
for a 25 deg command, or a constant gyro bias, does not bend the dynamics),
and one (delay, tau, rate) is fitted to all accepted events of a channel
together. A rate limit is reported only when it binds and earns a 10 % lower
squared error; otherwise "n/r", not reached, and the steps were too small.

Channels, from a bag (time = bag receive time unless --stamp header):

  steer       Control.lateral.steering_tire_angle -> SteeringReport. What MPC
              sees: the interface's slew, the CAN hop, the EPS, the 50 Hz report.
  steer_yaw   the same command -> atan(wheelbase * yaw_rate / v), from an IMU
              while moving. The only way to see LEFT steps while the VCU's
              left report reads 0 (Phase 9, vendor issue 1).
  speed       Control.longitudinal.velocity -> VelocityReport. The VCU runs in
              speed mode; rate is the acceleration (rising steps) or the
              unbraked deceleration (falling steps) it achieves.
  brake       Control.longitudinal.acceleration stepping negative -> dv/dt.
              The gain is the achieved fraction of the request, which is
              S3's brake-stage question; no rate limit is fitted.

From a candump -L log (needs the vendor DBC), the same channels one hop
further down: the interface's slew-limited Ads_Vcu_Target_Tire_Angle against
Vcu_Ads_Tire_Angle, Target_Speed against Vehicle_Speed, Target_Deceleration
against d(Vehicle_Speed)/dt. Kernel timestamps on one clock, so the CAN delay
is the VCU's own; bag minus CAN is the interface, the report tick and the link.

Events are rejected, with the reason printed, when the report does not move
(the left steering report), has not settled before the next step (hold
longer), or the VCU was not in AUTO throughout.

Needs numpy; a bag needs rosbag2_py (source scripts/env.sh), a CAN log needs
cantools and CAX_ADS_CAN.dbc (CAX_ADS_DBC or the vehicle interface crate root).
"""

from __future__ import annotations

import argparse
import dataclasses
import math
import os
import re
import sys
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parents[3]
DEFAULT_DBC = REPO / 'src/vehicle/golfcart_vehicle_launch/golfcart_vehicle_interface/CAX_ADS_CAN.dbc'
VEHICLE_INFO = (REPO / 'src/vehicle/golfcart_vehicle_launch/golfcart_vehicle_description'
                / 'config/vehicle_info.param.yaml')

# Stock values the fit replaces: universe 0.48.0 / autoware_launch 1.5.0 and
# golfcart_vehicle_description's simulator_model.param.yaml (Lexus numbers).
STOCK = {
    'input_delay': 0.24, 'vehicle_model_steer_tau': 0.27, 'steer_rate_lim_dps': 40.0,
    'delay_compensation_time': 0.1,
    'steer_time_delay': 0.24, 'steer_time_constant': 0.27, 'steer_rate_lim': 5.0,
    'acc_time_delay': 0.1, 'acc_time_constant': 0.1, 'vel_rate_lim': 7.0,
    'vel_time_delay': 0.25, 'vel_time_constant': 0.5,
}

RATE_NONE = 1e3          # "no rate limit" in the units of y per second
SIM_DT = 0.005           # internal integration step [s]


# ---------------------------------------------------------------- the model

def delayed_input(t_grid: np.ndarray, t_u: np.ndarray, u: np.ndarray, delay: float) -> np.ndarray:
    """u held between samples (zero-order hold), read `delay` seconds late."""
    i = np.searchsorted(t_u, t_grid - delay, side='right') - 1
    return u[np.clip(i, 0, len(u) - 1)]


def simulate(t_grid: np.ndarray, t_u: np.ndarray, u: np.ndarray, y0: float,
             delay: float, tau: float, rate: float, series: bool = False) -> np.ndarray:
    """First-order lag with dead time and a rate limit.

    parallel (series=False), simple_planning_simulator's form: the lag's own
    rate is clipped, dy/dt = clip((target - y)/tau, -rate, rate). Per step of
    t_grid the lag moves (target - y)(1 - exp(-h/tau)), the exact solution for
    a held target, and the move is clipped to rate * h.

    series (series=True), MPC's form: the command is rate limited first (MPC's
    steer_rate_lim constrains its own output; the vehicle interface slews the
    same way), then delayed, then lagged.
    """
    target = delayed_input(t_grid, t_u, u, delay).tolist()
    h = np.diff(t_grid, prepend=t_grid[0]).tolist()
    tau = max(tau, 1e-4)
    y = y0
    r = y0                       # the rate-limited command (series only)
    out = [0.0] * len(target)
    last_h = None
    for k in range(len(target)):
        hk = h[k]
        if hk != last_h:
            a = 1.0 - math.exp(-hk / tau)
            lim = rate * hk
            last_h = hk
        if series:
            d = target[k] - r
            r += lim if d > lim else (-lim if d < -lim else d)
            y += (r - y) * a
        else:
            d = (target[k] - y) * a
            if d > lim:
                d = lim
            elif d < -lim:
                d = -lim
            y += d
        out[k] = y
    return np.asarray(out)


def step_response(t: np.ndarray, t_step: float, u0: float, u1: float, y0: float,
                  delay: float, tau: float, rate: float) -> np.ndarray:
    """Closed form-free helper for tests: response to one step at t_step."""
    t_u = np.array([t[0] - 1.0, t_step])
    u = np.array([u0, u1])
    grid = np.arange(t[0], t[-1] + SIM_DT, SIM_DT)
    return np.interp(t, grid, simulate(grid, t_u, u, y0, delay, tau, rate))


# ---------------------------------------------------------------- events

@dataclasses.dataclass
class Fit:
    delay: float
    tau: float
    rate: float            # RATE_NONE when not fitted
    rms: float
    rate_active: bool      # did the limit bind anywhere in the data
    n: int = 1
    series: bool = False


@dataclasses.dataclass
class Event:
    t0: float              # first command change of the step
    t_end: float           # end of the analysis window
    u0: float
    u1: float
    y0: float = float('nan')
    y1: float = float('nan')
    gain: float = float('nan')
    status: str = 'ok'
    fit: Fit | None = None
    # window data, normalised command already applied
    t: np.ndarray | None = None
    y: np.ndarray | None = None
    t_u: np.ndarray | None = None
    u_n: np.ndarray | None = None
    extra: dict = dataclasses.field(default_factory=dict)   # brake: model-free numbers

    @property
    def ok(self) -> bool:
        return self.status == 'ok'


def find_steps(t_u: np.ndarray, u: np.ndarray, threshold: float, merge_s: float = 0.3,
               min_hold_s: float = 1.0, t_stop: float | None = None) -> list[Event]:
    """Group command changes into steps.

    Consecutive changes less than `merge_s` apart are one step, so a command the
    interface slews at 0.4 rad/s (a ramp on CAN) is one event, as is a step in a
    bag. A step must move more than `threshold` and hold `min_hold_s` before the
    next one; shorter holds (keyboard repeats) are dropped as not a step.
    """
    if len(u) < 2:
        return []
    change = np.nonzero(np.abs(np.diff(u)) > 1e-9)[0] + 1
    groups: list[list[int]] = []
    for i in change:
        if groups and t_u[i] - t_u[groups[-1][-1]] <= merge_s:
            groups[-1].append(i)
        else:
            groups.append([i])
    t_last = t_u[-1] if t_stop is None else t_stop
    events = []
    for gi, g in enumerate(groups):
        t_start = t_u[g[0]]
        t_settle = t_u[g[-1]]
        t_next = t_u[groups[gi + 1][0]] if gi + 1 < len(groups) else t_last
        u0, u1 = u[g[0] - 1], u[g[-1]]
        if abs(u1 - u0) <= threshold:
            continue
        ev = Event(t0=t_start, t_end=t_next, u0=float(u0), u1=float(u1))
        if t_next - t_settle < min_hold_s:
            ev.status = f'hold {t_next - t_settle:.2f} s < {min_hold_s} s'
        events.append(ev)
    return events


def _median_in(t: np.ndarray, y: np.ndarray, a: float, b: float) -> float:
    m = (t >= a) & (t <= b) & np.isfinite(y)
    return float(np.median(y[m])) if m.sum() >= 2 else float('nan')


def prepare(ev: Event, t_u: np.ndarray, u: np.ndarray, t_y: np.ndarray, y: np.ndarray,
            pre_s: float = 0.5, settle_frac: float = 0.25, min_gain: float = 0.2,
            settle_tol: float = 0.1, gain_fixed: float | None = None) -> None:
    """Steady levels, gain, settledness; cut the window. Sets ev.status on rejection."""
    if not ev.ok:
        return
    win = ev.t_end - ev.t0
    a, b = ev.t0 - pre_s, ev.t_end
    m = (t_y >= a) & (t_y < b) & np.isfinite(y)
    if m.sum() < 10:
        ev.status = f'{int(m.sum())} report samples in the window'
        return
    tail = max(settle_frac * win, 0.3)
    ev.y0 = _median_in(t_y, y, a, ev.t0)
    ev.y1 = _median_in(t_y, y, b - tail, b)
    if not (math.isfinite(ev.y0) and math.isfinite(ev.y1)):
        ev.status = 'no report before or after the step'
        return
    du = ev.u1 - ev.u0
    ev.gain = (ev.y1 - ev.y0) / du if gain_fixed is None else gain_fixed
    if gain_fixed is None and ev.gain < min_gain:
        ev.status = ('no response: report flat' if abs(ev.gain) < min_gain
                     else 'report moved the wrong way')
        return
    # Settled: the previous tail-sized slice already sits near the final level.
    prev = _median_in(t_y, y, b - 2 * tail, b - tail)
    step = abs(ev.y1 - ev.y0)
    if math.isfinite(prev) and abs(ev.y1 - prev) > settle_tol * step:
        ev.status = 'not settled before the next step (hold longer)'
        return
    ev.t, ev.y = t_y[m], y[m]
    k = np.searchsorted(t_u, a, side='right') - 1
    k = max(k, 0)
    mu = (t_u >= a) & (t_u < b)
    ev.t_u = np.concatenate(([a - 5.0], t_u[mu]))
    raw = np.concatenate(([u[k]], u[mu]))
    ev.u_n = ev.y0 + ev.gain * (raw - ev.u0)


# ---------------------------------------------------------------- fitting

def _residuals(events: list[Event], delay: float, tau: float, rate: float,
               series: bool = False) -> np.ndarray:
    res = []
    for ev in events:
        grid = np.arange(ev.t[0], ev.t[-1] + SIM_DT, SIM_DT)
        sim = simulate(grid, ev.t_u, ev.u_n, ev.y0, delay, tau, rate, series)
        res.append(np.interp(ev.t, grid, sim) - ev.y)
    return np.concatenate(res)


def _nelder_mead(f, x0: np.ndarray, step: np.ndarray, iters: int = 200, tol: float = 1e-10):
    n = len(x0)
    pts = [x0] + [x0 + np.eye(n)[i] * step[i] for i in range(n)]
    vals = [f(p) for p in pts]
    for _ in range(iters):
        order = np.argsort(vals)
        pts = [pts[i] for i in order]
        vals = [vals[i] for i in order]
        if abs(vals[-1] - vals[0]) <= tol * (abs(vals[0]) + tol):
            break
        c = np.mean(pts[:-1], axis=0)
        xr = c + (c - pts[-1])
        fr = f(xr)
        if fr < vals[0]:
            xe = c + 2 * (c - pts[-1])
            fe = f(xe)
            pts[-1], vals[-1] = (xe, fe) if fe < fr else (xr, fr)
        elif fr < vals[-2]:
            pts[-1], vals[-1] = xr, fr
        else:
            xc = c + 0.5 * (pts[-1] - c)
            fc = f(xc)
            if fc < vals[-1]:
                pts[-1], vals[-1] = xc, fc
            else:
                pts = [pts[0]] + [pts[0] + 0.5 * (p - pts[0]) for p in pts[1:]]
                vals = [vals[0]] + [f(p) for p in pts[1:]]
    i = int(np.argmin(vals))
    return pts[i], vals[i]


def _max_slope(events: list[Event], win_s: float = 0.15) -> float:
    best = 0.0
    for ev in events:
        for i in range(len(ev.t)):
            j = np.searchsorted(ev.t, ev.t[i] + win_s)
            if j < len(ev.t) and ev.t[j] - ev.t[i] > 0:
                best = max(best, abs(ev.y[j] - ev.y[i]) / (ev.t[j] - ev.t[i]))
    return best


def _fit(events: list[Event], fit_rate: bool, series: bool, max_delay: float):
    slope = max(_max_slope(events), 1e-6)

    def cost(p):
        delay, ltau = p[0], p[1]
        if delay < 0 or delay > max_delay or not -6 < ltau < 2:
            return 1e30
        rate = math.exp(p[2]) if fit_rate else RATE_NONE
        r = _residuals(events, delay, math.exp(ltau), rate, series)
        return float(r @ r)

    best = None
    for d0 in (0.05, 0.3):
        for tau0 in (0.05, 0.4):
            x0 = [d0, math.log(tau0)] + ([math.log(slope * 1.2)] if fit_rate else [])
            st = [0.1, 0.7] + ([0.5] if fit_rate else [])
            x, v = _nelder_mead(cost, np.array(x0), np.array(st))
            if best is None or v < best[1]:
                best = (x, v)
    x, v = _nelder_mead(cost, best[0], np.array([0.03, 0.2] + ([0.15] if fit_rate else [])))
    if v > best[1]:
        x, v = best
    return float(x[0]), float(math.exp(x[1])), (float(math.exp(x[2])) if fit_rate else RATE_NONE), v


def fit_events(events: list[Event], fit_rate: bool = True, max_delay: float = 2.0,
               series: bool = False) -> Fit | None:
    """One (delay, tau, rate) for all events; Nelder-Mead from a few starts.

    The rate limit is kept only if it earns its place: it must bind (removing
    it moves the model by more than 2 % of the largest step) and it must cut
    the squared error by more than 10 % against a fit without one. Otherwise a
    free rate soaks up timing quantisation as a fast "limit" that means nothing.
    """
    events = [e for e in events if e.ok and e.t is not None]
    if not events:
        return None
    n = sum(len(e.t) for e in events)
    delay, tau, _, v = _fit(events, False, series, max_delay)
    plain = Fit(delay=delay, tau=tau, rate=RATE_NONE, rms=math.sqrt(v / n), rate_active=False,
                n=len(events), series=series)
    if not fit_rate:
        return plain
    delay, tau, rate, v_rate = _fit(events, True, series, max_delay)
    step = max(abs(e.y1 - e.y0) for e in events)
    free = (_residuals(events, delay, tau, RATE_NONE, series)
            - _residuals(events, delay, tau, rate, series))
    if np.abs(free).max() <= 0.02 * step or v_rate > 0.9 * v:
        return plain
    return Fit(delay=delay, tau=tau, rate=rate, rms=math.sqrt(v_rate / n), rate_active=True,
               n=len(events), series=series)


# ---------------------------------------------------------------- series

@dataclasses.dataclass
class Series:
    t: np.ndarray
    v: np.ndarray

    @classmethod
    def of(cls, rows):
        if not rows:
            return cls(np.zeros(0), np.zeros(0))
        a = np.asarray(sorted(rows), dtype=float)
        return cls(a[:, 0], a[:, 1])

    def __len__(self):
        return len(self.t)


def derivative(s: Series, half_window_s: float = 0.15) -> Series:
    """Slope of a local straight-line fit, +-half_window_s around each sample."""
    t, v = s.t, s.v
    out = np.full(len(t), np.nan)
    lo = np.searchsorted(t, t - half_window_s)
    hi = np.searchsorted(t, t + half_window_s, side='right')
    for i in range(len(t)):
        a, b = lo[i], hi[i]
        if b - a >= 3:
            tt = t[a:b] - t[a:b].mean()
            den = tt @ tt
            if den > 0:
                out[i] = tt @ (v[a:b] - v[a:b].mean()) / den
    return Series(t, out)


def yaw_steer(imu: Series, vel: Series, wheelbase: float, v_min: float,
              smooth_s: float = 0.1) -> Series:
    """Effective tire angle from yaw rate: atan(L * w / v), NaN below v_min."""
    if not len(imu) or not len(vel):
        return Series(np.zeros(0), np.zeros(0))
    w = imu.v
    if smooth_s > 0 and len(w) > 3:
        dt = np.median(np.diff(imu.t))
        k = max(1, int(round(smooth_s / dt)))
        w = np.convolve(w, np.ones(k) / k, mode='same')
    v = np.interp(imu.t, vel.t, vel.v)
    with np.errstate(divide='ignore', invalid='ignore'):
        d = np.arctan(wheelbase * w / v)
    d[np.abs(v) < v_min] = np.nan
    return Series(imu.t, d)


# ---------------------------------------------------------------- readers

def read_bag(path: str, topics: dict[str, str], stamp: str = 'receive',
             imu_axis: str = 'z', imu_sign: float = 1.0) -> dict[str, Series]:
    """cmd_steer / cmd_vel / cmd_acc / steer / vel / imu_w / auto Series from a rosbag2."""
    import rosbag2_py
    from rclpy.serialization import deserialize_message
    from rosidl_runtime_py.utilities import get_message

    storage = 'sqlite3'
    meta = Path(path) / 'metadata.yaml'
    if meta.is_file():
        mm = re.search(r'storage_identifier:\s*(\S+)', meta.read_text())
        if mm:
            storage = mm.group(1)
    reader = rosbag2_py.SequentialReader()
    reader.open(rosbag2_py.StorageOptions(uri=str(path), storage_id=storage),
                rosbag2_py.ConverterOptions('cdr', 'cdr'))
    types = {t.name: t.type for t in reader.get_all_topics_and_types()}
    wanted = {v: k for k, v in topics.items() if v in types}
    reader.set_filter(rosbag2_py.StorageFilter(topics=list(wanted)))
    classes = {t: get_message(types[t]) for t in wanted}
    rows: dict[str, list] = {k: [] for k in
                             ('cmd_steer', 'cmd_vel', 'cmd_acc', 'steer', 'vel', 'imu_w', 'auto')}

    def ts(msg, recv):
        if stamp == 'receive':
            return recv * 1e-9
        st = getattr(msg, 'stamp', None) or msg.header.stamp
        return st.sec + st.nanosec * 1e-9

    while reader.has_next():
        topic, data, recv = reader.read_next()
        role = wanted[topic]
        msg = deserialize_message(data, classes[topic])
        t = ts(msg, recv)
        if role == 'cmd':
            rows['cmd_steer'].append((t, msg.lateral.steering_tire_angle))
            rows['cmd_vel'].append((t, msg.longitudinal.velocity))
            rows['cmd_acc'].append((t, msg.longitudinal.acceleration))
        elif role == 'steer':
            rows['steer'].append((t, msg.steering_tire_angle))
        elif role == 'vel':
            rows['vel'].append((t, msg.longitudinal_velocity))
        elif role == 'imu':
            rows['imu_w'].append((t, imu_sign * getattr(msg.angular_velocity, imu_axis)))
        elif role == 'mode':
            rows['auto'].append((t, 1.0 if msg.mode == 1 else 0.0))  # AUTONOMOUS
    out = {k: Series.of(v) for k, v in rows.items()}
    out['_missing'] = [t for t in topics.values() if t and t not in types]
    return out


CANDUMP = re.compile(r'^\((\d+\.\d+)\)\s+\S+\s+([0-9A-Fa-f]+)#([0-9A-Fa-f]*)')


def read_candump(path: str, dbc: str, steer_sign: float = -1.0) -> dict[str, Series]:
    """Same roles from a candump -L log. Steering flipped to REP-103 (left +)."""
    import cantools
    db = cantools.database.load_file(dbc)
    want = {0x065, 0x068, 0x075, 0x101, 0x102, 0x103}
    rows: dict[str, list] = {k: [] for k in
                             ('cmd_steer', 'cmd_vel', 'cmd_acc', 'steer', 'vel', 'auto')}
    with open(path) as f:
        for line in f:
            m = CANDUMP.match(line)
            if not m:
                continue
            fid = int(m.group(2), 16)
            if fid not in want:
                continue
            t = float(m.group(1))
            try:
                d = db.decode_message(fid, bytes.fromhex(m.group(3)), decode_choices=False)
            except (cantools.database.errors.Error, KeyError, ValueError):   # malformed frame
                continue
            if fid == 0x065:
                rows['cmd_steer'].append((t, steer_sign * math.radians(d['Ads_Vcu_Target_Tire_Angle'])))
            elif fid == 0x075:
                rows['cmd_vel'].append((t, d['Ads_Vcu_Target_Speed']))
            elif fid == 0x068:
                rows['cmd_acc'].append((t, -d['Ads_Vcu_Target_Deceleration']))
            elif fid == 0x102:
                rows['steer'].append((t, steer_sign * math.radians(d['Vcu_Ads_Tire_Angle'])))
            elif fid == 0x101:
                rows['vel'].append((t, d['Vcu_Ads_Vehicle_Speed']))
            elif fid == 0x103:
                rows['auto'].append((t, 1.0 if d['Vcu_Ads_Driving_State'] == 2 else 0.0))
    out = {k: Series.of(v) for k, v in rows.items()}
    out['imu_w'] = Series(np.zeros(0), np.zeros(0))
    out['_missing'] = []
    return out


def wheelbase_from_vehicle_info(path: Path = VEHICLE_INFO, default: float = 2.061) -> float:
    try:
        m = re.search(r'wheel_base:\s*([0-9.]+)', path.read_text())
        return float(m.group(1)) if m else default
    except OSError:
        return default


# ---------------------------------------------------------------- analysis

@dataclasses.dataclass
class Channel:
    name: str
    unit: str              # display unit of the command / report
    scale: float           # SI -> display
    events: list[Event]
    pooled: dict[str, Fit | None]   # series form; key '' (all), 'up'/'down', 'left'/'right'
    pooled_par: dict[str, Fit | None] = dataclasses.field(default_factory=dict)  # parallel form

    def prefers_series(self, group: str = '') -> bool:
        """The form with the smaller error; series when they tie (no rate limit)."""
        s, p = self.pooled.get(group), self.pooled_par.get(group)
        return p is None or (s is not None and s.rms <= p.rms * 1.001)

    def preferred(self, group: str = '') -> Fit | None:
        return (self.pooled if self.prefers_series(group) else self.pooled_par).get(group)


CHANNEL_DEFAULTS = {
    #            threshold (SI)    fit_rate  display unit, scale
    'steer':     (math.radians(0.5), True, 'deg', 180 / math.pi),
    'steer_yaw': (math.radians(0.5), True, 'deg', 180 / math.pi),
    'speed':     (0.1, True, 'm/s', 1.0),
    'brake':     (0.3, False, 'm/s2', 1.0),
}


def brake_metrics(ev: Event, vel: Series, acc: Series) -> None:
    """Model-free brake numbers, for steps the lag model cannot describe.

    Speed at the request, time to the first 3 cm/s lost, and the mean and peak
    deceleration from there to the stop (or the window's end).
    """
    if len(vel) < 2:
        return
    v0 = float(np.interp(ev.t0, vel.t, vel.v))
    m = (vel.t >= ev.t0) & (vel.t <= ev.t_end)
    tt, vv = vel.t[m], vel.v[m]
    lost = np.nonzero(vv < v0 - 0.03)[0]
    ev.extra['v0'] = v0
    if v0 < 0.1 or not len(lost):
        return
    t_on = float(tt[lost[0]])
    ev.extra['onset'] = t_on - ev.t0
    t_e = float(tt[-1])
    if t_e - t_on > 0.05:
        ev.extra['mean'] = (float(np.interp(t_on, tt, vv)) - float(vv[-1])) / (t_e - t_on)
    ma = (acc.t >= ev.t0) & (acc.t <= ev.t_end) & np.isfinite(acc.v)
    if ma.any():
        ev.extra['peak'] = -float(np.min(acc.v[ma]))


def _in_auto(auto: Series, a: float, b: float) -> bool:
    if not len(auto):
        return True                       # no mode topic: cannot tell, do not reject
    i = np.searchsorted(auto.t, a, side='right') - 1
    m = (auto.t >= a) & (auto.t <= b)
    vals = list(auto.v[m]) + ([auto.v[i]] if i >= 0 else [])
    return bool(vals) and min(vals) > 0.5


def analyse(data: dict[str, Series], channel: str, opts) -> Channel:
    thr, fit_rate, unit, scale = CHANNEL_DEFAULTS[channel]
    if channel in ('steer', 'steer_yaw'):
        cmd = data['cmd_steer']
    elif channel == 'speed':
        cmd = data['cmd_vel']
    else:
        cmd = data['cmd_acc']
    if channel == 'steer':
        rep = data['steer']
    elif channel == 'steer_yaw':
        rep = yaw_steer(data['imu_w'], data['vel'], opts.wheelbase, opts.v_min)
    elif channel == 'speed':
        rep = data['vel']
    else:
        rep = derivative(data['vel'])
    if not len(cmd) or not len(rep):
        return Channel(channel, unit, scale, [], {})
    events = find_steps(cmd.t, cmd.v, thr, merge_s=opts.merge, min_hold_s=opts.min_hold,
                        t_stop=float(rep.t[-1]))
    vel = data['vel']
    for ev in events:
        if channel == 'brake':
            if ev.u1 > -thr or ev.u1 > ev.u0:
                ev.status = 'skip'        # only steps into a deceleration
                continue
            # After the stop dv/dt is 0 whatever the command: end the window there.
            if len(vel):
                after = (vel.t > ev.t0 + 0.2) & (vel.t < ev.t_end) & (np.abs(vel.v) < 0.05)
                if after.any():
                    ev.t_end = float(vel.t[after][0])
        if ev.ok and not _in_auto(data['auto'], ev.t0 - 0.5, ev.t_end):
            ev.status = 'VCU not in AUTO throughout'
        if ev.ok and channel == 'steer_yaw':
            m = (rep.t >= ev.t0 - 0.5) & (rep.t < ev.t_end)
            if m.sum() == 0 or np.isnan(rep.v[m]).mean() > 0.2:
                ev.status = f'not moving (v < {opts.v_min} m/s)'
        prepare(ev, cmd.t, cmd.v, rep.t, rep.v, pre_s=0.5 if channel != 'brake' else 0.3,
                settle_frac=0.25 if channel != 'brake' else 0.4,
                settle_tol=opts.settle_tol if channel != 'brake' else 10.0)
        if channel == 'brake':
            brake_metrics(ev, vel, rep)
            if ev.status.startswith(('no response', 'report moved')):
                ev.status = 'achieved < 20 % of the request (coasting?)'
        if channel == 'steer_yaw' and ev.status == 'report moved the wrong way':
            ev.status = 'yaw-derived angle moved the wrong way: try --imu-sign -1'
    events = [e for e in events if e.status != 'skip']
    groups: dict[str, list[Event]] = {'': events}
    if channel in ('steer', 'steer_yaw'):
        # By side of centre, not by direction: 0 -> +5 and +5 -> 0 are both
        # left-side steps, read by the same (left) half of the report.
        groups['left'] = [e for e in events if e.u0 + e.u1 > 0]
        groups['right'] = [e for e in events if e.u0 + e.u1 < 0]
    elif channel == 'speed':
        groups['up'] = [e for e in events if e.u1 > e.u0]
        groups['down'] = [e for e in events if e.u1 < e.u0]
    pooled = {k: fit_events(v, fit_rate=fit_rate, series=True) for k, v in groups.items()}
    # Without a rate limit the two forms are the same model.
    pooled_par = ({k: fit_events(v, fit_rate=True, series=False) for k, v in groups.items()}
                  if fit_rate else dict(pooled))
    ch = Channel(channel, unit, scale, events, pooled, pooled_par)
    for ev in events:
        if ev.ok:
            ev.fit = fit_events([ev], fit_rate=fit_rate, series=ch.prefers_series())
    return ch


# ---------------------------------------------------------------- report

def _rate_str(f: Fit, scale: float) -> str:
    return f'{f.rate * scale:7.2f}' if f.rate_active else '   n/r '


def print_channel(ch: Channel, source: str, out=None) -> None:
    out = out or sys.stdout
    p = lambda *a: print(*a, file=out)  # noqa: E731
    p(f'\n== {ch.name}  [{source}]')
    if not ch.events:
        p('   no step events (no command changes, or a topic is missing)')
        return
    p(f'   per step, {"series" if ch.prefers_series() else "parallel"} form:')
    p(f'   {"#":>2} {"t[s]":>8}  {"command " + ch.unit:>19}  {"gain":>5}  {"delay":>6}  '
      f'{"tau":>6}  {"rate/s":>7}  {"rms":>6}  status')
    t_first = ch.events[0].t0
    for i, e in enumerate(ch.events, 1):
        cmd = f'{e.u0 * ch.scale:7.2f} ->{e.u1 * ch.scale:7.2f}'
        g = f'{e.gain:5.2f}' if math.isfinite(e.gain) else '    -'
        if e.fit:
            f = e.fit
            p(f'   {i:2d} {e.t0 - t_first:8.2f}  {cmd:>19}  {g}  {f.delay:6.3f}  {f.tau:6.3f}  '
              f'{_rate_str(f, ch.scale)}  {f.rms * ch.scale:6.3f}  ok')
        else:
            p(f'   {i:2d} {e.t0 - t_first:8.2f}  {cmd:>19}  {g}  {"":6}  {"":6}  {"":7}  {"":6}  '
              f'{e.status}')
    forms = [('series', ch.pooled)]
    if CHANNEL_DEFAULTS[ch.name][1]:
        forms.append(('parallel', ch.pooled_par))
    for form, pooled in forms:
        for k, f in pooled.items():
            label = f'{form} ' + (k or 'all')
            if f is None:
                p(f'   {label:15s} no accepted events')
                continue
            rate = (f'rate {f.rate * ch.scale:.2f} {ch.unit}/s' if f.rate_active
                    else 'rate limit not reached (n/r)')
            p(f'   {label:15s} n={f.n:2d}  delay {f.delay:.3f} s  tau {f.tau:.3f} s  {rate}  '
              f'rms {f.rms * ch.scale:.3f} {ch.unit}')
    s_all, p_all = ch.pooled.get(''), ch.pooled_par.get('')
    if len(forms) > 1 and s_all and p_all and s_all.rate_active:
        better = 'series' if s_all.rms <= p_all.rms else 'parallel'
        p(f'   the data prefer the {better} form (rms {s_all.rms * ch.scale:.3f} series, '
          f'{p_all.rms * ch.scale:.3f} parallel {ch.unit}): it feeds MPC and the PID; '
          'the simulator always takes the parallel fit')
    if ch.name == 'brake':
        seen = [e for e in ch.events if e.extra.get('v0', 0.0) >= 0.1]
        if seen:
            p('   brake, model-free (S3: the VCU brakes in stages at 1.2 / 1.8 / 2.8 m/s2, '
              'nothing below):')
            p('     request   from v   onset   mean decel   peak decel')
            for e in seen:
                x = e.extra
                f = lambda k, fmt: (fmt.format(x[k]) if k in x else '-')  # noqa: E731
                p(f'     {-e.u1:5.2f}     {x["v0"]:5.2f}   {f("onset", "{:5.2f}"):>5}   '
                  f'{f("mean", "{:6.2f}"):>10}   {f("peak", "{:6.2f}"):>10}   m/s, s, m/s2')


def _fmt(v: float) -> str:
    return f'{v:.3f}'


def paste_block(results: dict[str, Channel], out=None) -> None:
    """The Autoware parameter lines, from the bag channels (what the controller sees).

    MPC limits the rate of its own command and models the plant as delay + lag
    behind it: the series fit. simple_planning_simulator clips the lag's rate:
    the parallel fit. Each consumer gets the form it implements.
    """
    out = out or sys.stdout
    p = lambda *a: print(*a, file=out)  # noqa: E731
    steer, yaw = results.get('steer'), results.get('steer_yaw')
    speed, brake = results.get('speed'), results.get('brake')
    src = steer if steer and steer.pooled.get('') else (
        yaw if yaw and yaw.pooled.get('') else None)
    p('\n== paste (from the bag: command as Autoware publishes it -> report as Autoware reads it)')
    if src:
        sf, pf = src.preferred(''), src.pooled_par.get('') or src.pooled['']
        form = 'series' if src.prefers_series() else 'parallel'
        p(f'# steering, from {src.name}, n={sf.n}')
        p(f'# autoware_launch config/control/trajectory_follower/lateral/mpc.param.yaml ({form} fit)')
        p(f'input_delay: {_fmt(sf.delay)}               # stock {STOCK["input_delay"]}')
        p(f'vehicle_model_steer_tau: {_fmt(sf.tau)}   # stock {STOCK["vehicle_model_steer_tau"]}')
        if sf.rate_active:
            r = f'{math.degrees(sf.rate):.1f}'
            p(f'steer_rate_lim_dps_list_by_curvature: [{r}, {r}, {r}]   # stock [40.0, 50.0, 60.0]')
            p(f'steer_rate_lim_dps_list_by_velocity: [{r}, {r}, {r}]    # stock [60.0, 50.0, 40.0]')
        else:
            p('# steer_rate_lim_*: not identified, no step was large enough to hit the limit')
        p('# golfcart_vehicle_description config/simulator_model.param.yaml (parallel fit)')
        p(f'steer_time_delay: {_fmt(pf.delay)}           # stock {STOCK["steer_time_delay"]}')
        p(f'steer_time_constant: {_fmt(pf.tau)}        # stock {STOCK["steer_time_constant"]}')
        if pf.rate_active:
            p(f'steer_rate_lim: {pf.rate:.3f}             # rad/s, stock {STOCK["steer_rate_lim"]}')
        left, right = src.pooled.get('left'), src.pooled.get('right')
        if (left is None) != (right is None):
            side = 'left' if left is None else 'right'
            p(f'# NOTE: no accepted {side} steps in {src.name}; these numbers are one side only.')
    else:
        p('# steering: no accepted events')
    up = speed.pooled.get('up') if speed else None
    up_par = speed.pooled_par.get('up') if speed else None
    down_par = speed.pooled_par.get('down') if speed else None
    if up:
        # The PID has no rate model to absorb a ramp: give it the delay of the
        # form that fits the plant better.
        pid = speed.preferred('up')
        form = 'series' if speed.prefers_series('up') else 'parallel'
        p(f'# longitudinal, from rising speed steps, n={up.n}')
        p(f'# autoware_launch config/control/trajectory_follower/longitudinal/pid.param.yaml ({form} fit)')
        p(f'delay_compensation_time: {_fmt(pid.delay)}   # stock {STOCK["delay_compensation_time"]}')
        p('# simulator_model.param.yaml if vehicle_model_type: DELAY_STEER_VEL '
          '(the VCU runs speed mode; parallel fit)')
        p(f'vel_time_delay: {_fmt(up_par.delay)}            # stock {STOCK["vel_time_delay"]}')
        p(f'vel_time_constant: {_fmt(up_par.tau)}         # stock {STOCK["vel_time_constant"]}')
        if up_par.rate_active:
            p(f'vel_rate_lim: {up_par.rate:.3f}              # m/s2, stock {STOCK["vel_rate_lim"]}')
        if down_par and down_par.rate_active:
            p(f'# falling steps without brake slow at {down_par.rate:.3f} m/s2 '
              f'(delay {down_par.delay:.3f} s, tau {down_par.tau:.3f} s)')
    else:
        p('# longitudinal: no accepted rising speed steps')
    bf = brake.pooled.get('') if brake else None
    if bf:
        p(f'# braking, n={bf.n}: simulator_model.param.yaml for DELAY_STEER_ACC(_GEARED)')
        p(f'acc_time_delay: {_fmt(bf.delay)}            # stock {STOCK["acc_time_delay"]}')
        p(f'acc_time_constant: {_fmt(bf.tau)}         # stock {STOCK["acc_time_constant"]}')


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter,
                                 epilog=__doc__.split('\n\n', 1)[1])
    ap.add_argument('bag', nargs='?', help='rosbag2 directory')
    ap.add_argument('--can', help='candump -L log of the vehicle bus')
    ap.add_argument('--dbc', default=os.environ.get('CAX_ADS_DBC') or str(DEFAULT_DBC))
    ap.add_argument('--channels', default='steer,steer_yaw,speed,brake')
    ap.add_argument('--cmd-topic', default='/control/command/control_cmd')
    ap.add_argument('--steer-topic', default='/vehicle/status/steering_status')
    ap.add_argument('--vel-topic', default='/vehicle/status/velocity_status')
    ap.add_argument('--mode-topic', default='/vehicle/status/control_mode')
    ap.add_argument('--imu-topic', default='/sensing/camera/zed/imu/data',
                    help='yaw rate source for steer_yaw (default the ZED IMU, raw)')
    ap.add_argument('--imu-axis', default='z', choices=['x', 'y', 'z'])
    ap.add_argument('--imu-sign', type=float, default=1.0,
                    help='-1 if the IMU axis points down; check against a right step')
    ap.add_argument('--stamp', default='receive', choices=['receive', 'header'],
                    help="bag receive time (one clock, the recorder's) or message stamps")
    ap.add_argument('--wheelbase', type=float, default=wheelbase_from_vehicle_info())
    ap.add_argument('--v-min', type=float, default=0.25, help='steer_yaw: slowest usable speed')
    ap.add_argument('--merge', type=float, default=0.3, help='changes closer than this are one step [s]')
    ap.add_argument('--min-hold', type=float, default=1.0, help='shortest hold that counts as a step [s]')
    ap.add_argument('--settle-tol', type=float, default=0.1,
                    help='reject a step whose last two tail slices differ by more than this fraction')
    ap.add_argument('--no-paste', action='store_true')
    args = ap.parse_args(argv)
    if not args.bag and not args.can:
        ap.error('give a bag, --can LOG, or both')
    channels = [c.strip() for c in args.channels.split(',') if c.strip()]
    for c in channels:
        if c not in CHANNEL_DEFAULTS:
            ap.error(f'unknown channel {c}')

    bag_results: dict[str, Channel] = {}
    if args.bag:
        topics = {'cmd': args.cmd_topic, 'steer': args.steer_topic, 'vel': args.vel_topic,
                  'mode': args.mode_topic, 'imu': args.imu_topic}
        data = read_bag(args.bag, topics, stamp=args.stamp, imu_axis=args.imu_axis,
                        imu_sign=args.imu_sign)
        if data['_missing']:
            print(f'bag: topics not in the bag: {", ".join(data["_missing"])}')
        for c in channels:
            bag_results[c] = analyse(data, c, args)
            print_channel(bag_results[c], f'bag {args.stamp} time')
    if args.can:
        if not Path(args.dbc).is_file():
            print(f'no DBC at {args.dbc}: copy CAX_ADS_CAN.dbc to the vehicle interface crate '
                  'root or set CAX_ADS_DBC', file=sys.stderr)
            return 2
        data = read_candump(args.can, args.dbc)
        for c in channels:
            if c == 'steer_yaw':
                continue
            print_channel(analyse(data, c, args), 'CAN, interface TX -> VCU report')
    if bag_results and not args.no_paste:
        paste_block(bag_results)
    return 0


if __name__ == '__main__':
    sys.exit(main())
