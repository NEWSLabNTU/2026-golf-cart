# Setup experience: what is wrong, and a proposed replacement

`./setup.sh` works, and everything below is about the parts that are hard to
*use* rather than parts that fail. Four complaints drove this, and investigating
them turned up three more.

**Implemented 2026-09-02.** The five decisions below were answered and the
design built; this document is kept as the record of what was wrong and why the
replacement is shaped the way it is. `setup/README.md` documents the result.

---

## What is actually wrong

### 1. Thirteen steps run without appearing in the menu

The menu offers 16 entries. The `setup:` recipe runs 25 steps. The difference is
not optional extras — it is most of the install:

```
ros2  ros2-dev-tools  gdown  geographiclib  pacmod  dev-tools  python-deps
nebula-driver  ublox-driver  ublox-udev  tier4-camera  gscam  ros-deps
```

The menu header says "core (ROS 2, dev tools, GeographicLib, Python deps) is
always installed", which covers four of the thirteen. The other nine —
including two that write **udev rules** and three that install **sensor
drivers** — are invisible. On a laptop with no sensors attached, all of them
still run.

### 2. One step runs with no gate and is not in the menu at all

`_setup-iceoryx` has no condition:

```just
_setup-iceoryx:
    # No question gate: ... Treat it as required, like the RMW itself.
    just iceoryx
```

Meanwhile `CLAUDE.md` records, of the play_launch optimisation campaign: *"Note
that Iceoryx did not work and thus was not used."* So a shared-memory transport
that the project measured as not working is installed unconditionally on every
machine, with a systemd unit, and the menu never mentions it.

Whether it should stay is a real question. That it is invisible is not.

### 3. Re-running one step requires internal knowledge

State is one empty file per step under `setup/.markers/`. Every recipe opens
with the same four lines:

```bash
[[ -f "{{marker_dir}}/nebula-driver" ]] && printf "✓ already done" && exit 0
```

`clean-markers` and `clean-marker NAME` exist, and `clean-markers` is in
`--help`. But `clean-marker` is not, and its argument is the *internal* step id.
To re-run one step you must know that the id is `ublox-udev` and not `ublox`,
and that the file lives in a dotted directory the menu never mentions.

A marker also records only "this ran once". Not when, not what it installed, not
whether the step's own definition has changed since. A step whose script was
edited last week still reads as done.

### 4. The menu is laggy, and it is measurable why

`setup.sh` is 586 lines, of which ~250 are a hand-written TUI: viewport
scrolling, cursor rewind arithmetic, width-aware truncation, an escape-sequence
decoder. It is careful work — the comments explain each trap it avoids — but
every keystroke triggers a full re-render, and each render forks:

- `tput lines` and `tput cols`, once each
- `cut -d'|' -f N` **once per field per visible item** — `menu_field` is a
  subshell, and each item reads 3 to 5 fields
- `menu_item_height` forks another `cut` per item, twice, inside the scroll
  calculation

With 16 items that is on the order of 50 to 100 forked processes per arrow key.
That is the lag. It is inherent to keeping the script dependency-free, which is
the constraint the current design chose.

That constraint is also not quite true today: `setup.sh` refuses to run without
`just`, which the user must install first from a piped `curl`.

### 5. Hardware-dependent steps are not modelled

Three usage contexts exist and the setup knows about none of them:

| context | what it needs |
|---|---|
| laptop, offline dev and replay | ROS 2, build deps, Autoware, no sensors |
| Orin devkit, no sensors | the above, plus CUDA and TensorRT |
| the vehicle | all of it, plus udev, CAN, PTP, camera kmods |

The only hardware awareness in the whole system is one line: Isaac ROS is
defaulted off when `uname -m` is not `aarch64`. Meanwhile `hardware-config`
matches specific MAC addresses, `linuxptp` is hardcoded to interface
`enP5p5s0`, and `otocam` needs a vendor blob and a specific kernel — all three
default to `n`, which is right, but they sit in the same flat list as ROS 2 with
nothing saying why.

### 6. Two steps look like leftovers

- **`pacmod`** adds an AutonomouStuff APT source and a rosdep list. `grep -rl
  pacmod src/` returns nothing. The golf cart's vehicle interface is Turing
  Drive, and the PWM interface it replaced is stubbed. It also adds the source
  with `[trusted=yes]`, which disables signature checking on a third-party
  repository.
- **`gdown`** is installed and never used. The only mentions in the repo are its
  own install recipe and a line in `setup/README.md`.

### 7. Isaac ROS

Dropped by decision — cuVSLAM/cuVGL are no longer part of the plan, and
`pose_source` already lost its `isaac` and `visual` options.

---

## Proposed design

### Shape

```
./setup.sh                 pure-bash bootstrap, ~60 lines, no deps
  └─ installs uv           single static binary, no system Python needed
  └─ creates setup/.venv   and installs the TUI deps into it
  └─ exec setup/main.py    everything else lives here
```

The bootstrap is the only shell that remains, and it does one thing. Everything
that needs logic — the step registry, state, detection, the UI — becomes Python
with real data structures instead of `cut -d'|'`.

`uv` rather than `python3 -m venv` because it needs no system Python, resolves
in seconds, and is one binary to remove. It installs to `~/.local/bin`; if it is
already present the bootstrap skips straight to the venv.

### Every step is a declared object

One registry, one entry per step, nothing hidden:

```python
Step(
    id="ublox-udev",
    label="u-blox GNSS udev rules",
    why="Gives the receiver a stable /dev name. Without it the driver "
        "opens whichever ttyACM enumerated first.",
    requires=Requires(hardware="ublox-gnss", sudo=True),
    profiles={"laptop": False, "orin": False, "vehicle": True},
    run=Script("install-ublox-udev.sh"),
)
```

The `setup:` chain disappears. There is no `_setup-*` wrapper layer, because the
condition lives on the step. A step that is not selected does not run, and
*every* step can be deselected — including ROS 2, which today cannot.

### State replaces markers

One file, `setup/.state.json`:

```json
{
  "steps": {
    "ros2":       {"status": "ok",      "at": "2026-08-14T10:22:31Z", "digest": "a91f…"},
    "ublox-udev": {"status": "skipped", "at": "2026-08-14T10:24:02Z", "reason": "profile"},
    "opencv":     {"status": "failed",  "at": "2026-08-14T10:31:55Z", "exit": 1}
  }
}
```

`digest` is a hash of the step's script and arguments. When it changes, the UI
shows the step as **stale** rather than done, which is the case markers cannot
represent and the one that silently bites.

Re-running becomes a keystroke on the step, not a file to find and delete. And
there is exactly one file to remove if the state is ever wrong.

### Profiles, chosen by detection but never imposed

At startup, detect and display:

- architecture, and whether a CUDA device is present
- whether the CAN interfaces exist
- whether the u-blox, the Robin-W and the cameras are visible
- whether this is the master or the orin, from `config/host`

Detection picks the *default* profile and annotates each step — an item whose
hardware is absent is shown as such. It never blocks: someone preparing a
machine before the hardware arrives can select anything.

Profiles are named presets over the same step list, not separate code paths:

| profile | for |
|---|---|
| `laptop` | offline development, replay, simulation |
| `orin` | Jetson without sensors attached |
| `vehicle` | the real cart |
| `ci` | headless, minimal, no prompts |

### The TUI

**Recommend `textual`.** It gives a real checkbox tree with grouping, per-item
status badges (done / stale / failed / n-a), a details pane for the `why` text,
and a scrollable log while steps run — all of which the current menu either
fakes or omits. Cost is about 12 MB in the venv and a hard dependency on a
terminal.

Lighter alternative if that is too much: `questionary` over `prompt_toolkit`,
about 2 MB, which does grouped checkboxes well but has no live log view.

Either way the UI is a *view* of the registry, so switching is contained.

### Non-interactive paths are first class

The TUI must not be the only door — the vehicle is often reached over SSH, and
CI has no terminal:

```bash
./setup.sh --profile vehicle --yes      # no prompts
./setup.sh --list                       # every step, status, applicability
./setup.sh --status                     # what is installed, stale, failed
./setup.sh --only nebula-driver         # one step
./setup.sh --rerun opencv               # ignore state for this step
./setup.sh --dry-run                    # resolve and print, install nothing
```

`--list` and `--status` must work **without** the venv, so a broken environment
is still diagnosable.

### Fixing a broken venv

```bash
./setup.sh --reset-env    # remove setup/.venv and re-bootstrap
```

Pure bash, in the bootstrap, before anything imports.

---

## Step review

Recommendations, for discussion rather than as decided:

| step | now | proposed |
|---|---|---|
| ros2, ros2-dev-tools, ros-deps | forced | **explicit**, on in every profile |
| geographiclib, dev-tools, python-deps | forced | **explicit**, on in every profile |
| colcon-cargo-ros2 | menu | keep — the build aborts without it |
| autoware-debian (+ prereqs) | menu | keep |
| autoware-data, tensorrt-engines | menu | keep; engines off by default (~11 min) |
| opencv | menu | keep, but Jetson-only in practice — annotate |
| nebula-driver, ublox-driver | forced | **explicit**; build deps, on except `ci` |
| ublox-udev, tier4-camera, gscam | forced | **explicit**, `vehicle` only |
| cyclonedds-sysctl, multicast-lo | menu | keep, on everywhere — ROS will not start without them |
| **iceoryx** | **ungated, hidden** | **explicit, default OFF** — measured not to work |
| turbovnc-virtualgl | menu | keep, off on `laptop` |
| hardware-config, otocam, linuxptp | menu | keep, `vehicle` only; `linuxptp` interface becomes a parameter |
| chrony-master / chrony-orin | recipes only | surface as a multi-machine step |
| **isaac-ros** | menu | **drop** |
| **pacmod** | forced | **drop** — unreferenced, and an unsigned apt source |
| **gdown** | forced | **drop** — nothing uses it |

---

## Migration

The riskiest part is that this replaces a system people have working machines
from. Proposed order:

1. Land the registry and state model with the **existing** shell menu still
   driving it, so the step list and the state file can be validated before any
   UI change.
2. Import existing `.markers/` into `.state.json` on first run, so nobody
   reinstalls ROS 2 because the format changed.
3. Add the bootstrap and the Python CLI, non-interactive paths first.
4. Add the TUI last, since it is the part with the heaviest dependency and the
   least risk if it lands late.
5. Keep `just setup …` working as a thin alias for one release.

---

## Decisions, as answered

1. **Iceoryx — dropped, and then removed from the project entirely.** It never
   worked because the runtime caps publisher ports at a compiled-in count this
   stack exceeds, so the failure is a hard abort at participant creation rather
   than a fallback to the network transport. Dropping the setup step left the
   rest of the plumbing standing, which is worse than either state, so the
   removal went the whole way: `config/iceoryx/`, `scripts/iceoryx/`, the
   `iox-roudi.service` unit, the `<SharedMemory>` blocks in all three
   CycloneDDS profiles, and the guards in `scripts/env.sh` and the justfile.
   Reasoning kept in `config/README.md`.
2. **pacmod and gdown — dropped.**
3. **Textual**, with the menu closing before any install runs. Installs are apt,
   sudo and kernel modules; they prompt, and their output is what you need when
   one fails, so the terminal is handed back rather than captured.
4. **`just` leaves the setup path** and becomes an ordinary setup step, since the
   rest of the repo needs it. `setup/justfile` is deleted.
5. **Profile names kept**, with per-step customization in the menu: a profile
   sets defaults and every step stays individually selectable.

## What shipped

| | |
|---|---|
| `setup/setup.sh` | 586 lines → 74, bootstrap only |
| `setup/justfile` | deleted; steps live in `registry.py` |
| steps offered in the menu | 16 of 25 → **25 of 25** |
| ungated hidden steps | 1 (`iceoryx`) → 0 |
| forks per keystroke | ~50-100 → 0 |
| state | one empty file per step → `.state.json` with `stale` detection |

Old command forms (`./setup.sh status`, `./setup.sh <step>`) still work.
`clean-markers` reports where state moved to rather than failing.

---

## Revised 2026-09-10: the menu, and the presets

Two things came back after a week of use.

### Textual was too heavy for what it drew

| | disk | import, warm | first run, cold | dependencies |
|---|---|---|---|---|
| Textual | 5.8 MB in a 15 MB venv | 250-300 ms | **~54 s** while uv fetched a Python and resolved | rich, pygments, markdown-it, linkify-it, mdurl, platformdirs, typing_extensions |
| stdlib `curses` | 0 | 3 ms | 0 | none |

Fifty-four seconds before the first pixel, to draw a list of 25 checkboxes. The
menu is now `curses`, and dropping the dependency took the venv, `uv`,
`requirements.txt` and the whole bootstrap with it: `setup.sh` is a launcher
that execs `main.py`, and `--list` answers in about 45 ms.

Considered and not chosen: `simple-term-menu` (60 KB, no deps, but still a venv
for something the stdlib does), `prompt_toolkit` (~1.5 MB, ready-made
checkbox dialogs, still a widget framework), and a plain numbered menu with no
full-screen drawing. The last one ships anyway as `--plain`, and as the
automatic fallback when curses cannot drive the terminal.

### The preset is a question, not a side pane

It used to sit in a left pane, competing with the step list for focus, which is
what made the arrow keys ambiguous in the first place. It is now the **first
screen**: pick a preset, then the list opens seeded from it. `p` re-asks
without leaving the list.

### Five presets, and the boundary is one group

| was | now | |
|---|---|---|
| `laptop`, `orin` | `dev` | laptop, workstation, PC: dev tools, libraries, sysctl, loopback multicast |
| `vehicle` | `vehicle` | `dev` plus the **System config** group |
| -- | `all` | every step, opt-in ones included |
| -- | `none` | nothing preselected |
| `ci` | `ci` | headless, build dependencies only |

The `orin` profile is gone. A Jetson with no sensors attached is a development
machine and a Jetson in the cart is the vehicle; a per-board profile meant
maintaining a third column that only differed by what happened to be plugged
in. `suggested_profile` now looks at the hardware, not the SoC.

`vehicle` is exactly `dev` plus one group, and the groups were renamed so that
boundary is visible: **Sensor packages** (apt, no device touched, in `dev`)
against **System config** (udev, CAN, PTP, kernel modules, `vehicle` only).
`all` and `none` are computed in `Step.default_for` rather than declared per
step, so a new step joins them without anyone remembering to.

### The OS check

Every install script writes Ubuntu 22.04 apt package names, so `/etc/os-release`
is read before anything runs: 22.04 proceeds, another Ubuntu or a Debian warns
and proceeds, anything else stops and names `--ignore-os-check`. Three outcomes
rather than two, because a neighbouring Ubuntu can be made to work and someone
doing that is doing it deliberately, while a distribution with no Humble
packages at all is not a near miss.
