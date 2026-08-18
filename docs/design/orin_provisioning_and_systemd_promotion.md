# Orin Provisioning Script + Systemd Promotion of Both Hosts' Launches

**Status**: Proposed (2026-08-11)
**Builds on**: [multi_machine_deployment.md](multi_machine_deployment.md) — the
two-machine architecture this extends. Operational reference:
[../multi-machine.md](../multi-machine.md).

**Goal**:

1. A single entry point (`./setup.sh orin`) that provisions a fresh orin (slave
   Jetson) from bare JetPack to "the master can start me", replacing the manual
   checklist in docs/multi-machine.md.
2. The master's launch promoted to a systemd user service, symmetric with the
   orin's, so both hosts run under the same lifecycle mechanism — and the
   shell-trap orchestration in `just launch-master` moves into the unit, where
   it survives every stop path.

---

## 1. Background: what exists, what is missing

### Orin provisioning today

The one-time setup is a hand-run list (docs/multi-machine.md §"One-time
provisioning"): on the orin, `install-orin-host.sh` (units + lingering),
`configure-cyclonedds-sysctl.sh`, `just chrony-orin`, and a `colcon build`; on
the master, `ssh-copy-id` and `just chrony-master`. Gaps:

- **`install-zed-sdk.sh` was planned (§3 of the deployment design) and never
  written.** The SDK is assumed at `/usr/local/zed`; the workspace build gates
  ZED packages on that directory (`justfile` `build` recipe).
- The entire `setup.sh` / `setup/justfile` interactive flow is master-oriented
  (Nebula, u-blox, OTOCAM, pacmod, hardware-config). There is no orin entry
  point; `install-orin-host.sh` is not even a recipe.
- **Ordering trap**: the ZED SDK installs
  `/etc/sysctl.d/60-zed-buffers.conf`, which undercuts our
  `net.core.rmem_max` and makes CycloneDDS refuse to create a domain on every
  profile. `configure-cyclonedds-sysctl.sh` must run *after* the SDK, every
  time the SDK is (re)installed.
- The units hardcode `%h/2026-golf-cart`; a repo elsewhere gets only a printed
  warning from `install-orin-host.sh`, then fails at start time.

### Master launch today

The orin already runs under systemd (`golfcart-orin.service` + watchdog:
`KillSignal=SIGINT`, `KillMode=control-group`, `Restart=no`, no `[Install]`).
The master does not: `just launch-master` runs play_launch in the foreground
and tears the orin down from a bash `EXIT INT TERM` trap. Two problems:

- **The trap is the weakest link in the lifecycle matrix.** Bash does not run
  an EXIT trap when killed by an untrapped signal; the recipe compensates by
  trapping INT/TERM too, but SIGKILL and shell death still leak through to the
  orin's ~42 s watchdog. systemd's `ExecStopPost` runs on *every* stop path,
  including crashes.
- **Large master bags lose their `metadata.yaml`** (docs/roadblocks.md):
  play_launch's stop grace period is shorter than a multi-gigabyte flush, so
  the recorder is killed mid-finalize and leaves a 0-byte metadata file. The
  orin side does not have this problem precisely because systemd stops it with
  `KillSignal=SIGINT` and `TimeoutStopSec=30`. Promoting the master to systemd
  with a larger `TimeoutStopSec` fixes this roadblock at the source.

Also of note: the "Systemd Service Integration" section of CLAUDE.md describes
a `golfcart` CLI and auto-installed service from the old AutoSDV system that do
not exist in this repository. It should be rewritten as part of this work.

---

## 2. Part 1 — fresh-orin setup

### 2.1 `setup/scripts/install-zed-sdk.sh` (new)

- Download the ZED SDK for JetPack 6.x / L4T R36.4 from Stereolabs, **pinned to
  an exact version**, and run the `.run` installer non-interactively
  (`-- silent skip_od_module skip_python skip_hub` or equivalent).
- Verify `/usr/local/zed` exists afterwards; fail loudly if not.
- **Immediately re-run `configure-cyclonedds-sysctl.sh`** so
  `99-cyclonedds-max.conf` wins over the SDK's `60-zed-buffers.conf`. The
  script owns this ordering so no caller can get it wrong.
- Open item (§5): fetch from the Stereolabs URL at install time vs. staging the
  ~1.5 GB `.run` file locally. The direct URLs work non-interactively; the
  EULA page is only in the browser path.

### 2.2 `setup/justfile`: an `orin` role

New recipes, following the existing marker pattern:

```just
# ZED SDK for the orin (JetPack 6.x). Re-runs cyclonedds-sysctl afterwards.
zed-sdk: _init
    @just _run zed-sdk "{{scripts_dir}}/install-zed-sdk.sh"

# systemd user units + lingering for the orin host
orin-host: _init
    @just _run orin-host "{{scripts_dir}}/install-orin-host.sh"

# Everything a fresh orin needs, in dependency order.
# zed-sdk MUST precede cyclonedds-sysctl (the SDK stomps the sysctl).
orin-setup: _init autoware-debian python-deps zed-sdk cyclonedds-sysctl orin-host
    @printf "✓ orin setup complete — run 'just chrony-orin' (sudo), then build.\n"
```

`chrony-orin` stays a separate explicit step (sudo, touches `/etc`), as today.

### 2.3 `./setup.sh orin` (entry point)

A non-interactive path — the orin has exactly one hardware configuration, so
there is nothing to ask. It runs, in order:

1. `git submodule update --init --recursive --checkout`
2. `just orin-setup` (in `setup/`)
3. `just chrony-orin`
4. `just build` from the repo root (ZED packages now included, since
   `/usr/local/zed` exists and the build gating picks them up automatically)
5. The verification pass (§2.5)
6. Prints the two master-side one-liners it cannot do itself:
   `ssh-copy-id jetson@<orin>` and `(cd setup && just chrony-master)`.

### 2.4 Harden the workspace-path assumption

`install-orin-host.sh` currently warns when the repo is not at
`~/2026-golf-cart` and installs units that will then fail. Instead, install a
drop-in with the real path:

```
~/.config/systemd/user/golfcart-orin.service.d/override.conf
    [Service]
    Environment=GOLFCART_WORKSPACE=<resolved repo dir>
    ExecStart=
    ExecStart=<resolved repo dir>/scripts/multi_machine/orin_unit_exec.sh
```

Same treatment for the watchdog unit and, in Part 2, the master unit's
installer. Removes a silent-failure mode; the units in `setup/files/systemd/`
stay generic.

### 2.5 Verification: `just orin-check`

Runnable locally on the orin and over ssh from the master. Checks the known
failure modes, not hypothetical ones:

| Check | Failure it catches |
|---|---|
| units installed, `inactive`, linger enabled | provisioning incomplete; unit dies when ssh session ends |
| `sysctl net.core.rmem_max` ≥ 10 MB | ZED SDK sysctl stomp → `rmw_create_node: failed to create domain` |
| `chronyc tracking` references `192.168.125.100` | bags recorded on divergent clocks, unmergeable |
| `/usr/local/zed` present | SDK missing → ZED packages silently skipped by the build |
| `install/` contains `zed_wrapper` libexec | workspace not rebuilt → unit fails with `libexec directory does not exist` |

### 2.6 Docs

Replace the manual list in docs/multi-machine.md §"One-time provisioning" with
`./setup.sh orin` plus the two master-side commands.

---

## 3. Part 2 — promote both launches to systemd

### 3.1 `setup/files/systemd/golfcart-master.service` (new, user unit)

```ini
[Unit]
Description=Golf Cart master host stack
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=%h/2026-golf-cart/scripts/multi_machine/master_unit_exec.sh
# Orchestration lives here, not in a shell trap: ExecStopPost runs on every
# stop path, including crashes the trap could miss. "-" preserves the rule
# that a missing orin must never block or fail the master.
ExecStartPost=-%h/2026-golf-cart/scripts/multi_machine/orin_start_if_enabled.sh
ExecStopPost=-%h/2026-golf-cart/scripts/multi_machine/orin_remote.sh stop
KillMode=control-group
# play_launch ignores SIGTERM (measured; see multi_machine_deployment.md).
KillSignal=SIGINT
# Sized for a multi-gigabyte bag flush. 30s (the orin's value) is enough for a
# 300 MB ZED bag but not for the master's 2+ GB bags, whose metadata.yaml was
# left 0 bytes (docs/roadblocks.md). This is the fix for that roadblock.
TimeoutStopSec=180
Restart=no

[Install]
# Present so boot autostart is POSSIBLE (systemctl --user enable), but the
# installer does not enable it. The orin unit keeps no [Install] at all: it
# must only ever be started by the master.
WantedBy=default.target
```

Lifecycle matrix after this change:

| Failure | What stops the orin | How long |
|---|---|---|
| Master unit stopped (`just stop-master`, web UI, `systemctl`) | `ExecStopPost` → ssh stop | immediate |
| Master play_launch crashes or is SIGKILLed | unit leaves `active` → `ExecStopPost` still runs | immediate |
| Network cut / master powered off | orin watchdog, unchanged | ~42 s |

### 3.2 `scripts/multi_machine/master_unit_exec.sh` (new)

Mirror of `orin_unit_exec.sh` — systemd units get no direnv, no `~/.bashrc`,
no `~/.local/bin` on PATH, so everything is set explicitly:

- `cd "${GOLFCART_WORKSPACE:-$HOME/2026-golf-cart}"`; source
  `/opt/autoware/1.5.0/setup.bash` then `install/setup.bash` (no `set -u` —
  ROS setup files read unbound variables).
- `export CYCLONEDDS_URI=file://$WORKSPACE/config/cyclonedds/master.xml`;
  `unset ROS_LOCALHOST_ONLY`.
- Replicate `.envrc`'s bag-dir logic: prefer `/mnt/external/rosbags` when
  mounted and writable (the root filesystem fills in under two minutes of
  recording), else `~/rosbags`; an explicit `GOLFCART_BAG_DIR` wins.
- `exec play_launch launch --web-addr 0.0.0.0:8081 golfcart_launch
  golfcart.launch.yaml host:=master rviz:=false record:=${GOLFCART_RECORD:-false}
  ${GOLFCART_MASTER_ARGS:-}` — `exec` so systemd supervises play_launch itself.
  Headless always; RViz remains an interactive tool (`just tool rviz`).

`orin_start_if_enabled.sh` is a three-line wrapper: exit 0 unless
`GOLFCART_USE_ORIN` (default 1), else `orin_remote.sh start
"${GOLFCART_RECORD:-false}"`. It exists because `ExecStartPost` cannot express
the conditional.

### 3.3 Rewire `just launch-master`

One launch path, not two — two paths would race on port 8081 and double-start
the orin:

```just
launch-master ARGS="":
    # parse record:=true out of ARGS, then:
    systemctl --user set-environment GOLFCART_RECORD=<...> \
        GOLFCART_USE_ORIN=${GOLFCART_USE_ORIN:-1} GOLFCART_MASTER_ARGS="<rest>"
    systemctl --user restart golfcart-master.service
    journalctl --user -fu golfcart-master.service

stop-master:
    systemctl --user stop golfcart-master.service
```

`launch-orin` stays as-is for on-orin debugging. Behavioural changes to accept:

- **Ctrl-C on the journal follow no longer stops the stack.** The stop verbs
  are `just stop-master` and the play_launch web UI. This is deliberate: it is
  what makes the master survive a dropped ssh session or closed terminal.
- Per-invocation launch args travel via `GOLFCART_MASTER_ARGS` in the user
  manager's environment (set-environment persists until unset — `stop-master`
  should `unset-environment` the trio to avoid stale flags on the next start).

### 3.4 `setup/scripts/install-master-host.sh` (new) + wiring

Mirror of `install-orin-host.sh`: install the unit (with the §2.4 drop-in),
`daemon-reload`, `loginctl enable-linger` (required — both boot start and
ssh-driven operation outlive login sessions). Add a `master-host` recipe and an
optional question in `setup.sh`'s interactive flow, per the documented
component pattern in CLAUDE.md. Not enabled at boot by default; enabling is a
one-liner once the cart should come up unattended.

### 3.5 Docs + cleanup

- docs/multi-machine.md: daily-operation section (`launch-master` semantics,
  `stop-master`), the "What stops the orin" table (trap → `ExecStopPost`).
- multi_machine_deployment.md: an amendment recording the promotion and why.
- CLAUDE.md: rewrite the stale "Systemd Service Integration" section (the
  `golfcart` CLI it describes is from the old AutoSDV system and does not
  exist here).
- Remove the trap logic from the `launch-master` recipe once the unit path is
  verified.

---

## 4. Implementation order

1. §3.1–3.2 master unit + exec script, tested by hand (`systemctl --user
   start`) with the justfile untouched — the old path still works throughout.
2. §3.3 justfile rewire + §3.4 installer, once the unit passes checklist items
   1–4.
3. §2.1–2.4 orin setup scripts (ZED SDK script is testable on the orin
   independently of everything else).
4. §2.5 `orin-check`, §2.3 entry point.
5. §3.5/§2.6 docs, CLAUDE.md correction.

Rough size: 5 new files (`install-zed-sdk.sh`, `golfcart-master.service`,
`master_unit_exec.sh`, `orin_start_if_enabled.sh`, `install-master-host.sh`),
edits to `setup/justfile`, `setup.sh`, root `justfile`,
`install-orin-host.sh`, and three docs.

## 5. Verification checklist

1. **Single-box regression**: `just launch` untouched — loopback profile, no
   systemd involvement.
2. **Fresh-orin dry run**: `./setup.sh orin` on a wiped orin → `orin-check`
   passes → the master's `just launch-master` picks it up with no manual steps
   beyond `ssh-copy-id` and `chrony-master`.
3. **Recording end-to-end**: `just launch-master record:=true` → both units
   active, two bags; `just stop-master` → both inactive, no orphans, and the
   master bag's `metadata.yaml` is **non-empty on a >2 GB recording** (the
   `TimeoutStopSec=180` fix).
4. **Crash coverage**: `kill -9` the master's play_launch → `ExecStopPost`
   still stops the orin immediately (the case the shell trap could miss).
5. **Watchdog unchanged**: network cut → orin units stop in ~42 s.
6. **Stale-env guard**: `launch-master record:=true`, stop, then plain
   `launch-master` → recording is off (set-environment cleanup works).
7. **Boot test** (optional): `systemctl --user enable golfcart-master`,
   reboot → master stack up, orin following.

## 6. Open items

- **ZED SDK delivery**: pin-and-download from the Stereolabs URL at install
  time vs. staging the ~1.5 GB `.run` installer locally (EULA is browser-only;
  direct URLs work). Decide before writing §2.1.
- **Interactive path**: recommendation is to fully switch `launch-master` to
  the systemd path (§3.3); the alternative — keeping today's foreground recipe
  alongside a boot-only service — preserves Ctrl-C semantics at the cost of
  two competing launch paths. Needs a decision before §3.3 lands.
- Whether `sensor_only.launch.yaml` should grow the same `host:` gating, or is
  master-only by definition (out of scope here; note for later).
