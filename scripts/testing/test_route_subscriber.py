"""Tests for route_subscriber.py, without a ROS graph.

    python3 -m pytest scripts/testing/test_route_subscriber.py
"""

import importlib.util
from pathlib import Path
import sys
from types import SimpleNamespace as NS

import pytest

_SCRIPT = Path(__file__).resolve().with_name('route_subscriber.py')
_spec = importlib.util.spec_from_file_location('route_subscriber', _SCRIPT)
rs = importlib.util.module_from_spec(_spec)
sys.modules['route_subscriber'] = rs
_spec.loader.exec_module(rs)


class FakeNode:
    """get_subscriptions_info_by_topic answers from a list, one call per entry."""

    def __init__(self, answers):
        self.answers = list(answers)
        self.topics = []

    def get_subscriptions_info_by_topic(self, topic):
        self.topics.append(topic)
        names = self.answers.pop(0) if len(self.answers) > 1 else self.answers[0]
        return [NS(node_name=n) for n in names]


@pytest.fixture
def no_spin(monkeypatch):
    fake = NS(spin_once=lambda node, timeout_sec=None: None)
    monkeypatch.setitem(sys.modules, 'rclpy', fake)


def test_defaults_name_the_1_5_0_checker_and_route_topic():
    assert rs.LANE_DEPARTURE_CHECKER == 'lane_departure_checker_node'
    assert rs.ROUTE_TOPIC == '/planning/mission_planning/route'


def test_returns_at_once_when_already_subscribed(no_spin):
    node = FakeNode([['behavior_path_planner', 'lane_departure_checker_node']])
    assert rs.wait_for_route_subscriber(node, 5.0, say=lambda m: None) == ''
    assert node.topics == [rs.ROUTE_TOPIC]


def test_waits_until_the_checker_appears(no_spin):
    said = []
    node = FakeNode([['behavior_path_planner'], [], ['lane_departure_checker_node']])
    assert rs.wait_for_route_subscriber(node, 5.0, say=said.append) == ''
    assert len(node.topics) == 3
    assert said[0].startswith('waiting for lane_departure_checker_node')
    assert said[-1] == 'lane_departure_checker_node subscribed to ' + rs.ROUTE_TOPIC


def test_times_out_with_the_reason(no_spin):
    node = FakeNode([['behavior_path_planner']])
    err = rs.wait_for_route_subscriber(node, 0.3, say=lambda m: None)
    assert 'lane_departure_checker_node has not subscribed' in err
    assert 'VOLATILE' in err and 'control_check_container' in err


def test_zero_timeout_skips_the_graph():
    node = FakeNode([[]])
    assert rs.wait_for_route_subscriber(node, 0.0) == ''
    assert node.topics == []
