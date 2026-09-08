# Phase 4-M: system_monitor across both machines

Belongs to **Phase 4, Track A (MRM & Safety Review)** in [ROADMAP.md](../../ROADMAP.md),
alongside [4-O: abnormality observability](4-diagnostics-observability.md).

4-O is about making the diagnostic graph readable. This one is about the leaves
that feed it: making them exist on both machines, making them mean something on
Jetson hardware, and making the two hosts distinguishable once they both publish.

Everything below was measured on 2026-09-08 against the live pair — the
Advantech (`advantech`, 192.168.125.100) and the second AGX Orin (`orin`,
192.168.125.101) — and against `play_log/2026-08-28_14-42-31`, the most recent
captured run.

## What was wrong

### M-1. The 2026-08-28 fix was committed and never installed — FIXED

`fe0c27a` added three files and `docs/known-config-defects.md#4` records the
defect as FIXED. It was not running. `--symlink-install` only creates symlinks
for files that exist at build time, and `install/golfcart_launch` was last built
**2026-08-21**, six days before those files were written. So this was the state
of the installed package until this phase:

```
$ ls $(ros2 pkg prefix golfcart_launch)/share/golfcart_launch/launch/components/
aruco_detector.launch.xml         golfcart_map_component.launch.xml
aruco_localization.launch.xml     tier4_localization_component.launch.xml
```

Missing: `tier4_system_component.launch.xml`,
`golfcart_system_monitor_nodes.launch.xml`, `planning_sim_vehicle.launch.xml`,
and the whole `config/system/system_monitor/` directory —
`golfcart_autoware.launch.xml:101` includes the first of those by
`find-pkg-share`.

The captured run shows the consequence, all eight monitors and the stock
parameters:

| leaf | level | reports |
|---|---|---|
| `gpu_monitor` (5 checks) | ERROR | 59 each |
| `hdd_monitor` Temperature / PowerOnHours / RecoveredError / TotalDataWritten | ERROR | 58 each |
| `voltage_monitor: CMOS Battery Status` | WARNING | 112 |

**The general lesson, which is not specific to this phase: a new file in an
already-built package is invisible until the package is rebuilt.** Editing an
existing installed file needs no rebuild; adding one does. A launch file that
does not exist in `install/` fails at `find-pkg-share` with no hint that the
source tree has it.

### M-2. `if=` on a `<composable_node>` was silently ignored — FIXED

This is why M-1 was believable for eleven days. `fe0c27a`'s message says
"Verified by resolving the full launch: five monitors instead of eight" — and
that verification does not reproduce under the parser that actually runs the
vehicle.

Minimal case, argument false:

```xml
<node_container pkg="rclcpp_components" exec="component_container_mt" name="c" namespace="t">
  <composable_node pkg="autoware_system_monitor" plugin="CPUMonitor" name="a"/>
  <composable_node pkg="autoware_system_monitor" plugin="MemMonitor" name="b_inline_if" if="$(var enable_b)"/>
</node_container>
<group if="$(var enable_b)">
  <load_composable_node target="/t/c">
    <composable_node pkg="autoware_system_monitor" plugin="GPUMonitor" name="b_group_if"/>
  </load_composable_node>
</group>
```

| | `b_inline_if` | `b_group_if` |
|---|---|---|
| play_launch Rust parser (the default) | **present** | absent |
| play_launch Python parser | absent | absent |

`ros2 launch` agrees with the Python parser. The two forms mean the same thing
in ROS 2 and different things under the Rust parser, so the excluded monitor was
loaded anyway.

**This is a play_launch bug that was already fixed upstream and not installed
here.** `19e5abc6`, "fix(parser): honour if/unless on composable_node (#7)",
landed 2026-08-22 00:41 and is on `origin/main`; the wheel installed on this
machine was 0.9.0 dated **2026-08-21 17:05**, under seven hours older. The
`container.rs` comment upstream describes exactly this symptom. So the two
staleness problems, M-1 and M-2, are the same Aug-21 snapshot seen twice.

play_launch has since been rebuilt and installed on the Advantech (**0.10.0**),
and the minimal case above now resolves to `['/a', '/t/c']` under both parsers.
The orin is a different story — see M-H.

`golfcart_system_monitor_nodes.launch.xml` now uses the `<group if>` +
`<load_composable_node>` form regardless, because it resolves identically under
both parsers and does not depend on which play_launch a machine happens to have.

### M-3. Nothing monitored the orin at all

`golfcart_autoware.launch.xml` — and with it the entire system component — is
inside `if: $(var is_master)`. The orin's group held exactly one thing, the ZED
camera. Every `system_monitor` row in the captured run carries `hardware_id:
advantech`; `orin` appears zero times.

### M-4. Two hosts, one set of diagnostic names

`diagnostic_updater` builds each status name as `node_name + ": " + task_name`
(`diagnostic_updater.hpp:593`), where `node_name` is `get_name()` — **without the
namespace**. Its publisher is hardcoded to the absolute topic `/diagnostics`
(`diagnostic_updater.hpp:391`). So two hosts running the same monitors publish
byte-identical names, and no namespace can separate them.

Nothing breaks today: `golfcart_system_monitor_node.py:658` keys its table on
`hardware_id/name`, and `hardware_id` is the hostname. But a diagnostic graph
leaf matches on **name alone**, so the moment 4-O adds system monitor leaves, one
leaf would be fed by two machines and flip between them with nothing to show why.

### M-5. Machine-specific parameters that only described one machine

`net_monitor`'s `devices` list is true of exactly one host. `ntp_monitor`'s
`server: ntp.nict.jp` cannot be reached from the orin, which has no DNS:

```
$ ssh jetson@orin.local 'git ls-remote origin'
ssh: Could not resolve hostname github.com: Temporary failure in name resolution
```

## The two-host picture

Measured on the orin:

| | value | consequence |
|---|---|---|
| hostname | `orin` | `hardware_id` separates the hosts for free |
| interfaces UP | `lo`, `eno1` | `wlP1p1s0 can0 can1 l4tbr0 usb0 usb1 docker0` are all DOWN, and NetMonitor ERRORs if any monitored interface is down |
| NVML | absent | Autoware's `GPUMonitor` is NVML-only in this build |
| DNS | none | `ntp.nict.jp` unreachable |
| chrony | synced to 192.168.125.100, offset +75 µs | the master is both the reachable NTP answer and the correct one |

Nothing needs bridging for the orin's rows to reach the master: absolute
`/diagnostics`, one DDS domain. The aggregator stays master-only — one graph per
vehicle.

## What runs where

`is_orin` is `host in ('orin', 'all')`, so it is **true in single-machine mode**.
That distinction is the trap in this phase:

- `is_orin` means *"this device is present"*. A camera exists once, wherever it
  hangs, so the ZED group keys on it.
- `is_orin_host` (`host == 'orin'`) means *"this machine is the second box"*. A
  monitor set describes the host it runs on, and under `host:=all` there is one
  host, already covered by the master's set.

Gating the monitors on `is_orin` would put ten monitors on one machine in
single-machine mode, with `orin_net_monitor` watching `eno1` — an interface the
Advantech does not have — ERROR forever.

| | `host:=master` | `host:=orin` | `host:=all` |
|---|---|---|---|
| `golfcart_autoware` → `tier4_system_component` | yes | no | yes |
| cpu, mem, net, ntp, process (unprefixed) | yes | — | yes |
| the same five, `orin_` prefixed | — | yes | **no** |
| `diagnostic_graph_aggregator` | yes | no | yes |
| `golfcart_system_monitor` web UI :8080 | yes | yes | yes |

Both web UIs see both machines, because both subscribe to the one `/diagnostics`.

## The address is written down once

`config/multi_machine.conf` is the only file in the repository containing either
machine's address. It was already the single source for the ssh scripts in
`scripts/multi_machine/`, which each source it directly. This phase extends that
to the launch tree:

```
config/multi_machine.conf   MASTER_IP="${GOLFCART_MASTER_IP:-192.168.125.100}"
  -> scripts/env.sh         export GOLFCART_MASTER_IP="${MASTER_IP}"
  -> golfcart.launch.yaml   <arg name="master_ip" default="$(env GOLFCART_MASTER_IP)"/>
  -> orin_system_monitor    <arg name="ntp_server" value="$(var master_ip)"/>
  -> the NTPMonitor node    <param name="server" value="$(var ntp_server)"/>
```

There is **no fallback literal** in the launch file on purpose: a second copy of
an address is the thing being avoided, and an unset variable fails loudly at
launch rather than silently measuring the wrong machine's clock. `.envrc` and the
systemd units both source `scripts/env.sh`, so it is set on every path that
starts this stack.

The `<param name="server">` sits *after* `<param from=…>`, so it overrides that
one field and leaves `offset_warn`, `offset_error` and `timeout` as Autoware set
them. Verified in the resolved model:
`{'offset_error': 5.0, 'offset_warn': 0.1, 'server': '192.168.125.100', 'timeout': 5}`.

## Work items

### M-A: install what was already committed — DONE

`colcon build --packages-select golfcart_launch`. All seven components and the
`config/system/system_monitor/` directory now install. A stale dangling symlink
to the old `net_monitor.param.yaml` was removed by hand; colcon does not prune.

### M-B: parser-portable gating — DONE

`golfcart_system_monitor_nodes.launch.xml` moves `hdd`, `gpu` and `voltage` out
of the container body into `<group if>` + `<load_composable_node>`. Verified: 144
nodes and five monitors under **both** parsers, where the Rust parser previously
gave 147 and eight.

### M-C: per-host parameters — DONE

- `net_monitor.param.yaml` → `net_monitor_master.param.yaml`; neither file is the
  unmarked default, because the device list is true of one machine.
- `net_monitor_orin.param.yaml`, `devices: ["lo", "eno1"]`.
- `enable_traffic_monitor` is now **false on both**. It needs the `traffic_reader`
  daemon from `/opt/autoware/1.5.0/lib/autoware_system_monitor/`, which no unit
  starts on either machine, so NetMonitor logged `Failed to connect socket. No
  such file or directory` every cycle — the one permanently-red check left after
  the 2026-08-28 pass.

### M-D: the orin's monitors — DONE, not yet run on the vehicle

`launch/components/orin_system_monitor.launch.xml`, included from the
`is_orin_host` group. Resolves under both parsers to five `orin_`-prefixed
monitors with `net_monitor_orin.param.yaml` and `ntp_server` = the master.

### M-E: deploy to the orin — DONE

Resolved by installing the orin's public key on the master, which made the orin
able to ssh *back*. That turned the transport around: the orin fetches from the
master as an ordinary git remote, so there is no push into a checked-out repo, no
`receive.denyCurrentBranch`, no side refs to clean up afterwards.

```bash
# on the orin
git remote add master ubuntu@192.168.125.100:/mnt/external/2026-golf-cart
git fetch master main
git -C src/localization/cuda_ndt_matcher checkout -- Cargo.lock   # build artifact; blocks the update
git merge --ff-only master/main
git submodule foreach --quiet '
  gd=$(git rev-parse --absolute-git-dir | sed "s|.*/\.git/modules/|.git/modules/|")
  git fetch -q ubuntu@192.168.125.100:/mnt/external/2026-golf-cart/$gd \
      "+refs/heads/*:refs/remotes/mstr/heads/*" "+refs/remotes/origin/*:refs/remotes/mstr/origin/*"
'
git submodule update --init --recursive
```

`5b30dec` → `d37d4f7`, 233 commits, fast-forward, all 13 submodules clean. Both
refspecs are needed: `cuda_ndt_matcher/tests/rosbag_replay`'s pinned SHA is
reachable only from `refs/remotes/origin/main` in the master's gitdir, not from
any local head, so fetching heads alone leaves `git submodule update` asking
GitHub for a commit it cannot reach.

Nothing here touches the Submodule Pointer Rule: every pointer on `main` is
already on a long-lived fork branch, so this transports only published commits.
Two standing constraints — never commit on the orin, since such a commit would
exist nowhere else, and the orin keeps a `master` remote and `mstr/*` tracking
refs afterwards.

The orin has since also been given internet through a phone hotspot on
`wlP1p1s0`, so a plain `git pull` works there again; the fetch-from-master path
remains the one that works with no uplink at all.

Two things found while rebuilding it, neither caused by this phase:

- **`install/` there held a fully dangling `golfcart_board_initializer`** — the
  package was deleted upstream in `84b33f6` and colcon never prunes, so
  `find-pkg-share` could still resolve it to nothing. `golfcart_launch` was
  rebuilt from scratch to clear the same class of leftover in its own tree; the
  board initializer's is still there.
- **OpenCV**: the orin's 4.8.0 from NVIDIA's apt shadowed Ubuntu's 4.5.4 and
  carried no `aruco` module, so `golfcart_aruco_localizer` failed with `Could NOT
  find OpenCV (missing: aruco)` — and under plain `just build` that one failure
  aborts the whole build, which is how a 44-package build looked like a success.
  Fixed by re-running `./setup.sh` on the orin.

`just build` does not forward its `*FLAGS` to colcon — only `--clean` is read
(`justfile:59`) — so building past a failure means invoking colcon directly, and
then `scripts/_env_guard.sh` must be sourced by hand or the build fails with
`No module named 'ament_package'` a long way from the cause.

**Why this was blocked, and the documentation gap it exposed.** The orin's only
remote was `git@github.com:...` and it had no DNS, so the documented update path
— `docs/multi-machine.md:404-406`, which assumes the orin pulls from GitHub
itself — had never been possible on that machine. No rsync or git-push path
existed either: `scripts/multi_machine/on_orin.sh:96` is ssh command execution
only, and `bag_fetch_orin.sh:149` pulls bags the other way. That doc still
describes the GitHub pull as the way to update the orin and should say what to do
when the machine has no uplink.

### M-F: a GPU diagnostic that works on Jetson — NOT STARTED

Autoware's `GPUMonitor` needs NVML and neither machine has it, so it stays off on
both. jtop does not use NVML either: `jtop/core/gpu.py:27` sets
`DEFAULT_IGPU_PATH = "/sys/class/devfreq/"` and reads `load` as per-mille.

We already read the same files —
`scripts/profiling/jetson_gpu_sampler.py:39`, from `2f5edb8`. Verified identical
and unprivileged-readable on both hosts:

| | advantech | orin |
|---|---|---|
| `/sys/devices/platform/gpu.0/load` | 0 | 0 |
| `/sys/class/devfreq/17000000.gpu/cur_freq` | 306000000 | 306000000 |
| `ina3221` hwmon rails | hwmon1, hwmon2 | hwmon1, hwmon2 |

So the work is a small diagnostic publisher wrapping that sampler — GPU load,
clock, and the VDD_GPU_SOC rail — named so it can become a graph leaf per host.
It is the only one of the three disabled monitors that has a real answer on this
hardware; `hdd_monitor` needs a daemon nobody wants and `voltage_monitor` needs a
CMOS battery that does not exist.

### M-H: play_launch versions drifted between the machines — CLOSED, with a gap left

Found while fixing M-2. The two hosts were running launch resolvers a month
apart:

| | before | after |
|---|---|---|
| Advantech | 0.9.0, 2026-08-21 | **0.10.0**, 2026-09-08 |
| orin | 0.5.1, **2026-08-07** | **0.10.0** |

The units on both hosts resolve the *same* launch files with these binaries, so
the machines could disagree about what the launch tree means — and both old
versions predate `19e5abc6`, so both had the `if=` bug M-2 is about. Both are now
0.10.0, built from `/mnt/external/play_launch` and installed on the orin from the
same wheel; the minimal case resolves to `['/a', '/t/c']` under the Rust parser
on both.

**The gap that remains: nothing pins or checks this.** A launch resolver is part
of the deployed system, and the drift was invisible until someone went looking —
there is no reason it will not happen again. `just service doctor` is the obvious
place for a version comparison across the pair, and it does not do one today.

### M-G: system monitor leaves in the diagnostic graph — NOT STARTED, needs 4-O

`autoware-main.yaml` has no system monitor leaves, so none of these rows reach
the graph today; they are visible only in the web UI. Adding them is what makes
the `orin_` prefix load-bearing rather than merely tidy, and it belongs with 4-O
rather than here.

## Verification status

Resolved on the machine each mode belongs to:

| what | where | result |
|---|---|---|
| `host:=master`, both parsers | Advantech | 144 nodes, five monitors, `net_monitor_master.param.yaml` (was 147 and eight under the Rust parser) |
| `host:=orin` | orin | 11 nodes, five `orin_`-prefixed monitors |
| `orin_system_monitor.launch.xml` standalone, both parsers | Advantech | five `orin_` monitors, `net_monitor_orin.param.yaml`, `ntp_server` 192.168.125.100 merged over Autoware's thresholds |
| the `is_orin` / `is_orin_host` gate, all three modes | Advantech | see below |

The gate was verified on a reduced launch file carrying only the two `<let>`s and
one stand-in node per group, because neither machine can resolve `host:=all`
end-to-end — the Advantech has no `zed_wrapper`, and on the orin the full master
stack dies at `KeyError: 'rear_overhang'` for want of the vehicle description.
Both are pre-existing environment gaps, unrelated to this phase.

| `host` | `is_orin` group (the ZED) | `is_orin_host` group (the monitors) |
|---|---|---|
| `master` | absent | absent |
| `orin` | present | present |
| `all` | present | **absent** |

That last row is the property this phase turns on: in single-machine mode the
camera group still fires, and the monitor group does not.

**Nothing here has run on the vehicle.** The orin now carries the code — see
M-E — but no stack has been brought up on either machine since.
