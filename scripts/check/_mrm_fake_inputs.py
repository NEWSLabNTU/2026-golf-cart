#!/usr/bin/env python3
"""Synthetic vehicle inputs that mrm_handler needs, for bench testing.

Not a simulator. mrm_handler subscribes odometry, control mode and gear and
will not act without them; none of the three influence WHICH MRM it selects,
which is driven by operation mode availability. Underscore-prefixed because it
is a fixture for scripts/check/mrm_timeline_test.sh, not a tool.
"""
import rclpy
from rclpy.node import Node
from nav_msgs.msg import Odometry
from autoware_vehicle_msgs.msg import ControlModeReport, GearCommand


def main():
    rclpy.init()
    n = Node("mrm_fake_inputs")
    odo = n.create_publisher(Odometry, "/localization/kinematic_state", 1)
    cm = n.create_publisher(ControlModeReport, "/vehicle/status/control_mode", 1)
    gear = n.create_publisher(GearCommand, "/control/command/gear_cmd", 1)

    def tick():
        now = n.get_clock().now().to_msg()
        o = Odometry()
        o.header.stamp = now
        o.header.frame_id = "map"
        o.child_frame_id = "base_link"
        odo.publish(o)                      # stationary at the origin
        c = ControlModeReport()
        c.stamp = now
        c.mode = ControlModeReport.AUTONOMOUS   # MRM only engages under autonomy
        cm.publish(c)
        g = GearCommand()
        g.stamp = now
        g.command = GearCommand.DRIVE
        gear.publish(g)

    n.create_timer(0.1, tick)
    try:
        rclpy.spin(n)
    except KeyboardInterrupt:
        pass
    rclpy.shutdown()


if __name__ == "__main__":
    main()
