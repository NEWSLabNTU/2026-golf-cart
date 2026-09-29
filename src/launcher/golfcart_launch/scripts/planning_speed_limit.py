#!/usr/bin/env python3
"""Publish a startup planning speed limit, latched (Phase 8, S4).

Autoware's planning maximum (`max_vel`, 4.17 m/s) lives in autoware_launch's
common.param.yaml, which tier4_planning_component passes as a fixed include
value, so no launch argument reaches it. The supported runtime lever is
`/planning/scenario_planning/max_velocity_default`: the external velocity limit
selector subscribes to it transient_local, depth 1, and keeps the latest.

This node publishes one message there, transient_local, and stays up so a
selector that starts later still receives it. It is a DEFAULT, not a ceiling:
an operator's later publish (the route TUI's 'L' key) replaces it. The ceiling
is the vehicle interface's `max_speed_mps`.

Not `ros2 topic pub` from the launch file: play_launch executes `executable`
actions during its dump and drops them from the run.
"""

import math

ROOTS_MAX_SPEED_MPS = 25.0 / 3.6  # the VCU's target-speed ceiling, 25 km/h
SENDER = 'golfcart_planning_speed_limit'
TOPIC = '/planning/scenario_planning/max_velocity_default'


def validate_limit(value: float) -> float:
    """Return the limit, or raise ValueError if it cannot be a real cap."""
    if not math.isfinite(value) or value <= 0.0:
        raise ValueError(f'max_velocity must be finite and positive, got {value}')
    if value > ROOTS_MAX_SPEED_MPS:
        raise ValueError(
            f'max_velocity {value} m/s exceeds the VCU ceiling '
            f'{ROOTS_MAX_SPEED_MPS:.3f} m/s; that is no cap at all')
    return value


def limit_fields(value: float) -> dict:
    """Field values for the VelocityLimit message."""
    return {'max_velocity': value, 'use_constraints': False, 'sender': SENDER}


def main() -> None:
    import rclpy
    from rclpy.node import Node
    from rclpy.qos import DurabilityPolicy, QoSProfile, ReliabilityPolicy
    from tier4_planning_msgs.msg import VelocityLimit

    from rcl_interfaces.msg import ParameterDescriptor

    rclpy.init()
    node = Node('planning_speed_limit')
    # Dynamic typing: `planning_speed_limit:=1` arrives as an integer, and a
    # float-typed declaration would reject it at startup.
    node.declare_parameter('max_velocity', 1.0,
                           ParameterDescriptor(dynamic_typing=True))
    raw = node.get_parameter('max_velocity').value
    if raw is None:
        raise ValueError('max_velocity is unset')
    limit = validate_limit(float(raw))

    qos = QoSProfile(depth=1, reliability=ReliabilityPolicy.RELIABLE,
                     durability=DurabilityPolicy.TRANSIENT_LOCAL)
    pub = node.create_publisher(VelocityLimit, TOPIC, qos)

    msg = VelocityLimit()
    for key, val in limit_fields(limit).items():
        setattr(msg, key, val)
    msg.stamp = node.get_clock().now().to_msg()
    pub.publish(msg)
    node.get_logger().info(f'planning speed default {limit:.2f} m/s on {TOPIC}')

    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.try_shutdown()


if __name__ == '__main__':
    main()
