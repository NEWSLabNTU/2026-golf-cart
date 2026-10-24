"""Tests for sysid_fit.py and sysid_steps.py (Phase 8, V4).

    python3 -m pytest scripts/testing/sysid/test_sysid_fit.py

Synthetic step responses with known delay, time constant and rate limit, clean
and noisy, through every channel; a candump log (needs the vendor DBC) and a
rosbag2 written with rosbag2_py (needs scripts/env.sh sourced) end to end.
Tests needing what is absent are skipped, not failed.
"""

import importlib.util
import io
import math
import os
import sys
from pathlib import Path
from types import SimpleNamespace

import numpy as np
import pytest

_HERE = Path(__file__).resolve().parent


def _load(name):
    spec = importlib.util.spec_from_file_location(name, _HERE / f'{name}.py')
    mod = importlib.util.module_from_spec(spec)
    sys.modules[name] = mod  # dataclasses look their module up here
    spec.loader.exec_module(mod)
    return mod


F = _load('sysid_fit')
S = _load('sysid_steps')

DEG = math.pi / 180


def staircase(levels, hold, t0=0.0, rate_hz=30.0):
    """A command published at rate_hz holding each level for `hold` seconds."""
    t = np.arange(t0, t0 + hold * len(levels), 1.0 / rate_hz)
    u = np.zeros_like(t)
    for i, lv in enumerate(levels):
        u[t >= t0 + i * hold] = lv
    return t, u


def plant(t_u, u, t_y, delay, tau, rate, y0=0.0, series=False):
    grid = np.arange(t_y[0], t_y[-1] + F.SIM_DT, F.SIM_DT)
    return np.interp(t_y, grid, F.simulate(grid, t_u, u, y0, delay, tau, rate, series))


def opts(**kw):
    o = dict(merge=0.3, min_hold=1.0, settle_tol=0.1, wheelbase=2.061, v_min=0.25)
    o.update(kw)
    return SimpleNamespace(**o)


def empty():
    return F.Series(np.zeros(0), np.zeros(0))


# ------------------------------------------------------------------ the model

def test_simulate_is_a_first_order_lag_with_dead_time():
    t = np.arange(0, 5, 0.01)
    y = F.step_response(t, 1.0, 0.0, 1.0, 0.0, delay=0.3, tau=0.5, rate=F.RATE_NONE)
    expect = np.where(t >= 1.3, 1 - np.exp(-(t - 1.3) / 0.5), 0.0)
    assert np.abs(y - expect).max() < 0.012   # one 5 ms grid step of slope 2/s


def test_simulate_rate_limit_is_a_ramp():
    t = np.arange(0, 6, 0.01)
    y = F.step_response(t, 0.0, 0.0, 0.5, 0.0, delay=0.0, tau=0.01, rate=0.13)
    m = (t > 0.5) & (t < 3.0)
    slope = np.polyfit(t[m], y[m], 1)[0]
    assert slope == pytest.approx(0.13, rel=0.01)
    assert y[-1] == pytest.approx(0.5, abs=1e-3)


# ------------------------------------------------------------------ the fit

def _fit_staircase(levels, hold, delay, tau, rate, noise=0.0, rate_hz=50.0, jitter=0.0, seed=0):
    rng = np.random.default_rng(seed)
    t_u, u = staircase(levels, hold)
    t_y = np.arange(0, t_u[-1], 1.0 / rate_hz)
    t_y = np.sort(t_y + rng.uniform(0, jitter, len(t_y)))
    y = plant(t_u, u, t_y, delay, tau, rate) + rng.normal(0, noise, len(t_y))
    evs = F.find_steps(t_u, u, 0.5 * DEG, t_stop=t_u[-1])
    for e in evs:
        F.prepare(e, t_u, u, t_y, y)
    return evs, F.fit_events(evs)


def test_recovers_delay_and_tau_from_small_clean_steps():
    evs, f = _fit_staircase([0, 2 * DEG, 0, -2 * DEG, 0, 4 * DEG, 0], 4.0,
                            delay=0.24, tau=0.27, rate=F.RATE_NONE)
    assert all(e.ok for e in evs) and f.n == 6
    assert f.delay == pytest.approx(0.24, abs=0.01)
    assert f.tau == pytest.approx(0.27, rel=0.05)
    assert not f.rate_active      # small steps never hit a limit: not identified


def test_recovers_rate_limit_from_large_steps():
    # The cart: ~7.5 deg/s at the wheels, steps up to 20 deg.
    evs, f = _fit_staircase([0, 2 * DEG, 0, 10 * DEG, 0, -20 * DEG, 0], 6.0,
                            delay=0.3, tau=0.4, rate=7.5 * DEG)
    assert f.rate_active
    assert math.degrees(f.rate) == pytest.approx(7.5, rel=0.03)
    assert f.delay == pytest.approx(0.3, abs=0.02)
    assert f.tau == pytest.approx(0.4, rel=0.1)


def test_series_form_recovers_a_slewed_command_behind_a_lag():
    """MPC's form: rate limit on the command, then delay and lag (the interface's slew)."""
    t_u, u = staircase([0, 2 * DEG, 0, 10 * DEG, 0, -20 * DEG, 0], 6.0)
    t_y = np.arange(0, t_u[-1], 0.02)
    y = plant(t_u, u, t_y, 0.05, 0.2, math.radians(22.9), series=True)
    evs = F.find_steps(t_u, u, 0.5 * DEG, t_stop=t_u[-1])
    for e in evs:
        F.prepare(e, t_u, u, t_y, y)
    s, p = F.fit_events(evs, series=True), F.fit_events(evs, series=False)
    assert s.rate_active and math.degrees(s.rate) == pytest.approx(22.9, rel=0.02)
    assert s.delay == pytest.approx(0.05, abs=0.01) and s.tau == pytest.approx(0.2, rel=0.05)
    assert s.rms < 0.5 * p.rms       # the parallel form cannot match it as well


def test_a_rate_that_buys_nothing_is_dropped():
    """A tiny fast ramp only shifts timing: no rate limit should be reported."""
    t_u, u = staircase([0, 0.5, 1.0, 0.5, 0], 5.0)
    t_y = np.arange(0, t_u[-1], 0.02)
    y = plant(t_u, u, t_y, 0.01, 0.5, F.RATE_NONE)
    evs = F.find_steps(t_u, u, 0.1, t_stop=t_u[-1])
    for e in evs:
        F.prepare(e, t_u, u, t_y, y)
    for series in (True, False):
        f = F.fit_events(evs, series=series)
        assert not f.rate_active and f.tau == pytest.approx(0.5, rel=0.03)


def test_recovers_parameters_through_noise_and_jitter():
    # 0.1 deg report noise, 50 Hz with up to 10 ms of arrival jitter.
    evs, f = _fit_staircase([0, 3 * DEG, 0, -3 * DEG, 0, 12 * DEG, 0, -12 * DEG, 0], 6.0,
                            delay=0.25, tau=0.35, rate=8.0 * DEG,
                            noise=0.1 * DEG, jitter=0.01, seed=3)
    assert sum(e.ok for e in evs) == 8
    assert f.delay == pytest.approx(0.255, abs=0.03)   # jitter adds ~5 ms on average
    assert f.tau == pytest.approx(0.35, rel=0.15)
    assert math.degrees(f.rate) == pytest.approx(8.0, rel=0.05)
    assert math.degrees(f.rms) == pytest.approx(0.1, rel=0.2)


def test_flat_report_is_rejected_not_fitted():
    """The VCU's left report reads 0: a left step must say so, not fit garbage."""
    t_u, u = staircase([0, 5 * DEG, 0], 4.0)
    t_y = np.arange(0, t_u[-1], 0.02)
    y = np.zeros_like(t_y)
    evs = F.find_steps(t_u, u, 0.5 * DEG, t_stop=t_u[-1])
    for e in evs:
        F.prepare(e, t_u, u, t_y, y)
    assert [e.status for e in evs] == ['no response: report flat'] * 2
    assert F.fit_events(evs) is None


def test_unsettled_step_is_rejected():
    evs, _ = _fit_staircase([0, 20 * DEG, 0], 2.0, delay=0.3, tau=0.4, rate=7.5 * DEG)
    assert evs[0].status.startswith('not settled')


def test_short_holds_are_not_steps():
    t_u, u = staircase([0, DEG, 2 * DEG, 3 * DEG], 0.7)   # keyboard repeats
    evs = F.find_steps(t_u, u, 0.5 * DEG, t_stop=t_u[-1] + 0.7)
    assert evs[0].status.startswith('hold') and evs[-1].ok


def test_a_slewed_ramp_is_one_event_and_fits_through_the_ramp():
    """On CAN the interface's 0.4 rad/s slew turns a step into a ramp of tiny steps."""
    t_u = np.arange(0, 12, 0.01)                       # 100 Hz TX
    u = np.clip((t_u - 1.0) * 0.4, 0, 0.2)             # ramp to 0.2 rad, held
    u[t_u >= 6] = np.clip(0.2 - (t_u[t_u >= 6] - 6) * 0.4, 0, 0.2)
    t_y = np.arange(0, 12, 0.02)
    y = plant(t_u, u, t_y, delay=0.05, tau=0.2, rate=F.RATE_NONE)
    evs = F.find_steps(t_u, u, 0.5 * DEG, t_stop=12)
    assert len(evs) == 2 and evs[0].u1 == pytest.approx(0.2)
    for e in evs:
        F.prepare(e, t_u, u, t_y, y)
    f = F.fit_events(evs)
    assert f.tau == pytest.approx(0.2, rel=0.05)
    assert f.delay == pytest.approx(0.05, abs=0.01)
    assert not f.rate_active   # the input ramp, not a limit, sets the slope


def test_gain_and_offset_do_not_bend_the_dynamics():
    """A report that saturates (right stop) or carries an offset still fits."""
    t_u, u = staircase([0, -10 * DEG, 0], 6.0)
    t_y = np.arange(0, t_u[-1], 0.02)
    y = 0.8 * plant(t_u, u, t_y, 0.2, 0.3, F.RATE_NONE) + 0.01
    evs = F.find_steps(t_u, u, 0.5 * DEG, t_stop=t_u[-1])
    for e in evs:
        F.prepare(e, t_u, u, t_y, y)
    assert evs[0].gain == pytest.approx(0.8, rel=0.01)
    f = F.fit_events(evs)
    assert f.delay == pytest.approx(0.2, abs=0.01) and f.tau == pytest.approx(0.3, rel=0.05)


# ------------------------------------------------------------------ channels

def _data(**kw):
    d = {k: empty() for k in ('cmd_steer', 'cmd_vel', 'cmd_acc', 'steer', 'vel', 'imu_w', 'auto')}
    d.update(kw)
    return d


def test_speed_channel_splits_up_and_down():
    t_u, v_cmd = staircase([0, 0.5, 1.0, 0.5, 0.0], 6.0)
    t_y = np.arange(0, t_u[-1], 0.02)
    # Up: 0.4 m/s2 limited, tau 0.5, delay 0.3. Down (from 18 s): unbraked, 0.25 m/s2.
    y = plant(t_u, v_cmd, t_y, 0.3, 0.5, 0.4)
    i = np.searchsorted(t_y, 18.0)
    k = t_u >= 17.0
    y[i:] = plant(t_u[k], v_cmd[k], t_y[i:], 0.3, 0.5, 0.25, y0=y[i])
    data = _data(cmd_vel=F.Series(t_u, v_cmd), vel=F.Series(t_y, y))
    ch = F.analyse(data, 'speed', opts())
    # Generated in the simulator's (parallel) form, so read the parallel fit.
    assert ch.pooled_par['up'].rate == pytest.approx(0.4, rel=0.05)
    assert ch.pooled_par['down'].rate == pytest.approx(0.25, rel=0.05)
    assert ch.pooled_par['up'].delay == pytest.approx(0.3, abs=0.03)


def test_brake_channel_measures_achieved_deceleration():
    # 1 m/s, then -2.0 requested; the VCU's stage gives 1.4 after 0.2 s, tau 0.15.
    t_u = np.arange(0, 6, 1 / 30)
    acc = np.where(t_u >= 2.0, -2.0, 0.0)
    t_y = np.arange(0, 6, 0.02)
    grid = np.arange(0, 6, F.SIM_DT)
    a = F.simulate(grid, t_u, 0.7 * acc, 0.0, 0.2, 0.15, F.RATE_NONE)
    v = np.maximum(1.0 + np.cumsum(a) * F.SIM_DT, 0.0)
    data = _data(cmd_acc=F.Series(t_u, acc), vel=F.Series(t_y, np.interp(t_y, grid, v)))
    ch = F.analyse(data, 'brake', opts())
    (ev,) = ch.events
    assert ev.ok, ev.status
    assert -(ev.y1 - ev.y0) == pytest.approx(1.4, rel=0.1)
    assert ev.fit.delay == pytest.approx(0.2, abs=0.06)


def test_yaw_channel_sees_left_steps_the_report_cannot():
    """Left report flat, yaw rate alive: steer rejects left, steer_yaw fits it."""
    v, wb = 0.5, 2.061
    t_u, cmd = staircase([0, 4 * DEG, 0, -4 * DEG, 0], 4.0, t0=2.0)
    t_u = np.concatenate(([0.0], t_u))
    cmd = np.concatenate(([0.0], cmd))
    t_imu = np.arange(0, t_u[-1], 0.01)
    delta = plant(t_u, cmd, t_imu, 0.25, 0.3, F.RATE_NONE)
    rng = np.random.default_rng(1)
    w = v * np.tan(delta) / wb + 0.002 + rng.normal(0, 0.002, len(t_imu))  # bias + noise
    t_rep = np.arange(0, t_u[-1], 0.02)
    rep = np.minimum(np.interp(t_rep, t_imu, delta), 0.0)    # left reads 0
    data = _data(cmd_steer=F.Series(t_u, cmd), steer=F.Series(t_rep, rep),
                 imu_w=F.Series(t_imu, w), vel=F.Series(t_rep, np.full(len(t_rep), v)))
    steer = F.analyse(data, 'steer', opts())
    yaw = F.analyse(data, 'steer_yaw', opts())
    assert [e.status for e in steer.events][0] == 'no response: report flat'
    assert steer.pooled['left'] is None and steer.pooled['right'] is not None
    assert all(e.ok for e in yaw.events)
    assert yaw.pooled['left'].delay == pytest.approx(0.25, abs=0.06)   # 0.1 s smoothing
    assert yaw.pooled['left'].tau == pytest.approx(0.3, rel=0.3)


def test_steps_outside_auto_are_rejected():
    t_u, u = staircase([0, 5 * DEG, 0], 4.0)
    t_y = np.arange(0, t_u[-1], 0.02)
    auto = F.Series(np.array([0.0, 5.0]), np.array([1.0, 0.0]))   # driver left AUTO at 5 s
    data = _data(cmd_steer=F.Series(t_u, u), steer=F.Series(t_y, plant(t_u, u, t_y, .2, .3, 9)),
                 auto=auto)
    ch = F.analyse(data, 'steer', opts())
    assert [e.status for e in ch.events] == ['VCU not in AUTO throughout'] * 2


def test_paste_block_names_the_autoware_parameters():
    evs, f = _fit_staircase([0, 2 * DEG, 0, 15 * DEG, 0], 6.0,
                            delay=0.3, tau=0.4, rate=7.5 * DEG)
    ch = F.Channel('steer', 'deg', 1 / DEG, evs, {'': f, 'left': f, 'right': None})
    buf = io.StringIO()
    F.paste_block({'steer': ch}, out=buf)
    text = buf.getvalue()
    for key in ('input_delay:', 'vehicle_model_steer_tau:', 'steer_rate_lim_dps_list_by_curvature:',
                'steer_time_delay:', 'steer_time_constant:', 'steer_rate_lim:'):
        assert key in text
    assert 'no accepted right steps' in text


# ------------------------------------------------------------------ candump

DBC = Path(os.environ.get('CAX_ADS_DBC') or F.DEFAULT_DBC)


@pytest.mark.skipif(not DBC.is_file(), reason='vendor DBC not on this machine')
def test_candump_log_end_to_end(tmp_path, capsys):
    cantools = pytest.importorskip('cantools')
    db = cantools.database.load_file(str(DBC))
    eps_tx, eps_rx = db.get_message_by_frame_id(0x065), db.get_message_by_frame_id(0x102)
    veh_rx = db.get_message_by_frame_id(0x103)
    # Vendor sign: positive = right. Autoware right step of 10 deg = vendor +10.
    t_tx = np.arange(0, 16, 0.01)
    tgt = np.where((t_tx >= 2) & (t_tx < 9), 10.0, 0.0)
    t_rx = np.arange(0, 16, 0.02)
    rep = plant(t_tx, tgt, t_rx, 0.12, 0.3, 7.5)

    def frame(t, msg, **sig):
        full = {s.name: 0 for s in msg.signals}
        full.update(sig)
        data = msg.encode(full, strict=False)
        return t, f'({t:.6f}) can0 {msg.frame_id:03X}#{data.hex().upper()}\n'

    lines = [frame(t, eps_tx, Ads_Vcu_Target_Tire_Angle=a) for t, a in zip(t_tx, tgt)]
    lines += [frame(t, eps_rx, Vcu_Ads_Tire_Angle=a) for t, a in zip(t_rx, rep)]
    lines += [frame(t, veh_rx, Vcu_Ads_Driving_State=2) for t in t_rx]
    log = tmp_path / 'can.log'
    log.write_text(''.join(line for _, line in sorted(lines)))
    assert F.main(['--can', str(log), '--dbc', str(DBC), '--channels', 'steer']) == 0
    out = capsys.readouterr().out
    pooled = next(line for line in out.splitlines() if 'parallel all' in line)
    delay = float(pooled.split('delay')[1].split()[0])
    rate = float(pooled.split('rate')[1].split()[0])
    assert delay == pytest.approx(0.12, abs=0.01) and rate == pytest.approx(7.5, rel=0.02)
    # Vendor +10 deg is a RIGHT step in Autoware's sign.
    assert ' -10.00' in out


# ------------------------------------------------------------------ rosbag2

def test_rosbag_end_to_end(tmp_path, capsys):
    rosbag2_py = pytest.importorskip('rosbag2_py')
    ser = pytest.importorskip('rclpy.serialization')
    from autoware_control_msgs.msg import Control
    from autoware_vehicle_msgs.msg import ControlModeReport, SteeringReport, VelocityReport

    bag = tmp_path / 'sysid'
    w = rosbag2_py.SequentialWriter()
    w.open(rosbag2_py.StorageOptions(uri=str(bag), storage_id='sqlite3'),
           rosbag2_py.ConverterOptions('cdr', 'cdr'))
    topics = {'/control/command/control_cmd': 'autoware_control_msgs/msg/Control',
              '/vehicle/status/steering_status': 'autoware_vehicle_msgs/msg/SteeringReport',
              '/vehicle/status/velocity_status': 'autoware_vehicle_msgs/msg/VelocityReport',
              '/vehicle/status/control_mode': 'autoware_vehicle_msgs/msg/ControlModeReport'}
    for name, typ in topics.items():
        w.create_topic(rosbag2_py.TopicMetadata(name=name, type=typ, serialization_format='cdr'))

    T0 = 1_792_658_480.0
    # Steering: right steps the report sees (2, 15 deg), one left step it does not.
    t_s, steer = staircase([0, -2 * DEG, 0, -15 * DEG, 0, 6 * DEG, 0], 6.0)
    t_v, vel = staircase([0] * 7, 6.0)
    t_v2, vel2 = staircase([0, 0.5, 1.0, 0.5, 0.0], 6.0, t0=t_s[-1] + 1 / 30)
    t_c = np.concatenate((t_s, t_v2))
    c_steer = np.concatenate((steer, np.zeros_like(t_v2)))
    c_vel = np.concatenate((vel, vel2))
    t_r = np.arange(0, t_c[-1], 0.02)
    r_steer = plant(t_c, c_steer, t_r, 0.28, 0.35, 7.5 * DEG, series=True)   # MPC's form
    r_steer = np.minimum(r_steer, 0.0)                 # left report dead
    r_vel = plant(t_c, c_vel, t_r, 0.35, 0.5, 0.4)
    msgs = []
    for t, s, v in zip(t_c, c_steer, c_vel):
        m = Control()
        m.lateral.steering_tire_angle = float(s)
        m.longitudinal.velocity = float(v)
        msgs.append((t, '/control/command/control_cmd', m))
    for t, s, v in zip(t_r, r_steer, r_vel):
        msgs.append((t, '/vehicle/status/steering_status', SteeringReport(steering_tire_angle=float(s))))
        vr = VelocityReport()
        vr.longitudinal_velocity = float(v)
        msgs.append((t, '/vehicle/status/velocity_status', vr))
        msgs.append((t, '/vehicle/status/control_mode', ControlModeReport(mode=1)))
    for t, topic, m in sorted(msgs, key=lambda x: x[0]):
        w.write(topic, ser.serialize_message(m), int((T0 + t) * 1e9))
    del w

    assert F.main([str(bag), '--channels', 'steer,speed']) == 0
    out = capsys.readouterr().out
    assert 'no response: report flat' in out             # the left step
    assert 'no accepted left steps' in out

    def val(key):
        line = next(x for x in out.splitlines() if x.startswith(key + ':'))
        return float(line.split(':')[1].split('#')[0].strip().strip('[').split(',')[0])
    assert val('input_delay') == pytest.approx(0.28, abs=0.02)
    assert val('vehicle_model_steer_tau') == pytest.approx(0.35, rel=0.1)
    assert val('steer_rate_lim_dps_list_by_curvature') == pytest.approx(7.5, rel=0.05)
    assert val('delay_compensation_time') == pytest.approx(0.35, abs=0.02)  # the better form's
    assert val('vel_time_delay') == pytest.approx(0.35, abs=0.02)
    assert val('vel_time_constant') == pytest.approx(0.5, rel=0.05)
    assert val('vel_rate_lim') == pytest.approx(0.4, rel=0.05)
    assert 'the data prefer the series form' in out         # steering was generated series


# ------------------------------------------------------------------ sysid_steps

def test_profiles_fit_the_basement_lane_and_respect_the_right_stop():
    for name in S.PROFILES:
        segs = S.build_profile(name)
        assert S.distance(segs, 0.5) < 17.8, name    # the Ming-Da lane
        assert min(s.steer_deg for s in segs) >= -20.0
        assert max(abs(s.speed) for s in segs) <= 1.5   # the interface's first-run cap


def test_brake_profile_requests_each_level_with_speed_zero():
    segs = S.build_profile('brake', levels=[1.5, 3.0])
    brakes = [s for s in segs if s.label.startswith('brake')]
    assert [(s.accel, s.speed, s.accel_dur) for s in brakes] == [(-1.5, 0.0, 4.0), (-3.0, 0.0, 4.0)]
    steer, v, a = S.command_at(segs, brakes[0].t + 0.1)
    assert (v, a) == (0.0, -1.5)


def test_rising_speed_steps_carry_a_bounded_acceleration():
    segs = S.build_profile('speed', levels=[0.5, 1.0, 0.0], accel=0.5)
    s05 = next(s for s in segs if s.label == 'speed 0.5')
    assert s05.at(0.5)[2] == 0.5 and s05.at(1.5)[2] == 0.0       # 0.5 m/s at 0.5 m/s2: 1 s
    s0 = next(s for s in segs if s.label == 'speed 0')
    assert s0.at(0.1)[2] == 0.0                                   # falling: no brake


def test_standstill_holds_cover_the_slew():
    segs = S.build_profile('steer-standstill', amps=[20.0])
    left = next(s for s in segs if s.label == 'left 20')
    assert left.dur >= 20.0 / S.EXPECTED_STEER_DPS + 2.0
    assert S.command_at(segs, left.t + 0.01)[0] == pytest.approx(math.radians(20.0))
