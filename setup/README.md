# Setup

```bash
./setup.sh                       # open the menu
./setup.sh --status              # what is installed
./setup.sh --list                # every step, and whether it applies here
./setup.sh --profile vehicle -y  # no prompts, for SSH and CI
./setup.sh --rerun opencv        # forget one step's state and run it again
./setup.sh --reset-env           # rebuild the setup venv, then exit
```

`./setup.sh status` and `./setup.sh <step>` still work.

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

`--status`, `--list` and `--help` import only the standard library and run
straight from `python3`, so they still work when the venv is the broken thing.

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
