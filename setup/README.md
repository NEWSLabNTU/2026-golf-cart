# Setup

```bash
./setup.sh                       # open the menu
./setup.sh --status              # what is installed
./setup.sh --list                # every step, and whether it applies here
./setup.sh --rerun opencv        # forget one step's state and run it again
./setup.sh --reset-env           # rebuild the setup venv, then exit
```

`./setup.sh status` and `./setup.sh <step>` still work.

### In the menu

| key | |
|---|---|
| `↑` `↓`, `j` `k` | move between steps |
| `space` | tick / untick the focused step |
| `tab` | switch between the step list and the profile picker |
| `↑` `↓` then `enter` | in the profile picker: highlight, then apply |
| `a` / `n` / `r` | all / none / back to the profile's defaults |
| `enter` | review the selection, then install |
| `q` | quit without installing |

Enter opens a review dialog rather than installing straight away — it names
every step, flags any the machine does not look to need, and `escape` returns to
the menu with the selection intact.

### Unattended

Every flagged form runs on the system `python3` and never builds the venv; only
the menu needs it.

```bash
./setup.sh --run --profile vehicle --yes        # the profile's steps, no prompts
./setup.sh --run --all --skip tensorrt-engines  # everything bar one step
./setup.sh --only ros2 ros2-dev-tools --yes     # exactly these
./setup.sh --dry-run --json --profile ci        # what would run, as JSON
./setup.sh --status --json                      # state, for a health check
./setup.sh --run --profile orin -y --keep-going # do not stop at the first failure
```

| flag | |
|---|---|
| `--run` | run the resolved selection without opening the menu |
| `--profile P` | preset selection; detected when omitted |
| `--all` | every step, not just the profile's |
| `--only STEP...` | exactly these, done or not |
| `--skip STEP...` | subtract from whatever else was selected |
| `--force` | run selected steps even if already done |
| `--keep-going` | continue past a failure instead of stopping |
| `--dry-run` | resolve and print, install nothing |
| `--json` | machine-readable `--list`, `--status`, `--dry-run` |
| `--yes` / `-y` | no prompts |

With no terminal and no flags, setup says which flag was wanted instead of
trying to draw a menu.

## How it fits together

`setup/setup.sh` is a bootstrap and nothing else: it installs [uv], builds
`setup/.venv`, and hands off to `setup/main.py`. Everything with logic in it is
Python.

```
setup/setup.sh            bootstrap, no dependencies
setup/main.py             CLI
setup/golfcart_setup/
    registry.py           every step, in run order
    model.py              what a Step is; hardware detection
    state.py              .state.json, and the .markers import
    runner.py             execution
    tui.py                the menu (textual)
setup/scripts/            the install scripts steps call
```

`main.py` imports Textual lazily and nothing else outside the standard library,
so every form except the menu runs straight from `python3`. That is two things
at once: an unattended install does not stop to build an environment it will not
use, and `--status` / `--list` keep working when the venv is the broken thing.

## Profiles

A profile is a set of defaults over the same step list, not a separate path.
Every step stays individually selectable in the menu.

| profile | for |
|---|---|
| `laptop` | offline development, replay, simulation |
| `orin` | Jetson without sensors attached |
| `vehicle` | the cart: udev, CAN, PTP, camera kernel modules |
| `ci` | headless and minimal, no prompts |

The suggested profile comes from detection — architecture, whether a CUDA device
is present, whether CAN interfaces exist, `config/host` — and is a starting
point, never a restriction. A step whose hardware is absent is shown as such and
can still be selected, because machines get provisioned before hardware arrives.

## State

`setup/.state.json`, one entry per step: status, timestamp, and a digest of what
the step would run.

The digest is why `stale` exists. A marker file could only say "ran once", so an
edited install script still read as done. When a step's script changes its digest
changes, and the menu shows it as stale rather than complete.

An existing `setup/.markers/` directory is imported automatically on first run,
so a working machine does not reinstall everything because the format changed.

To re-run one step, tick it in the menu or use `--rerun <step>`. There is no
marker file to find and delete.

## Adding a step

One entry in `setup/golfcart_setup/registry.py`:

```python
Step(
    id="my-thing",
    label="My thing",
    why="One sentence on what breaks without it.",
    run=[_S("install-my-thing.sh")],
    requires=Requires(sudo=True, hardware="can"),
    profiles=_on("vehicle"),
    group="Hardware",
)
```

There is no second place to register it and no wrapper to write. A step absent
from this list does not run; a step present in it is shown in the menu.

[uv]: https://docs.astral.sh/uv/
