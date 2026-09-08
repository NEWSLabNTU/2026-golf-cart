#!/usr/bin/env python3
"""Golf cart setup.

Reached through ./setup.sh, which bootstraps the environment first. Runnable
directly with a system python3 for everything except the TUI -- `--status`,
`--list` and `--dry-run` import nothing outside the standard library, on purpose:
those are what you need when the venv is the thing that is broken.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from golfcart_setup.model import PROFILE_HELP, PROFILES, Machine  # noqa: E402
from golfcart_setup.registry import BY_ID, STEPS, ordered  # noqa: E402
from golfcart_setup.runner import Runner  # noqa: E402
from golfcart_setup.state import State  # noqa: E402

MARK = {
    "ok": "\033[32m✓\033[0m",
    "stale": "\033[33m~\033[0m",
    "failed": "\033[31m✗\033[0m",
    "skipped": "\033[90m-\033[0m",
    "pending": "\033[90m○\033[0m",
}
LEGEND = "✓ done   ~ stale (script changed since)   ✗ failed   ○ not run   - skipped"


def _statuses(state: State) -> dict[str, str]:
    return {s.id: state.status_of(s.id, s.digest()) for s in STEPS}


def cmd_list(args) -> int:
    machine = Machine()
    state = State()
    status = _statuses(state)
    profile = args.profile or machine.suggested_profile()
    group = None
    print(f"Profile: {profile}   host: {machine.arch}"
          f"{'  (jetson)' if machine.is_jetson else ''}\n")
    for step in STEPS:
        if step.group != group:
            group = step.group
            print(f"  {group}")
        ok, reason = machine.applicable(step)
        default = "on " if step.default_for(profile) else "   "
        note = "" if ok else f"   ({reason})"
        print(f"    {MARK[status[step.id]]} {default} {step.id:<20} {step.label}{note}")
    print(f"\n  {LEGEND}")
    return 0


def cmd_status(args) -> int:
    state = State()
    status = _statuses(state)
    counts: dict[str, int] = {}
    for value in status.values():
        counts[value] = counts.get(value, 0) + 1
    print("Setup status\n")
    for step in STEPS:
        rec = state.record(step.id) or {}
        when = rec.get("at", "")
        extra = ""
        if status[step.id] == "failed":
            extra = f"  exit {rec.get('exit', '?')}"
        elif status[step.id] == "stale":
            extra = "  re-run to pick up changes"
        print(f"  {MARK[status[step.id]]} {step.id:<20} {when}{extra}")
    print("\n  " + "   ".join(f"{k}: {v}" for k, v in sorted(counts.items())))
    print(f"  state file: {state.path}")
    return 0


def _select(args, machine: Machine, state: State) -> list:
    if args.only:
        unknown = [s for s in args.only if s not in BY_ID]
        if unknown:
            print(f"unknown step(s): {', '.join(unknown)}", file=sys.stderr)
            raise SystemExit(2)
        return ordered(set(args.only))

    profile = args.profile or machine.suggested_profile()
    status = _statuses(state)
    chosen = set()
    for step in STEPS:
        if not step.default_for(profile):
            continue
        if not args.force and status[step.id] == "ok":
            continue
        chosen.add(step.id)
    return ordered(chosen)


def cmd_run(args) -> int:
    machine = Machine()
    state = State()
    imported = state.import_markers({s.id: s.digest() for s in STEPS})
    if imported:
        print(f"Imported {imported} completed steps from the old .markers/ "
              f"directory; those will not be reinstalled.\n")

    steps = _select(args, machine, state)
    if not steps:
        print("Nothing to do: everything selected is already done.")
        print("Use --force to re-run, or --only <step> to pick one.")
        return 0

    profile = args.profile or machine.suggested_profile()
    print(f"Profile: {profile}   {len(steps)} step(s) to run\n")
    for step in steps:
        ok, reason = machine.applicable(step)
        flag = "" if ok else f"   ({reason} -- selected anyway)"
        print(f"  · {step.label}{flag}")
    print()

    if args.dry_run:
        print("Dry run. Nothing installed.")
        Runner(state, machine, dry_run=True).run_all(steps)
        return 0

    if not args.yes and sys.stdin.isatty():
        if input("Continue? [Y/n] ").strip().lower() in {"n", "no"}:
            print("Cancelled.")
            return 0
        print()

    failures = Runner(state, machine).run_all(steps)
    print()
    if failures:
        print(f"{failures} step(s) failed. Re-run to resume; "
              f"completed steps are skipped.")
        return 1
    print("Setup complete.")
    return 0


def cmd_rerun(args) -> int:
    state = State()
    for step_id in args.steps:
        if step_id not in BY_ID:
            print(f"unknown step: {step_id}", file=sys.stderr)
            return 2
        state.forget(step_id)
    state.save()
    print(f"Cleared state for: {', '.join(args.steps)}")
    args.only = args.steps
    args.force = True
    return cmd_run(args)


def cmd_tui(args) -> int:
    try:
        from golfcart_setup.tui import run_tui
    except ImportError as exc:
        print(f"The TUI needs its dependencies: {exc}", file=sys.stderr)
        print("Run ./setup.sh (which installs them), or use --profile/--only.",
              file=sys.stderr)
        return 3
    return run_tui(args)


def _accept_old_forms(argv: list[str]) -> list[str]:
    """Keep the previous command forms working.

    `./setup.sh status` and `./setup.sh <recipe>` were both documented, and are
    in CLAUDE.md and the README. Translating them costs a few lines and saves
    everyone relearning a tool they already know.
    """
    if not argv or argv[0].startswith("-"):
        return argv
    head, rest = argv[0], argv[1:]
    if head in {"status", "list"}:
        return [f"--{head}", *rest]
    if head in {"clean-markers", "clean-marker"}:
        print("Markers are gone; state lives in setup/.state.json.\n"
              "Use --rerun <step> for one step, or delete that file to reset all.",
              file=sys.stderr)
        raise SystemExit(2)
    if head in BY_ID:
        return ["--only", *argv]
    return argv


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        prog="setup.sh",
        description="Golf cart setup. With no arguments, opens the menu.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="Profiles:\n" + "\n".join(
            f"  {name:<9} {PROFILE_HELP[name]}" for name in PROFILES
        ),
    )
    ap.add_argument("--profile", choices=PROFILES,
                    help="preset selection; detected if omitted")
    ap.add_argument("--only", nargs="+", metavar="STEP",
                    help="run exactly these steps")
    ap.add_argument("--rerun", nargs="+", metavar="STEP",
                    help="forget these steps' state, then run them")
    ap.add_argument("--force", action="store_true",
                    help="run selected steps even if already done")
    ap.add_argument("--yes", "-y", action="store_true", help="no prompts")
    ap.add_argument("--dry-run", action="store_true",
                    help="resolve and print, install nothing")
    ap.add_argument("--list", action="store_true",
                    help="every step, its status and whether it applies here")
    ap.add_argument("--status", action="store_true", help="what is installed")
    args = ap.parse_args(_accept_old_forms(
        list(argv) if argv is not None else sys.argv[1:]))

    if args.list:
        return cmd_list(args)
    if args.status:
        return cmd_status(args)
    if args.rerun:
        args.steps = args.rerun
        return cmd_rerun(args)
    if args.only or args.profile or args.yes or args.dry_run:
        return cmd_run(args)
    return cmd_tui(args)


if __name__ == "__main__":
    sys.exit(main())
