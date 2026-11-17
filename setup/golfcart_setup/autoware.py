"""The Autoware version catalogue (versions.yaml) and the selected version.

    python3 setup/golfcart_setup/autoware.py selected
    python3 setup/golfcart_setup/autoware.py list
    python3 setup/golfcart_setup/autoware.py shell [VERSION] [--platform P]

`selected` prints the version this checkout builds and runs, as
scripts/autoware_version.sh resolves it (GOLFCART_AUTOWARE_VERSION, then
config/autoware-version, then config/runtime.conf). That shell file is the one
rule; this module asks it rather than re-implementing it.

`shell` prints one release's facts as shell assignments for
setup/scripts/install-autoware-debian.sh to eval:

    AW_VERSION=2.1.0 AW_RELEASE=2.1.0-1 AW_SUFFIX=2-1-0 AW_PLATFORM=jetpack62
    AW_DEB=... AW_SHA256=... AW_URL=https://github.com/.../2.1.0-1/<deb>

Standard library only, like the rest of setup: versions.yaml is read by a
small parser for the subset it uses (nested mappings of scalars, `#`
comments, quoted or bare values). Anything else in it is an error, not a
guess.
"""

from __future__ import annotations

import os
import platform as _platform
import re
import shlex
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
CATALOGUE = REPO_ROOT / "versions.yaml"
VERSION_SH = REPO_ROOT / "scripts" / "autoware_version.sh"
RELEASE_URL = "https://github.com/NEWSLabNTU/autoware-localrepo/releases/download"
FALLBACK_VERSION = "1.5.0"
_VERSION_RE = re.compile(r"^\d+\.\d+\.\d+$")


class CatalogueError(Exception):
    pass


def _scalar(text: str, where: str) -> str:
    text = text.strip()
    if len(text) >= 2 and text[0] == text[-1] and text[0] in "\"'":
        return text[1:-1]
    if text[:1] in "[{&*!|>":
        raise CatalogueError(f"{where}: only plain scalars are supported, got {text!r}")
    return text


def _strip_comment(line: str) -> str:
    """Drop a `#` comment that is not inside quotes."""
    quote = None
    for i, ch in enumerate(line):
        if quote:
            if ch == quote:
                quote = None
        elif ch in "\"'":
            quote = ch
        elif ch == "#" and (i == 0 or line[i - 1].isspace()):
            return line[:i]
    return line


def parse(text: str, name: str = "versions.yaml") -> dict:
    """Parse the YAML subset versions.yaml is written in."""
    root: dict = {}
    stack: list[tuple[int, dict]] = [(-1, root)]
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = _strip_comment(raw).rstrip()
        if not line.strip():
            continue
        where = f"{name}:{lineno}"
        if "\t" in line[: len(line) - len(line.lstrip())]:
            raise CatalogueError(f"{where}: tab in indentation")
        indent = len(line) - len(line.lstrip(" "))
        body = line.strip()
        if body.startswith("- "):
            raise CatalogueError(f"{where}: lists are not supported")
        key, sep, value = body.partition(":")
        if not sep:
            raise CatalogueError(f"{where}: expected `key: value`")
        if key[:1] in "\"'" and key[-1:] == key[:1]:
            key = key[1:-1]
        while stack and indent <= stack[-1][0]:
            stack.pop()
        if not stack:
            raise CatalogueError(f"{where}: bad indentation")
        parent = stack[-1][1]
        if key in parent:
            raise CatalogueError(f"{where}: duplicate key {key!r}")
        if value.strip():
            parent[key] = _scalar(value, where)
        else:
            child: dict = {}
            parent[key] = child
            stack.append((indent, child))
    return root


@dataclass(frozen=True)
class Release:
    version: str        # 2.1.0
    release: str        # 2.1.0-1, the GitHub tag and the deb's revision
    suffix: str         # 2-1-0
    platform: str       # ubuntu2204 | jetpack62
    deb: str
    sha256: str

    @property
    def url(self) -> str:
        return f"{RELEASE_URL}/{self.release}/{self.deb}"

    @property
    def localrepo_package(self) -> str:
        return f"autoware-localrepo-{self.suffix}"

    @property
    def localrepo_deb_version(self) -> str:
        """The Version: field of the localrepo deb, e.g. 2.1.0-1jetpack62."""
        return f"{self.release}{self.platform}"

    def shell(self) -> str:
        pairs = {
            "AW_VERSION": self.version, "AW_RELEASE": self.release,
            "AW_SUFFIX": self.suffix, "AW_PLATFORM": self.platform,
            "AW_DEB": self.deb, "AW_SHA256": self.sha256, "AW_URL": self.url,
            "AW_LOCALREPO_PACKAGE": self.localrepo_package,
            "AW_LOCALREPO_VERSION": self.localrepo_deb_version,
        }
        return "".join(f"{k}={shlex.quote(v)}\n" for k, v in pairs.items())


def load(path: Path = CATALOGUE) -> dict:
    try:
        data = parse(path.read_text(), path.name)
    except OSError as e:
        raise CatalogueError(f"cannot read {path}: {e}") from e
    versions = data.get("autoware")
    if not isinstance(versions, dict) or not versions:
        raise CatalogueError(f"{path.name}: no `autoware:` catalogue")
    for ver, entry in versions.items():
        if not _VERSION_RE.match(ver) or not isinstance(entry, dict):
            raise CatalogueError(f"{path.name}: autoware.{ver}: not an X.Y.Z entry")
        for k in ("release", "suffix", "platforms"):
            if k not in entry:
                raise CatalogueError(f"{path.name}: autoware.{ver} has no {k}")
        if entry["suffix"] != ver.replace(".", "-"):
            raise CatalogueError(f"{path.name}: autoware.{ver}.suffix should be "
                                 f"{ver.replace('.', '-')}, is {entry['suffix']}")
        if not entry["release"].startswith(ver + "-"):
            raise CatalogueError(f"{path.name}: autoware.{ver}.release "
                                 f"{entry['release']} is not a {ver} release")
    return versions


def versions(path: Path = CATALOGUE) -> list[str]:
    return sorted(load(path), key=lambda v: tuple(int(x) for x in v.split(".")))


def detect_platform() -> str:
    """The catalogue platform of this machine; AUTOWARE_PLATFORM overrides."""
    forced = os.environ.get("AUTOWARE_PLATFORM", "").strip()
    if forced:
        return forced
    machine = _platform.machine()
    if machine == "x86_64":
        return "ubuntu2204"
    if machine == "aarch64":
        if Path("/etc/nv_tegra_release").is_file():
            return "jetpack62"
        raise CatalogueError("aarch64 without /etc/nv_tegra_release: not a Jetson. "
                             "The catalogue lists only ubuntu2204 and jetpack62; "
                             "set AUTOWARE_PLATFORM to choose one.")
    raise CatalogueError(f"unsupported architecture {machine}")


def release(version: str, platform: str | None = None,
            path: Path = CATALOGUE) -> Release:
    cat = load(path)
    if version not in cat:
        raise CatalogueError(f"Autoware {version} is not in {path.name}; "
                             f"supported: {', '.join(versions(path))}")
    entry = cat[version]
    plat = platform or detect_platform()
    asset = entry["platforms"].get(plat) if isinstance(entry["platforms"], dict) else None
    if not isinstance(asset, dict) or "deb" not in asset or "sha256" not in asset:
        have = ", ".join(entry["platforms"]) if isinstance(entry["platforms"], dict) else "-"
        raise CatalogueError(f"Autoware {version} has no {plat} deb in {path.name} (have: {have})")
    if not re.fullmatch(r"[0-9a-f]{64}", asset["sha256"]):
        raise CatalogueError(f"autoware.{version}.platforms.{plat}.sha256 is not a sha256")
    return Release(version=version, release=entry["release"], suffix=entry["suffix"],
                   platform=plat, deb=asset["deb"], sha256=asset["sha256"])


def selected_version(env: dict | None = None) -> str:
    """The version scripts/autoware_version.sh resolves, in a clean subshell."""
    env = dict(os.environ if env is None else env)
    try:
        res = subprocess.run(
            ["bash", "-c", '. "$1" >/dev/null && printf %s "$GOLFCART_AUTOWARE_VERSION"',
             "_", str(VERSION_SH)],
            capture_output=True, text=True, env=env, check=False, timeout=10,
        )
        ver = res.stdout.strip()
    except (OSError, subprocess.TimeoutExpired):
        ver = ""
    return ver if _VERSION_RE.match(ver) else FALLBACK_VERSION


def main(argv: list[str]) -> int:
    import argparse
    p = argparse.ArgumentParser(prog="autoware.py", description=__doc__.split("\n\n")[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("selected", help="the version this checkout runs")
    sub.add_parser("list", help="every version in the catalogue")
    sh = sub.add_parser("shell", help="one release as shell assignments")
    sh.add_argument("version", nargs="?", help="X.Y.Z (default: the selected one)")
    sh.add_argument("--platform", help="ubuntu2204 | jetpack62 (default: this machine)")
    args = p.parse_args(argv)
    try:
        if args.cmd == "selected":
            print(selected_version())
        elif args.cmd == "list":
            for v in versions():
                print(v)
        else:
            print(release(args.version or selected_version(), args.platform).shell(), end="")
    except CatalogueError as e:
        print(f"autoware.py: {e}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
