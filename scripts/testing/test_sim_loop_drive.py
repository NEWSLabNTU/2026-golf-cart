"""Tests for sim_loop_drive.py (Phase 8, M6): goal loading, leg sequencing,
per-leg statistics, the verdict, and the committed loop goals against the map.

    python3 -m pytest scripts/testing/test_sim_loop_drive.py

No ROS needed: the script imports rclpy only once it starts driving.
"""

import importlib.util
import math
from pathlib import Path
import sys

import pytest

_SCRIPT = Path(__file__).resolve().with_name('sim_loop_drive.py')
_spec = importlib.util.spec_from_file_location('sim_loop_drive', _SCRIPT)
assert _spec is not None and _spec.loader is not None, _SCRIPT
sld = importlib.util.module_from_spec(_spec)
sys.modules['sim_loop_drive'] = sld  # dataclasses look their module up by name
_spec.loader.exec_module(sld)

MAP = sld.REPO / 'data/mingda-basement'
GOALS = MAP / 'loop_goals_cw.yaml'

TWO_GOALS = """
frame_id: map
start: {name: s, x: 0, y: 0, yaw_deg: 0}
goals:
  - {name: a, x: 10, y: 0, yaw_deg: 0}
  - {name: b, x: 10, y: 10, yaw_deg: 90}
"""


def write(tmp_path, text, name='goals.yaml'):
    p = tmp_path / name
    p.write_text(text)
    return p


# --- goal file -------------------------------------------------------------

def test_load_goals_reads_start_goals_and_options(tmp_path):
    plan = sld.load_goals(write(tmp_path, TWO_GOALS))
    assert plan.start == sld.Goal('s', 0.0, 0.0, 0.0)
    assert [g.name for g in plan.goals] == ['a', 'b']
    assert plan.goals[1].yaw == pytest.approx(math.pi / 2)
    assert plan.allow_goal_modification is False
    assert plan.centreline is None


def test_load_goals_resolves_centreline_beside_the_file(tmp_path):
    plan = sld.load_goals(write(tmp_path, TWO_GOALS + 'centreline: route.yaml\n'))
    assert plan.centreline == tmp_path / 'route.yaml'


@pytest.mark.parametrize('text, match', [
    ('goals: []\nstart: {x: 0, y: 0, yaw_deg: 0}\n', 'non-empty'),
    ('goals:\n  - {x: 1, y: 0, yaw_deg: 0}\n', 'no start'),
    ('start: {x: 0, y: 0, yaw_deg: 0}\ngoals:\n  - {x: 1, y: 0}\n', r'goals\[0\]: missing yaw_deg'),
    ('start: {x: 0, y: 0, yaw_deg: 0}\ngoals:\n  - {x: one, y: 0, yaw_deg: 0}\n', 'numbers'),
    ('start: {x: 0, y: 0, yaw_deg: 0}\ngoals:\n  - {x: 1, y: 0, yaw_deg: 900}\n', 'degrees'),
    ('frame_id: odom\nstart: {x: 0, y: 0, yaw_deg: 0}\ngoals:\n  - {x: 1, y: 0, yaw_deg: 0}\n',
     'frame_id'),
    ('- 1\n- 2\n', 'mapping'),
])
def test_load_goals_rejects_bad_files(tmp_path, text, match):
    with pytest.raises(ValueError, match=match):
        sld.load_goals(write(tmp_path, text))


# --- leg sequence ----------------------------------------------------------

def test_leg_sequence_repeats_goals_per_lap_and_chains_origins(tmp_path):
    plan = sld.load_goals(write(tmp_path, TWO_GOALS))
    legs = sld.leg_sequence(plan, 3)
    assert [(leg.lap, leg.goal.name) for leg in legs] == [
        (1, 'a'), (1, 'b'), (2, 'a'), (2, 'b'), (3, 'a'), (3, 'b')]
    assert [leg.index for leg in legs] == list(range(6))
    assert legs[0].origin.name == 's'
    # lap 2 starts where lap 1 ended, not at the start pose
    assert legs[2].origin.name == 'b'
    assert all(nxt.origin == prev.goal for prev, nxt in zip(legs, legs[1:]))


def test_leg_sequence_needs_a_lap(tmp_path):
    plan = sld.load_goals(write(tmp_path, TWO_GOALS))
    with pytest.raises(ValueError):
        sld.leg_sequence(plan, 0)


# --- statistics ------------------------------------------------------------

def drive(stats, xs, v, t0=0.0, dt=0.1, y=0.0):
    t = t0
    for x in xs:
        stats.add(t, x, y, v)
        t += dt
    return t


def test_leg_stats_speeds_error_and_duration():
    goal = sld.Goal('g', 20.0, 0.0, 0.0)
    s = sld.LegStats((0.0, 0.0), goal, cruise_margin=3.0)
    t = drive(s, [0.0, 1.0, 2.0], 0.5)                 # accelerating, near the start
    t = drive(s, [4.0, 8.0, 12.0], 1.2, t0=t)          # cruising
    t = drive(s, [10.0], 0.8, t0=t)                    # slower, still cruising
    drive(s, [18.0, 19.9], 0.2, t0=t)                  # braking near the goal
    assert s.v_max == pytest.approx(1.2)
    assert s.v_min_cruise == pytest.approx(0.8)        # 0.5 and 0.2 are at the ends
    assert s.error() == pytest.approx(0.1)
    assert s.duration == pytest.approx(0.8)
    assert s.stops == 0


def test_leg_stats_counts_a_mid_leg_stop_once():
    goal = sld.Goal('g', 20.0, 0.0, 0.0)
    s = sld.LegStats((0.0, 0.0), goal)
    t = drive(s, [10.0] * 30, 0.0)                     # 3 s standing mid-leg
    drive(s, [11.0, 12.0], 1.0, t0=t)
    t = drive(s, [13.0] * 5, 0.0, t0=10.0)             # 0.4 s: a hesitation, not a stop
    assert s.stops == 1
    assert s.v_min_cruise == 0.0


def test_leg_stats_stop_at_the_goal_is_not_a_stop():
    s = sld.LegStats((0.0, 0.0), sld.Goal('g', 20.0, 0.0, 0.0))
    drive(s, [19.9] * 50, 0.0)
    assert s.stops == 0
    assert s.v_min_cruise is None


def test_leg_stats_truth_error_is_separate():
    s = sld.LegStats((0.0, 0.0), sld.Goal('g', 5.0, 0.0, 0.0))
    s.add(0.0, 5.0, 0.0, 0.0)
    s.add_truth(5.0, 0.3)
    assert s.error() == pytest.approx(0.0)
    assert s.error(truth=True) == pytest.approx(0.3)


# --- verdict ---------------------------------------------------------------

def result(err=0.1, arrived=True, vmax=1.0, stops=0, refused=''):
    goal = sld.Goal('g', 10.0, 0.0, 0.0)
    leg = sld.Leg(0, 1, 0, goal, sld.Goal('s', 0.0, 0.0, 0.0))
    s = sld.LegStats((0.0, 0.0), goal)
    s.add(0.0, 10.0 - err, 0.0, 0.0)
    s.v_max, s.stops = vmax, stops
    return sld.LegResult(leg, s, arrived, refused=refused)


def test_judge_passes_a_clean_leg():
    assert sld.judge_leg(result(), 0.5, 1.5, False) == []


@pytest.mark.parametrize('kw, words', [
    (dict(err=0.7), 'from the goal'),
    (dict(arrived=False), 'not ARRIVED'),
    (dict(vmax=1.6), 'ceiling'),
    (dict(stops=2), 'mid-leg'),
    (dict(refused='route refused: lane'), 'route refused'),
])
def test_judge_names_the_failure(kw, words):
    why = sld.judge_leg(result(**kw), 0.5, 1.5, False)
    assert why and words in why[0]


def test_judge_uses_truth_when_asked():
    r = result(err=0.0)
    r.stats.add_truth(10.0, 0.8)
    assert sld.judge_leg(r, 0.5, 1.5, False) == []
    assert 'from the goal' in sld.judge_leg(r, 0.5, 1.5, True)[0]


def test_rows_line_up_with_the_header():
    for truth in (False, True):
        assert len(sld.format_row(result(), truth)) == len(sld.header(truth))


# --- placement check, synthetic --------------------------------------------

def square_loop(side=20.0, step=0.5, width=2.5):
    """Closed square, counter-clockwise, first point repeated last."""
    pts = []
    corners = [(0, 0), (side, 0), (side, side), (0, side), (0, 0)]
    for (ax, ay), (bx, by) in zip(corners, corners[1:]):
        n = int(round(math.hypot(bx - ax, by - ay) / step))
        pts += [(ax + (bx - ax) * i / n, ay + (by - ay) * i / n, width) for i in range(n)]
    return pts + [pts[0]]


def plan_with(*goals):
    return sld.LoopPlan(start=sld.Goal('s', 5.0, 0.0, 0.0), goals=tuple(goals))


def test_placement_accepts_a_goal_on_the_lane():
    plan = plan_with(sld.Goal('a', 20.0, 10.0, 90.0))
    assert sld.check_goal_placement(plan, square_loop(), [(0.0, 0.0)], (0.8, 2.5)) == []


@pytest.mark.parametrize('goal, words', [
    (sld.Goal('off', 20.3, 10.0, 90.0), 'off the centreline'),
    (sld.Goal('turned', 20.0, 10.0, 80.0), 'heading'),
    (sld.Goal('backwards', 20.0, 10.0, -90.0), 'heading'),
    (sld.Goal('seam', 20.0, 10.2, 90.0), 'lanelet boundary'),
])
def test_placement_rejects(goal, words):
    probs = sld.check_goal_placement(plan_with(goal), square_loop(), [(20.0, 10.0)], (0.8, 2.5))
    assert any(words in p for p in probs), probs


def test_placement_rejects_a_cart_standing_in_a_narrow_stretch():
    pts = square_loop()
    # narrow the lane 1.5 m to 2.0 m AHEAD of a goal at (20, 10): the nose is there
    pts = [(x, y, 1.5 if x == 20.0 and 11.5 <= y <= 12.0 else w) for x, y, w in pts]
    plan = plan_with(sld.Goal('a', 20.0, 10.0, 90.0))
    probs = sld.check_goal_placement(plan, pts, [], (0.8, 2.5))
    assert any('wide' in p for p in probs), probs
    # with a short nose the cart stops before it
    assert sld.check_goal_placement(plan, pts, [], (0.8, 1.0)) == []


# --- the committed Ming-Da loop goals --------------------------------------

def test_committed_goals_load():
    plan = sld.load_goals(GOALS)
    assert plan.lanelet2_map_file == 'lanelet2_map_loop.osm'
    assert plan.allow_goal_modification is False
    assert len(plan.goals) >= 2
    assert (MAP / plan.lanelet2_map_file).exists()


def test_committed_goals_are_placeable_on_the_committed_lane():
    plan = sld.load_goals(GOALS)
    assert sld.preflight(plan, GOALS) == []


def test_committed_goals_go_round_once_per_lap_in_travel_order():
    """Arc lengths strictly increase from the start through every goal, and the
    lap closes: the goals are in clockwise order and no leg is a wrap-around."""
    plan = sld.load_goals(GOALS)
    line = sld.load_centreline(plan.centreline)
    s = sld.arc_lengths(line)
    arcs = [sld.project(line, s, g.x, g.y)[1] for g in (plan.start, *plan.goals)]
    assert arcs == sorted(arcs)
    legs = [b - a for a, b in zip(arcs, arcs[1:])]
    assert min(legs) > 10.0, legs
    # the next lap's first leg, last goal -> first goal, is also forward
    assert (arcs[1] - arcs[-1]) % s[-1] > 10.0


def test_committed_vehicle_extent_is_read_from_the_description():
    rear, front = sld.vehicle_extent()
    assert 0.5 < rear < 1.5
    assert 2.0 < front < 3.0
