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
# Host configuration mirrored from /etc: setup/host/manifest.yaml + the tree.
HOST_DIR = SETUP_DIR / "host"
HARDWARE_DIR = REPO_ROOT / "scripts" / "hardware"

# `all` and `none` are computed rather than declared per step, so a new step
# joins them without being listed anywhere -- see Step.default_for.
PROFILES = ("dev", "vehicle", "all", "none", "ci")
DECLARED = ("dev", "vehicle", "ci")

PROFILE_HELP = {
    "dev": "Laptop, workstation, PC. Dev tools, libraries, kernel socket "
           "buffers and loopback multicast. No sensor or CAN system config.",
    "vehicle": "The cart itself: everything in dev, plus sensor udev rules, "
               "CAN, PTP and camera kernel modules.",
    "all": "Every step, including the slow and opt-in ones.",
    "none": "Nothing preselected. Tick what you want.",
    "ci": "Headless and minimal. Build dependencies only, no prompts.",
}

# There was no `orin` profile in the end: a Jetson with no sensors attached is a
# development machine, and one with sensors is the vehicle. Keeping a
# per-board profile meant maintaining a third column that only ever differed
# from `dev` by whether hardware happened to be plugged in.
RETIRED_PROFILES = {"laptop": "dev", "orin": "dev"}

# Which machine of the two-host pair this checkout is. Written to config/host by
# `./setup.sh --role`, read by scripts/env.sh (DDS profile, domain ids) and by the
# systemd unit installer. A role is not a profile: it adds the few steps that
# belong to exactly one machine (see Step.roles) and drops the ones that belong
# to the other (Requires.role), on top of whatever profile was picked.
ROLES = ("master", "orin")
HOST_FILE = REPO_ROOT / "config" / "host"

# The profile `--role` implies when no --profile is given: both hosts are the
# vehicle, so both want the sensor and bus configuration.
ROLE_PROFILE = "vehicle"

# Profiles a role adds its own steps to. `none` means nothing preselected and
# `ci` is a headless build box; neither should grow systemd units.
ROLE_ADDS_TO = ("dev", "vehicle", "all")

# How a step's recorded state is spelled, everywhere it is shown. The menu also
# offers a tick box, and the two answer different questions -- "run this now?"
# against "does the machine already have it?" -- so neither is a symbol that
# could be mistaken for the other.
STATE_WORDS = {
    "ok": "installed",
    "stale": "script changed",
    "failed": "failed",
    "skipped": "skipped",
    "pending": "",
}

# ROS 2 Humble's supported platform. Anything else is somebody's afternoon.
SUPPORTED_OS = ("ubuntu", "22.04")
OS_OK, OS_WARN, OS_ERROR = "ok", "warn", "error"


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
    # Host roles (config/host) this step means anything on; empty means any.
    # Like `hardware` it annotates, never blocks -- but once a role is known,
    # a step for the other role also drops out of the preset's selection.
    role: tuple[str, ...] = ()


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
    roles: tuple[str, ...] = ()          # roles that select it, whatever the profile
    # Repo files or directories whose contents the step installs. Hashed into
    # the digest like a script in `run`, so an edited config file under
    # setup/host shows the step as stale.
    inputs: tuple[str, ...] = ()

    def default_for(self, profile: str, role: str | None = None) -> bool:
        """Is this step ticked by `profile` on a host playing `role`?

        Without a role this is the profile alone, exactly as before roles
        existed. With one, the role's own steps are added (unless the profile
        is `none` or `ci`) and steps meant only for the other role are removed,
        so `--role orin` does not install the master's LiDAR NIC profiles.
        """
        if role is not None and self.requires.role and role not in self.requires.role:
            return False
        if profile == "all":
            return True
        if profile == "none":
            return False
        if role is not None and role in self.roles and profile in ROLE_ADDS_TO:
            return True
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
            # Most argv items are commands, flags, or (for `bash -euc`) an
            # entire shell program.  Check containment before asking the OS
            # about the path: an arbitrary shell program can exceed the
            # filesystem's maximum filename length when passed to stat().
            try:
                in_repo = candidate.is_relative_to(REPO_ROOT)
            except ValueError:
                in_repo = False
            if in_repo and candidate.is_file():
                h.update(candidate.read_bytes())
        for item in self.inputs:
            path = Path(item)
            files = sorted(p for p in path.rglob("*") if p.is_file()) \
                if path.is_dir() else [path]
            for f in files:
                try:
                    name = str(f.relative_to(REPO_ROOT))
                except ValueError:
                    name = str(f)
                h.update(name.encode())
                h.update(b"\0")
                h.update(f.read_bytes() if f.is_file() else b"<missing>")
        return h.hexdigest()[:12]


class Machine:
    """Detected facts about this host, cached for the process lifetime."""

    def __init__(self, role: str | None = None) -> None:
        self.arch = platform.machine()
        self.is_jetson = Path("/etc/nv_tegra_release").exists()
        # What config/host says now, and the role this run is for: `--role`
        # when given (config/host may not be written yet -- a dry run never
        # writes it), else config/host when it names a real role.
        self.host_role = self._host_role()
        self.role = role or (self.host_role if self.host_role in ROLES else None)
        self.os_release = self._os_release()
        self._caps: dict[str, bool] = {}

    @staticmethod
    def _os_release() -> dict[str, str]:
        values: dict[str, str] = {}
        path = Path("/etc/os-release")
        if not path.is_file():
            return values
        for line in path.read_text().splitlines():
            key, _, value = line.partition("=")
            if key:
                values[key.strip()] = value.strip().strip('"\'')
        return values

    @property
    def os_name(self) -> str:
        rel = self.os_release
        return rel.get("PRETTY_NAME") or " ".join(
            filter(None, (rel.get("NAME", ""), rel.get("VERSION_ID", "")))
        )

    def os_check(self) -> tuple[str, str]:
        """Is this a machine ROS 2 Humble runs on?

        Three outcomes, not two. Humble targets exactly Ubuntu 22.04, and every
        install script here assumes its apt package names -- but a Debian or a
        neighbouring Ubuntu can be made to work, and someone doing that on
        purpose should get a warning rather than a wall. Anything else is not a
        near miss, so it stops by default and `--ignore-os-check` is the way
        past it.
        """
        rel = self.os_release
        distro = rel.get("ID", "").lower()
        version = rel.get("VERSION_ID", "")
        if (distro, version) == SUPPORTED_OS:
            return OS_OK, ""
        family = f"{distro} {rel.get('ID_LIKE', '')}".lower()
        if "ubuntu" in family or "debian" in family:
            return OS_WARN, (
                f"{self.os_name} is not Ubuntu 22.04. ROS 2 Humble is built "
                f"for 22.04; these steps use its apt package names, so some "
                f"will need adjusting."
            )
        return OS_ERROR, (
            f"{self.os_name or 'this system'} is not Ubuntu or Debian. "
            f"ROS 2 Humble is not packaged for it and these steps will not "
            f"work as written."
        )

    @staticmethod
    def _host_role() -> str | None:
        return read_host_role()

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
        """A starting point, never a verdict. The user can pick any profile.

        Hardware decides, not the board: a Jetson on a desk is a development
        machine and a Jetson in the cart is the vehicle, and the difference
        visible from here is whether the sensors and the bus are attached.
        """
        if self.has("can") or self.has("ublox-gnss") or self.has("tier4-camera"):
            return "vehicle"
        if self.role in ROLES:
            return ROLE_PROFILE
        return "dev"

    def applicable(self, step: Step) -> tuple[bool, str]:
        req = step.requires
        if req.role:
            wanted = " or ".join(req.role)
            if self.role is None:
                return False, (f"{wanted} host only; no role set "
                               f"(./setup.sh --role {'|'.join(ROLES)})")
            if self.role not in req.role:
                return False, f"{wanted} host only, this host is {self.role}"
        if req.arch and self.arch not in req.arch:
            return False, f"needs {' or '.join(req.arch)}, this host is {self.arch}"
        if req.hardware and not self.has(req.hardware):
            return False, f"{req.hardware} not detected"
        return True, ""


# --------------------------------------------------------------------------
# config/host
# --------------------------------------------------------------------------
def read_host_role(path: Path | None = None) -> str | None:
    """config/host's word, whatever it is, or None when absent or empty.

    Not validated here: scripts/env.sh accepts any name with a matching
    config/cyclonedds/<name>.xml (`loopback` too), and the caller decides what
    a value outside ROLES means for it.
    """
    path = path or HOST_FILE
    if path.is_file():
        value = path.read_text().strip()
        if value:
            return value
    return None


class RoleConflict(Exception):
    """config/host already names a different machine."""


def check_role(requested: str, force: bool, path: Path | None = None) -> str | None:
    """Validate `--role` against config/host. Returns the previous value.

    A checkout that is already the master must not quietly become the orin:
    the role picks the DDS profile, the domain ids and what the units start,
    and two masters on one LAN is a confusing afternoon. So a different value
    refuses unless `--force-role`.
    """
    if requested not in ROLES:
        raise ValueError(f"role must be one of {', '.join(ROLES)}, not {requested!r}")
    current = read_host_role(path)
    if current is not None and current != requested and not force:
        raise RoleConflict(
            f"config/host says '{current}', but --role {requested} was given.\n"
            f"This checkout is already set up as '{current}'. If this machine "
            f"really is the {requested}, re-run with --force-role: it rewrites "
            f"config/host and forgets the role-specific steps' state "
            f"(host-config, host-services, chrony-*, linuxptp, orin-can0) so "
            f"they run again."
        )
    return current


def write_host_role(role: str, path: Path | None = None) -> bool:
    """Write config/host. Returns True when the file changed."""
    path = path or HOST_FILE
    if read_host_role(path) == role:
        return False
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(role + "\n")
    return True
