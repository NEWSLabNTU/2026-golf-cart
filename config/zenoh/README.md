# Zenoh middleware (`GOLFCART_RMW=zenoh`)

`rmw_zenoh_cpp` as an alternative to CycloneDDS, selected per host by
`GOLFCART_RMW` in [`config/runtime.conf`](../runtime.conf).

Nothing here is measured against CycloneDDS yet. It is set up, verified to carry
topics on one host, and ready for the two-machine run.

## Why

Under `GOLFCART_CONTAINER_MODE=isolated`, CycloneDDS discovery measured at ~76%
of all CPU samples across 149 participants — see
[`docs/research/system/where-the-orin-cpu-goes.md`](../../docs/research/system/where-the-orin-cpu-goes.md).
That cost is O(N²) in participant count and is paid entirely in Cyclone's own
threads. Zenoh carries data over TCP with a different discovery mechanism, so
the curve should have a different shape. Whether it does is the question this
setup exists to answer.

## Topology: a peer clique discovered by multicast — no router

```
master 192.168.125.100                    orin 192.168.125.101
┌────────────────────────────┐          ┌────────────────────────────┐
│ ROS processes  mode:peer   │          │ ROS processes  mode:peer   │
│ listen tcp/…125.100:0      │          │ listen tcp/…125.101:0      │
└─────────────┬──────────────┘          └──────────────┬─────────────┘
              └────────── direct peer links ───────────┘
                       (discovery AND data)

     multicast scouting on 224.0.0.224:7446 — how peers find each other
```

Deliberately the same shape as the CycloneDDS deployment it replaces: multicast
discovery, then direct point-to-point links. **No `rmw_zenohd` runs anywhere.**

### Why there is no router

rmw_zenoh's documented arrangement is one router per host, because it ships with
`scouting.multicast.enabled: false` — which leaves router gossip as the only way
a node can learn that other nodes exist. That is a default, not an architectural
requirement. Zenoh has had Cyclone's SPDP-style multicast discovery all along.

Measured on the master, single host, talker/listener over 25 s:

| | published | heard | duplicated |
|---|---|---|---|
| router up, multicast off (stock) | 25 | 25 | 0 |
| **no router, multicast on** | 26 | 26 | 0 |

The router-less run also does not emit the `Scouting delay elapsed before start
conditions are met` warning that every node logs under the router arrangement.

Dropping the router removes a failure mode, not just a process. With a router
configured but absent, nodes do not fail and do not hang — they start, publish,
and are discovered by nobody, behind one log line saying "Proceeding with
initialization".

A two-router federation was also built and tested before this was settled on. It
works and does **not** duplicate samples (checked with one router, two routers
same side, and two routers split — all delivered exactly once). It was dropped
because it bought nothing over multicast here.

### `routing.peer.mode` stays `peer_to_peer`

That is Zenoh's **clique** topology — every peer linked directly to every other.
"Clique" is the name Zenoh's documentation gives the topology, not a value the
config accepts; the accepted values are `"peer_to_peer"` and `"linkstate"`, as
the comment above that key in each generated profile says. `peer_to_peer` is
already the shipped default, so it is not among the edits below.

The cost of a clique: links scale with the square of the **process** count.
Process, not node — rmw_zenoh opens one session per context, and
`GOLFCART_CONTAINER_MODE=observable` keeps composable nodes inside their
container's session. Under `isolated` the same mesh is drawn between ~149
processes, which is the shape of the problem that made CycloneDDS unusable in
the first place. **Do not pair `GOLFCART_RMW=zenoh` with
`GOLFCART_CONTAINER_MODE=isolated` without expecting that.**

## The profiles

Generated, not hand-written — `scripts/zenoh/generate_profiles.sh`. Both differ
from rmw_zenoh's shipped session default by exactly three keys:

| key | stock | here | why |
|---|---|---|---|
| `scouting.multicast.enabled` | `false` | `true` | the whole point; without it nothing discovers anything |
| `connect.endpoints` | `["tcp/localhost:7447"]` | `[]` | no router to connect to; stock would retry forever |
| `listen.endpoints` | `["tcp/localhost:0"]` | `["tcp/<LAN ip>:0"]` | stock advertises `127.0.0.1`, unreachable from the other host |

Binding the *specific* LAN address rather than `0.0.0.0` keeps the LiDAR nets
(`192.168.7.1`, `172.168.1.1`) and the 4G NIC out of the advertised locator set,
so a remote peer does not spend a connect timeout on each unreachable address.

**There is no loopback profile, deliberately.** `scripts/env.sh` leaves
`ZENOH_SESSION_CONFIG_URI` *unset* for that role, so single-machine operation
gets rmw_zenoh's shipped defaults — which means it still expects a router.
Single-machine zenoh is not a path this repo has set up; the two-host profiles
are.

### Why full copies rather than short overrides

Zenoh fills every absent key from **its own** defaults, which are not
rmw_zenoh's — so a short profile listing only the three keys above would
silently discard the SHM transport-optimization sizing, the 600 s query timeout,
and everything else rmw_zenoh tunes. Each profile is therefore the whole shipped
file with a named set of edits, listed in its own header.

`just rmw check` fails if the generated files have drifted from the installed
`ros-humble-rmw-zenoh-cpp` — run it after upgrading that package, then
`just rmw regen`.

## The failure modes

**A ros2 daemon from the other middleware.** ros2cli's daemon binds its RMW at
startup, and its XML-RPC port is `11511 + ROS_DOMAIN_ID` with *no RMW in it* —
so a CycloneDDS daemon and a Zenoh daemon claim the same port and the CLI talks
to whichever got there first. After switching `GOLFCART_RMW`, a leftover daemon
makes `ros2 topic list`, `ros2 node list`, `ros2 topic hz` and `ros2 topic echo`
all report an empty graph while the stack runs perfectly. Every instrument you
would reach for points at the launch instead of at the CLI.

**An interface without MULTICAST, or without the expected address.** Discovery
is multicast now, so if nothing owns the address the profile binds, or the
interface carrying it has no `MULTICAST` flag, every node starts, publishes and
discovers nobody with no error anywhere.

Both are gated by `scripts/rmw/ensure.sh`, which every launch and record path
calls.

```bash
just rmw daemon-stop    # after changing GOLFCART_RMW by hand
```

## Operating it

```bash
just rmw status         # middleware, config, listen address, multicast, daemon
just rmw peers          # what this host is actually linked to
just rmw regen / check  # profiles vs the installed rmw_zenoh defaults
just service doctor     # full diagnostic; middleware-aware
```

## Both hosts must agree

The two middlewares share no wire protocol. A master on zenoh and an orin on
cyclonedds do **not** fail — each comes up cleanly and never sees the other's
topics. `just service host-status` prints the effective middleware on both, and
it is the first thing to check when cross-host topics are missing.

## Known rough edges

**Graph convergence is slower than DDS.** A `ros2 topic list` run immediately
after a node starts can under-report — a publisher's liveliness token has to
reach the querying session over a peer link that may still be forming. Measured
on one host: reliable (8/8) once settled a few seconds, intermittently missing a
topic before that. Give it a moment before believing an empty list.

**Multicast on a shared segment.** `192.168.125.0/24` carries the 4G router and
whatever else is plugged into it, and `ROS_DOMAIN_ID` is unset — so any other
ROS 2 machine that joins this LAN on zenoh merges into this graph. The same
caveat already applies to the CycloneDDS profiles; see
[`config/cyclonedds/master.xml`](../cyclonedds/master.xml).

**Not yet tested across the two machines.** Everything above was measured on the
master alone.
