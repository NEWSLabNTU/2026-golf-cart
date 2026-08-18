# config/ — the single source of truth

Everything that differs between machines, deployments or recording sessions lives
here. Nothing in `scripts/` hardcodes any of it; each script reads these files, so
changing a value here changes it for every consumer on both hosts.

| File | Format | What it decides |
|---|---|---|
| `host` | one word (`master` or `orin`) | which machine this checkout is on. Selects the DDS profile. **Gitignored** — it is a property of the machine, not the branch |
| `multi_machine.conf` | shell assignments | the other host's `user@addr`, its repo path, the ssh key, the master's IP |
| `sensors.conf` | shell assignments | which IMU and camera driver the sensor kit uses (`IMU_SOURCE`, `CAMERA_MODEL`) |
| `vehicle.conf` | shell assignments | whether the vehicle interface may transmit on CAN (`GOLFCART_TX_ENABLED`) |
| `recording/master_topics.txt`<br>`recording/orin_topics.txt` | one topic per line, `#` comments | what each host records |
| `cyclonedds/{master,orin,loopback}.xml` | CycloneDDS XML | DDS network profiles, one per role |

Formats are deliberately unlike each other: the topic lists are edited by hand and
diffed per line, so a flat list beats YAML; `multi_machine.conf` is sourced by
shell scripts, so it is shell; the DDS profiles are XML because CycloneDDS reads
them directly and we do not want to generate them.

## Setting the host marker

```bash
echo master > config/host      # or: orin
just service doctor                    # confirms what resolved, and from where
```

Precedence, highest first: `GOLFCART_ENV_ROLE` (how the systemd units state their
role), then an exported `GOLFCART_DDS_PROFILE`, then this file, then `loopback`.
A marker naming a profile with no `cyclonedds/<name>.xml` is reported loudly and
falls back to `loopback` — silently running the wrong profile is the failure this
machinery exists to prevent.

The older location `.golfcart-host` in the repo root is still read when
`config/host` is absent, so an existing checkout keeps working after a pull.

## Changing the other host

`multi_machine.conf` keys take their value from the `GOLFCART_`-prefixed
environment variable of the same name when it is set, so an override still wins
for one shell or one unit:

```sh
ORIN_SSH="${GOLFCART_ORIN_SSH:-jetson@192.168.125.101}"
```

`ORIN_WORKSPACE` accepts `~/path` or an absolute path; the tilde is expanded by
the *remote* shell, since this machine's `$HOME` is the wrong answer.

## Changing the IMU or camera

`sensors.conf` holds `IMU_SOURCE` and `CAMERA_MODEL`. They are **environment
variables, not launch arguments**, and that is forced rather than chosen:
`golfcart.launch.yaml`'s `imu_source:=` reaches `golfcart_autoware.launch.xml`,
but the path onwards runs through two installed Autoware files that forward a
fixed set of arguments and drop the rest. So `just launch "imu_source:=zed"`
looks like it works and does nothing; `IMU_SOURCE=zed` is what the sensor kit
actually reads.

Currently `IMU_SOURCE=zed` — the ZED X's built-in IMU, published by the orin —
because the Xsens MTi is broken.

## Turning CAN TX on

`vehicle.conf` holds `GOLFCART_TX_ENABLED`. With it `false` — the default — the
vehicle interface only listens: `/vehicle/status/*` and `/diagnostics` fill in
normally and nothing we publish can move the cart.

It is an environment variable for the same forced reason as `IMU_SOURCE`: the
one installed Autoware file in between,
`tier4_vehicle_launch/vehicle.launch.xml`, forwards exactly `vehicle_id`,
`raw_vehicle_cmd_converter_param_path` and `initial_engage_state` to our
`vehicle_interface.launch.xml` and drops the rest. `just launch
"tx_enabled:=true"` looks like it works and does nothing.

Use the `tx=` token instead — the justfile strips it out of the launch
arguments and puts it in the environment:

```bash
just launch tx=on          # single machine, foreground
just launch-up tx=on       # this host, via systemd
just launch-all tx=on      # both hosts; TX applies to the master only
```

⚠️  `tx=on` puts real frames on `can0` and the cart can be commanded into motion.

`launch-all` splits the token off and forwards only the remaining launch
arguments to the orin. CAN is the master's alone — the orin has no bus, and
`golfcart.launch.yaml` gates the vehicle group on `is_master` — so the orin's
`launch-up` runs without `tx=` and therefore clears `GOLFCART_TX_ENABLED` in its
own user manager rather than inheriting a value from an earlier run.

`just service host-status` (and `just service status`, which runs it on both hosts)
prints the effective setting next to the unit states, and names where it came
from: `unit-env` when `launch-up` set it for this run, `config/vehicle.conf`
when nothing is set.

TX is deliberately **not sticky**. `launch-up` writes it into the user manager's
environment for that invocation only: an invocation that does not say `tx=`
clears it, and `launch-down` clears it too. Editing `vehicle.conf` changes the
resting default for the machine and does make it apply to every launch, which is
why the file is the wrong place to switch it on for one test.

`just vehicle interface tx=on` is a different path — it bypasses Autoware
entirely and passes `tx_enabled:=` as a real launch argument.

## Changing what is recorded

Record **first-hand driver output**. Topics a node computed from other topics —
the concatenated cloud, the corrected IMU — are commented out in the lists, since
replay is a logging simulation: the single-machine stack runs with drivers
disabled against the merged bag and recomputes them, using today's parameters
rather than the ones frozen at record time.

A topic that is expected but dead stays listed and records zero messages, on
purpose. `/sensing/imu/xsens/imu_raw` is the current example. An empty topic in a
bag says "this device was expected and was silent"; an absent one says nothing,
and months later nobody can tell which it was.

Edit the topic lists — not any script. Audit them against a running stack:

```bash
ros2 topic list > /tmp/live.txt
grep -vE '^\s*(#|$)' config/recording/master_topics.txt | tr -d ' ' \
  | while read -r t; do grep -qx "$t" /tmp/live.txt || echo "MISSING $t"; done
```

A stale entry records zero messages while still appearing in `ros2 bag info`,
which reads as "the sensor was quiet" rather than "the name is wrong".
