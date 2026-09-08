"""What a setup step is, and what the machine looks like.

The old design split this knowledge three ways: a `MENU_ITEMS` array in
`setup.sh` held the labels and defaults, the `setup:` recipe in the justfile held
the order, and a `_setup-*` wrapper per option held the condition. Steps that
nobody wrote a wrapper for ran unconditionally and never appeared in the menu --
thirteen of them, including two that write udev rules.

Here a step is one object. If it is not in this list it does not run, and if it
is in this list the UI shows it.
"""

from __future__ import annotations

import hashlib
import os
import platform
import shutil
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SETUP_DIR = REPO_ROOT / "setup"
SCRIPTS_DIR = SETUP_DIR / "scripts"
FILES_DIR = SETUP_DIR / "files"
HARDWARE_DIR = REPO_ROOT / "scripts" / "hardware"

PROFILES = ("laptop", "orin", "vehicle", "ci")

PROFILE_HELP = {
    "laptop": "Offline development, replay and simulation. No sensors attached.",
    "orin": "Jetson without sensors. Adds CUDA and TensorRT work.",
    "vehicle": "The cart itself: udev rules, CAN, PTP, camera kernel modules.",
    "ci": "Headless and minimal. Build dependencies only, no prompts.",
}


@dataclass(frozen=True)
class Requires:
    """What a step needs from the machine it runs on.

    `hardware` is a capability name resolved by `Machine.has`. It never blocks a
    step -- someone provisioning a machine before the hardware arrives must be
    able to select anything -- it only annotates the step as not applicable so
    the reason a default is off is visible rather than mysterious.
    """

    sudo: bool = False
    network: bool = True
    arch: tuple[str, ...] = ()          # empty means any
    hardware: str | None = None
    reboot: bool = False


@dataclass
class Step:
    id: str
    label: str
    why: str
    run: list[str]                       # argv, executed without a shell
    requires: Requires = field(default_factory=Requires)
    profiles: dict[str, bool] = field(default_factory=dict)
    group: str = "Core"
    after: tuple[str, ...] = ()          # ordering only, not auto-selection
    note: str = ""                       # printed after a successful run

    def default_for(self, profile: str) -> bool:
        return self.profiles.get(profile, False)

    def digest(self) -> str:
        """Fingerprint of what this step would do.

        Covers the argv and, when the step runs a script from this repo, that
        script's contents. A marker file could only say "ran once"; this is what
        lets the UI say "ran, but the script has changed since" -- the case that
        silently bites when an install script is edited.
        """
        h = hashlib.sha256()
        for part in self.run:
            h.update(part.encode())
            h.update(b"\0")
            candidate = Path(part)
            if candidate.is_file() and candidate.is_relative_to(REPO_ROOT):
                h.update(candidate.read_bytes())
        return h.hexdigest()[:12]


class Machine:
    """Detected facts about this host, cached for the process lifetime."""

    def __init__(self) -> None:
        self.arch = platform.machine()
        self.is_jetson = Path("/etc/nv_tegra_release").exists()
        self.host_role = self._host_role()
        self._caps: dict[str, bool] = {}

    @staticmethod
    def _host_role() -> str | None:
        # config/host is gitignored and says which machine this checkout is.
        path = REPO_ROOT / "config" / "host"
        if path.is_file():
            value = path.read_text().strip()
            if value:
                return value
        return None

    def has(self, capability: str) -> bool:
        if capability not in self._caps:
            self._caps[capability] = self._detect(capability)
        return self._caps[capability]

    def _detect(self, capability: str) -> bool:
        if capability == "cuda":
            return self.is_jetson or shutil.which("nvidia-smi") is not None
        if capability == "can":
            return any(Path("/sys/class/net").glob("can*"))
        if capability == "ublox-gnss":
            return self._usb_present("1546")            # u-blox AG
        if capability == "tier4-camera":
            return self._usb_present("2560") or self._usb_present("0525")
        if capability == "ptp-nic":
            return bool(list(Path("/sys/class/ptp").glob("ptp*")))
        if capability == "display":
            return bool(os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY"))
        return False

    @staticmethod
    def _usb_present(vendor: str) -> bool:
        if shutil.which("lsusb") is None:
            return False
        try:
            out = subprocess.run(
                ["lsusb"], capture_output=True, text=True, timeout=5
            ).stdout
        except (OSError, subprocess.SubprocessError):
            return False
        return f" {vendor}:" in out.replace("ID ", " ")

    def suggested_profile(self) -> str:
        """A starting point, never a verdict. The user can pick any profile."""
        if self.host_role == "orin" or self.is_jetson:
            return "vehicle" if self.has("can") else "orin"
        if self.has("can"):
            return "vehicle"
        return "laptop"

    def applicable(self, step: Step) -> tuple[bool, str]:
        req = step.requires
        if req.arch and self.arch not in req.arch:
            return False, f"needs {' or '.join(req.arch)}, this host is {self.arch}"
        if req.hardware and not self.has(req.hardware):
            return False, f"{req.hardware} not detected"
        return True, ""
