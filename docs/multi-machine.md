# Multi-Machine Operation (master + orin)

How to run the golf cart stack across its two machines. For why it is built this
way, see [design/multi_machine_deployment.md](design/multi_machine_deployment.md).

## The two hosts

| | address | interface | runs |
|---|---|---|---|
| master | `192.168.125.100` | `enP5p3s0` | the whole Autoware stack, plus the wired sensors (Velodyne, Falcon, GNSS, IMU, USB cameras) |
| orin | `jetson@192.168.125.101` | `eno1` | the ZED X camera only |

Both sit on the shared 4G LAN, which negotiates **100 Mb/s**. That is the reason
each host records to its own disk instead of streaming images across.

## Daily operation

Everything runs from the master:

```bash
just launch-master                  # master stack + the orin's ZED, started over ssh
just launch-master "record:=true"   # the same, with both hosts recording locally
```

Stopping the master (Ctrl-C, or play_launch's stop button) stops the orin too.
Bags land in `~/rosbags/master_<ts>` and `~/rosbags/orin_<ts>` on their respective
machines; override the directory with `GOLFCART_BAG_DIR`.

Single-machine operation is untouched:

```bash
just launch                         # host:=all, loopback DDS, nothing remote
GOLFCART_USE_ORIN=0 just launch-master   # master alone, without touching the orin
```

To drive the orin by hand:

```bash
./scripts/multi_machine/orin_remote.sh start [true|false]   # the argument enables recording
./scripts/multi_machine/orin_remote.sh status
./scripts/multi_machine/orin_remote.sh stop
```

## What stops the orin, and when

| Failure | What stops it | How long |
|---|---|---|
| Master stopped normally | `launch-master`'s EXIT trap runs `orin_remote.sh stop` over ssh | immediate |
| Master killed, network up | the same trap, if the shell survives; otherwise the watchdog | immediate, or ~42s |
| Network cut, or master powered off | the orin's own watchdog stops the unit locally | ~42s |

`KillMode=control-group` in the unit is what makes the no-orphan guarantee hold —
it kills everything play_launch spawned, not just the main process.

The orin is never enabled at boot. It is started on demand, because an orin that
launches its ZED with no master to talk to is just a warm camera.

## One-time provisioning of the orin

```bash
# On the orin:
cd ~/2026-golf-cart
./setup/scripts/install-orin-host.sh      # systemd user units + lingering
./setup/scripts/configure-cyclonedds-sysctl.sh
colcon build --base-paths src --symlink-install \
    --cmake-args -DCMAKE_BUILD_TYPE=Release

# On the master, once:
ssh-copy-id jetson@192.168.125.101
```

Key-based ssh is required, not optional: the orchestrator runs non-interactively
and cannot answer a password prompt.

## Troubleshooting

**`rmw_create_node: failed to create domain`, and `failed to increase socket
receive buffer size`.** The ZED SDK installs
`/etc/sysctl.d/60-zed-buffers.conf` with `net.core.rmem_max=1048576`, which sorts
after and undercuts our setting. Our DDS profiles require a 10 MB minimum, so
CycloneDDS refuses to start at all — on every profile, loopback included. Re-run
`./setup/scripts/configure-cyclonedds-sysctl.sh`, which writes
`99-cyclonedds-max.conf`. Re-run it any time the SDK is reinstalled.

**`InvalidHandle: cannot use Destroyable because destruction was requested`.**
A `ros2` daemon started under a different `CYCLONEDDS_URI` is still running. Run
`ros2 daemon stop`, or pass `--no-daemon` (note `ros2 topic hz` does not accept
it).

**The orin's unit fails with `libexec directory ... does not exist`.** Its
workspace has not been rebuilt since the recorders were added. Run `colcon build`
there.

**`git pull` on the orin fails with "correct access rights".** Its remote is
`git@github.com:...` and a non-interactive ssh session carries no agent. Pull
from an interactive shell on the orin.

**Nothing is discovered between the hosts.** Check the profile actually in use —
`launch-master` and `launch-orin` set `CYCLONEDDS_URI` themselves, but a plain
shell falls back to `.envrc`, which defaults to `loopback`. Set
`GOLFCART_DDS_PROFILE=master` (or `orin`) for manual work.

## Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `GOLFCART_DDS_PROFILE` | `loopback` | which `config/cyclonedds/<name>.xml` `.envrc` exports |
| `GOLFCART_USE_ORIN` | `1` | set to `0` to run the master without the orin |
| `GOLFCART_ORIN_SSH` | `jetson@192.168.125.101` | ssh destination for the orin |
| `GOLFCART_ORIN_WAIT` | `60` | seconds to wait for the orin before giving up |
| `GOLFCART_MASTER_IP` | `192.168.125.100` | what the orin's watchdog pings |
| `GOLFCART_BAG_DIR` | `~/rosbags` | where each host writes its bags |
| `GOLFCART_WORKSPACE` | `~/2026-golf-cart` | workspace the orin's unit launches from |
