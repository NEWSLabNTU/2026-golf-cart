# Operating the cart

Run every command here on the **master**, in the repository directory. The
master starts and stops the orin for you over ssh.

## Start and stop

```bash
just up        # start both machines; returns at once
just logs      # follow this machine's log (Ctrl-C stops following, not the cart)
just down      # stop both machines
```

`just up` starts the stack as systemd services on both machines. Closing the
terminal or the ssh session does not stop the cart. **`just down` is the only
stop command.** It leaves a recording running; stop that with
`just record stop`, then `just record collect` (see [recording.md](recording.md)).

The play_launch web UI is at http://localhost:8081 on the master.

If the orin cannot be reached, `just up` still starts the master and prints a
warning. The vehicle interface runs on the orin, so **without the orin the cart
cannot be driven**.

## Launch arguments and argument files

Add launch arguments after the command, as `key:=value`:

```bash
just up map_path:=./data/ntu-campus-planning/r01
just up use_gnss:=false
```

`@name` reads a saved set of arguments from `config/launch/<name>.args`.
Arguments after it win:

```bash
just up @mingda-loop
just up @mingda-loop planning_speed_limit:=0.5
```

`just up` prints the final argument list before it starts anything.

Argument files for the cart (`just up @name`):

| file | for |
|---|---|
| `@basement` | supervised drive on the basement map: board start, no GNSS, 1.0 m/s, indoor planning |
| `@mingda` | supervised drive on the Ming-Da basement map: board start, no GNSS, 2.0 m/s, indoor planning |
| `@mingda-loop` | `@mingda` on the clockwise loop lane (`lanelet2_map_loop.osm`) |

Argument files for the simulators (`just sim planning @name`, `just sim aruco
@sim-aruco`; see [DEVELOPMENT.md](../DEVELOPMENT.md)):

| file | for |
|---|---|
| `@sim-basement` | planning simulator, basement map |
| `@sim-mingda` | planning simulator, Ming-Da map |
| `@sim-mingda-loop` | planning simulator, Ming-Da loop lane |
| `@sim-ntu-r01`, `@sim-ntu-r02` | planning simulator, NTU campus routes |
| `@sim-aruco` | ArUco localization in the planning simulator |

Each file starts with a comment that says what it does. To make your own, copy
one and edit it.

**With `@basement`, `@mingda` and `@mingda-loop`, perception is off. There is no
obstacle detection.** The driver is the obstacle detector.

## Choosing the map

`map_path:=` picks the map. The default is `./data/COSS-map-planning`.

```bash
just up map_path:=./data/ntu-campus-planning/r02
```

Getting and checking maps: [maps.md](maps.md).

## Setting the initial pose

Localization needs a starting pose. `pose_initializer:=` decides where it comes
from:

| value | starting pose from |
|---|---|
| `gnss` (default) | the GNSS fix (outdoors) |
| `board` | the reflective board in front of the cart (indoors; use with `use_gnss:=false`) |
| `none` | you: click *2D Pose Estimate* in RViz |

With `board`, if the first try fails, stop the cart with the board in view and
run `just pose board` to try again.

### Saved start spots

If GNSS puts the cart in the wrong place, save the start spot once and reuse it.

First time, parked on the spot:

```bash
just pose capture ntu-r02 gate   # click 2D Pose Estimate in RViz first, let it settle
```

Every time after, parked on the same spot:

```bash
just pose init ntu-r02 gate
```

You can also save a start **and** a goal by clicking them in RViz, then replay
both:

```bash
just pose listen ntu-r02 gate    # click 2D Pose Estimate, then 2D Goal Pose; Ctrl-C
just pose go ntu-r02 gate        # set the start, then the route. Does not engage.
just pose list                   # maps and saved spots
```

Spots are stored in `config/initial_poses/<map>/<spot>.yaml`.

## RViz

`just up` opens RViz on the master's screen when `DISPLAY` is set. To skip it:

```bash
just up rviz:=false
```

To open it later: `just tool rviz`. `just down` closes the RViz that `just up`
opened.

## Driving

Before any autonomous drive, follow
[guides/control_testing.md](guides/control_testing.md): roles, pre-drive checks,
and the engage order.

In short: the driver puts the cart in AUTO on the dashboard (brake pedal held,
then the AUTO button), and only then does the operator engage in RViz. To see
what the VCU reports:

```bash
just can vcu-status
```

Known VCU limits are listed in [hardware.md](hardware.md#the-vehicle-turing-drive-vcu).

## Logs

```bash
just logs                     # follow this machine's stack log
just service status           # unit states on both machines
```

The logs are kept across reboots on both machines. To read an older run, or the
orin's log:

```bash
journalctl --user -u golfcart-launch.service --since "1 hour ago"
./scripts/multi_machine/on_orin.sh journalctl --user -u golfcart-launch.service -n 100
```

## Troubleshooting

Start here:

```bash
just service doctor        # this machine: environment, network profile, units, disk
just service doctor-orin   # the orin
```

| symptom | try |
|---|---|
| `ros2 topic list` shows nothing, but the stack is running | open a new shell in the repository directory (or `source scripts/env.sh`), then `ros2 daemon stop` |
| `just up` says the unit failed to start | `just service doctor`; the services may not be installed yet (see [setup.md](setup.md)) |
| the orin is unreachable | check the cable and `ping 192.168.125.101`; then `just service doctor-orin` |
| the cart never localizes | check the initial pose; try `pose_source:=ndt` as a control run |
| no speed report (`/vehicle/status/velocity_status` silent) | is the orin up? is the cart powered on? `just can vcu-status` |
| no camera from the ZED | on the orin: `sudo service zed_x_daemon restart`, wait 25 s, then `just down` and `just up` |

Known open problems: [roadblocks.md](roadblocks.md). Deeper troubleshooting:
[multi-machine.md](multi-machine.md#troubleshooting).
