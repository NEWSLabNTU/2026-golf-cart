# golfcart_domain_bridge

The one participant each host puts on the master/orin wire.

Under `host:=master` and `host:=orin` the CycloneDDS profiles bind ROS domain 0
to `lo` and only the link domain (`GOLFCART_LINK_DOMAIN_ID`, 42) to the LAN
interface. Nothing in the stack can reach the other machine. This process
holds one node in each domain and copies the topics listed in
`config/link/topics.yaml` between them, in the direction the file gives, as
serialized bytes. It never deserializes a message.

```
domain 0 on lo                 link domain on the LAN                 domain 0 on lo
┌──────────────────────┐      ┌────────────────────────────┐      ┌─────────────────────┐
│ orin stack (ZED, ...)│ ──▶  │ bridge(orin) ── bridge(master)│ ──▶│ master stack        │
│ /sensing/camera/zed/…│      │  the only two participants │      │ gyro_odometer, agg… │
└──────────────────────┘      └────────────────────────────┘      └─────────────────────┘
```

## Running

The launch starts it: `golfcart.launch.yaml` has a `node:` entry gated on
`host` being `master` or `orin`. By hand, for a host whose stack is not up:

```bash
just link bridge                                       # role from config/host
ros2 run golfcart_domain_bridge domain_bridge --role orin --config config/link/topics.yaml
```

Arguments, each with an environment fallback that `scripts/env.sh` exports:

| flag | env | meaning |
|---|---|---|
| `--role master\|orin` | `GOLFCART_HOST` | which end this is; decides direction |
| `--config PATH` | `GOLFCART_LINK_TOPICS` | the topic list |
| `--internal-domain N` | `ROS_DOMAIN_ID` (0) | the stack's domain |
| `--link-domain M` | `GOLFCART_LINK_DOMAIN_ID` (42) | the wire's domain |

Anything after `--ros-args` goes to rclcpp, which is how play_launch's node
name remap reaches it. Both nodes then carry that name; they are in different
domains and never meet.

## The list

`config/link/topics.yaml`, one file for both hosts:

```yaml
orin_to_master:
  - topic: /sensing/camera/zed/imu/data
    type: sensor_msgs/msg/Imu
    reliability: best_effort     # default
    durability: volatile         # default
    depth: 10                    # default
    max_hz: 0                    # default: every sample
master_to_orin: []
```

The orin's bridge publishes `orin_to_master` into the link and subscribes to
`master_to_orin` out of it; the master's does the reverse. A topic in both
lists is refused at startup: it would be re-published into the domain it came
from and sent back forever.

QoS applies to both ends of a lane. Two matches have to hold, and they pull
in opposite directions:

- the bridge's *subscription* against the source publisher: a reliable
  subscription matches only a reliable publisher; best_effort matches both;
- the bridge's *publisher* against the far consumers: a best_effort publisher
  is invisible to a reliable subscriber.

So sensor streams are best_effort (their Autoware consumers use
SensorDataQoS, and a lost IMU sample is cheaper than a retransmit storm on a
100 Mb/s link), and `/diagnostics` and `/tf_static` are reliable because
`diagnostic_aggregator` and tf2 subscribe reliable. `/tf_static` is also
`transient_local` with a depth that covers every static publisher on the
source host, since the bridge's one publisher has to hold all their latched
samples for a listener that starts later.

`max_hz` drops samples to hold a rate on the wire. It is the knob for an
image: the ZED's compressed stream is ~5 MB/s at 15 Hz, half the link, and
`max_hz: 2` makes it a preview.

## What it costs

Measured in `scripts/testing/link_sim` (two network namespaces, one veth, the
real profiles): the IMU crosses two bridges at 100.0 Hz with 0.17 ms mean and
0.4 ms p99 added latency. Every 10 s each lane logs `forwarded=` and
`throttled=` counts.

A type whose support library this host lacks (`zed_msgs` on a master without
the ZED SDK) is logged as an error and skipped; the other lanes run.

## Why not ros2/domain_bridge

It would do. It is not in this workspace, and this is 300 lines with the one
feature it lacks that matters here, the per-topic rate cap. If it grows past
that, switch.
