# Setting up a machine

Do this once per machine. The cart needs both: the **master** and the **orin**
(see [hardware.md](hardware.md)).

Before you start, each machine needs:

- JetPack 6.2 (Ubuntu 22.04) on a Jetson AGX Orin
- network access, to clone the repository and install packages
- sudo

## 1. Install on each machine

On the master:

```bash
git clone --recurse-submodules https://github.com/NEWSLabNTU/2026-golf-cart.git
cd 2026-golf-cart
./setup.sh --role master
just build
```

On the orin, the same, with the other role:

```bash
git clone --recurse-submodules https://github.com/NEWSLabNTU/2026-golf-cart.git
cd 2026-golf-cart
./setup.sh --role orin
just build
```

`--role` does the following for you:

- writes `config/host` (`master` or `orin`), which tells every script which
  machine this is
- selects the `vehicle` preset: ROS 2, Autoware 1.5.0, build tools, DDS settings,
  udev rules, CAN
- adds the steps for that role: `chrony-master` on the master; `chrony-orin` and
  `orin-can0` on the orin
- runs the `host-services` step, which installs the systemd units and enables
  lingering

The first run takes a long time. Re-running `./setup.sh` is safe; finished steps
are skipped.

## 2. Pair the two machines (on the master, once)

```bash
just service pair
```

This creates an ssh key for the orin, copies it over (you type the orin's
password once), checks the orin, and runs the health checks on both machines.

## 3. Things you must install by hand (orin)

Two pieces cannot be installed by the script. Both go on the **orin**.

### Vendor CAN database

The vehicle interface is built from Turing Drive's `CAX_ADS_CAN.dbc`. It is
proprietary and is not in the repository. Get it from Turing Drive, then:

```bash
cp /path/to/CAX_ADS_CAN.dbc src/vehicle/golfcart_vehicle_launch/golfcart_vehicle_interface/
just build
```

Without it, `just build` skips the vehicle interface and still succeeds, but the
cart has no speed report and cannot be engaged.

### ZED SDK

Download the ZED SDK `.run` installer for JetPack 6 from Stereolabs and run it.
It installs to `/usr/local/zed`. Then:

```bash
./setup.sh --rerun cyclonedds-sysctl
just build
```

The re-run is needed because the ZED installer lowers a network buffer setting
that ROS needs; without it no ROS node starts. Without the SDK, `just build`
skips the ZED packages and the camera never appears.

## 4. Check what is missing

On either machine:

```bash
./setup.sh --status
```

This prints a checklist of what is installed and what is still missing, including
the by-hand items above. To check that the two machines can run together:

```bash
just service doctor        # this machine
just service doctor-orin   # the orin, from the master
```

## Time sync

The orin follows the master's clock through chrony. Setup installs it
(`chrony-master` / `chrony-orin`). To confirm, on the orin:

```bash
chronyc sources     # the master, 192.168.125.100, is marked ^*
```

Details: [Time sync](multi-machine.md#time-sync).

## Maps

The COSS, Ming-Da and sample point clouds are in the repository compressed;
`./setup.sh` unpacks them (step `map-data`), or run `just data unpack`. The NTU
campus maps are downloaded separately. See [maps.md](maps.md#preparing-map-data).

## Updating

```bash
git pull
just checkout      # update submodules
just data unpack   # if a map changed (see maps.md)
just build
```

Do this on both machines. If setup steps changed, `./setup.sh --status` shows
them as changed; run `./setup.sh` again.

## More

- `./setup.sh --list` lists every step
- `./setup.sh --rerun <step>` runs one step again
- [setup/README.md](../setup/README.md) describes the setup tool itself
