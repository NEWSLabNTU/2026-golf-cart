# Running the Isaac twin demo

The cart's own Autoware drives the golf cart in the NTU campus twin on Isaac Sim. The drive
makes one or two turns at the T junction in front of 學新館. The plan and its runs are in
[roadmap 10](../roadmaps/10-isaac-twin-demo.md).

This page assumes newslab-118-server, which is already set up. Run every command from the
repository root. For another host, see [Setting up a new host](#setting-up-a-new-host).

## Before you start

1. Open a VNC viewer on `newslab-118-server:9`. Isaac's window and RViz open there.
2. Check that the host is quiet. The sim slows down with the host: on 2026-11-07 another job's
   load dropped it to 0.2x real time.
   ```bash
   uptime        # load average well under 48
   nvidia-smi    # GPU 0 free: no other large process on it
   ```
3. Check that nothing of the demo is up: no `play_launch` of yours is running.
   ```bash
   pgrep -u $USER -x play_launch    # prints nothing
   ```

## Start

Open three terminals at the repository root. Source the demo's environment in each one: it
sources Autoware, swb and this repository, and sets the ROS domain and the DDS profile that
both sides share.

```bash
source scripts/twin/setup.bash
```

It is a bash script: in zsh or fish, run `bash` first. A virtualenv's `python3` on `PATH` would
hide ROS's, so it takes such directories out of `PATH` in that terminal and says so.

It prints the domain, the map, Isaac's install and the display:
`twin: domain 11, map /mnt/renegade/aeon/ntu-twin/map, Isaac /mnt/renegade/aeon/isaac-sim, display :9`.

**Terminal 1: Isaac Sim and the cart** (2 to 3 min)

```bash
play_launch launch golfcart_twin twin_world.launch.py route:=1
```

Isaac's window opens on the display with the campus and the cart on the road at route 1's
start, and its view follows the cart. The node log ends with `sensors warm` when the cart is
ready:

```
ego newslab_golfcart ... at (480.25, 148.25, 11.93); sensors warm
```

Its arguments: `route` (1 to 4), `render` (`auto`: a window when `DISPLAY` is set; `window`
or `headless`), `map_path` (default `$TWIN_MAP`), `gpu` (default `$TWIN_GPU`).

The cart is this repository's: `golfcart_twin/vehicle/newslab_golfcart.yaml` (its spec) and
`golfcart_twin/isaac/` (aib's ego config, the rig generated from the spec, the body and the
lidar profiles, all committed). scenario-world-bridge provides only the Isaac runner
(`aib_launch isaac_vehicle.launch.xml`). After changing the spec, `make_lidars.py` or the
body tools, run `just twin generate` and commit what it writes; `just twin generate --check`
tells whether the rig is stale.

**Terminal 2: the cart's Autoware and RViz** (about 1 min)

```bash
play_launch launch --web-addr 127.0.0.1:8081 golfcart_twin twin_autoware.launch.xml
```

Each play_launch serves a web UI, and terminal 1's took the default port 8080: give this one
its own, or it runs without one. The web UIs are at http://127.0.0.1:8080 (the world) and
http://127.0.0.1:8081 (Autoware).

RViz opens looking straight down on the T junction, north up:

- the lanes are drawn in white;
- the cart sits at its start;
- lidar points surround it;
- the camera image is in the image dock.

Localization initializes itself from the GNSS. The sim plays the cart's u-blox RTK receiver
as a fixed RTK solution at 1 Hz with no noise. Autoware's automatic pose initializer retries
until the GNSS fix and the map are in. Its log shows `The GNSS pose has not arrived` or
`align server failed` once or twice, and this is normal. Within about 10 s of the start, the
Autoware state panel shows the localization as initialized and the operation mode as STOP.
The same holds when only Autoware is restarted, wherever the cart stands.

## Drive

**By hand, in RViz:**

1. Choose **2D Goal Pose** on the toolbar.
2. Press on the route's goal in the picture below, and drag along its arrow to give the
   direction. The planned route and trajectory appear.
3. Press **AUTO** in the Autoware state panel's operation mode. The cart drives off and stops
   at the goal.

![Where to set each route's goal in RViz](images/isaac_twin_routes.png)

The goals, in words:

| Route | Goal |
|---|---|
| 1 | on the north-south road, northbound, about 50 m north of the T |
| 2, 4 | on the east-west road, westbound, about 30 m west of the T |
| 3 | on the north road, westbound, about 45 m west of the north junction |

**Or by script, in terminal 3.** It waits for localization, sets the goal, engages, and
reports until the cart arrives:

```bash
ros2 run golfcart_twin twin_go.py 1
```

It ends with `arrived in 65.8 s, 0.76 m from the goal`.

## Routes

From `src/simulation/golfcart_twin/config/routes.yaml`. Each route is checked against the
twin's lanes, and each stays on scanned ground.

| Route | What it does | Turns | Length |
|---|---|---|---|
| 1 | from the west, left at the T, north | 1 | 89.5 m |
| 2 | from the north, right at the T, west | 1 | 92.1 m |
| 3 | from the west, left at the T, left again at the north junction, west | 2 | 163.6 m |
| 4 | the north road eastbound, right to the south, right again at the T, west | 2 | 135.8 m |

The cart drives at up to 2.5 m/s; route 1 takes under a minute. Route 4's first right turn
is tight: its radius is 4.5 m, against the cart's 3.6 m minimum.

To drive another route, start again from that route's start: stop both launches, then start
terminal 1 with `route:=3` and terminal 2 as before.

## Stop

Press Ctrl-C in terminal 2 (Autoware), then in terminal 1 (Isaac Sim). Each play_launch
stops its nodes and exits.

## Recipes

`just twin` runs the same launches in the background, with logs in `log/twin/`:

```bash
just twin world 1     # terminal 1's launch
just twin autoware    # terminal 2's
just twin go 1        # twin_go.py
just twin status
just twin stop        # Autoware, then Isaac Sim
```

## When it does not work

| Symptom | Likely cause | What to do |
|---|---|---|
| The cart does not move | No route, no engage, or localization not initialized | Set the goal again; press AUTO; wait until the state panel shows localization initialized |
| RViz shows nothing, or no cart | RViz and the sim do not see each other: a different ROS domain or DDS profile | Source `scripts/twin/setup.bash` in both terminals: it gives both the package's `cyclonedds-unicast-lo.xml` and `TWIN_DOMAIN` |
| `Web server error: Address already in use` | Two play_launch on one web port | Harmless: the launch runs without its web UI. Give the second one `--web-addr 127.0.0.1:8081` |
| Localization stays uninitialized | No GNSS fix or no map: terminal 1 not up, or a different domain | Check `ros2 topic hz /sensing/gnss/ublox/nav_sat_fix` (about 1 Hz) in terminal 3 |
| The sim runs slowly | Host load | Check `uptime` and `nvidia-smi`; wait for the other job |
| `world` takes over 10 min | The first start on a host compiles shaders | Let it finish once; later starts are quick |
| The cart goes faster than 2.5 m/s | The sim's speed ceiling is missing. Like the cart's VCU, it is the motor's top speed in swb's `newslab_golfcart` spec (sim_vehicle_spec 62ac087 or later). Autoware itself plans up to 4.17 m/s: its 2.5 default does not reach the planner (roadmap 10) | In `TWIN_SWB`, `git pull` and `git submodule update --init --recursive`, then restart the world |
| `world` or `autoware` says it is already up, or a second Isaac window | An earlier run is still alive | Ctrl-C it, or `just twin stop` |

Each play_launch logs to `play_log/<time>/` of the directory it was started in (`play_log/latest/node/<node>/out` and `err`); `just twin` logs to `log/twin/`.

## Setting up a new host

1. Install scenario-world-bridge (swb) and build it at its pins. It holds aib, the Isaac side.
   Install Isaac Sim 6.1 with swb's `src/swb_isaac_world/scripts/install_isaac.sh`.
2. Copy the twin's map directory to a local disk. It holds:
   - `lanelet2_map.osm`;
   - `pointcloud_map/` with `pointcloud_map_metadata.yaml`;
   - `map_projector_info.yaml`;
   - `isaac/world.yaml`.

   Do not run it from the NAS: a dropped mount takes the map loaders down.
3. Write `config/twin.env` (git-ignored). `scripts/twin/setup.bash` reads it:
   ```bash
   TWIN_SWB=$HOME/repos/carla-scenario-bridge    # the swb checkout
   ISAAC_ROOT=/mnt/disk1/isaac-sim                # Isaac Sim 6.1
   TWIN_MAP=/path/to/ntu-twin/map                 # the local map directory
   TWIN_DOMAIN=1                                  # ROS domain for both sides, at most 57
   TWIN_DISPLAY=:9                                # Isaac's window; empty runs headless
   TWIN_GPU=0                                     # the GPU Isaac renders on
   AUTOWARE_DATA=$HOME/autoware_data              # Autoware's models, writable
   AUTOWARE_TENSORRT_LIB=/path/to/tensorrt-10.8.0/lib   # swb's setting; avoids engine rebuilds
   ```
4. Build:
   ```bash
   just build
   ```
5. The first world launch compiles Isaac's
   shaders. The first Autoware launch builds the CenterPoint engines in `AUTOWARE_DATA`. Both
   take minutes, once.
