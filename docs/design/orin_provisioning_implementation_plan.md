# Implementation Plan — Orin Provisioning + Systemd Promotion

**Status**: Working plan (2026-08-14)
**Plans**: [orin_provisioning_and_systemd_promotion.md](orin_provisioning_and_systemd_promotion.md) — the
design this sequences. Read that first; this document records what a review of
the codebase changed about it, and the order the work should land in.

---

## 1. What the codebase check confirmed

| Design claim | Verified |
|---|---|
| §2.1 `install-zed-sdk.sh` missing; build gates on `/usr/local/zed` | Yes — `justfile:31-33`, `zed-ros2-wrapper` present in `src/` |
| §2.4 units hardcode `%h/2026-golf-cart`, installer only warns | Yes — `install-orin-host.sh:18-22`; both units affected |
| §3.1 master runs from a shell trap, not systemd | Yes — `justfile:119-125`; master has `Linger=no` and no golfcart units |
| §3.2 systemd units get no direnv, so `GOLFCART_BAG_DIR` must be set explicitly | Yes — `record_master.sh` reads it, falling back to `~/rosbags` |

## 2. What the check changed

### 2.1 `./setup.sh orin` needs no change to `setup.sh`

`setup.sh:296` already ends in `just "$@"` executed inside `setup/`. Any recipe
added to `setup/justfile` is reachable as `./setup.sh <recipe>` immediately.
Design §2.3 is therefore a *recipe*, not an entry point.

One wrinkle: §2.3 steps 1 and 4 (`git submodule update`, `just build`) live in
the **root** justfile, which `setup/justfile` has no access to. The `orin`
recipe must shell out with an explicit working directory.

### 2.2 The sysctl ordering trap is already mostly closed

Design §2.1 and §2.5 treat the ZED SDK stomping `net.core.rmem_max` as an open
ordering hazard requiring `configure-cyclonedds-sysctl.sh` to re-run after every
SDK install. But that script already writes `99-cyclonedds-max.conf` — which
sorts *after* the SDK's `60-zed-buffers.conf` — and deletes the superseded
`10-cyclone-max.conf` so the two cannot disagree.

Persistence across reboot is solved. What remains is only the **running** value
in the same session as an SDK install, since dropping a file into
`/etc/sysctl.d` does not apply it. The post-SDK step is therefore
`sudo sysctl --system`, not a full re-run, and `orin-setup`'s hard ordering
constraint between `zed-sdk` and `cyclonedds-sysctl` largely dissolves.

The `orin-check` item (§2.5) stays as-is regardless: it verifies the running
value, which is exactly the thing that can still be wrong.

### 2.3 §3.1's headline justification is unverified — settle it before building on it

Design §3.1 presents `TimeoutStopSec=180` as *the fix* for the 0-byte
`metadata.yaml` roadblock. `docs/roadblocks.md:121` states the cause is
**play_launch's** shutdown grace, not the supervisor's. If roadblocks.md is
right, the systemd timeout is inert: systemd sends SIGINT to play_launch, and
play_launch still kills the recorder on its own schedule.

Neither claim is currently established, because the two hypotheses fit every
observation we have:

- *Size*: master bags (2.2 GB, 2.5 GB) fail; orin bags (~300 MB) do not.
- *Supervision*: the master runs play_launch in the foreground; the orin runs it
  under systemd with `KillSignal=SIGINT` and `TimeoutStopSec=30`.

The only systemd-supervised host never writes a large bag, so the variables have
never been separated. play_launch 0.5.1 exposes no CLI grace flag; its
`-c/--config` YAML advertises "process control", but no shutdown-timeout key
could be confirmed in the shipped binary.

This matters because §3.3 (justfile rewire) and §3.4 (installer) inherit §3.1's
justification. **Phase 0 below separates the variables before anything depends
on the answer.**

### 2.4 Stray user units on the master

`box-ddspong.service` is enabled via `default.target.wants` and running — a
leftover ROS 2 node from `~/systemd-user-test` that joins the DDS domain. Five
further `box-*` units are installed but inactive. Removing them belongs in the
phase that touches the master's user manager (Phase 2).

---

## 3. Phases

### Phase 0 — separate size from supervision — RUN 2026-08-14

Master unit (`setup/files/systemd/golfcart-master.service`) and exec script
(`scripts/multi_machine/master_unit_exec.sh`) written; justfile untouched, so
the existing launch path kept working throughout.

**Result: the bag finalized.** 3.2 GiB written to the SSD — above both previously
reproduced failures (2.2 GB, 2.5 GB) — then stopped with
`systemctl --user stop`:

```
metadata.yaml   10530 bytes (was 0 on every previous multi-GB bag)
ros2 bag info   213.9s duration, 94444 messages
PRAGMA quick_check  ok
SELECT count(*)     94444   (matches metadata exactly)
```

**But the design's stated mechanism is not what produced this.** `stop` returned
in ~1 s, so `TimeoutStopSec=180` was never approached, let alone exercised. Any
value ≥2 s would have given the same result. Whatever distinguishes the systemd
path from the foreground path, it is not the length of the grace period, and
§3.1's comment sizing the timeout "for a multi-gigabyte bag flush" describes a
mechanism that did not engage.

The obvious candidate — systemd delivering SIGINT where the foreground path did
not — does not survive scrutiny either: Ctrl-C also sends SIGINT, and
`KillMode=control-group` signals the whole cgroup much as a terminal signals the
foreground process group.

#### Control arm — same size, foreground path

Run immediately afterwards with every variable held constant except the
supervision path: same `record:=true use_gnss:=false`, no orin, same SSD
directory, same session. Started through the old `just launch-master` under
`setsid`, then stopped with `kill -INT -<pgid>` — SIGINT to the whole process
group, which is what a terminal does on Ctrl-C.

```
bag size            3.3 GB   (vs 3.2 GiB for the systemd arm)
metadata.yaml       absent
PRAGMA quick_check  ok
SELECT count(*)     100646   (data intact; only finalization was lost)
stack exit          still running after 240s (systemd arm: ~1s)
```

**Conclusion: supervision is the variable, not bag size.** Two bags of the same
size, minutes apart, same disk and same arguments: the systemd path finalized,
the foreground path did not. The design's promotion is therefore justified —
but *not* by the reason §3.1 gives, since `TimeoutStopSec` was never approached
in the arm that worked.

The mechanism remains unidentified, and the obvious candidate is now ruled out:
both paths deliver SIGINT to every process (`KillMode=control-group` signals the
whole cgroup, exactly as a terminal signals the process group). The unexplained
asymmetry is the shutdown *duration* — ~1 s under systemd versus >240 s in the
foreground arm, where play_launch was still alive when the wait expired. The
extra `just`→bash→`just`→bash layers between the signal and play_launch are the
place to look next.

Caveat: the control used `setsid` + `kill -INT -<pgid>`, not a real terminal —
faithful in signal delivery, but with no controlling tty.

**Actions taken**: `docs/roadblocks.md` corrected — its root-cause sentence
attributed the failure to a shutdown grace shorter than a multi-gigabyte flush,
which the control arm disproves at equal size. §3.1's `TimeoutStopSec` comment
should be reworded before Phase 1 lands, since it claims a mechanism that never
engaged.

---

## 4. Revision (2026-08-14) — supersedes design §3.1–3.4

Agreed after Phase 0. The design's per-host units, in-launch recording, and
launch-scoped watchdog are replaced by the structure below. Design §2.1, §2.5,
§2.6 and §3.5 carry over unchanged.

### 4.1 Workflows this has to produce

One-time, per machine:

```bash
echo master > .golfcart-host      # or: orin        (gitignored, see 4.3)
just service-install master       # or: orin
just service-remove  master       # mirror, same script
```

Daily driving — launch only, no recording:

```bash
just launch-master        # starts the launch unit here + the orin's over ssh
just stop-master
```

Recording — independent, start any time, stack up or down:

```bash
just record-start         # both hosts begin recording to their own disks
just record-status
just record-stop          # both finalize
just bag-fetch-orin       # existing, unchanged
just bag-merge <a> <b>    # existing, unchanged
```

Terminal:

```bash
cd ~/2026-golf-cart       # direnv resolves the DDS profile from the marker
ros2 topic list           # sees the live graph on either machine
just doctor               # resolved profile, host role, unit states, bag dir
```

### 4.2 Units and scripts

| Unit | Hosts | Purpose |
|---|---|---|
| `golfcart-launch.service` | both | play_launch only; role from a drop-in |
| `golfcart-record.service` | both | rosbag only; independent lifecycle |
| `golfcart-watchdog.service` | orin | independent; see 4.5 |

One unit file per role-independent job, not per host. The installer writes a
drop-in carrying `Environment=GOLFCART_HOST=master|orin` plus the resolved repo
path, which also retires the `%h/2026-golf-cart` hardcode (design §2.4).

`master_unit_exec.sh` and `orin_unit_exec.sh` collapse into one
`launch_unit_exec.sh` that derives the DDS profile and `host:=` argument from
`GOLFCART_HOST`.

Installer: `setup/scripts/install-host-service.sh <master|orin> [--remove]`,
replacing `install-orin-host.sh`; recipes `just service-install|service-remove
ROLE`. It installs units, `daemon-reload`s, and enables lingering — required on
the master, which currently has `Linger=no` and would lose its units with the
terminal.

### 4.3 Host identity: a marker file, not an IP probe

`.golfcart-host` in the repo root, gitignored, containing `master` or `orin`.
`.envrc` reads it and validates the value against `config/cyclonedds/<value>.xml`.

An earlier draft inferred the role from a local `192.168.125.x` address. Rejected:
addresses change, and inference hides identity. When the marker is missing,
`.envrc` falls back to `loopback` and prints how to create one, rather than
guessing.

### 4.4 Remote control and its config

Remote control is **ssh + running the same recipe on the far side**. A ROS service
or topic was rejected: it would only work while DDS is healthy and something is
running to host it, coupling recording to exactly the thing it must be
independent of.

Revised 2026-08-14, after a first attempt built a 243-line `orin_remote.sh` with
unit aliases, per-unit failure policies and implied-unit rules. All of it
duplicated, on the master, decisions the orin can make for itself. Since both
machines carry the same repository, the whole remote layer is instead
`scripts/multi_machine/on_orin.sh` — how to log in and where to `cd`, nothing
else — and orchestration is symmetric per-host recipes (`launch-up`,
`launch-down`, `record-up`, `record-down`, `host-status`) run locally and then
over there. The exit status is the remote command's, so callers decide what a
failure means rather than having a policy imposed on them.

`config/multi_machine.conf` (tracked) holds `ORIN_SSH`, `MASTER_IP`,
`ORIN_SSH_KEY` and `ORIN_WORKSPACE` — the last accepting `~/path`, expanded by
the *remote* shell. It is sourced by `on_orin.sh`, the watchdog, `setup_ssh.sh`
and `bag_fetch_orin.sh`, which previously each carried their own hardcoded copy.

`scripts/multi_machine/setup_ssh.sh` generates a key if absent and runs
`ssh-copy-id` to the configured remote. Interactive by nature; the maintainer
runs it. No credential handling beyond that.

### 4.5 The watchdog becomes independent

Today `golfcart-orin-watchdog.service` is `PartOf=golfcart-orin.service`: it
exists only while the launch unit runs, and stops only that unit.

Splitting recording out breaks both halves of that. A network cut would leave the
orin recording forever and filling its disk, with no master left to call
`record-stop` — the exact failure the watchdog exists to prevent, newly
uncovered. And `PartOf` scoped to the launch unit means the watchdog is absent
precisely when recording runs alone; scoping it to both units is wrong in the
other direction, since it would be torn down when the launch stops while
recording continues.

So the watchdog runs as its own unit:

- started by whichever remote start command runs first (launch or record);
- on master loss, stops **every** active `golfcart-*` unit, not just the launch;
- exits once no `golfcart-*` unit is active, so it never pings indefinitely on a
  machine being used standalone.

Detection is unchanged and stays ping-based: ~42 s to fire (6 misses × (5 s
interval + 2 s ping timeout)). A DDS heartbeat would add a ROS dependency to the
one process whose job is surviving ROS being broken, and covers no failure the
ssh stop does not already handle.

Accepted cost: a master reboot mid-recording now kills the recording after ~42 s.
One timeout for both units was chosen over a longer recorder timeout — an
interrupted recording is recoverable, a full disk is not.

### 4.6 Recording infrastructure

| Piece | Path |
|---|---|
| Topic lists | `config/recording/master_topics.txt`, `orin_topics.txt` |
| Recorder entry point | `scripts/recording/record_unit_exec.sh` |
| Unit | `golfcart-record.service` |
| Both-sides control | `just record-start` / `record-stop` / `record-status` |

Topic-list format follows the existing `scripts/testing/rosbag/record_topics.txt`
(one topic per line, `#` comments), which is folded in as the seed rather than
having a second convention invented alongside it.

`record:` and both recorder `node:` entries come out of `golfcart.launch.yaml`,
and `GOLFCART_RECORD` out of the exec scripts. Beyond the separation you asked
for, this **dissolves the metadata.yaml roadblock at its root**: the recorder
stops being a play_launch child, so play_launch's shutdown — whatever it is doing
wrong, still unidentified — can no longer reach it.

If the orin is unreachable, the master still records; the failure is reported and
the command exits non-zero. Consistent with the standing rule that a missing orin
never blocks the master.

### 4.7 Environment, and the ros2 daemon

`.envrc` resolves the profile from the marker file. No daemon automation: a
daemon's DDS context is fixed when it starts, so `.envrc` cannot repair a running
one. `just doctor` instead reports that a daemon is running and says to
`ros2 daemon stop` when the graph looks wrong — a warning, not a side effect.

A sourceable `scripts/env.sh` covers bare (non-direnv) shells; units set their
own environment already.

---

## 5. Phases

| # | Work | State |
|---|---|---|
| 1 | Consolidated installer + `golfcart-launch.service` + `launch_unit_exec.sh` (4.2) | **done** 2026-08-14 |
| 2 | Marker file, `.envrc` resolution, `scripts/env.sh`, `just doctor` (4.3, 4.7) | **done** 2026-08-14 |
| 3 | `config/multi_machine.conf`, `setup_ssh.sh`, remote control rewire (4.4) | **done** 2026-08-14 |
| 4 | Recording infra; strip `record:` from the launch file (4.6) | **done** 2026-08-14 |
| 5 | Independent watchdog (4.5) | **done** 2026-08-14 |
| 6 | justfile rewire: `launch-master` to the systemd path, `stop-master` | **done** 2026-08-14 |
| 7 | Orin provisioning: `install-zed-sdk.sh`, `orin` recipe (design §2.1–2.3, revised per §2.2) | blocked: ZED SDK delivery |
| 8 | `orin-check` (design §2.5) | **partly done**: `just doctor` / `just doctor-orin` cover every item except the two ZED ones, which need phase 7 |
| 9 | CLAUDE.md's stale AutoSDV `golfcart` CLI section | **done** 2026-08-14 |

Phases 1–5 landed together. `docs/multi-machine.md` was rewritten with them
(daily operation, recording, provisioning, watchdog, DDS profile, environment
variables, the topic-list audit), so only the CLAUDE.md correction is left of the
original phase 9.

The justfile gained `service-install`, `service-remove`, `service-status`,
`ssh-setup`, `record-start`, `record-stop`, `record-status` and `doctor`, all
additive. `launch-master` was updated to the new per-host recipes and had
its `record:=` parsing removed — required, since that argument no longer exists —
but still runs play_launch in the foreground. Moving it onto the unit is phase 6.

### Deviations found while implementing

- **§4.5 contained a race.** "Started by whichever remote start runs first" and
  "exits once no `golfcart-*` unit is active" contradict each other at startup:
  the watchdog can reach its first poll before the unit it guards goes active, and
  exit immediately. Resolved with a startup grace window
  (`GOLFCART_WATCHDOG_STARTUP_GRACE`, 60 s), and the orin's watchdog is brought
  up before the unit it guards.
- **`golfcart-master.service` was never installed by anything.** §4.2 framed the
  new installer as replacing `install-orin-host.sh` "for parity", but that script
  only ever handled the orin; the master unit was dead code with no installer and
  no lingering. The installer makes it real for the first time.
- **`GOLFCART_MASTER_ARGS` → `GOLFCART_LAUNCH_ARGS`.** Only the master exec script
  accepted extra launch arguments; the merged script serves both roles.
- **`golfcart_launch/CMakeLists.txt` installed the two recorder scripts.** Deleting
  them without touching it would have broken the build.
- **Launch-unit `TimeoutStopSec` is 30, not the design's 180.** Phase 0 measured a
  ~1 s stop, and the bag flush that justified 180 no longer happens in that
  process tree at all.

## 6. Decisions

Resolved 2026-08-14: marker file over IP inference (4.3); ssh + systemd for
remote control (4.4); independent watchdog with a shared timeout (4.5);
recording as a systemd unit, removed from the launch file (4.6); no daemon
automation (4.7).

Resolved 2026-08-14: **Ctrl-C semantics** — the master moves fully onto systemd.
`launch-master` returns immediately, `just stop-master` is the stop verb, and no
terminal is occupied. `launch-master`'s EXIT trap is gone with it; the orin is
torn down by `stop-master`, with the watchdog as the backstop for everything else.

Still open:

1. **ZED SDK delivery.** Pinned download at install time vs. staging the ~1.5 GB
   `.run` locally. Blocks phase 7.

## 8. The ssh key, and why it is named explicitly

Key-based ssh to the orin used to work **only from an interactive terminal**. The
authorized key was `~/.ssh/golfcart_slave` — a non-default filename, reachable
only through the gnome-keyring agent. ssh tries default names
(`id_ed25519`, `id_rsa`, …) and nothing else, so with the agent removed:

```
$ env -u SSH_AUTH_SOCK ssh -o BatchMode=yes -o IdentitiesOnly=yes jetson@192.168.125.101 hostname
jetson@192.168.125.101: Permission denied (publickey,password).
```

systemd units carry no agent, so every unit-driven remote call would have failed
while the same command kept working by hand — the worst kind of intermittent.

Resolved by pinning a **dedicated key at a fixed path**,
`ORIN_SSH_KEY` (default `~/.ssh/golfcart_orin`), which `setup_ssh.sh` creates and
copies. Two properties matter and neither is optional:

- It is never `~/.ssh/id_*`, so the installer cannot generate over or silently
  adopt a key the user relies on elsewhere.
- Every consumer passes it with `ssh -i`. A fixed non-default name only works if
  it is named explicitly; otherwise it reintroduces the exact agent dependency
  above.

`setup_ssh.sh` verifies with `env -u SSH_AUTH_SOCK`, because a running agent can
make the check pass while every unit still fails.

## 7. Carried over from the original design

Still to fix, unchanged by this revision:

- `box-ddspong.service` is enabled and running on the master, a leftover ROS 2
  node from `~/systemd-user-test` that joins the DDS domain. Five further `box-*`
  units are installed but inactive. Remove in phase 1.
- Design §3.1's `TimeoutStopSec` comment claims a mechanism Phase 0 showed never
  engages; reword when the unit is rewritten.
