# Known Roadblocks

**Target machine**: NVIDIA Jetson AGX Orin Developer Kit, JetPack 6.2.1 (L4T R36.4, Ubuntu 22.04).
**Verified**: 2026-08-10 — see *Sensor status* below. The 2026-04-07 survey further down is superseded.

---
## `feat/gmslcam-rviz-sampler`: play_launch's Rust parser rejects `value-sep` (found 2026-09-22)

The one-process `camera.launch.xml` on that branch (sensor kit `360c51c`)
passes gmslcam its camera list and per-camera file lists as launch-XML list
parameters:

```xml
<param name="cameras" type="list_of_str" value="rear,left,right" value-sep=","/>
<param name="rear.params_files" type="list_of_str" value-sep="," value="…/camera_rear.yaml,…/rear.yaml"/>
```

`value-sep` is a documented `launch_xml` attribute and `ros2 launch` accepts
it. play_launch 0.11.0 (PyPI latest, the Advantech's version; the orin has
0.10.0) does not, and its default Rust parser has no fallback, so the unit
exits in its second second and `just launch-all` reports it as `failed`:

```
Error: Rust parser error while parsing golfcart_launch: Unexpected attribute(s) found in `param`: {'value-sep'}
Hint: if this is a parser limitation rather than a bad launch file, re-run the same command with `--parser python` (slower, maximum compatibility).
```

Seen from RViz it is "no camera image, no LiDAR", because nothing at all is
running; the only topics listed are RViz's own subscriptions. Not a rebase
artifact: the pre-rebase tip `0aec5ee` has the same seven `value-sep`
attributes and `main`'s `ebad63a` has none, so the branch was only ever run
under `ros2 launch` or `--parser python`.

Undecided. Two ways out: (a) drop `value-sep` and express the lists in a form
the Rust parser takes — untested, `type="list_of_str"` alone may or may not
parse a bracketed literal; (b) run the units with `--parser python`, at the
cost of a slower parse on every start. Until one is chosen the branch cannot
be launched on the vehicle through the units.

---

## Orin: unit active, every node dies at birth — `wmem_max` too small for the DDS profile (found 2026-09-22)

After `just launch-all` the orin's unit was `active`, `ros2 node list` there
returned nothing, and every process in the play_log had exited within its
first second with

```
rmw_create_node: failed to create domain, error Error
failed to initialize rcl node: rcl node's rmw handle is invalid
```

With stderr not thrown away the line above it says why:

```
failed to increase socket send buffer size to at least 16777216 bytes, current is 425984 bytes
```

`c228d87` (2026-09-21) added `<SocketSendBufferSize min="16MB">` to every
CycloneDDS profile so the LiDARs hold 10 Hz, and CycloneDDS treats an unmet
`min` as fatal to the domain. The Advantech had `net.core.wmem_max=16777216`;
the orin's `/etc/sysctl.d/99-cyclonedds-max.conf` was written by an older
`cyclonedds-sysctl` step that set only the receive side, so `wmem_max` was the
kernel default 212992. Fix on the orin: `./setup.sh --rerun cyclonedds-sysctl`,
then `sysctl net.core.wmem_max` must print 16777216, then relaunch.

The lesson is the same as the stale-unit entry above: a commit that changes
what a setup step writes does nothing on a machine until that step is re-run
there, and `setup/.state.json` marks the step *stale*, not failed, so nothing
shouts. After pulling a change to `setup/scripts/`, run `./setup.sh --status`
on both hosts.

---

## Stale unit files: `just launch-all` reports active, the stack never runs (found 2026-09-22)

On the Advantech, `just launch-all` printed `advantech: launch active` and RViz
came up, but no camera or LiDAR data appeared. `ros2 topic list` showed only
the topics RViz itself subscribes to (three `image_raw/compressed`, two LiDAR
clouds, no `camera_info`), `ros2 node list` returned two nodes, and
`ros2 topic hz` on anything printed nothing. That is what a display with no
publishers behind it looks like, and it is easy to misread as a transport
problem: it was first blamed on the domain split of `perf/domain-split`, which
had run the same stack fine in the foreground an hour earlier.

`systemctl --user status golfcart-launch.service` gave it away:
`Active: active (running) since ... 11ms ago`, a new `Main PID` on every look,
`NRestarts=0`. Two seconds after each start systemd logged `Stopping Golf Cart
launch stack`, with nothing on the machine issuing a stop.

The installed unit was from 2026-08-25 and still carried

```
Requires=iox-roudi.service
After=iox-roudi.service
```

Iceoryx was removed from the project on 2026-09-02, `scripts/iceoryx/` with
it. `iox-roudi.service` was still installed, `enabled`, with
`Restart=on-failure` and `RestartSec=2`; its `ExecStart` now pointed at a
deleted script (`code=exited, status=203/EXEC`). Every two seconds it failed,
and `Requires=` stopped the launch unit along with it; the next start of the
launch unit pulled roudi in again, which failed again. The orin's units, from
2026-08-14, predate iceoryx on that host and were fine.

Fix, on the machine with the stale units:

```bash
just stop-all
systemctl --user disable --now iox-roudi.service
rm -rf ~/.config/systemd/user/iox-roudi.service ~/.config/systemd/user/iox-roudi.service.d
systemctl --user daemon-reload && systemctl --user reset-failed
just service install master        # regenerates from setup/files/systemd
grep -n 'Requires\|iox' ~/.config/systemd/user/golfcart-launch.service   # expect nothing
```

Two lessons. `just service install` is not idempotent against units it no
longer knows about: the installer removes only the units it installs, so a unit
dropped from the repo stays on every machine it was ever installed on, and a
`Requires=` from an older launch unit keeps it alive. And "launch active" from
`just launch-all` means the unit started, not that play_launch survived; when
RViz shows nothing, look at `systemctl --user status` for the PID age before
looking at DDS.

---


## A partial Autoware download looked like a tampered one (found and fixed 2026-09-11)

`./setup.sh` refused the `autoware-debian` step with a checksum mismatch on the
1.9 GB localrepo `.deb`, and advised "update the script with the correct
checksum if you are using a custom build" — advice that would have installed a
damaged package by switching off the check that caught it. The expected hash was
right: GitHub publishes the asset digest as `sha256:9f433f7a…`, the same value.

**What a partial aria2c download looks like, and why nothing else notices.**
aria2c preallocates the whole file and fills ten segments in parallel, so an
unfinished download has the *exact* published byte count and a valid `.deb`
header — `ls -l` and `dpkg-deb --info` both pass. The holes are mid-file. Only
the hash sees them, and the leftover `.aria2` control file (aria2c deletes it on
success) is the one unambiguous marker that a download is unfinished.

**Exit 7 is not a failure.** aria2c returns 7 when it was signalled — SIGINT,
SIGTERM, SIGHUP — with the download unfinished, and that is exactly when the
bytes on disk are worth keeping. Reproduced: both SIGINT and SIGHUP give exit 7,
a full-size preallocated file, and a kept control file. Treating 7 like any
other error deletes 1.9 GB of good bytes and starts over.

The installer now resumes a partial (`--continue=true`), stops rather than
wiping on exit 7, removes the control file alongside the data file when it does
fall back to wget or curl, and, on a genuine mismatch with no control file,
points at the published digest instead of suggesting an edit to the checksum.

**How the original one was interrupted was never determined.** Worth recording
what the forensics ruled out, since the same question will come up again: the
file and its control file both stopped changing at 20:46 on 2026-09-08, about
six minutes in. Not OOM, no reboot, no disk pressure; not the network (the
tailscale control-plane errors in the journal that evening run 88–92 per hour
on the previous day too, and stopped entirely once fixed on the 9th); not an
expired signed URL (GitHub's SAS token is valid ~52 minutes); not the SSH drop
at 20:47:42, which only detached screen — that window still existed on reattach
at 23:27; not the Textual menu leaving the terminal wedged (replaying that
commit shows it restores alt screen, mouse, cursor, paste mode and tty flags,
and Ctrl-C propagates normally afterwards). What remains is a terminal-side
signal to setup's process group, and the evidence to name it is gone: no screen
logging configured, process accounting off, and that window has since closed.

## cuda_ndt GPU scorer read the wrong rotation (found and fixed 2026-08-30)

**Fixed.** Recorded because the same defect has now appeared three times in this
crate, and because the first assessment of its blast radius was wrong.

`GpuScoringPipeline` takes poses as `[x, y, z, roll, pitch, yaw]` and rebuilds
the rotation with `pose_to_transform_matrix`, which composes `Rx(roll) ·
Ry(pitch) · Rz(yaw)` — Autoware's order, and what every consumer of a pose
vector in this crate assumes. Two callers built those angles with nalgebra's
`Isometry3::rotation.euler_angles()`, which describes the opposite composition.
The two agree only when at most one angle is non-zero.

Measured over 294 frames, scoring the same poses both ways:

| scorer | NVTL mean |
|---|---|
| `evaluate_nvtl_gpu` (isometry → matrix; agrees with the CPU scorer to 3 dp) | 3.138 |
| `GpuScoringPipeline` (via euler angles) | 2.821 |

Mean absolute difference 0.317, max 0.808, against a convergence gate of 2.0.

**What it actually affected**, which is narrower than that gap suggests:

- `evaluate_nvtl_batch` — used only by `covariance.rs`, for `MULTI_NDT` and
  `MULTI_NDT_SCORE`. `cuda_scan_matcher.param.yaml` ships
  `covariance_estimation_type: 0` (FIXED), so this path was dormant.
- `compute_per_point_scores_for_visualization` — the per-point score overlay.
  Live, but cosmetic.

**What it did not affect**, contrary to the first reading: initial-pose
estimation. The estimator scores its particles with the singular
`evaluate_nvtl`, which takes the matrix route and was always correct. Nor the
per-scan path.

The fix uses `isometry_to_pose_vector`, the exact inverse of
`rotation_from_pose_angles`, which `derivatives/gpu.rs` already round-trip
tests against `pose_to_transform_matrix`. That test passed throughout — these
two call sites simply bypassed the converter it guards.

Why it keeps recurring: nothing in the type system separates "angles in
nalgebra's order" from "angles in Autoware's order". Both are `(f64, f64, f64)`,
and a fixture with yaw-only motion cannot tell them apart. `cuda_scan_matcher.param.yaml`
records the 2026-08-03/04 instance, where the NVTL gate was recalibrated against
the wrong number rather than the number being fixed.

---

## play_launch on the Orin was 0.5.1, breaking every `just launch*` recipe (fixed 2026-08-30)

Every launch verb in the justfile passes `--container-mode`, in seven places
(`just launch`, `launch-up`, `launch-sim-logging`, `launch-sim-planning`,
`ntu-test up`, ...). The play_launch installed on this machine does not have it,
in any position:

```
$ play_launch --version
play_launch 0.5.1
$ play_launch launch ... --container-mode observable ...
error: unexpected argument '--container-mode' found
```

It is not a justfile bug. The source checkout at `~/repos/play_launch` is
**0.10.0** and does have the flag; the install at
`~/.local/lib/python3.10/site-packages/play_launch` is from 2026-08-03 and is
five minor versions behind. `pip show play_launch` reports the stale one, and
`~/.local/bin/play_launch` resolves to it.

Consequence: every `just launch*` recipe fails immediately on this Orin, before
anything starts. Nothing in the error names the version, so it reads as a
justfile defect.

**Fixed** by `pip install --upgrade play_launch`, which brings **0.9.0** — the
latest release, and the version that already carries `--container-mode`. Every
flag this repo passes (`--container-mode`, `--web-addr`, `--parser`) is present
in it, checked against the binary before installing. `just --evaluate` and
`just --list` both pass afterwards, and
`logging_simulation.launch.yaml` reaches `Startup complete` through the
justfile's own invocation.

The source checkout is an unreleased **0.10.0**, and was not used: building it
means a full Rust build of a tree that is itself two commits behind its origin,
to gain nothing this repository asks for.

**Note for anyone re-reading the measurements** in
[handover/2026-08-30-cuda-ndt-on-orin.md](handover/2026-08-30-cuda-ndt-on-orin.md):
they were taken under 0.5.1, invoking play_launch directly without
`--container-mode`. The A/B is unaffected — both arms ran under the same
version — but absolute CPU figures include that version's monitoring overhead
and should not be compared against numbers taken under 0.9.0.

---

## Measuring anything on this Orin needs a stale-process guard (observed 2026-08-30)

`play_launch` stacks survive their SIGINT here. Two consecutive replay runs left
six of them alive, competing for the same 12 cores, and the load average reached
**278** while a "measurement" was running.

The result was not noise, it was a confident wrong answer: `pointcloud_container`
appeared to drop from 117.7% to 38.6% CPU between backends, a 3x win. Re-measured
on a quiet machine, the same comparison is 117.9% to 91.5% — 1.29x.

Any resource measurement here needs to (1) refuse to start while a
`play_launch`, `component_container` or `ros2 bag` process is alive, and (2)
wait for the load average to fall before opening its window. Killing the parent
is not enough; `pkill -9 -f play_launch` plus `component_container` is.

**Confirmed under 0.9.0 as well.** Four measured runs each left three
play_launch processes alive 25 seconds after SIGINT, so this is not a 0.5.1
defect and the upgrade does not retire the guard. Beware also that
`pgrep -f play_launch` matches the checking command itself; match on `comm`.

**This is a shared machine, and the guard must check ownership.** On 2026-08-31
another user's LCTK calibration — RViz at 382% CPU, a board detector, a solver
and a bag player — ran during a measurement and produced a clean, wrong,
confidently-reported result: `cuda_ndt` appeared to fail 122 of 192 alignments
on the CPU sensing chain. It reproduced as healthy twice on an idle machine.
Check `ps -eo user` before concluding anything, and before trying to clear
what looks like a stale stack: if the processes are not yours, waiting is the
only correct response.

---

## Sensor status (observed 2026-08-10)

Measured from a live two-host run of `just launch-all "record:=true"` and the
resulting 150s bag. Counts are messages recorded; rates are `ros2 topic hz` over
~10s while the stack ran.

| Sensor | Topic | Status | Evidence |
|---|---|---|---|
| Velodyne VLP-32C | `/sensing/lidar/vlp32/velodyne_points` | **working** | 1290 msgs / 150s |
| Falcon (Seyond) | `/sensing/lidar/falcon/iv_points` | **working** | 1546 msgs / 150s, 9.8 Hz |
| Fused cloud | `/sensing/lidar/concatenated/pointcloud` | **working** | 792 msgs / 150s, 3.5 Hz |
| ZED X (orin) | `/sensing/camera/zed/rgb/color/rect/image/compressed` | **working** | 5554 frames / 186s ≈ 30 Hz |
| Otobrite GMSL cameras | `/sensing/camera/{left,right,rear}/image_raw/compressed` | **not working** | topics exist, 0 messages, no `/dev/video*` |
| GNSS (Xsens MTi) | `/sensing/gnss/mti/fix`, `/sensing/gnss/fixed` | **no data** | topics exist, 0 messages recorded |
| IMU (Xsens) | `/sensing/imu/xsens/imu_raw`, `/sensing/imu/imu_data` | **no data** | topics exist, 0 messages recorded |
| Vehicle interface | `/vehicle/status/control_mode` | **partial** | 8045 msgs; velocity, steering, gear, actuation and turn/hazard all recorded 0 |
| TF | `/tf` | **empty** | 0 dynamic transforms recorded; only 2–3 `tf_static` messages |

The GNSS/IMU/vehicle gaps were **not investigated** — they were noticed while
auditing the recorder's topic list and are recorded here as observations, not
diagnoses. The cause could be unplugged hardware, an unstarted driver, or a wrong
topic name, and nothing here distinguishes those.

Two rate observations worth a look. **Investigated 2026-08-26**, see
[LiDAR Pipeline Starvation](research/sensing/lidar-pipeline-starvation.md):

- The Velodyne measured **6.8 Hz** live and averages ~8.6 Hz across the bag,
  against a nominal 10 Hz. Some of that is `ros2 topic hz` competing with a
  loaded system, but not obviously all of it.
- The fused cloud runs at **3.5 Hz**, well below either input. Expected behaviour
  for a synchroniser waiting on the slower source is roughly the slower input
  rate, not a third of it.

The second one is the interesting half and the instinct above was right: the
fused rate is not explained by the slower input. The concatenator's own
`debug_mode` diagnostics show the Falcon present in **95.6%** of windows and the
Velodyne in **47.2%**. The first explanation offered here was a `timeout_sec:
0.2` window against a measured 135 ms inter-sensor arrival skew. **That was
tested on 2026-08-28 and ruled out**: sweeping `timeout_sec` over 0.2/0.3/0.4
left Velodyne presence flat at 48-56%, while the Falcon and all-inputs-present
both improved, which is what a genuinely late input looks like. The Velodyne is
not late, it is absent. The NTU bag carries it at 7.02 Hz against 3.7 Hz of
concatenation attempts, so roughly half the scans are lost upstream of the
synchroniser and the cause is still open.

Separately, and not the same fault: RViz shows **no** Velodyne points at all,
because a RELIABLE subscriber cannot match the driver's BEST_EFFORT publisher
and receives nothing rather than less. Check with
`ros2 topic info -v /sensing/lidar/vlp32/velodyne_points`.

### NTU CSIE-1 rosbag: Velodyne cloud is not trustworthy

**Reported 2026-08-30, not yet investigated.** The Velodyne point cloud in the
`2026-08-14_NTU-campus` recordings covers only a fraction of the sensor's field
of view. Recalled rather than measured, so confirm before relying on it either
way.

It matters because that bag was used for a lot of measurement. Anything below
taken on it should be re-run on the Autoware sample bag before it is trusted:

- the cpu vs cuda `pointcloud_backend` localization comparison
- the concatenator's Velodyne presence figures, ~47-54% (though the 2026-08-25
  *vehicle* run showed 47.2% independently, so that finding has separate support)
- the `timeout_sec` sweep, whose result was null and could be null for the wrong
  reason if the input was already degraded

See docs/research/sensing/lidar-pipeline-starvation.md.

### Otobrite GMSL cameras — not enumerating

The cameras are physically attached but produce nothing. The ROS topics exist
only because `camera.launch.xml` starts gscam unconditionally; gscam is pointed at
`/dev/v4l/by-path/platform-tegra-capture-vi-video-index{0,10,12}`, which do not
exist, so every recording shows `Count: 0`.

State as found on 2026-08-10:

| Check | Result |
|---|---|
| `/dev/video*` | none |
| `lsmod` for `max9296` / `nv_imx390` | not loaded |
| `/lib/modules/5.15.148-tegra/extra/otocam/` | does not exist — vendor `.ko` never staged |
| `/etc/modules-load.d/otocam.conf`, `/etc/modprobe.d/otocam.conf` | neither installed |
| Vendor blob `/usr/local/bin/otocam/` | **present** (`max9296.ko`, `nv_imx390.ko`, `agxorin/oto.dtbo`) |
| Kernel | `5.15.148-tegra` — matches the `.ko` ABI requirement |
| `/boot/extlinux/extlinux.conf` | `OVERLAYS .../oto.dtbo` **is** on the default `primary` label |
| Live device tree cameras | `imx274_bottom_A6V26`, `imx274_top_A6V26`, … |

That last row is the decisive one: the six camera modules registered in the
running device tree are **imx274**, the devkit's stock configuration, not the
otobrite IMX390s. No `imx390` or `max9296` node exists anywhere in
`/proc/device-tree`. So the overlay is configured but the running kernel booted
without it.

Read together: `setup-otocam.sh` steps 3 and 4 (module staging, modprobe configs)
have never run, and there has been no reboot since the `extlinux.conf` overlay
line was added. Whether a reboot alone fixes it is **unknown and untested** — the
overlay may also be failing to apply for its own reasons, which this evidence
cannot distinguish.

Next step, both needing root:

```bash
sudo ./scripts/hardware/otocam/setup-otocam.sh
sudo reboot
# then:
ls /dev/video*
lsmod | grep -E 'max9296|imx390'
cat /proc/device-tree/tegra-camera-platform/modules/module0/badge   # want imx390, not imx274
```

**Before running it**, note that `scripts/hardware/otocam/setup-otocam.sh` has
uncommitted local edits: `exit 1` changed to `exit 2` on the vendor-blob check,
and `? possible to be the problem` comments on exactly steps 3 and 4. Someone was
mid-debug. Those steps never executed at all, so the comments mark untested
suspicion rather than observed failure. Decide whether the edits are a fix or
scratch marks before relying on the script.

### ZED extrinsics uncalibrated

`zed.launch.xml` disables all TF publishing from the wrapper
(`pos_tracking.publish_tf`, `publish_map_tf`, `sensors.publish_imu_tf` all false).
The wrapper's defaults broadcast `map -> odom` and `odom -> camera_link`, which
would fight Autoware's localization once both hosts share a DDS graph.

Consequence: the ZED image is recordable and viewable but cannot feed perception,
because nothing relates `zed_left_camera_frame_optical` to `base_link`. Re-enable
only after the extrinsics are measured and a `base_link -> zed_camera_link` entry
exists in the sensor kit calibration.

---

## Tooling issues found while building the two-machine deployment

These are defects in the tools, not the vehicle. Each is worked around; none is
fixed at the source.

### play_launch does not finalize bags when stopped from the foreground

Recording through `just launch-all` and stopping it the way a terminal does
leaves a complete `.db3` and a `metadata.yaml` that is **0 bytes or missing
entirely**; `ros2 bag info` then reports
`invalid node; first invalid key: "version"`. Seen at 2.2 GB, 2.5 GB and 3.3 GB.

Recovery is lossless:

```bash
rm -f <bag>/metadata.yaml && ros2 bag reindex <bag>
```

**At multi-gigabyte sizes, the stop path decides.** Small bags finalize on either
path — a 604 MB bag stopped without systemd came out valid. Size alone is
therefore not the whole story: the two matched 3+ GB runs below were recorded
minutes apart with the same arguments on the same SSD, and differ only in how
they were stopped.

| Stop path | Bag | `metadata.yaml` | Stack exit |
|---|---|---|---|
| `systemctl --user stop` on a user unit | 3.2 GiB | 10530 bytes, valid | ~1 s |
| SIGINT to the process group (as Ctrl-C does) | 3.3 GB | absent | still alive after 240 s |

The database survives either way (`PRAGMA quick_check` ok, row count intact), so
only finalization is lost.

An earlier version of this entry blamed a shutdown grace shorter than a
multi-gigabyte flush. The equal-size comparison above disproves that: 3.2 GB
finalized in about a second when systemd did the stopping.

Mechanism still unidentified. The obvious candidate is ruled out — both paths
deliver SIGINT to every process, since `KillMode=control-group` signals the whole
cgroup exactly as a terminal signals the foreground process group. The
unexplained part is the shutdown *duration*; the `just`→bash→`just`→bash layers
between the signal and play_launch are the next place to look.

Workaround today: stop the master through systemd rather than Ctrl-C (see
docs/design/orin_provisioning_implementation_plan.md). `--max-bag-size` rollover
remains untried.

### play_launch drops `executable:` launch entries

`ros2 launch` runs them; play_launch runs them during its *dump* phase, waits for
them to exit, and then omits them from `record.json` entirely, so replay spawns
nothing. A long-lived `executable:` entry therefore hangs the launch forever.

Worked around by making the recorders package executables launched as `node:`
entries, and by driving the orin orchestrator from the justfile rather than the
launch file. See the Amendments section of
`docs/design/multi_machine_deployment.md`.

### rosbag2 does not replay `tf_static` usefully

Only 2–3 `tf_static` messages are recorded, and rosbag2 does not republish them
with the transient-local QoS that subscribers expect. Verified three ways —
subscribing with matching QoS, subscribing before playback started, and with an
explicit message type — all received nothing.

Consequence: a bag alone cannot place `velodyne`- or `seyond`-stamped clouds.
`just bag replay` works around it by running `robot_state_publisher` from the
vehicle description, which is arguably better anyway since it reflects current
calibration rather than the calibration of the recording day.

### RViz Image display ignores the compressed transport hint

With `Transport Hint: compressed` set on the display, the compressed topic showed
**0 subscribers**. Worked around in `bag_replay.launch.xml` by decoding with
`image_transport republish` onto `/replay/zed/image`. Root cause not investigated.

### The ZED SDK silently breaks CycloneDDS

The SDK installs `/etc/sysctl.d/60-zed-buffers.conf` with
`net.core.rmem_max=1048576`, which sorts after our settings file and undercuts it.
Our DDS profiles require a 10 MB minimum, so CycloneDDS then refuses to create a
domain **on every profile, loopback included** — presenting as
`rmw_create_node: failed to create domain`, which points at the network rather
than at a sysctl.

Fixed by numbering our file `99-cyclonedds-max.conf`, but **it will recur on any
ZED SDK reinstall**. Re-run `./setup/scripts/configure-cyclonedds-sysctl.sh`
afterwards.

### Master root filesystem is nearly full

`/` is a 54 GB eMMC sitting at ~93% with ~3.9 GB free. Recording runs at roughly
15 MB/s, so an unattended recording fills it in about four minutes — and a full
disk during a bag write is what corrupts bags.

`.envrc` now points `GOLFCART_BAG_DIR` at the 916 GB SSD (`/mnt/external`, ~861 GB
free) when it is mounted, which removes the pressure for recordings started from
a direnv shell. It does **not** help a recording started from a bare shell or a
systemd unit, where the default is still `~/rosbags` on the eMMC.

### A truncated bag reports itself as healthy

An rsync that ran while the destination filesystem was full produced a bag that
`ros2 bag info` showed with full message counts and no error, because info reads
`metadata.yaml` and never opens the database. The corruption surfaced only much
later, in `ros2 bag convert`:
`database disk image is malformed`.

`bag_fetch_orin.sh` now verifies size and runs a SQLite `quick_check` after every
fetch, and `bag_merge.sh` refuses to start when the destination cannot hold the
result. Neither guard exists for bags written by the recorder itself.

---

## Open Issues

### Car size should be fix
- src/vehicle/golfcart_vehicle_launch/golfcart_vehicle_description/urdf/vehicle.xacro




### ~~No sensors physically connected~~ (2026-04-07) — superseded

Kept for history. As of 2026-08-10 both LiDARs, the Xsens and the ZED X are wired
and the first three enumerate; see *Sensor status* at the top of this file for
what actually produces data.

- **Status**: The target machine has all software dependencies installed but zero external sensors are attached.
- **Hardware available on the board**:
  - 4× Ethernet ports (1 active on LAN at 192.168.10.182; 3 spare for LiDAR)
  - 2× CAN bus interfaces (`can0`, `can1`) — available but DOWN (useful for Turing Drive DBW)
  - 9× I2C buses (`i2c-0` through `i2c-8`)
  - 3× Tegra UART ports (`ttyTHS1`–`ttyTHS3`)
  - GMSL camera connectors (ZED-X driver probes but no cameras present)
- **Missing connections**:
  - No Velodyne VLP-32C — no interface on 192.168.7.x subnet
  - No u-blox GNSS — no `/dev/ttyACM*` or `/dev/ublox-gps`
  - No Tamagawa IMU — no serial devices
  - No cameras — no `/dev/video*` devices
- **Impact**: All hardware verification tasks (LiDAR in RViz, GNSS fix, IMU data, camera streaming) remain blocked on physical sensor connection.
- **Action**: Connect sensors to the Orin DevKit and configure network/serial interfaces.


### `camera.launch.xml` still uses ZED driver, not USB camera

- **File**: `src/sensor_kit/golfcart_sensor_kit_launch/golfcart_sensor_kit_launch/launch/camera.launch.xml`
- **Status**: The launch file still includes `zed_wrapper/launch/zed_camera.launch.py` with `camera_model` defaulting to `zedxm`, left over from the previous Golf Cart system. Per the migration plan, the golf cart uses USB cameras (`camera_model:=usb`) and will later upgrade to TIER IV GMSL.
- **Impact**: Launching camera with `camera_model:=usb` does nothing useful — it just passes `usb` to the ZED wrapper. USB cameras (via `ros-humble-usb-cam`, already installed on target) are never started.
- **Action**: Rewrite `camera.launch.xml` to launch `usb_cam` for `camera_model:=usb` (and `none` for no camera). Keep a path for `camera_model:=tier4` when GMSL hardware arrives. Remove the ZED wrapper include.


### Tamagawa IMU driver — Placeholder only

- **Package**: Unknown (driver source not confirmed)
- **Status**: `just tamagawa-imu` creates a marker file but installs nothing.
- **Impact**: IMU launch will fail until the driver is obtained and manually installed.
- **Action**: Request Turing Drive (the company) to provide the Tamagawa IMU driver package.


### Sensor mount calibration — values present but unverified on golf cart

- **Files**:
  - `src/param/autoware_individual_params/.../sensor_kit_calibration.yaml` (active, used at runtime)
  - `src/sensor_kit/golfcart_sensor_kit_launch/golfcart_sensor_kit_description/config/sensor_kit_calibration.yaml` (used by URDF/xacro)
- **Status**: Both files are synchronized and contain plausible meter values (verified 2026-04-07):
  ```yaml
  vlp32c:        x: 0.46,  y: 0.0,  z: 1.96   # LiDAR
  imu_link:      x: -0.67, y: 0.03, z: 1.81   # IMU
  gnss_base_link: x: 0.83, y: 0.0,  z: 1.69   # GNSS
  ```
  The `autoware_individual_params` version also has USB camera placeholder entries.
- **Impact**: These values may be carried over from the previous vehicle, not measured on the golf cart. Using incorrect calibration will degrade NDT localization and sensor fusion.
- **Action**: Physically measure all sensor mount positions on the golf cart relative to `base_link` and verify/update both files.


### ~~`wheel_radius: 0.53` may need verification~~ — Fixed

- **File**: `src/vehicle/golfcart_vehicle_launch/golfcart_vehicle_description/config/vehicle_info.param.yaml`
- **Was**: `wheel_radius: 0.53` — this was the **diameter**, not the radius.
- **Fix**: Changed to `wheel_radius: 0.265` (0.53 / 2). Fixed 2026-04-07.

### GNSS antenna calibration — unverified on golf cart

- **File**: `src/param/autoware_individual_params/.../sensor_kit_calibration.yaml` lines 16-22
- **Status**: Values present (x=0.83, y=0.0, z=1.69) but not confirmed as measured on the golf cart. Verified 2026-04-07.
- **Impact**: GNSS initial pose will be offset if values are wrong.
- **Action**: Verify or re-measure antenna position on the golf cart.

### IMU mount calibration — unverified on golf cart

- **File**: `src/param/autoware_individual_params/.../sensor_kit_calibration.yaml` lines 9-15
- **Status**: Values present (x=-0.67, y=0.03, z=1.81) but not confirmed as measured on the golf cart. Verified 2026-04-07.
- **Impact**: IMU data will be misaligned if values are wrong. Also blocked by Tamagawa driver availability.
- **Action**: Verify or re-measure once IMU hardware is installed on the golf cart.

---

## Resolved

### Nebula decoder silent — "Missed pointcloud output deadline" (LiDAR broadcasting)

- **Symptom**: `ros2 launch sensors.launch.xml launch_lidar:=true ...` produced no point clouds. `velodyne_ros_wrapper_node` logged `Missed pointcloud output deadline` every 5 s. Ping to `192.168.7.10` succeeded and `tcpdump -i enP5p4s0 udp port 2368` showed ~1400 pkt/s from the LiDAR.
- **Cause**: The VLP-32C's "Host (Destination) IP" was set to `255.255.255.255` (broadcast). Nebula binds its UDP socket to the unicast `host_ip` (`192.168.7.1:2368`, confirmed via `ss -nlup`), so the kernel dropped the broadcast packets before they reached the driver — tcpdump (link layer) still saw them.
- **Fix**:
  1. In the LiDAR web UI at `http://192.168.7.10` → *Network*, set destination IP to `192.168.7.1` (the host's iface IP), click **Set** and **Save Configuration**, then power-cycle the sensor. Verified 2026-04-23: packets now `192.168.7.10:2368 → 192.168.7.1:2368`, decoder deadline warnings dropped to zero.
  2. Added a destination-IP sanity check to `scripts/check/run.sh` (tcpdump-based) that warns when the LiDAR is broadcasting instead of unicasting to the host's iface IP. Requires `tcpdump` (install via `sudo apt install tcpdump`; optional `sudo setcap cap_net_raw,cap_net_admin=eip $(which tcpdump)` to avoid the `sudo` prompt).

### `scripts/check/sensors.launch.xml` — RViz config not loading from non-`scripts/check/` CWD

- **Symptom**: Launching from any CWD other than `scripts/check/` caused RViz to start with an empty config. A PointCloud2 display added by hand then subscribed to `/velodyne_points` with default **RELIABLE** QoS, while Nebula publishes **BEST_EFFORT**, producing: `New subscription discovered on topic '/velodyne_points', requesting incompatible QoS ... RELIABILITY_QOS_POLICY`.
- **Cause**: The launch used `args="-d sensors.rviz"` (relative path). Fix attempt 1 (`-d $(dirname)/sensors.rviz` inline on the node) also failed: `$(dirname)` is evaluated lazily and, after the `<include>` of `velodyne_launch_all_hw.xml`, resolved to `/opt/autoware/.../nebula_ros/launch/` rather than the top-level file's directory.
- **Fix**: Capture `$(dirname)` into an `<arg>` declared **before** any `<include>`, then reference via `$(var ...)` on the node:
  ```xml
  <arg name="rviz_config" default="$(dirname)/sensors.rviz"/>
  ...
  <node pkg="rviz2" exec="rviz2" name="rviz2_sensors" args="-d $(var rviz_config)"/>
  ```
  With the saved config loading correctly, the RViz subscription uses BEST_EFFORT and the QoS warning only appears once during RViz startup as a transient probe (benign, does not recur).

### `just build` / `just test` / `just setup` (ros-deps) — Duplicate `individual_params` package

- **Error**: `Duplicate package names not supported: individual_params` (colcon) / `Multiple packages found with the same name "individual_params"` (rosdep)
- **Cause**: `src/` contained two packages with the same name:
  - `src/param/autoware_individual_params/individual_params/` (ours)
  - `src/localization/cuda_ndt_matcher/src/autoware_rosbag_replay/individual_params/` (internal tool inside submodule)
- **Fix**: Added `COLCON_IGNORE` marker file to `src/localization/cuda_ndt_matcher/src/autoware_rosbag_replay/`. Verified: `just build`, `just test`, and `rosdep check` all pass.

### `just check-sensors` — Missing `install/setup.bash`

- **Error**: `scripts/check/run.sh: line 6: .../install/setup.bash: No such file or directory`
- **Cause**: `scripts/check/run.sh` unconditionally sourced `install/setup.bash`, which only exists after `just build`.
- **Fix**: Added guard in `run.sh` that prints `"Error: install/setup.bash not found. Run 'just build' first."` and exits.

### Nebula & u-blox drivers — No standalone install step

- **Nebula apt packages**: `ros-humble-nebula-ros-1-5-0`, `ros-humble-nebula-decoders-1-5-0`, etc.
- **u-blox apt packages**: `ros-humble-ublox-gps`, `ros-humble-ublox-msgs`, `ros-humble-ublox-serialization`
- **Fix**: Added dedicated `nebula-driver` and `ublox-driver` recipes to `setup/justfile`. Both run as core (non-optional) steps so drivers are available even if the user skips Autoware Debian.

### TIER IV camera driver — Was placeholder only

- **Status**: `just tier4-camera` was a stub that created a marker but installed nothing.
- **Fix**: Replaced with real install script (`setup/scripts/install-tier4-camera.sh`) that installs `ros-humble-usb-cam` and `v4l-utils`. The GMSL2-USB 3.0 Conversion Kit presents the TIER IV C1 as a standard UVC device. Udev rules template installed at `/etc/udev/rules.d/99-tier4-camera.rules` (requires port path configuration when hardware is connected). Note: `ros-humble-v4l2-camera` was originally planned but is unavailable in the Humble arm64 apt repo (404); `usb_cam` is the replacement.

### GNSS default receiver was `garmin`, not `ublox`

- **File**: `src/sensor_kit/golfcart_sensor_kit_launch/.../launch/gnss.launch.xml` line 3
- **Fix**: Changed default `gnss_receiver` from `garmin` to `ublox`.

---

### ~~TIER IV camera driver — `v4l2-camera` not installed on target~~ — Resolved

- **Was**: `ros-humble-v4l2-camera` planned but unavailable in Humble arm64 apt repo (404 Not Found).
- **Fix**: Switched to `ros-humble-usb-cam` (already installed on target, v0.8.1). Both are V4L2-based UVC drivers; `usb_cam` covers the same use case. Updated `setup/scripts/install-tier4-camera.sh` to use `usb_cam`. Resolved 2026-04-07.

---

## Reference: `just setup` on Fresh JetPack 6.2

The setup chain is:
```
ros2 → ros2-dev-tools → gdown → geographiclib → pacmod → dev-tools
→ autoware-debian → isaac-ros → python-deps → nebula-driver
→ ublox-driver → ublox-udev → tier4-camera → cyclonedds-sysctl
→ turbovnc-virtualgl → tamagawa-imu → ros-deps
```

| Step | Will it work? | Notes |
|------|--------------|-------|
| `ros2` | Yes | Installs `ros-humble-desktop` from packages.ros.org |
| `ros2-dev-tools` | Yes | Standard apt packages + `rosdep init` |
| `gdown` | Yes | `pip3 install --user gdown` (no PEP 668 on Ubuntu 22.04) |
| `geographiclib` | Yes | apt + `geographiclib-get-geoids` |
| `pacmod` | Yes | Adds AutonomouStuff apt repo |
| `dev-tools` | Yes | git-lfs, golang, pre-commit, plotjuggler |
| `autoware-debian` | Yes | Downloads JP6.2 deb — matches the target machine |
| `isaac-ros` | Yes (if selected) | Adds NVIDIA Isaac ROS apt repo, installs cuVSLAM/cuVGL |
| `python-deps` | Yes | `play_launch>=0.5.0,<0.6.0` available on PyPI |
| `nebula-driver` | Yes | Installs Nebula LiDAR 1.5.0 packages from apt |
| `ublox-driver` | Yes | Installs `ros-humble-ublox-gps`, `ublox-msgs`, `ublox-serialization` |
| `ublox-udev` | Yes | Copies udev rules, adds `dialout` group |
| ~~`usb-cam`~~ | Merged | Merged into `tier4-camera` recipe |
| `cyclonedds-sysctl` | Yes (if selected) | sysctl configuration |
| `turbovnc-virtualgl` | Yes (if selected) | Adds repos, installs, configures VirtualGL |
| `tamagawa-imu` | Stub | Prints warning, creates marker — does not install anything |
| `tier4-camera` | Yes | Installs `ros-humble-usb-cam`, `v4l-utils`, udev rules template |
| `ros-deps` | Yes | Fixed by `COLCON_IGNORE` (see Resolved section) |

All steps pass on JetPack 6.2. The Autoware Debian step installs `autoware-full-1-5-0`, which includes Nebula and u-blox drivers as transitive dependencies.

### Verified on target (2026-04-07)

| Component | Package | Installed? |
|-----------|---------|------------|
| ROS 2 Humble | `ros-humble-desktop` | Yes (0.10.0) |
| Autoware 1.5.0 | `autoware-full-1-5-0` | Yes (at `/opt/autoware/1.5.0/`) |
| Nebula LiDAR | `ros-humble-nebula-ros-1-5-0` | Yes (0.2.5) |
| u-blox GNSS | `ros-humble-ublox-gps` | Yes (2.3.0) |
| Camera (USB + TIER IV C1) | `ros-humble-usb-cam` | Yes (0.8.1) — single driver for USB and TIER IV C1 via UVC |
| CycloneDDS | `ros-humble-cyclonedds` | Yes (0.10.5) |
| GeographicLib | `geographiclib-tools` | Yes (1.52) |
| Tamagawa IMU | — | **No** (stub only) |
| PACMod | — | No (not needed) |
| Workspace build | `just build` | Yes (17 packages) |
| Disk space | — | 16 GB free of 54 GB (70% used) |
