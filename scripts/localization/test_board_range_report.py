"""Tests for board_range_report.py's geometry and scoring (no ROS, no bag).

    python3 -m pytest scripts/localization/test_board_range_report.py
"""

import importlib.util
import math
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path

import numpy as np

_SCRIPT = Path(__file__).resolve().with_name('board_range_report.py')
_spec = importlib.util.spec_from_file_location('board_range_report', _SCRIPT)
assert _spec is not None and _spec.loader is not None, _SCRIPT
brr = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(brr)

BOARD = (0.0, 0.0, 1.3)
SENSOR = brr.transform((0.46, 0.0, 1.966), np.eye(3))


def _pose(x, y, yaw_deg):
    return brr.transform((x, y, 0.0), brr.rpy_matrix(0.0, 0.0, math.radians(yaw_deg)))


def test_mingda_lane_start_geometry():
    # base_link at the lane start, (17.6, -4.9), heading -x toward the board.
    g = brr.board_geometry(_pose(17.6, -4.9, 180.0), SENSOR, BOARD)
    # The sensor sits 0.46 m ahead of base_link, so at (17.14, -4.9).
    assert math.isclose(g['sensor_x'], 17.14, abs_tol=1e-9)
    assert math.isclose(g['range'], math.sqrt(17.14 ** 2 + 4.9 ** 2 + 0.666 ** 2), rel_tol=1e-9)
    # Board ahead and to the RIGHT: facing -x, the right hand points to +y.
    assert math.isclose(g['bearing'], -math.degrees(math.atan2(4.9, 17.6)), abs_tol=1e-9)
    # Seen from the board, the sensor is right of its normal (negative aspect).
    assert math.isclose(g['aspect'], -math.degrees(math.atan2(4.9, 17.14)), abs_tol=1e-9)


def test_behind_the_board_has_aspect_over_90():
    g = brr.board_geometry(_pose(-5.0, 0.0, 0.0), SENSOR, BOARD)
    assert abs(g['aspect']) > 90.0
    assert math.isclose(g['bearing'], 0.0, abs_tol=1e-9)


def test_pose_track_interpolates_position_and_yaw():
    q0 = [0.0, 0.0, 0.0, 1.0]
    q1 = [0.0, 0.0, math.sin(math.radians(45)), math.cos(math.radians(45))]   # 90 deg
    tr = brr.PoseTrack(np.array([0.0, 1.0]), np.array([[0, 0, 0], [2, 0, 0.0]]),
                       np.array([q0, q1]), max_gap=2.0)
    m = tr.at(0.5)
    assert np.allclose(m[:3, 3], [1.0, 0.0, 0.0])
    assert math.isclose(math.degrees(math.atan2(m[1, 0], m[0, 0])), 45.0, abs_tol=1e-6)
    assert tr.at(-0.1) is None and tr.at(1.1) is None


def test_pose_track_refuses_to_bridge_a_gap():
    q = [0.0, 0.0, 0.0, 1.0]
    tr = brr.PoseTrack(np.array([0.0, 2.0]), np.zeros((2, 3)), np.array([q, q]), max_gap=0.5)
    assert tr.at(1.0) is None


class _S(Enum):
    OK = 'ok'
    NO_CANDIDATE = 'no_candidate'
    AMBIGUOUS = 'ambiguous'


@dataclass
class _Det:
    centre: np.ndarray
    confidence: float = 0.9


@dataclass
class _Rej:
    reason: str
    centroid: np.ndarray


@dataclass
class _Res:
    status: _S
    detection: object = None
    candidates: list = field(default_factory=list)
    rejections: list = field(default_factory=list)


def test_classify_outcomes():
    here = np.array([10.0, 2.0, -0.7])
    far = here + [5.0, 0.0, 0.0]
    c = brr.classify
    args = dict(min_confidence=0.6, retro_near=0, cluster_min_points=60,
                in_range=True, behind=False)
    assert c(_Res(_S.OK, _Det(here)), here, **args) == 'detected'
    assert c(_Res(_S.OK, _Det(here, 0.3)), here, **args) == 'low_conf'
    assert c(_Res(_S.OK, _Det(far)), here, **args) == 'wrong'
    assert c(_Res(_S.AMBIGUOUS, candidates=[_Det(far), _Det(here)]), here, **args) == 'ambiguous'
    assert c(_Res(_S.NO_CANDIDATE, rejections=[_Rej('bad_height', here)]), here,
             **args) == 'rej:bad_height'
    assert c(_Res(_S.NO_CANDIDATE), here, **args) == 'few_points'
    assert c(_Res(_S.NO_CANDIDATE), here, **{**args, 'in_range': False}) == 'out_of_range'
    assert c(_Res(_S.NO_CANDIDATE), here, **{**args, 'behind': True}) == 'behind'


def test_table_bins_and_rates():
    rows = [{'range': 5.0, 'outcome': 'detected', 'retro_near': 300},
            {'range': 5.5, 'outcome': 'few_points', 'retro_near': 10},
            {'range': 13.0, 'outcome': 'detected', 'retro_near': 90}]
    out = brr.table(rows, 'range', [4, 6, 12, 14], 'range m')
    assert '| 4-6 | 2 | 1 | 50 % |' in out
    assert '| 12-14 | 1 | 1 | 100 % |' in out
    assert '6-12' not in out
