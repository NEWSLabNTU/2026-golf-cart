#!/usr/bin/env python3
"""Stand-in perception outputs, for a run with the perception stack off.

With `launch_perception:=false` nothing publishes the two topics the planners
wait on, and the whole lane-driving chain stays silent: behavior_path_planner
logs `waiting for occupancy_grid` every 5 s and publishes no path, so there is
no trajectory, no control command and `is_autonomous_mode_available` stays
false. The objects topic already has a stand-in (empty_objects_publisher);
this adds the other two:

- `/perception/occupancy_grid_map/map`: an all-free grid in `map`, covering
  the maps we drive (the Ming-Da cloud spans x -62..42, y -38..48).
- `/perception/obstacle_segmentation/pointcloud`: an empty cloud in `base_link`.

An empty cloud and an all-free grid say "there is nothing here", which is
the same as running with no obstacle detection at all. THE DRIVER IS THE
OBSTACLE DETECTOR in this mode. Use it only on a closed, empty course.

Why not perception_preset:=minimal: CenterPoint's TensorRT engine build blocks
the composable container its constructor runs in for 10 to 30 minutes
(dds_report.txt: lidar_centerpoint, common_ground_filter, glog_component
"still loading after 238 s"), and the ground filter behind it never starts, so
the real occupancy grid is not produced either until the engine exists.

Not `ros2 topic pub` from the launch file: play_launch executes `executable`
actions during its dump and drops them from the run.
"""

OCCUPANCY_GRID_TOPIC = '/perception/occupancy_grid_map/map'
OBSTACLE_CLOUD_TOPIC = '/perception/obstacle_segmentation/pointcloud'


def grid_fields(resolution: float, width: int, height: int,
                origin_x: float, origin_y: float) -> dict:
    """Header-less fields of an all-free OccupancyGrid (0 = free)."""
    if resolution <= 0.0 or width <= 0 or height <= 0:
        raise ValueError(
            f'grid needs positive resolution/size, got {resolution} {width}x{height}')
    return {
        'resolution': float(resolution),
        'width': int(width),
        'height': int(height),
        'origin_x': float(origin_x),
        'origin_y': float(origin_y),
        'data': [0] * (int(width) * int(height)),
    }


def main() -> None:
    import rclpy
    from nav_msgs.msg import OccupancyGrid
    from rcl_interfaces.msg import ParameterDescriptor
    from rclpy.node import Node
    from rclpy.qos import DurabilityPolicy, QoSProfile, ReliabilityPolicy
    from sensor_msgs.msg import PointCloud2, PointField

    rclpy.init()
    node = Node('perception_stubs')
    dyn = ParameterDescriptor(dynamic_typing=True)
    for name, default in (('rate_hz', 10.0), ('grid_resolution', 0.5),
                          ('grid_width', 240), ('grid_height', 200),
                          ('grid_origin_x', -70.0), ('grid_origin_y', -45.0)):
        node.declare_parameter(name, default, dyn)
    get = lambda n: node.get_parameter(n).value  # noqa: E731
    fields = grid_fields(float(get('grid_resolution')), int(get('grid_width')),
                         int(get('grid_height')), float(get('grid_origin_x')),
                         float(get('grid_origin_y')))
    rate = float(get('rate_hz'))
    if rate <= 0.0:
        raise ValueError(f'rate_hz must be positive, got {rate}')

    # Reliable and volatile connects to both reliable and best-effort readers.
    qos = QoSProfile(depth=1, reliability=ReliabilityPolicy.RELIABLE,
                     durability=DurabilityPolicy.VOLATILE)
    grid_pub = node.create_publisher(OccupancyGrid, OCCUPANCY_GRID_TOPIC, qos)
    cloud_pub = node.create_publisher(PointCloud2, OBSTACLE_CLOUD_TOPIC, qos)

    def tick() -> None:
        now = node.get_clock().now().to_msg()
        g = OccupancyGrid()
        g.header.stamp = now
        g.header.frame_id = 'map'
        g.info.resolution = fields['resolution']
        g.info.width = fields['width']
        g.info.height = fields['height']
        g.info.origin.position.x = fields['origin_x']
        g.info.origin.position.y = fields['origin_y']
        g.info.origin.orientation.w = 1.0
        g.data = fields['data']
        grid_pub.publish(g)

        c = PointCloud2()
        c.header.stamp = now
        c.header.frame_id = 'base_link'
        c.height = 1
        c.width = 0
        c.fields = [PointField(name=k, offset=4 * i, datatype=PointField.FLOAT32, count=1)
                    for i, k in enumerate('xyz')]
        c.point_step = 12
        c.row_step = 0
        c.is_dense = True
        c.is_bigendian = False
        c.data = b''
        cloud_pub.publish(c)

    node.create_timer(1.0 / rate, tick)
    node.get_logger().warn(
        'perception is OFF: publishing an all-free occupancy grid and an empty '
        'obstacle cloud. There is no obstacle detection; the driver is the detector.')
    try:
        rclpy.spin(node)
    except KeyboardInterrupt:
        pass
    finally:
        node.destroy_node()
        rclpy.try_shutdown()


if __name__ == '__main__':
    main()
