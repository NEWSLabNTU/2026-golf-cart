"""The setup menu.

Replaces ~250 lines of hand-rolled bash: viewport arithmetic, cursor rewind,
width-aware truncation and an escape-sequence decoder, all of which re-forked
`tput` and `cut` on every keystroke. Textual owns all of that now.

Two things the old menu could not do, and the reasons this exists at all:

* Show each step's **current state**. Everything was offered as if never
  installed, because a marker file was not something the menu could read.
* Offer every step. Thirteen ran unconditionally without appearing here.
"""

from __future__ import annotations

from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, VerticalScroll
from textual.widgets import Checkbox, Footer, Header, Label, RadioButton, RadioSet, Static

from .model import PROFILE_HELP, PROFILES, Machine
from .registry import STEPS, ordered
from .state import State

BADGE = {
    "ok": ("✓", "green"),
    "stale": ("~", "yellow"),
    "failed": ("✗", "red"),
    "skipped": ("-", "grey54"),
    "pending": ("○", "grey54"),
}


class SetupApp(App):
    CSS = """
    Screen { layout: horizontal; }
    #left { width: 34; border-right: solid $panel-lighten-2; padding: 1 2; }
    #right { padding: 1 2; }
    .heading { text-style: bold; margin-bottom: 1; }
    .group { text-style: bold; color: $accent; margin-top: 1; }
    .why { color: $text-muted; margin-left: 4; margin-bottom: 1; }
    .na { color: $warning; margin-left: 4; }
    Checkbox { border: none; padding: 0; height: 1; }
    """

    BINDINGS = [
        Binding("enter", "start", "Install"),
        Binding("a", "all", "All"),
        Binding("n", "none", "None"),
        Binding("r", "reset_profile", "Reset to profile"),
        Binding("q", "quit", "Quit"),
    ]

    def __init__(self, machine: Machine, state: State, profile: str) -> None:
        super().__init__()
        self.machine = machine
        self.state = state
        self.profile = profile
        self.selection: set[str] = set()
        self.result: list | None = None

    # -- layout ----------------------------------------------------------
    def compose(self) -> ComposeResult:
        yield Header(show_clock=False)
        with VerticalScroll(id="left"):
            yield Label("Profile", classes="heading")
            with RadioSet(id="profile"):
                for name in PROFILES:
                    yield RadioButton(name, value=(name == self.profile), id=f"p-{name}")
            yield Static("", id="profile-help", classes="why")
            yield Label("This machine", classes="heading")
            yield Static(self._machine_summary(), id="machine", classes="why")
        with VerticalScroll(id="right"):
            yield Label("Steps  —  space toggles, enter installs", classes="heading")
            group = None
            for step in STEPS:
                if step.group != group:
                    group = step.group
                    yield Label(group, classes="group")
                applicable, reason = self.machine.applicable(step)
                yield Checkbox(self._label(step), id=f"s-{step.id}")
                yield Static(step.why, classes="why")
                if not applicable:
                    yield Static(f"not applicable here: {reason}", classes="na")
        yield Footer()

    def on_mount(self) -> None:
        self.title = "Golf cart setup"
        self._apply_profile(self.profile)
        self.query_one("#profile-help", Static).update(PROFILE_HELP[self.profile])

    def _machine_summary(self) -> str:
        m = self.machine
        bits = [f"arch: {m.arch}"]
        if m.is_jetson:
            bits.append("Jetson")
        if m.host_role:
            bits.append(f"config/host: {m.host_role}")
        for cap in ("cuda", "can", "ublox-gnss", "tier4-camera", "ptp-nic"):
            bits.append(f"{cap}: {'yes' if m.has(cap) else 'no'}")
        return "\n".join(bits)

    def _label(self, step) -> str:
        mark, colour = BADGE[self.state.status_of(step.id, step.digest())]
        return f"[{colour}]{mark}[/] {step.label}"

    # -- behaviour -------------------------------------------------------
    def _apply_profile(self, profile: str) -> None:
        """Profile sets the defaults; the checkboxes stay editable.

        A step already done is left unticked so the common case -- re-running
        setup after adding one component -- does not reinstall everything. It is
        still selectable, which is how a step gets re-run without knowing any
        internal file name.
        """
        self.profile = profile
        for step in STEPS:
            done = self.state.status_of(step.id, step.digest()) == "ok"
            want = step.default_for(profile) and not done
            self.query_one(f"#s-{step.id}", Checkbox).value = want

    def on_radio_set_changed(self, event: RadioSet.Changed) -> None:
        name = str(event.pressed.label)
        self.query_one("#profile-help", Static).update(PROFILE_HELP[name])
        self._apply_profile(name)

    def action_all(self) -> None:
        for step in STEPS:
            self.query_one(f"#s-{step.id}", Checkbox).value = True

    def action_none(self) -> None:
        for step in STEPS:
            self.query_one(f"#s-{step.id}", Checkbox).value = False

    def action_reset_profile(self) -> None:
        self._apply_profile(self.profile)

    def action_start(self) -> None:
        chosen = {
            s.id for s in STEPS
            if self.query_one(f"#s-{s.id}", Checkbox).value
        }
        self.result = ordered(chosen)
        self.exit(self.result)


def run_tui(args) -> int:
    """Pick steps in the menu, then run them on the plain terminal.

    Running the installs inside the Textual app was tempting and is wrong: these
    steps are apt, sudo and kernel modules, they prompt, and their output is the
    thing you need when one fails. The app closes first and hands the terminal
    back.
    """
    from .runner import Runner

    machine = Machine()
    state = State()
    imported = state.import_markers({s.id: s.digest() for s in STEPS})
    if imported:
        print(f"Imported {imported} completed steps from the old .markers/ "
              f"directory; those will not be reinstalled.")

    profile = args.profile or machine.suggested_profile()
    steps = SetupApp(machine, state, profile).run()
    if not steps:
        print("Nothing selected.")
        return 0

    print(f"\nInstalling {len(steps)} step(s):")
    for step in steps:
        print(f"  · {step.label}")
    print()
    failures = Runner(state, machine).run_all(steps)
    print()
    if failures:
        print(f"{failures} step(s) failed. Re-run to resume.")
        return 1
    print("Setup complete.")
    return 0
