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
    reliability: reliable        # default is best_effort; see below
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

Read the consumer before choosing; instinct is wrong here. The ZED IMU is
reliable because `imu_corrector` subscribes reliable and the wrapper
publishes reliable, `/diagnostics` because `diagnostic_aggregator` does,
`/tf` and `/tf_static` because tf2 does. `/tf_static` is also
`transient_local` with a depth that covers every static publisher on the
source host, since the bridge's one publisher has to hold all their latched
samples for a listener that starts later.

`max_hz` drops samples to hold a rate on the wire. It is the knob for an
image: the ZED's compressed stream is ~6.5 MB/s at 30 Hz, half the link, and
`max_hz: 2` makes it a preview.

## What it costs

Measured in `scripts/testing/link_sim` (two network namespaces, one veth
shaped to 100 Mbit/s, the real master stack): the ZED IMU crosses two bridges
and reaches `imu_corrector` at 99.7 Hz, and gyro_odometer produces twist from
it, which means the IMU `/tf` lane arrived too. Every 10 s each lane logs
`forwarded=` and `throttled=` counts.

Two of the lanes in `config/link/topics.yaml` exist because running the real
stack against the bridge showed they were wrong or missing: the IMU has to be
`reliable` (the wrapper publishes reliable, `imu_corrector` subscribes
reliable; a best_effort lane was invisible to the consumer, and the bridge
said so: `requesting incompatible QoS`), and the ZED's dynamic `/tf` has to
cross or gyro_odometer drops every IMU sample without a word.

A type whose support library this host lacks (`zed_msgs` on a master without
the ZED SDK) is logged as an error and skipped; the other lanes run.

## Why not ros2/domain_bridge

It would do. It is not in this workspace, and this is 300 lines with the one
feature it lacks that matters here, the per-topic rate cap. If it grows past
that, switch.
