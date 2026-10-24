#!/usr/bin/env python3
"""Fit a closed lane into the free corridor of an obstacle grid: centre and width.

    python3 scripts/map/fit_lane_corridor.py centre GRID.npz SEED.yaml OUT.yaml
    python3 scripts/map/fit_lane_corridor.py refine GRID.npz ROUTE.yaml FIT.yaml OUT.yaml

Phase 8, M7. GRID.npz is obstacle_grid.py's output; routes are
centerline_to_lanelet.py's input format, closed (first point repeated last),
in the direction of travel. OUT.yaml is {x, y, width} per point, ready for the
builder; --header-from copies a route file's comment block on top, so a refit
can be diffed against the committed file.

**centre** puts a lane on a rough line, such as a driven path. Each point moves
along its normal to equalise the two edges' clearance (rays capped at
--reach), weighted by 1 / span^4 so a narrow gap holds its neighbours, averaged
over --window, --passes times; then the line is relaxed wherever the radius
over 1 m chords is under --min-radius. Width is min(--width, free span - 2 *
--margin) over a --window running minimum, floored at --min-width. This made
the 2026-10-22 Ming-Da loop.

**refine** moves an existing lane only as far as it must, on the stretches
FIT.yaml names, and leaves the rest alone. The variables are the lateral
offsets of the points along their normals; the objective is the squared second
differences of the moved points (a curvature proxy, so bends spread out) plus
a small pull toward the input; the bounds keep both lane edges a margin off
every obstacle cell. Bounded linear least squares (scipy's lsq_linear), the
curvature rows reweighted until no radius over consecutive points is under
`min_radius`. A stretch is re-solved from its own result `passes` times. This
made the 2026-10-23 one; data/mingda-basement/loop_fit.yaml is its FIT.yaml
and says what each key does.

Free space is measured along each normal in a strip `strip` either side along
the path, not a single ray: points are 0.5 m apart and a ray each slips
between them past a thin row of cells (a duct at 2.11 m did).

The cart's body (rear and front of base_link, half width) comes from
vehicle_info.param.yaml, as the builder reads it. --slow-below tags the
narrow stretch with a speed limit, as the builder takes it.

Every pass starts from the precision the file is written in (x, y to the
millimetre, width floored to the centimetre), because that is how the
committed lane was made and a refit must reproduce it exactly.
"""

from __future__ import annotations

import argparse
import math
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import centerline_to_lanelet as c2l  # noqa: E402
from obstacle_grid import in_box, load_grid  # noqa: E402


# ---------------------------------------------------------------- geometry


def free_space(grid: dict, p: np.ndarray, n: np.ndarray, reach: float, step: float,
               strip: float = 0.0, strip_step: float = 0.05) -> np.ndarray:
    """Distance from each point along its normal to the first obstacle cell, capped at reach.

    With `strip` > 0 the ray is a strip that wide either side along the path;
    any cell in a row of it stops it."""
    occ, x0, y0, c = grid['occ'], grid['x0'], grid['y0'], grid['cell']
    rs = np.arange(0.0, reach + 1e-9, step)
    ts = np.arange(-strip, strip + 1e-9, strip_step) if strip > 0 else np.array([0.0])
    out = np.full(len(p), reach)
    for i, (pt, nn) in enumerate(zip(p, n)):
        tt = np.array([nn[1], -nn[0]])
        r = pt[None, None, :] + rs[:, None, None] * nn + ts[None, :, None] * tt
        ix = np.floor((r[..., 0] - x0) / c).astype(int)
        iy = np.floor((r[..., 1] - y0) / c).astype(int)
        ok = (ix >= 0) & (ix < occ.shape[0]) & (iy >= 0) & (iy < occ.shape[1])
        h = np.zeros(ix.shape, bool)
        h[ok] = occ[ix[ok], iy[ok]]
        h = h.any(axis=1)
        if h.any():
            out[i] = rs[np.argmax(h)]
    return out


def ring_normals(ring: np.ndarray) -> np.ndarray:
    """Left normals of a closed ring (no repeated point), central differences."""
    t = np.roll(ring, -1, 0) - np.roll(ring, 1, 0)
    t /= np.linalg.norm(t, axis=1, keepdims=True)
    return np.stack([-t[:, 1], t[:, 0]], 1)


def ring_radii(ring: np.ndarray, span: int = 1) -> np.ndarray:
    """Circumradius at each point of a ring through its neighbours `span` away."""
    a, b, c = np.roll(ring, span, 0), ring, np.roll(ring, -span, 0)
    ab, bc, ca = (np.linalg.norm(u, axis=1) for u in (b - a, c - b, a - c))
    cr = np.abs((b[:, 0] - a[:, 0]) * (c[:, 1] - a[:, 1]) - (b[:, 1] - a[:, 1]) * (c[:, 0] - a[:, 0]))
    return np.where(cr > 1e-12, ab * bc * ca / (2 * np.maximum(cr, 1e-12)), 1e9)


def resample_closed(p: np.ndarray, step: float) -> np.ndarray:
    s = np.concatenate([[0], np.cumsum(np.linalg.norm(np.diff(p, axis=0), axis=1))])
    t = np.linspace(0, s[-1], int(round(s[-1] / step)) + 1)
    q = np.stack([np.interp(t, s, p[:, 0]), np.interp(t, s, p[:, 1])], axis=1)
    q[-1] = q[0]
    return q


def _ring_filter(v: np.ndarray, k: int, fn) -> np.ndarray:
    """fn over a 2k + 1 window round a closed sequence whose last entry repeats the first."""
    ring = v[:-1]
    pad = np.concatenate([ring[-k:], ring, ring[:k]])
    out = np.array([fn(pad[i:i + 2 * k + 1], axis=0) for i in range(len(ring))])
    return np.concatenate([out, out[:1]])


def _closed_normals(p: np.ndarray) -> np.ndarray:
    n = ring_normals(p[:-1])
    return np.vstack([n, n[:1]])


def _quantise(xy: np.ndarray, w: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    """What writing and reading back the route file leaves."""
    return (np.array([[float(f'{x:.3f}'), float(f'{y:.3f}')] for x, y in xy]),
            np.array([float(f'{math.floor(v * 100 + 1e-6) / 100:.2f}') for v in w]))


# ---------------------------------------------------------------- centre


def fit_centre(grid: dict, seed: np.ndarray, *, width=2.5, margin=0.2, min_width=1.5,
               reach=3.5, window=6.0, passes=3, min_radius=3.5, step=0.25, out_step=0.5,
               log=print) -> tuple[np.ndarray, np.ndarray]:
    """Closed points and widths, `out_step` apart, from a closed seed line."""
    def lr(p, n):
        return (free_space(grid, p, n, reach, grid['cell'] / 2),
                free_space(grid, p, -n, reach, grid['cell'] / 2))

    k = max(1, int(round(window / step / 2)))
    p = resample_closed(seed, step)
    for _ in range(passes):
        n = _closed_normals(p)
        L, R = lr(p, n)
        target = np.clip((L - R) / 2, -2.0, 2.0)
        wgt = (L + R) ** -4.0   # a narrow gap outweighs its wide neighbours
        shift = _ring_filter(target * wgt, k, np.sum) / _ring_filter(wgt, k, np.sum)
        p = p + shift[:, None] * n
        p[-1] = p[0]
        p = resample_closed(_ring_filter(p, max(1, k // 2), np.mean), step)

    # Relax toward the chord midpoint wherever the radius over 1 m chords, the
    # builder's own check, is under min_radius.
    span = max(1, int(round(1.0 / step)))
    for it in range(400):
        tight = ring_radii(p[:-1], span) < min_radius
        if not tight.any():
            break
        ring = p[:-1]
        mid = (np.roll(ring, span, axis=0) + np.roll(ring, -span, axis=0)) / 2
        m = _ring_filter(np.concatenate([tight, tight[:1]]).astype(float), span, np.max)[:-1] > 0
        ring = np.where(m[:, None], ring + 0.3 * (mid - ring), ring)
        p = resample_closed(np.vstack([ring, ring[:1]]), step)
    log(f'curvature relax: {it} iterations, min radius {ring_radii(p[:-1], span).min():.1f} m')

    n = _closed_normals(p)
    L, R = lr(p, n)
    raw = np.clip(L + R - 2 * margin, min_width, width)
    w = _ring_filter(_ring_filter(raw, k, np.min), k // 2 or 1, np.mean)
    w = np.minimum(w, _ring_filter(raw, k, np.min))  # never wider than the local allowance
    log(f'width: min {w.min():.2f} m, {int(np.sum(w < width - 1e-3))}/{len(w)} samples narrowed')

    s = np.concatenate([[0], np.cumsum(np.linalg.norm(np.diff(p, axis=0), axis=1))])
    t = np.linspace(0, s[-1], int(round(s[-1] / out_step)) + 1)
    xo, yo, wo = np.interp(t, s, p[:, 0]), np.interp(t, s, p[:, 1]), np.interp(t, s, w)
    xo[-1], yo[-1], wo[-1] = xo[0], yo[0], wo[0]
    log(f'{len(xo)} points, {s[-1]:.1f} m')
    # This stage floors widths without refine's 1e-6 guard; kept, so the
    # 2026-10-22 lane reproduces.
    return (np.array([[float(f'{x:.3f}'), float(f'{y:.3f}')] for x, y in zip(xo, yo)]),
            np.array([float(f'{math.floor(v * 100) / 100:.2f}') for v in wo]))


# ---------------------------------------------------------------- refine


def _where(xy: np.ndarray, boxes) -> np.ndarray:
    """Points inside any of a list of {x, y: [lo, hi]} boxes (open where null)."""
    hit = np.zeros(len(xy), bool)
    for b in boxes or []:
        hit |= in_box(xy, b)
    return hit


def level_with(xy: np.ndarray, n: np.ndarray, pinch: dict,
               body: tuple[float, float, float]) -> np.ndarray:
    """Stations at which any part of the cart is level with the pinch along map x.

    The aisle there must run along map x, either way: the cart covers base_link
    -rear .. +front along its travel, read from the normals `n`. `pad` widens
    that at both ends."""
    rear, front, _ = body
    lo, hi = pinch['x']
    pad = float(pinch.get('pad', 0.0))
    forward = n[:, 1] >= 0   # left normal +y: travelling +x
    back = np.where(forward, rear, front) + pad
    ahead = np.where(forward, front, rear) + pad
    return _where(xy, [pinch['aisle']]) & (xy[:, 0] - back < hi) & (xy[:, 0] + ahead > lo)


def refine_pass(grid: dict, P: np.ndarray, W_in: np.ndarray, cfg: dict, stretch: dict,
                body: tuple[float, float, float], log=print) -> tuple[np.ndarray, np.ndarray]:
    """One least-squares solve of one stretch. P, W_in: the ring, no repeated point."""
    try:
        from scipy.optimize import lsq_linear
    except ImportError as e:   # numpy 2 in the user site against apt's scipy, on the workstation
        raise SystemExit(f'scipy does not import ({e}); try python3 -s, which skips the user site')

    N = len(P)
    reach, strip = float(cfg.get('reach', 3.5)), float(cfg.get('strip', 0.25))
    width, min_width = float(cfg['width']), float(cfg['min_width'])
    margin = float(stretch['margin'])
    n = ring_normals(P)
    s = np.concatenate([[0], np.cumsum(np.linalg.norm(np.diff(P, axis=0), axis=1))])
    zone = _where(P, stretch['where'])
    idx = np.where(zone)[0]
    if len(idx) == 0:
        raise ValueError(f'stretch {stretch.get("name")} selects no points')
    if not np.all(np.diff(idx) == 1):
        raise ValueError(f'stretch {stretch.get("name")} is not contiguous in the route')

    # Width: the lane width, narrowed to the pinch's where the cart is level
    # with it and over its hold boxes, eased back over `ease` m by
    # (distance / ease)^2; never wider than the free span less both margins.
    pinch = cfg.get('pinch')
    level = level_with(P, n, pinch, body) if pinch else np.zeros(N, bool)
    w = W_in.copy()   # outside the stretch the input's widths stand
    w[zone] = width
    if pinch:
        hold = level | _where(P, pinch.get('hold'))
        sb = s[hold]
        pw, ease = float(pinch['width']), float(pinch['ease'])
        for i in idx:
            dmin = 0.0 if hold[i] else (np.min(np.abs(sb - s[i])) if len(sb) else math.inf)
            w[i] = pw + (width - pw) * min(1.0, dmin / ease) ** 2
    L = free_space(grid, P, n, reach, 0.025, strip)
    R = free_space(grid, P, -n, reach, 0.025, strip)
    for i in idx:
        w[i] = max(min_width, min(w[i], L[i] + R[i] - 2 * margin))

    # Edge margins: the stretch's, then the overrides in order, then the pinch's
    # cap beside it, where the lane fills the gap and the body band governs.
    mg = np.full(N, margin)
    for o in cfg.get('margins') or []:
        sel = _where(P, o['where'])
        if 'at_least' in o:
            mg[sel] = max(margin, float(o['at_least']))
        if 'at_most' in o:
            mg[sel] = np.minimum(mg[sel], float(o['at_most']))
    if pinch and 'edge_margin' in pinch:
        mg[level] = np.minimum(mg[level], float(pinch['edge_margin']))
    lo, hi = w / 2 + mg - R, L - w / 2 - mg

    # The body band: wherever any part of the cart is level with the pinch, its
    # sides keep `margin` off both faces, the cart near parallel to the aisle.
    # A per-point ray sees the obstacle at the one point beside it only.
    if pinch and 'body' in pinch and (level & zone).any():
        half = body[2]
        f0, f1 = pinch['body']['y']
        bm = float(pinch['body']['margin'])
        yc_lo, yc_hi = f0 + half + bm, f1 - half - bm
        log(f'body band: centre held in y {yc_lo:.2f} .. {yc_hi:.2f} at {int(level.sum())} points')
        for i in np.where(level)[0]:
            ny = n[i, 1]   # moving d along the normal moves y by d * ny
            b0, b1 = (yc_lo - P[i, 1]) / ny, (yc_hi - P[i, 1]) / ny
            lo[i] = max(lo[i], min(b0, b1))
            hi[i] = min(hi[i], max(b0, b1))

    m, pin = len(idx), int(cfg.get('pin', 3))
    bad = lo[idx] > hi[idx]
    mid = (lo[idx] + hi[idx]) / 2
    lb = np.where(bad, mid - 1e-3, lo[idx])
    ub = np.where(bad, mid + 1e-3, hi[idx])
    lb = np.minimum(lb, ub - 1e-3)
    # Pinned ends join the fixed rest of the loop.
    lb[:pin], ub[:pin], lb[-pin:], ub[-pin:] = -1e-4, 1e-4, -1e-4, 1e-4

    # Second differences of P_i + d_i n_i over the stretch and one fixed
    # neighbour each side.
    rows, rhs = [], []
    for j in range(-1, m + 1):
        ia, ib, ic = idx[0] + j - 1, idx[0] + j, idx[0] + j + 1
        for k in (0, 1):
            r = np.zeros(m)
            const = P[ia % N, k] - 2 * P[ib % N, k] + P[ic % N, k]
            for ii, coef in ((ia, 1.0), (ib, -2.0), (ic, 1.0)):
                jj = ii - idx[0]
                if 0 <= jj < m:
                    r[jj] += coef * n[ii % N, k]
            rows.append(r)
            rhs.append(-const)
    rows, rhs = np.array(rows), np.array(rhs)

    # Squared curvature spreads bends but does not cap them: reweight the rows
    # where the radius is still under min_radius, and solve again.
    rmin, lam = float(cfg['min_radius']), float(cfg.get('pull', 0.02))
    wt = np.ones(m + 2)
    for it in range(30):
        Wr = np.repeat(wt, 2)
        A = np.vstack([rows * Wr[:, None], math.sqrt(lam) * np.eye(m)])
        b = np.concatenate([rhs * Wr, np.zeros(m)])
        res = lsq_linear(A, b, bounds=(lb, ub), lsmr_tol='auto', max_iter=5000)
        d = res.x
        Q = P.copy()
        Q[idx] += d[:, None] * n[idx]
        r = np.take(ring_radii(Q), np.arange(idx[0] - 1, idx[-1] + 2), mode='wrap')
        if r.min() >= rmin:
            break
        wt = np.where(r < rmin, wt * 1.6, wt)
        wt = np.convolve(np.pad(wt, 2, mode='edge'), np.ones(5) / 5, 'valid')
    log(f'{stretch.get("name", "stretch")}: {m} points, reweighted {it} rounds, '
        f'min radius {r.min():.2f} m, max |offset| {np.abs(d).max():.2f} m, solver status {res.status}'
        + (f', {int(bad.sum())} INFEASIBLE points' if bad.any() else '')
        + (f', STILL UNDER {rmin} m' if r.min() < rmin else ''))
    if pinch and 'body' in pinch and (level & zone).any():
        yl = Q[level & zone, 1]
        log(f'  beside the pinch: centre y {yl.min():.3f} .. {yl.max():.3f}')
    return Q, w


def refine(grid: dict, P: np.ndarray, W: np.ndarray, cfg: dict,
           body: tuple[float, float, float], log=print) -> tuple[np.ndarray, np.ndarray]:
    """Every stretch of `cfg`, in order, each re-solved `passes` times. Closed in, closed out."""
    ring, w = P[:-1], W[:-1]
    for st in cfg['stretches']:
        for _ in range(int(st.get('passes', 1))):
            ring, w = refine_pass(grid, ring, w, cfg, st, body, log)
            ring, w = _quantise(ring, w)
    return np.vstack([ring, ring[:1]]), np.concatenate([w, w[:1]])


# ---------------------------------------------------------------- output


def slow_zone(xy: np.ndarray, w: np.ndarray, below: float, pad: float) -> tuple[int, int]:
    """Indices where the slow limit starts and where the normal one resumes.

    The stretch narrower than `below`, first to last such point (one stretch),
    plus `pad` m of path either side."""
    s = np.concatenate([[0], np.cumsum(np.linalg.norm(np.diff(xy, axis=0), axis=1))])
    nar = np.where(w < below)[0]
    if len(nar) == 0:
        raise ValueError(f'no point is narrower than {below} m')
    a = int(np.searchsorted(s, s[nar.min()] - pad))
    b = int(np.searchsorted(s, s[nar.max()] + pad))
    return a, b + 1


def route_text(xy: np.ndarray, w: np.ndarray, header: str = '',
               speeds: dict[int, float] | None = None) -> str:
    out = [header.rstrip('\n')] if header else []
    for i, ((x, y), ww) in enumerate(zip(xy, w)):
        sp = f', speed_limit: {speeds[i]:g}' if speeds and i in speeds else ''
        out.append(f'- {{x: {x:.3f}, y: {y:.3f}, width: {ww:.2f}{sp}}}')
    return '\n'.join(out) + '\n'


def read_route(path: Path, default_width: float = 2.5) -> tuple[np.ndarray, np.ndarray]:
    import yaml
    pts, widths, _ = c2l.parse_route(yaml.safe_load(Path(path).read_text()), default_width)
    xy = np.array(pts, float)
    if len(xy) < 4 or np.linalg.norm(xy[0] - xy[-1]) > 1e-6:
        raise ValueError(f'{path}: a closed route is needed, the first point repeated last')
    return xy, np.array(widths, float)


def main(argv=None) -> int:
    import yaml

    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest='cmd', required=True)
    c = sub.add_parser('centre', help='centre and size a lane on a rough line')
    c.add_argument('grid', type=Path)
    c.add_argument('route', type=Path)
    c.add_argument('out', type=Path)
    c.add_argument('--width', type=float, default=2.5)
    c.add_argument('--margin', type=float, default=0.2)
    c.add_argument('--min-width', type=float, default=1.5)
    c.add_argument('--reach', type=float, default=3.5)
    c.add_argument('--window', type=float, default=6.0)
    c.add_argument('--passes', type=int, default=3)
    c.add_argument('--min-radius', type=float, default=3.5)
    r = sub.add_parser('refine', help='move a lane off obstacles on chosen stretches')
    r.add_argument('grid', type=Path)
    r.add_argument('route', type=Path)
    r.add_argument('fit', type=Path, help='stretches, widths, margins, YAML')
    r.add_argument('out', type=Path)
    for p in (c, r):
        p.add_argument('--slow-below', type=float,
                       help='tag the stretch narrower than this, m, with --slow-speed')
        p.add_argument('--slow-pad', type=float, default=2.0, help='m of path either side')
        p.add_argument('--slow-speed', type=float, default=2.0, help='km/h')
        p.add_argument('--speed', type=float, default=4.0, help='km/h after the slow stretch')
        p.add_argument('--header-from', type=Path,
                       help="copy this route file's comment lines on top")
    args = ap.parse_args(argv)

    def log(msg):
        print(msg, file=sys.stderr)

    grid = load_grid(args.grid)
    xy, w = read_route(args.route)
    if args.cmd == 'centre':
        xy, w = fit_centre(grid, xy, width=args.width, margin=args.margin,
                           min_width=args.min_width, reach=args.reach, window=args.window,
                           passes=args.passes, min_radius=args.min_radius, log=log)
    else:
        xy, w = refine(grid, xy, w, yaml.safe_load(args.fit.read_text()), c2l.vehicle_body(), log)

    speeds = None
    if args.slow_below is not None:
        a, b = slow_zone(xy, w, args.slow_below, args.slow_pad)
        speeds = {a: args.slow_speed, b: args.speed}
        log(f'{args.slow_speed:g} km/h from ({xy[a, 0]:.2f}, {xy[a, 1]:.2f}) to '
            f'({xy[b, 0]:.2f}, {xy[b, 1]:.2f})')
    header = ''
    if args.header_from:
        header = '\n'.join(ln for ln in args.header_from.read_text().split('\n') if ln.startswith('#'))
    args.out.write_text(route_text(xy, w, header, speeds))
    log(f'wrote {args.out}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
