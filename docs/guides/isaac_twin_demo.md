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
3. Check that nothing of the demo is up:
   ```bash
   just twin status    # world: down, autoware: down
   ```

## Start

```bash
just twin world 1     # Isaac Sim with the twin, the cart at route 1's start: 2 to 3 min
just twin autoware    # the cart's Autoware and RViz: about 1 min
```

- **`world`** returns with `twin: the world is up`. Isaac's window shows the campus with the
  cart on the road, and its view follows the cart. The first start on a host takes longer
  (see the table at the end).
- **`autoware`** opens RViz, looking straight down on the T junction, north up:
  - the lanes are drawn in white;
  - the cart sits at its start;
  - lidar points surround it;
  - the camera image is in the image dock.

  When localization has settled, the cart stops jumping, and the Autoware state panel shows
  the localization as initialized and the operation mode as STOP.

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

**Or by script**, which waits for localization, sets the goal, engages, and reports until the
cart arrives:

```bash
just twin go 1
```

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

To drive another route, start again from that route's start:

```bash
just twin stop
just twin world 3
just twin autoware
```

## Stop

```bash
just twin stop    # Autoware, then Isaac Sim
```

## When it does not work

| Symptom | Likely cause | What to do |
|---|---|---|
| The cart does not move | No route, no engage, or localization not initialized | Set the goal again; press AUTO; wait until the state panel shows localization initialized |
| RViz shows nothing, or no cart | RViz and the sim do not see each other: a different ROS domain or DDS profile | Start both with `just twin`, which gives both swb's `cyclonedds-localhost.xml` and `TWIN_DOMAIN` |
| The sim runs slowly | Host load | Check `uptime` and `nvidia-smi`; wait for the other job |
| `world` takes over 10 min | The first start on a host compiles shaders | Let it finish once; later starts are quick |
| The cart goes faster than 2.5 m/s | The speed cap did not reach the planner | Look for `planning speed default 2.50 m/s` in `log/twin/play_log`, `planning_speed_limit` |
| `world` or `autoware` says it is already up | An earlier run is still alive | `just twin stop` |

Logs are in `log/twin/`: `world.log`, `autoware.log` and `play_log/`.

## Setting up a new host

1. Install scenario-world-bridge (swb) and build it at its pins. It holds aib, the Isaac side.
   Install Isaac Sim 6.1 with swb's `src/swb_isaac_world/scripts/install_isaac.sh`.
2. Copy the twin's map directory to a local disk. It holds:
   - `lanelet2_map.osm`;
   - `pointcloud_map/` with `pointcloud_map_metadata.yaml`;
   - `map_projector_info.yaml`;
   - `isaac/world.yaml`.

   Do not run it from the NAS: a dropped mount takes the map loaders down.
3. Write `config/twin.env` (git-ignored). `scripts/twin/twin.sh` lists every variable:
   ```bash
   TWIN_SWB=$HOME/repos/carla-scenario-bridge    # the swb checkout
   ISAAC_ROOT=/mnt/disk1/isaac-sim                # Isaac Sim 6.1
   TWIN_MAP=/path/to/ntu-twin/map                 # the local map directory
   TWIN_DOMAIN=1                                  # ROS domain for both sides, at most 57
   TWIN_DISPLAY=:9                                # Isaac's window; empty runs headless
   TWIN_GPU=0                                     # the GPU Isaac renders on
   TWIN_ASSETS=$HOME/.cache/golfcart_twin         # where `just twin assets` writes
   AUTOWARE_DATA=$HOME/autoware_data              # Autoware's models, writable
   AUTOWARE_TENSORRT_LIB=/path/to/tensorrt-10.8.0/lib   # swb's setting; avoids engine rebuilds
   ```
4. Build, and make the lidar profiles and the body:
   ```bash
   just build
   just twin assets
   ```
5. The first `just twin world` compiles Isaac's shaders, and the first `just twin autoware`
   builds the CenterPoint engines in `AUTOWARE_DATA`. Both take minutes once.
