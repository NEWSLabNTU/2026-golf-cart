#!/usr/bin/env python3
"""Summarize a creep bag: does the speed chain agree with how far the cart moved?

    python3 scripts/testing/mingda/creep_report.py BAG
    just tool creep-report BAG

Reads a bag from creep_record.sh. Topics are found by message type, not name,
so it works whichever pose estimator (ndt or cuda_ndt) was running:

  speed sources   VelocityReport and TwistWithCovarianceStamped topics:
                  min / max longitudinal speed, and the distance it integrates to
  pose sources    Odometry, PoseWithCovarianceStamped and PoseStamped topics:
                  first and last position, net displacement, path length, and
                  the largest jump between two consecutive messages, with when
  scores          Float32Stamped topics (NDT likelihoods): min / median / last

Then a 0.5 s timeline of the main series, and the verdicts that matter for
the handover's open item 2: does the integrated VCU speed match the board's
displacement (scale and sign), and when does NDT part from the board.

Paste the whole output back.
"""

from __future__ import annotations

import argparse
import bisect
import math
import statistics
import sys

SPEED_TYPES = ('autoware_vehicle_msgs/msg/VelocityReport',
               'geometry_msgs/msg/TwistWithCovarianceStamped',
               'geometry_msgs/msg/TwistStamped')
POSE_TYPES = ('nav_msgs/msg/Odometry',
              'geometry_msgs/msg/PoseWithCovarianceStamped',
              'geometry_msgs/msg/PoseStamped')
SCORE_TYPES = ('autoware_internal_debug_msgs/msg/Float32Stamped',
               'tier4_debug_msgs/msg/Float32Stamped')


def stamp_of(msg, fallback):
    header = getattr(msg, 'header', None)
    if header is not None and (header.stamp.sec or header.stamp.nanosec):
        return header.stamp.sec + header.stamp.nanosec * 1e-9
    return fallback


def speed_of(msg):
    if hasattr(msg, 'longitudinal_velocity'):
        return float(msg.longitudinal_velocity)
    twist = msg.twist.twist if hasattr(msg.twist, 'twist') else msg.twist
    return float(twist.linear.x)


def pose_of(msg):
    if hasattr(msg, 'pose') and hasattr(msg.pose, 'pose'):
        p = msg.pose.pose
    else:
        p = msg.pose
    q = p.orientation
    yaw = math.atan2(2 * (q.w * q.z + q.x * q.y), 1 - 2 * (q.y * q.y + q.z * q.z))
    return p.position.x, p.position.y, yaw


def read(bag):
    import rosbag2_py
    from rclpy.serialization import deserialize_message
    from rosidl_runtime_py.utilities import get_message

    reader = rosbag2_py.SequentialReader()
    reader.open(rosbag2_py.StorageOptions(uri=bag, storage_id=''),
                rosbag2_py.ConverterOptions('cdr', 'cdr'))
    types = {t.name: t.type for t in reader.get_all_topics_and_types()}
    wanted = {name: kind for name, kind in types.items()
              if kind in SPEED_TYPES + POSE_TYPES + SCORE_TYPES}
    classes = {name: get_message(kind) for name, kind in wanted.items()}
    series = {name: [] for name in wanted}
    counts = {name: 0 for name in types}
    while reader.has_next():
        name, data, t_ns = reader.read_next()
        counts[name] = counts.get(name, 0) + 1
        if name not in wanted:
            continue
        msg = deserialize_message(data, classes[name])
        t = stamp_of(msg, t_ns * 1e-9)
        kind = wanted[name]
        if kind in SPEED_TYPES:
            series[name].append((t, speed_of(msg)))
        elif kind in POSE_TYPES:
            series[name].append((t, pose_of(msg)))
        else:
            series[name].append((t, float(msg.data)))
    return types, wanted, series, counts


def integrate(samples):
    distance = 0.0
    for (t0, v0), (t1, v1) in zip(samples, samples[1:]):
        dt = t1 - t0
        if 0.0 < dt < 1.0:  # a gap longer than a second is a dropout, not motion
            distance += 0.5 * (v0 + v1) * dt
    return distance


def pose_stats(samples):
    xs = [(t, p) for t, p in samples]
    path = 0.0
    jump, jump_t = 0.0, None
    for (t0, a), (t1, b) in zip(xs, xs[1:]):
        step = math.hypot(b[0] - a[0], b[1] - a[1])
        path += step
        if step > jump:
            jump, jump_t = step, t1
    first, last = xs[0][1], xs[-1][1]
    net = math.hypot(last[0] - first[0], last[1] - first[1])
    return first, last, net, path, jump, jump_t


def at(samples, t):
    """The sample nearest in time to t, or None if none within 0.5 s."""
    if not samples:
        return None
    times = [s[0] for s in samples]
    i = bisect.bisect_left(times, t)
    best = min((j for j in (i - 1, i) if 0 <= j < len(samples)),
               key=lambda j: abs(times[j] - t))
    return samples[best][1] if abs(times[best] - t) <= 0.5 else None


def pick(names, *needles):
    for needle in needles:
        for name in names:
            if needle in name:
                return name
    return None


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    ap.add_argument('bag')
    ap.add_argument('--step', type=float, default=0.5, help='timeline step, s')
    args = ap.parse_args(argv)

    types, wanted, series, counts = read(args.bag)
    t0 = min((s[0][0] for s in series.values() if s), default=0.0)
    rel = lambda t: t - t0  # noqa: E731

    print(f'bag {args.bag}: {len(types)} topics')
    for name in sorted(types):
        print(f'  {counts.get(name, 0):6d}  {name}  [{types[name].split("/")[-1]}]')

    print('\nspeed sources (+ is forward):')
    speeds = {n: s for n, s in series.items() if wanted[n] in SPEED_TYPES and s}
    for name, s in sorted(speeds.items()):
        v = [x for _, x in s]
        print(f'  {name}\n      {len(s)} msgs, min {min(v):+.3f} max {max(v):+.3f} m/s, '
              f'integrates to {integrate(s):+.3f} m')

    print('\npose sources:')
    poses = {n: s for n, s in series.items() if wanted[n] in POSE_TYPES and s}
    for name, s in sorted(poses.items()):
        first, last, net, path, jump, jump_t = pose_stats(s)
        print(f'  {name}\n      {len(s)} msgs, ({first[0]:.2f}, {first[1]:.2f}, '
              f'{math.degrees(first[2]):.1f}) -> ({last[0]:.2f}, {last[1]:.2f}, '
              f'{math.degrees(last[2]):.1f}); net {net:.2f} m, path {path:.2f} m, '
              f'largest jump {jump:.2f} m at t={rel(jump_t) if jump_t else 0:.1f} s')

    print('\nscores:')
    scores = {n: s for n, s in series.items() if wanted[n] in SCORE_TYPES and s}
    for name, s in sorted(scores.items()):
        v = [x for _, x in s]
        print(f'  {name}: {len(v)} msgs, min {min(v):.3f} median {statistics.median(v):.3f} '
              f'last {v[-1]:.3f}')

    names = list(series)
    vcu = pick([n for n in speeds], '/vehicle/status/velocity_status')
    conv = pick([n for n in speeds], 'vehicle_velocity_converter')
    gyro = pick([n for n in speeds], 'twist_estimator')
    ekf = pick([n for n in poses], '/localization/kinematic_state', 'pose_twist_fusion_filter')
    ndt = pick([n for n in poses], 'pose_estimator/pose_with_covariance', 'pose_estimator')
    board = pick([n for n in poses], 'board_pose')
    nvtl = pick([n for n in scores], 'nearest_voxel_transformation_likelihood')
    del names

    print('\ntimeline (t s | vcu m/s | conv | gyro_odom | ekf x,y | ndt x,y | board x,y | nvtl):')
    t_end = max((s[-1][0] for s in series.values() if s), default=t0)
    t = t0
    fmt_xy = lambda p: f'{p[0]:7.2f},{p[1]:6.2f}' if p else '      -,     -'  # noqa: E731
    fmt_v = lambda v: f'{v:+.2f}' if v is not None else '   - '  # noqa: E731
    while t <= t_end:
        row = [f'{rel(t):5.1f}',
               fmt_v(at(series.get(vcu, []), t)), fmt_v(at(series.get(conv, []), t)),
               fmt_v(at(series.get(gyro, []), t)),
               fmt_xy(at(series.get(ekf, []), t)), fmt_xy(at(series.get(ndt, []), t)),
               fmt_xy(at(series.get(board, []), t))]
        score = at(series.get(nvtl, []), t)
        row.append(f'{score:.2f}' if score is not None else '-')
        print('  ' + ' | '.join(row))
        t += args.step

    print('\nverdicts:')
    if vcu and board and len(series[board]) >= 2:
        moved = pose_stats(series[board])[2]
        driven = integrate(series[vcu])
        if moved < 0.2:
            print(f'  board moved only {moved:.2f} m: too little to judge the speed scale')
        else:
            print(f'  VCU integrates to {driven:+.2f} m, board moved {moved:.2f} m: '
                  f'ratio {driven / moved:+.2f} (1.00 is right; negative is a sign flip)')
    else:
        print('  VCU vs board: missing one of them '
              f'(vcu {vcu or "none"}, board {board or "none"}); board_pose only '
              'publishes while the board is in view and a batch passes')
    if ndt and board:
        parted = None
        for tt, p in series[ndt]:
            b = at(series[board], tt)
            if b is not None and math.hypot(p[0] - b[0], p[1] - b[1]) > 1.0:
                parted = tt
                break
        print(f'  NDT vs board: ' + (f'first > 1 m apart at t={rel(parted):.1f} s'
                                     if parted else 'never more than 1 m apart'))
    if ekf and ndt:
        e = pose_stats(series[ekf])
        n = pose_stats(series[ndt])
        print(f'  largest single jump: EKF {e[4]:.2f} m at t={rel(e[5]) if e[5] else 0:.1f} s, '
              f'NDT {n[4]:.2f} m at t={rel(n[5]) if n[5] else 0:.1f} s')
    return 0


if __name__ == '__main__':
    sys.exit(main())
