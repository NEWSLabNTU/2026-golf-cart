# Zenoh middleware (`GOLFCART_RMW=zenoh`)

`rmw_zenoh_cpp` as an alternative to CycloneDDS, selected per host by
`GOLFCART_RMW` in [`config/runtime.conf`](../runtime.conf).

Nothing here is measured yet. It is set up, verified to carry topics on one
host, and ready for the two-machine run.

## Why

Under `GOLFCART_CONTAINER_MODE=isolated`, CycloneDDS discovery measured at ~76%
of all CPU samples across 149 participants — see
[`docs/research/system/where-the-orin-cpu-goes.md`](../../docs/research/system/where-the-orin-cpu-goes.md).
That cost is O(N²) in participant count and is paid entirely in Cyclone's own
threads. Zenoh moves discovery to a router and carries data over TCP, so the
curve should have a different shape. Whether it does is the question this setup
exists to answer.

## Topology: peer mesh over the LAN

```
master 192.168.125.100                    orin 192.168.125.101
┌────────────────────────────┐          ┌────────────────────────────┐
│ ROS processes  mode:peer   │          │ ROS processes  mode:peer   │
│ listen tcp/…125.100:0      │          │ listen tcp/…125.101:0      │
│        ↕ discovery         │          │        ↕ discovery         │
│ rmw_zenohd   :7447         │◄─────────│ rmw_zenohd   :7447         │
│ gossip multihop            │  connect │ gossip multihop            │
└─────────────┬──────────────┘          └──────────────┬─────────────┘
              └────────── direct peer links ───────────┘
                            (all data)
```

The routers carry **discovery only**. Data goes point-to-point between peers, on
both hosts and across them.

### Why not client mode

rmw_zenoh's README documents the other arrangement — nodes in `mode:"client"`
with the routers brokering every message — and explains that it is needed
because *"Zenoh router doesn't forward messages between peers"*. That is true and
it is the well-trodden path, but it puts an extra process hop on traffic where
**both ends are on the same box**, which on the master is every point cloud in
the preprocessing and concatenation chain. Peers keep the direct path.

The cost of the choice is a **full mesh**: peers autoconnect to peers, so links
scale with the square of the *process* count. Process, not node — rmw_zenoh
opens one session per context, and `GOLFCART_CONTAINER_MODE=observable` keeps
composable nodes inside their container's session. Under `isolated` the same
mesh is drawn between ~149 processes, which is the shape of the problem that
made CycloneDDS unusable in the first place. **Do not pair
`GOLFCART_RMW=zenoh` with `GOLFCART_CONTAINER_MODE=isolated` without expecting
that.**

If the mesh turns out to be the bottleneck, client mode is the fallback, and it
is two keys: `mode:"client"` in the session profiles, and reverting
`listen.endpoints` to `tcp/localhost:0`.

## The profiles

Generated, not hand-written — `scripts/zenoh/generate_profiles.sh`:

| file | role | differs from the shipped default by |
|---|---|---|
| `master-router.json5` | master `rmw_zenohd` | gossip multihop |
| `orin-router.json5` | orin `rmw_zenohd` | gossip multihop; `connect.endpoints` → master |
| `master-session.json5` | every ROS process on master | gossip multihop; `listen.endpoints` → `192.168.125.100:0` |
| `orin-session.json5` | every ROS process on orin | gossip multihop; `listen.endpoints` → `192.168.125.101:0` |

**There is no loopback profile, deliberately.** Single-machine operation wants
exactly rmw_zenoh's shipped defaults, and `scripts/env.sh` leaves
`ZENOH_SESSION_CONFIG_URI` and `ZENOH_ROUTER_CONFIG_URI` *unset* for that role.
An unset variable cannot drift when the package is upgraded; a checked-in
byte-identical copy can.

### Why full copies rather than short overrides

Zenoh fills every absent key from **its own** defaults, which are not
rmw_zenoh's. Most importantly, upstream Zenoh defaults `scouting.multicast.enabled`
to *true* and rmw_zenoh sets it to *false*. A short profile listing only the keys
we care about would silently re-enable multicast discovery on a LAN shared with a
4G router and whatever else is plugged into it. So each profile is the whole
shipped file with a named set of edits, and the header of each generated file
lists exactly what those edits were.

`just rmw check` fails if the generated files have drifted from the installed
`ros-humble-rmw-zenoh-cpp` — run it after upgrading that package, then
`just rmw regen`.

## Two things that fail silently

Both are gated by `scripts/rmw/ensure.sh`, which every launch and record path
calls. Neither produces an error on its own.

**No router.** rmw_zenoh ships with multicast scouting off, so gossip from the
local router is the *only* way a node learns other nodes exist. Without one,
every node starts, publishes, and is discovered by nobody. The one warning it
prints says "Proceeding with initialization" and scrolls past in a launch that
emits thousands of lines.

**A ros2 daemon from the other middleware.** ros2cli's daemon binds its RMW at
startup, and its XML-RPC port is `11511 + ROS_DOMAIN_ID` with *no RMW in it* —
so a CycloneDDS daemon and a Zenoh daemon claim the same port and the CLI talks
to whichever got there first. After switching `GOLFCART_RMW`, a leftover daemon
makes `ros2 topic list`, `ros2 node list`, `ros2 topic hz` and `ros2 topic echo`
all report an empty graph while the stack runs perfectly. Every instrument you
would reach for points at the launch instead of at the CLI.

```bash
just rmw daemon-stop    # after changing GOLFCART_RMW by hand
```

## Operating it

```bash
just rmw status         # middleware, config paths, router, daemon state
just rmw router         # run this host's router in the foreground
just rmw peers          # what this host is actually linked to
just rmw regen / check  # profiles vs the installed rmw_zenoh defaults
just service doctor     # full diagnostic; middleware-aware
```

`just launch` starts the router itself via `golfcart-zenoh-router.service` when
the unit is installed (`just service install master`), and refuses to launch
without one when it is not.

## Both hosts must agree

The two middlewares share no wire protocol. A master on zenoh and an orin on
cyclonedds do **not** fail — each comes up cleanly and never sees the other's
topics. `just service host-status` prints the effective middleware on both, and
it is the first thing to check when cross-host topics are missing.

## Known rough edge

Graph convergence is slower than DDS. A `ros2 topic list` run immediately after
a node starts can under-report — a publisher's liveliness token has to reach the
querying session over a peer link that may still be forming. Measured on one
host: reliable (8/8) once things have settled a few seconds, intermittently
missing a topic before that. Give it a moment before believing an empty list.
