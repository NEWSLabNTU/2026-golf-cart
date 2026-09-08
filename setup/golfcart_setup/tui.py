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
from textual.containers import Horizontal, Vertical, VerticalScroll
from textual.screen import ModalScreen
from textual.widgets import (
    Button, Checkbox, Header, Label, RadioButton, RadioSet, Static,
)

from .model import PROFILE_HELP, PROFILES, Machine
from .registry import STEPS, ordered
from .state import State


class Pane(VerticalScroll):
    """A scroll region that does not take focus.

    `VerticalScroll.can_focus` is True, so the pane itself was the first thing
    in the tab order and the thing the arrow keys reached. Focus landed on the
    container, the arrows scrolled it, and nothing looked selected -- the user
    had to press tab before any key did what it appeared to do.
    """

    can_focus = False


class StepCheckbox(Checkbox):
    """One step in the list.

    `Checkbox` binds enter and space to toggle and binds nothing to the arrows,
    which is right for a lone checkbox in a form and wrong for a list of 25:
    the arrows fell through to the scroll container, so the page moved while the
    focus stayed put, and enter toggled the focused step instead of starting the
    install the footer advertises.
    """

    BINDINGS = [
        Binding("up", "app.move_step(-1)", "Previous", show=False),
        Binding("down", "app.move_step(1)", "Next", show=False),
        Binding("k", "app.move_step(-1)", "Previous", show=False),
        Binding("j", "app.move_step(1)", "Next", show=False),
        Binding("home", "app.move_step(-9999)", "First", show=False),
        Binding("end", "app.move_step(9999)", "Last", show=False),
        Binding("space", "toggle_button", "Toggle", show=False),
        Binding("enter", "app.start", "Install", show=False),
        Binding("tab", "app.focus_profile", "Profile", show=False),
        Binding("shift+tab", "app.focus_profile", "Profile", show=False),
    ]


class ProfileRadioSet(RadioSet):
    """The profile picker.

    Tab is the pane switch in both directions, so it lands back on the step the
    list was left on. Default tab traversal walked the 25 checkboxes one at a
    time, which duplicates the arrow keys and buries the profile 25 presses
    away.
    """

    BINDINGS = [
        Binding("tab", "app.focus_steps", "Steps", show=False),
        Binding("shift+tab", "app.focus_steps", "Steps", show=False),
    ]


BADGE = {
    "ok": ("✓", "green"),
    "stale": ("~", "yellow"),
    "failed": ("✗", "red"),
    "skipped": ("-", "grey54"),
    "pending": ("○", "grey54"),
}


class ConfirmScreen(ModalScreen[bool]):
    """Review what enter is about to install.

    Enter is one keypress away from apt, sudo and kernel modules, and it sits on
    the same key that toggles a step in most list widgets, so it gets pressed by
    accident. This is the stop: it names every step, flags the ones this machine
    does not look like it needs, and goes back to the menu with the selection
    intact.
    """

    CSS = """
    ConfirmScreen { align: center middle; }
    #dialog {
        width: 78; max-width: 90%; height: auto; max-height: 80%;
        border: thick $accent; background: $surface; padding: 1 2;
    }
    #dialog .heading { text-style: bold; margin-bottom: 1; }
    #steps { height: auto; max-height: 16; margin-bottom: 1; }
    #steps .na { color: $warning; }
    #notes { color: $text-muted; margin-bottom: 1; }
    #buttons { height: auto; align: right middle; }
    #keys { width: 1fr; color: $text-muted; }
    #buttons Button { margin-left: 2; }
    """

    BINDINGS = [
        Binding("escape", "back", "Back to menu"),
        Binding("b", "back", "Back to menu"),
        Binding("q", "back", "Back to menu", show=False),
    ]

    def __init__(self, steps: list, machine: Machine) -> None:
        super().__init__()
        self.steps = steps
        self.machine = machine

    def compose(self) -> ComposeResult:
        with Vertical(id="dialog"):
            yield Label(f"Install {len(self.steps)} step(s)?", classes="heading")
            with VerticalScroll(id="steps"):
                for step in self.steps:
                    ok, reason = self.machine.applicable(step)
                    if ok:
                        yield Static(f"  · {step.label}")
                    else:
                        yield Static(f"  · {step.label}  ({reason} -- selected anyway)",
                                     classes="na")
            yield Static(self._notes(), id="notes")
            with Horizontal(id="buttons"):
                yield Static("enter installs   escape goes back", id="keys")
                yield Button("Back", id="back")
                yield Button("Install", variant="primary", id="go")

    def _notes(self) -> str:
        notes = []
        if any(s.requires.sudo for s in self.steps):
            notes.append("Root is needed; sudo is asked for once, up front.")
        if any(s.requires.reboot for s in self.steps):
            notes.append("At least one step wants a reboot afterwards.")
        notes.append("The menu closes first, so each step prompts and prints "
                     "on the plain terminal.")
        return "\n".join(notes)

    def on_mount(self) -> None:
        self.query_one("#go", Button).focus()

    def action_back(self) -> None:
        self.dismiss(False)

    def on_button_pressed(self, event: Button.Pressed) -> None:
        self.dismiss(event.button.id == "go")


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
    Checkbox:focus { background: $accent 20%; text-style: bold; }
    /* height auto so a narrow terminal wraps the hints instead of cutting
       the last ones off, which are the ones that end the session. */
    #hints { dock: bottom; height: auto; padding: 0 1; color: $text-muted;
             background: $panel; }
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
        self.focused_step: str | None = None
        self.result: list | None = None

    # -- layout ----------------------------------------------------------
    def compose(self) -> ComposeResult:
        yield Header(show_clock=False)
        with Pane(id="left"):
            yield Label("Profile  —  ↑↓ then enter", classes="heading")
            with ProfileRadioSet(id="profile"):
                for name in PROFILES:
                    yield RadioButton(name, value=(name == self.profile), id=f"p-{name}")
            yield Static("", id="profile-help", classes="why")
            yield Label("This machine", classes="heading")
            yield Static(self._machine_summary(), id="machine", classes="why")
        with Pane(id="right"):
            yield Label("Steps  —  ↑↓ move, space toggles, tab for profile, "
                        "enter installs", classes="heading")

            group = None
            for step in STEPS:
                if step.group != group:
                    group = step.group
                    yield Label(group, classes="group")
                applicable, reason = self.machine.applicable(step)
                yield StepCheckbox(self._label(step), id=f"s-{step.id}")
                yield Static(step.why, classes="why")
                if not applicable:
                    yield Static(f"not applicable here: {reason}", classes="na")
        # This replaces Textual's Footer, which docks to the same row and
        # renders only the bindings marked show=True -- the arrows and space,
        # the two keys a first-time user actually needs, are not among them.
        yield Static(
            "↑↓ move   space tick/untick   tab profile   "
            "a all   n none   r reset   enter review   q quit",
            id="hints")

    def on_mount(self) -> None:
        self.title = "Golf cart setup"
        self._apply_profile(self.profile)
        self.query_one("#profile-help", Static).update(PROFILE_HELP[self.profile])
        # The step list is what the menu is for, so start there. The profile
        # radio set is one tab away and keeps its own arrow-key handling.
        boxes = self._boxes()
        if boxes:
            boxes[0].focus()

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

    def on_descendant_focus(self, event) -> None:
        """Remember where the list was, so tab comes back to it."""
        if isinstance(event.widget, StepCheckbox):
            self.focused_step = event.widget.id

    def action_focus_profile(self) -> None:
        self.query_one("#profile", ProfileRadioSet).focus()

    def action_focus_steps(self) -> None:
        boxes = self._boxes()
        if not boxes:
            return
        target = next((b for b in boxes if b.id == self.focused_step), boxes[0])
        target.focus()
        target.scroll_visible(animate=False)

    def _boxes(self) -> list[StepCheckbox]:
        """The steps in screen order; `query` walks the DOM."""
        return list(self.query(StepCheckbox))

    def action_move_step(self, delta: int) -> None:
        boxes = self._boxes()
        if not boxes:
            return
        try:
            index = boxes.index(self.focused)
        except ValueError:
            index = 0 if delta > 0 else len(boxes) - 1
        else:
            index = max(0, min(len(boxes) - 1, index + delta))
        # Clamped, not wrapped: in a 25-item list, landing at the far end after
        # one keypress reads as a glitch rather than as navigation.
        boxes[index].focus()
        boxes[index].scroll_visible(animate=False)

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
        if not chosen:
            self.notify("Nothing ticked. Space ticks the focused step.",
                        severity="warning")
            return
        steps = ordered(chosen)

        def decided(go: bool | None) -> None:
            if go:
                self.result = steps
                self.exit(steps)

        self.push_screen(ConfirmScreen(steps, self.machine), decided)


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
