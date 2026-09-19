# RViz throttle relays

RViz is the single largest CPU consumer on the Orin when it runs on the
vehicle — 63.86% of a core on average, larger than the entire sensing pipeline
(`docs/research/system/where-the-orin-cpu-goes.md`, Finding 3). Almost none of
that is rendering: it is JPEG decode of three camera streams at 30 Hz and
`PointCloud2` deserialization of two LiDARs at 10 Hz, done once per subscribed
display. Halving the rate RViz *ingests* halves that decode cost without
turning any display off and without touching what the rest of the stack
receives.

## What is throttled, and what is not

Five `topic_tools::ThrottleNode` composables, all loaded into one
`rviz_relay_container` (`golfcart_launch/launch/rviz_relay.launch.xml`),
republish each source topic at half rate under a `/rviz/...` mirror:

| source (unchanged) | relay topic (what RViz subscribes to) | rate |
|---|---|---|
| `/sensing/camera/left/image_raw/compressed` | `/rviz/sensing/camera/left/image_raw/compressed` | 30 &rarr; 15 Hz |
| `/sensing/camera/right/image_raw/compressed` | `/rviz/sensing/camera/right/image_raw/compressed` | 30 &rarr; 15 Hz |
| `/sensing/camera/rear/image_raw/compressed` | `/rviz/sensing/camera/rear/image_raw/compressed` | 30 &rarr; 15 Hz |
| `/sensing/lidar/vlp32/velodyne_points` | `/rviz/sensing/lidar/vlp32/velodyne_points` | 10 &rarr; 5 Hz |
| `/sensing/lidar/falcon/iv_points` | `/rviz/sensing/lidar/falcon/iv_points` | 10 &rarr; 5 Hz |

Rates live in `golfcart_launch/config/rviz/relay.param.yaml`, the only thing
here that is tuning rather than wiring.

**The source topics are never touched.** `ThrottleNode` subscribes to the
compressed image and the serialized `PointCloud2` and republishes the same
bytes at a lower rate — it never decodes a JPEG or deserializes a cloud, so the
relay itself costs almost nothing to run. Recording, the concatenator,
perception, and anything else already subscribed to the driver topics keep the
full 30 Hz / 10 Hz stream, unaffected by whether RViz or the relay is even
running.

**What stayed as it was, deliberately:**

- `Global Options / Frame Rate` (30 in every `.rviz` file) — that governs
  RViz's own render loop, not message ingest, and was not asked to change.
- `Topic / Depth` and `Reliability Policy` on every repointed display — still
  5 and Best Effort, matching what the relay itself publishes (see below).
- `/perception/obstacle_segmentation/pointcloud`, the concatenated cloud, the
  NDT and map displays, and `camera6` (a Debug-group `Camera` display fed from
  a different topic) — out of scope, left pointed at their original topics.
- The ZED X display in `replay.rviz` — the ZED camera is out of scope for this
  change.
- `golfcart_ntu.rviz` — it has no display on any of the five source topics (no
  raw LiDAR `PointCloud2`, no per-camera `Image` display), so there was
  nothing to repoint.

## Why one container, and why no QoS override

Five standalone `topic_tools throttle` processes would each pay the roughly
4.9% of a core that a do-nothing standalone ROS 2 process costs just for
existing as its own DDS participant (`where-the-orin-cpu-goes.md`, Finding 1);
composed into one container they pay that cost once. All five are
`topic_tools::ThrottleNode` (Humble 1.1.2), which registers as an
`rclcpp_components` plugin — confirmed against this machine's own install:

```
$ cat /opt/ros/humble/share/ament_index/resource_index/rclcpp_components/topic_tools
topic_tools::ThrottleNode;lib/libthrottle_node.so
```

The camera and LiDAR drivers publish best-effort. A relay that subscribed
reliable would receive nothing. `ThrottleNode` does not need a manual
`qos_overrides` parameter to get this right: its base class,
`topic_tools::ToolBaseNode` (`topic_tools/tool_base_node.hpp`, installed
headers), discovers the source's actual QoS via
`get_publishers_info_by_topic()` and subscribes with whatever it finds,
polling every 100 ms until a publisher appears. It is graph-driven rather than
configured, so it stays correct if a driver restarts after the relay does.

`ThrottleNode` can also be a *lazy* tool node: `ToolBaseNode`'s subscribe/
unsubscribe decision checks its own output publisher's subscriber count and
only opens the upstream subscription once something is actually listening on
the `/rviz/...` topic. It is **not** lazy by default — the `lazy_` member
(`tool_base_node.hpp`) is backed by a `lazy` parameter whose compiled-in
default is `false`, which was confirmed on a running relay: `ros2 param get
/falcon_relay lazy` read `False`, and the source subscription stayed open for
over 8 seconds with zero subscribers on the relay's own output. Every
composable node in `rviz_relay.launch.xml` sets `lazy:=true` explicitly, and
with it set, a relay nobody has pointed RViz at costs a periodic graph check,
not a running subscription — which is why the container is safe to include
unconditionally wherever it is included, rather than needing its own enable
flag.

## Where it is wired in, and where it is not

The relay is included from `golfcart_autoware.launch.xml`, gated by the same
`rviz` argument as the `rviz2` node it sits next to — so `golfcart.launch.yaml`,
`logging_simulation.launch.yaml`, `indoor_logging_sim.launch.xml` and
`ntu_logging_sim.launch.xml` all get it automatically when `rviz:=true`,
without any change to those files, because all four already include
`golfcart_autoware.launch.xml`. `bag_replay.launch.xml` does not go through
that file — it plays a bag directly — so it includes `rviz_relay.launch.xml`
itself, next to its own `rviz2` node, with `use_sim_time:=true` hardcoded (it
has no `autoware_global_parameter_loader` group to set that globally the way
the other four do).

**Two RViz launches in this repo are standalone and do NOT go through
`golfcart_autoware.launch.xml`'s gate, so the relay is not started for them
automatically:**

- `just tool rviz` (`just/tool.just`) — a bare `rviz2 -d golfcart.rviz`.
- The indoor-test and ntu-test `rviz` step (`just indoor-test rviz`,
  `scripts/rosbag/indoor_sim_rviz.sh` / `ntu_sim_rviz.sh`) — these start RViz
  as its own process, deliberately separate from `indoor_logging_sim.launch.xml`
  / `ntu_logging_sim.launch.xml` (which run with `rviz:=false`), so RViz comes
  up on bag time instead of racing the stack.

For either case, start the relay yourself in a spare terminal:

```bash
just tool rviz-relay                       # against a live or logging_simulation stack
just tool rviz-relay use_sim_time:=true    # against a bag replay (indoor-test, ntu-test)
```

Without it those displays are not broken — they just show nothing, the same
as any display pointed at a topic nobody is publishing.

## How to verify

The whole point is that the source rate is unaffected. Check both sides:

```bash
# Source topics: must stay at their native rate, relay running or not
ros2 topic hz /sensing/camera/left/image_raw/compressed    # ~30 Hz
ros2 topic hz /sensing/camera/right/image_raw/compressed   # ~30 Hz
ros2 topic hz /sensing/camera/rear/image_raw/compressed    # ~30 Hz
ros2 topic hz /sensing/lidar/vlp32/velodyne_points          # ~10 Hz
ros2 topic hz /sensing/lidar/falcon/iv_points                # ~10 Hz

# Relay topics: only publish once RViz (or anything else) subscribes,
# and then at half the source rate
ros2 topic hz /rviz/sensing/camera/left/image_raw/compressed  # ~15 Hz
ros2 topic hz /rviz/sensing/lidar/vlp32/velodyne_points        # ~5 Hz
```

If a `/rviz/...` topic reports 0 Hz with RViz open and the display enabled,
check that the relay container is actually up
(`ros2 node list | grep rviz_relay`) before suspecting the throttle itself —
on the two standalone paths above, it is not started for you.
