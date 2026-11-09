"""What setup cannot do for you: the "still to do by hand" checklist.

Setup installs what it can. A few things it cannot, because they are vendor
files nobody may redistribute, or because a later manual install undoes a step:

* config/host, the one word that says which machine this checkout is;
* the Turing Drive DBC, without which the orin builds no vehicle interface;
* the ZED SDK, a Stereolabs .run installer -- which also writes
  /etc/sysctl.d/60-zed-buffers.conf and lowers net.core.rmem_max below what the
  CycloneDDS profiles demand, so cyclonedds-sysctl has to run again after it;
* the systemd user units and lingering, which a moved checkout invalidates.

Each check is read-only and names the exact command that fixes it. One module so
every caller agrees: `./setup.sh --status` and the end of a run print it,
`python3 setup/main.py --checklist [--json]` prints only it (exit 1 while
anything is outstanding), `scripts/doctor.sh` includes it, and
`just service pair` runs it on both hosts.

Standard library only, like the rest of setup.
"""

from __future__ import annotations

import getpass
import glob
import os
import re
import shutil
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

from .model import HOST_DIR, REPO_ROOT, ROLES, SCRIPTS_DIR, read_host_role

DBC_PATH = (REPO_ROOT / "src" / "vehicle" / "golfcart_vehicle_launch"
            / "golfcart_vehicle_interface" / "CAX_ADS_CAN.dbc")
ZED_GLOBS = ("/usr/local/zed/zed-config*.cmake", "/usr/local/zed/lib/libsl_zed*")
DDS_DIR = REPO_ROOT / "config" / "cyclonedds"
# What cyclonedds-sysctl installs (it used to be a heredoc in its script).
SYSCTL_FILE = HOST_DIR / "common" / "etc" / "sysctl.d" / "99-cyclonedds-max.conf"
UNIT_SCRIPT = SCRIPTS_DIR / "install-host-service.sh"
RUNTIME_CONF = REPO_ROOT / "config" / "runtime.conf"
USER_UNIT_DIR = Path.home() / ".config" / "systemd" / "user"


@dataclass
class Item:
    id: str
    ok: bool
    summary: str
    fix: list[str] = field(default_factory=list)   # lines; commands indented

    def as_dict(self) -> dict:
        return {"id": self.id, "ok": self.ok, "summary": self.summary, "fix": self.fix}


# --------------------------------------------------------------------------
# requirements, read from the files that impose them
# --------------------------------------------------------------------------
_UNITS = {"B": 1, "KB": 1024, "KIB": 1024, "MB": 1 << 20, "MIB": 1 << 20,
          "GB": 1 << 30, "GIB": 1 << 30}


def _memsize(text: str) -> int | None:
    """CycloneDDS memsize: binary multiples whatever the spelling (16MB = 16 MiB)."""
    m = re.fullmatch(r"\s*(\d+)\s*([A-Za-z]*)\s*", text)
    if not m:
        return None
    unit = (m.group(2) or "B").upper()
    return int(m.group(1)) * _UNITS[unit] if unit in _UNITS else None


def dds_rmem_min(role: str | None = None) -> int | None:
    """The largest `SocketReceiveBufferSize min=` the DDS profiles ask for.

    That is the hard floor: below it Cyclone refuses to create a domain
    ("failed to increase socket receive buffer size to at least ..."). Read
    from the profile XML rather than written here a second time -- doctor.sh
    carried a 10 MB copy while the profiles had moved to 16 MB. With a role,
    that role's profile only; otherwise every profile, so a host that has not
    picked one is still held to the strictest.
    """
    files = [DDS_DIR / f"{role}.xml"] if role else sorted(DDS_DIR.glob("*.xml"))
    best = None
    for path in files:
        try:
            text = path.read_text()
        except OSError:
            continue
        for value in re.findall(r'<SocketReceiveBufferSize[^>]*\bmin="([^"]+)"', text):
            size = _memsize(value)
            if size is not None and (best is None or size > best):
                best = size
    return best


def sysctl_target() -> int | None:
    """The rmem_max cyclonedds-sysctl writes, read from setup/host."""
    try:
        m = re.search(r"^net\.core\.rmem_max=(\d+)", SYSCTL_FILE.read_text(), re.M)
    except OSError:
        return None
    return int(m.group(1)) if m else None


def units_for(role: str) -> list[str]:
    """The units install-host-service.sh installs for `role`, read from it."""
    try:
        text = UNIT_SCRIPT.read_text()
    except OSError:
        return []
    m = re.search(rf"^\s*{re.escape(role)}\)\s*UNITS=\(([^)]*)\)", text, re.M)
    return m.group(1).split() if m else []


def _rmw() -> str:
    if os.environ.get("GOLFCART_RMW"):
        return os.environ["GOLFCART_RMW"]
    try:
        m = re.search(r'GOLFCART_RMW="\$\{GOLFCART_RMW:-(\w+)\}"', RUNTIME_CONF.read_text())
    except OSError:
        m = None
    return m.group(1) if m else "cyclonedds"


def _rel(path: Path) -> str:
    try:
        return str(path.relative_to(REPO_ROOT))
    except ValueError:
        return str(path)


def _human(n: int) -> str:
    for unit, size in (("GiB", 1 << 30), ("MiB", 1 << 20), ("KiB", 1 << 10)):
        if n >= size:
            return f"{n / size:g} {unit}"
    return f"{n} B"


# --------------------------------------------------------------------------
# checks
# --------------------------------------------------------------------------
def check_host_role(value: str | None) -> Item:
    if value in ROLES:
        return Item("host-role", True, f"config/host: {value}")
    what = "missing" if value is None else f"says '{value}', not master or orin"
    return Item("host-role", False, f"config/host {what}", [
        "on the master:  ./setup.sh --role master",
        "on the orin:    ./setup.sh --role orin",
    ] + ([] if value is None else ["(add --force-role to replace the current value)"]))


def check_dbc() -> Item:
    env = os.environ.get("CAX_ADS_DBC")
    if env and Path(env).is_file():
        return Item("vendor-dbc", True, f"vendor CAN DBC: {env} (CAX_ADS_DBC)")
    if DBC_PATH.is_file():
        return Item("vendor-dbc", True, "vendor CAN DBC: present in the crate root")
    summary = "vendor CAN DBC absent: just build skips the vehicle interface"
    if env:
        summary += f" (CAX_ADS_DBC={env} does not exist)"
    return Item("vendor-dbc", False, summary, [
        "obtain CAX_ADS_CAN.dbc from Turing Drive (proprietary, gitignored), copy it to",
        f"    {_rel(DBC_PATH)}",
        "then:",
        "    just build",
    ])


def check_zed_sdk() -> Item:
    for pattern in ZED_GLOBS:
        if glob.glob(pattern):
            return Item("zed-sdk", True, "ZED SDK: installed (/usr/local/zed)")
    return Item("zed-sdk", False, "ZED SDK absent (/usr/local/zed): no ZED X camera or IMU", [
        "download the ZED SDK .run installer for this JetPack from stereolabs.com, run it:",
        "    chmod +x ZED_SDK_*.run && ./ZED_SDK_*.run",
        "it lowers net.core.rmem_max (60-zed-buffers.conf), so afterwards:",
        "    ./setup.sh --rerun cyclonedds-sysctl",
        "    just build",
    ])


def check_rmem(role: str | None) -> Item | None:
    if _rmw() != "cyclonedds":
        return None                       # zenoh rides TCP; no such floor
    need = dds_rmem_min(role if role in ROLES else None)
    if need is None:
        return Item("rmem", False, "net.core.rmem_max: cannot read the DDS profiles' "
                    f"SocketReceiveBufferSize min from {_rel(DDS_DIR)}")
    target = sysctl_target()
    fix = ["    ./setup.sh --rerun cyclonedds-sysctl"
           + (f"   (writes {target} to /etc/sysctl.d/99-cyclonedds-max.conf)"
              if target else "")]
    try:
        live = int(Path("/proc/sys/net/core/rmem_max").read_text().strip())
    except (OSError, ValueError):
        return Item("rmem", False, "net.core.rmem_max unreadable", fix)
    if live < need:
        lower = _sysctl_files_setting_rmem()
        return Item("rmem", False,
                    f"net.core.rmem_max = {live} ({_human(live)}), below the "
                    f"{_human(need)} the DDS profiles require: no ROS node can start",
                    fix + [f"(set by: {', '.join(lower)})"] if lower else fix)
    # Live is fine; will it survive a reboot? A ZED SDK install after
    # cyclonedds-sysctl ran, or a 99- file removed by hand, is fine until boot.
    ours = Path("/etc/sysctl.d/99-cyclonedds-max.conf")
    if not ours.is_file():
        lower = [f for f, v in _sysctl_values() if v < need]
        if lower:
            return Item("rmem", False,
                        f"net.core.rmem_max = {_human(live)} now, but the next boot "
                        f"applies {', '.join(lower)} and drops it below {_human(need)}",
                        fix)
    return Item("rmem", True, f"net.core.rmem_max = {_human(live)} (>= {_human(need)})")


def _sysctl_values() -> list[tuple[str, int]]:
    out = []
    for path in sorted(glob.glob("/etc/sysctl.d/*.conf")) + ["/etc/sysctl.conf"]:
        try:
            text = Path(path).read_text()
        except OSError:
            continue
        for m in re.finditer(r"^\s*net\.core\.rmem_max\s*=\s*(\d+)", text, re.M):
            out.append((path, int(m.group(1))))
    return out


def _sysctl_files_setting_rmem() -> list[str]:
    return [f"{f} -> {v}" for f, v in _sysctl_values()]


def _lingering() -> bool | None:
    user = getpass.getuser()
    if shutil.which("loginctl"):
        try:
            out = subprocess.run(
                ["loginctl", "show-user", user, "--property=Linger"],
                capture_output=True, text=True, timeout=5).stdout
            if "Linger=" in out:
                return "Linger=yes" in out
        except (OSError, subprocess.SubprocessError):
            pass
    # No logind session for this user (e.g. never logged in): the marker file
    # is what logind itself reads at boot.
    return Path("/var/lib/systemd/linger", user).exists()


def check_host_services(role: str) -> Item:
    fix = ["    ./setup.sh --rerun host-services"]
    units = units_for(role)
    if not units:
        return Item("host-services", False,
                    f"cannot read the unit list for '{role}' from "
                    f"{_rel(UNIT_SCRIPT)}")
    problems = []
    for unit in units:
        if not (USER_UNIT_DIR / unit).is_file():
            problems.append(f"{unit} not installed")
            continue
        try:
            drop = (USER_UNIT_DIR / f"{unit}.d" / "override.conf").read_text()
        except OSError:
            problems.append(f"{unit} has no override.conf drop-in")
            continue
        host = re.search(r"^Environment=GOLFCART_HOST=(\S+)", drop, re.M)
        ws = re.search(r"^Environment=GOLFCART_WORKSPACE=(.+)$", drop, re.M)
        if not host or host.group(1) != role:
            problems.append(f"{unit} installed for "
                            f"'{host.group(1) if host else '?'}', this host is {role}")
        elif not ws or Path(ws.group(1).strip()).resolve() != REPO_ROOT.resolve():
            problems.append(f"{unit} points at "
                            f"{ws.group(1).strip() if ws else '?'}, not this checkout")
    linger = _lingering()
    if linger is False:
        problems.append("lingering off: units die with the last ssh session")
    if problems:
        return Item("host-services", False, "systemd units: " + "; ".join(problems), fix)
    return Item("host-services", True,
                f"systemd units installed ({', '.join(u.removesuffix('.service') for u in units)})"
                + (", lingering on" if linger else ""))


def run_checks(role_override: str | None = None) -> tuple[str | None, list[Item]]:
    """All checks for this host. Returns (role used, items)."""
    on_file = read_host_role()
    role = role_override or on_file
    if role_override and on_file != role_override:
        # Asked about a role config/host does not (yet) hold: check the rest
        # as that role, but do not report config/host as fine.
        items = [Item("host-role", False,
                      f"config/host {'missing' if on_file is None else f'says {on_file!r}'}"
                      f" (checked as {role_override})",
                      [f"    ./setup.sh --role {role_override}"
                       + (" --force-role" if on_file else "")])]
    else:
        items = [check_host_role(role)]
    if role == "orin":
        items += [check_dbc(), check_zed_sdk()]
    rmem = check_rmem(role)
    if rmem is not None:
        items.append(rmem)
    if role in ROLES:
        items.append(check_host_services(role))
    return role, items


# --------------------------------------------------------------------------
# presentation
# --------------------------------------------------------------------------
def render(role: str | None, items: list[Item], colour: bool) -> str:
    def paint(code: str, text: str) -> str:
        return f"\033[{code}m{text}\033[0m" if colour else text

    host = os.uname().nodename
    lines = [f"Still to do by hand on {host} "
             f"(role: {role or 'unset'}; commands run from {REPO_ROOT}):"]
    for item in items:
        tag = paint("32", "[ ok ]") if item.ok else paint("33", "[TODO]")
        lines.append(f"  {tag} {item.summary}")
        if not item.ok:
            lines += [f"         {line}" for line in item.fix]
    todo = sum(1 for i in items if not i.ok)
    if todo:
        lines.append(f"  {todo} item(s) outstanding.")
    else:
        lines.append("  Nothing left.")
        if role == "master":
            lines.append("  Next, once the orin is set up too:  just service pair")
        elif role == "orin":
            lines.append("  Next, on the master:  just service pair")
    return "\n".join(lines)


def as_json(role: str | None, items: list[Item]) -> dict:
    return {
        "host": os.uname().nodename,
        "repo": str(REPO_ROOT),
        "role": role,
        "outstanding": sum(1 for i in items if not i.ok),
        "items": [i.as_dict() for i in items],
    }
