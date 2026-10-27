"""Wait for the lane departure checker to subscribe to the route before setting one.

Autoware 1.5.0's lane_departure_checker_node subscribes to
/planning/mission_planning/route through autoware_utils'
InterProcessPollingSubscriber with its default QoS, `rclcpp::QoS{1}`: VOLATILE.
The mission planner publishes the route once, TRANSIENT_LOCAL, on each
set_route. A checker that subscribes after that never receives it, so it checks
nothing, logs "waiting for route msg..." and its diagnostic drops to the
diagnostic_updater's 1 Hz against the diagnostic graph's 1.0 s timeout: the
lane_departure leaf goes STALE now and then, and with it autonomous
availability, an MRM each time the phases line up. control_check_container
coming up after the test script set the route is enough to cause it.

Upstream declares the subscription transient_local after 1.5.0; drop this wait
with that upgrade. Ported from NEWSLabNTU/AutoSDV 5c400f3c (sim_pose_init's
wait_for_route_subscriber).

The scripts that set routes (sim_route_check.py, sim_loop_drive.py,
sim_mrm_check.py) call wait_for_route_subscriber() before their first
set_route_points.
"""

from __future__ import annotations

import time

ROUTE_TOPIC = '/planning/mission_planning/route'
LANE_DEPARTURE_CHECKER = 'lane_departure_checker_node'
DEFAULT_TIMEOUT = 120.0


def subscriber_names(infos) -> set[str]:
    """Node names of a get_subscriptions_info_by_topic() result."""
    return {i.node_name for i in infos}


def missing_message(name: str, topic: str, timeout: float) -> str:
    """Why the run stops when `name` never subscribed."""
    return (f'{name} has not subscribed to {topic} after {timeout:.0f} s. Its route '
            f'subscription is VOLATILE in Autoware 1.5.0 and the route is published '
            f'once, so a route set now would never reach it: no lane departure check, '
            f'its diagnostic at 1 Hz and autonomous availability flapping. Is '
            f'control_check_container up? (--route-subscriber-timeout 0 skips this wait)')


def wait_for_route_subscriber(node, timeout: float = DEFAULT_TIMEOUT,
                              name: str = LANE_DEPARTURE_CHECKER,
                              topic: str = ROUTE_TOPIC, say=print) -> str:
    """Block until `name` subscribes to `topic`; '' when it has, else why not.

    timeout <= 0 skips the wait. Spins `node` while waiting so its own
    subscriptions keep up.
    """
    if timeout <= 0:
        return ''
    import rclpy

    deadline = time.time() + timeout
    told = False
    while True:
        if name in subscriber_names(node.get_subscriptions_info_by_topic(topic)):
            if told:
                say(f'{name} subscribed to {topic}')
            return ''
        if time.time() >= deadline:
            return missing_message(name, topic, timeout)
        if not told:
            say(f'waiting for {name} to subscribe to {topic} (up to {timeout:.0f} s)')
            told = True
        rclpy.spin_once(node, timeout_sec=0.2)
