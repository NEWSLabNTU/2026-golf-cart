"""Host configuration kept in the repo: setup/host/.

    python3 setup/golfcart_setup/hostcfg.py diff [--orin] [--exit-code]
    python3 setup/golfcart_setup/hostcfg.py capture [--orin] [TARGET ...]
    python3 setup/golfcart_setup/hostcfg.py install [--step ID] [--target PATH ...]
    python3 setup/golfcart_setup/hostcfg.py scan
    python3 setup/golfcart_setup/hostcfg.py list

`setup/host/{common,master,orin}/` mirrors absolute target paths, and
`setup/host/manifest.yaml` says which file goes where, for which role, with what
mode and owner and what has to be reloaded afterwards. The manifest is an
allow-list: `capture` copies only what it names, so a personal Wi-Fi or VPN
profile on the same machine can never be swept into a public repository.

Three verbs, three directions:

* diff     repo vs live, read only. `--orin` reads the orin's files over ssh
           (scripts/multi_machine/on_orin.sh) and compares them with THIS
           checkout's tree, so it works whether or not the orin has pulled.
* capture  live -> repo, for files already in the manifest. Secrets and
           volatile keys are stripped first; see `strip_profiles`.
* install  repo -> live. This is the `host-config` setup step, and the narrower
           steps (ublox-udev, linuxptp, chrony-*, ...) call it with `--step`
           for their own subset. Idempotent: a file whose stripped content,
           mode and owner already match is not touched, and each reload action
           runs once, only if something it covers changed.

Stdlib plus PyYAML (python3-yaml, which ROS 2 already depends on). Imported
lazily by nothing in `./setup.sh --list`: that path stays stdlib-only.
"""

from __future__ import annotations

import argparse
import base64
import difflib
import fnmatch
import os
import re
import shlex
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    from golfcart_setup import model  # noqa: E402
else:
    from . import model

HOST_DIR = model.HOST_DIR
MANIFEST = HOST_DIR / "manifest.yaml"
ON_ORIN = model.REPO_ROOT / "scripts" / "multi_machine" / "on_orin.sh"

RELOADS = ("nmcli-reload", "udev-reload", "sysctl", "networkd-reload",
           "systemd-daemon-reload", "hostname", "none")
RELOAD_PREFIXES = ("enable:", "restart:")

# Lines in the tree that look like a credential. `-flags` keys only say who
# owns a secret, never hold one.
_SECRET_WORD = re.compile(r"psk|password|secret", re.IGNORECASE)


class ManifestError(Exception):
    pass


class NotAllowed(Exception):
    """A target that is not in the manifest's allow-list."""


# --------------------------------------------------------------------------
# manifest
# --------------------------------------------------------------------------
@dataclass(frozen=True)
class StripProfile:
    sections: tuple[str, ...] = ()
    keys: tuple[str, ...] = ()
    keep: tuple[str, ...] = ()
    volatile: tuple[str, ...] = ()

    def drops(self, key: str) -> bool:
        if any(fnmatch.fnmatchcase(key, p) for p in self.keep):
            return False
        return any(fnmatch.fnmatchcase(key, p)
                   for p in self.keys + self.volatile)


@dataclass
class FileEntry:
    repo: str                       # relative to setup/host
    target: str
    roles: tuple[str, ...]
    mode: str = "0644"
    owner: str = "root:root"
    reload: tuple[str, ...] = ()
    strip: str | None = None
    step: str = "host-config"
    restore: bool = True
    legacy: tuple[str, ...] = ()
    why: str = ""

    @property
    def repo_path(self) -> Path:
        return HOST_DIR / self.repo


@dataclass
class LineEntry:
    target: str
    roles: tuple[str, ...]
    match: str
    line: str
    reload: tuple[str, ...] = ()
    step: str = "host-config"
    why: str = ""


@dataclass
class GeneratedEntry:
    target: str
    roles: tuple[str, ...]
    by: str
    step: str = ""


@dataclass
class DisabledUnits:
    units: tuple[str, ...]
    roles: tuple[str, ...]
    why: str = ""


@dataclass
class AbsentFiles:
    """Files a host must NOT have: retired config that a restore deletes."""
    targets: tuple[str, ...]
    roles: tuple[str, ...]
    reload: tuple[str, ...] = ()
    why: str = ""


@dataclass
class Manifest:
    files: list[FileEntry] = field(default_factory=list)
    lines: list[LineEntry] = field(default_factory=list)
    generated: list[GeneratedEntry] = field(default_factory=list)
    disabled: list[DisabledUnits] = field(default_factory=list)
    absent: list[AbsentFiles] = field(default_factory=list)
    strip_profiles: dict[str, StripProfile] = field(default_factory=dict)

    def for_role(self, role: str | None, step: str | None = None,
                 targets: list[str] | None = None) -> "Manifest":
        """The entries a host playing `role` carries.

        `role=None` is only meaningful with `step`: a development machine with
        no config/host running, say, cyclonedds-sysctl. It then gets every
        entry of that step, which is what the step installed before the tree
        existed.
        """
        def keep(e) -> bool:
            if role is not None and role not in e.roles:
                return False
            if step is not None and getattr(e, "step", None) != step:
                return False
            if targets is not None and e.target not in targets:
                return False
            return True

        out = Manifest(
            files=[e for e in self.files if keep(e)],
            lines=[e for e in self.lines if keep(e)],
            generated=[e for e in self.generated if keep(e)],
            disabled=[d for d in self.disabled
                      if step in (None, "host-config") and targets is None
                      and (role is None or role in d.roles)],
            absent=[a for a in self.absent
                    if step in (None, "host-config") and targets is None
                    and (role is None or role in a.roles)],
            strip_profiles=self.strip_profiles,
        )
        seen: dict[str, str] = {}
        for e in out.files:
            if e.target in seen and seen[e.target] != e.repo:
                raise ManifestError(
                    f"{e.target} comes from both {seen[e.target]} and {e.repo}; "
                    f"set a role in config/host to pick one")
            seen[e.target] = e.repo
        return out

    def allowed_targets(self) -> set[str]:
        out = {e.target for e in self.files}
        for e in self.files:
            out.update(e.legacy)
        return out

    def check_allowed(self, targets: list[str]) -> None:
        allowed = self.allowed_targets()
        bad = [t for t in targets if t not in allowed]
        if bad:
            raise NotAllowed(
                "not in setup/host/manifest.yaml, refusing: " + ", ".join(bad)
                + "\nThe manifest is an allow-list. Add an entry there first "
                  "if this file really is cart configuration.")


def _tuple(value) -> tuple[str, ...]:
    if value is None:
        return ()
    if isinstance(value, str):
        return (value,)
    return tuple(str(v) for v in value)


def _check_reload(actions: tuple[str, ...], where: str) -> None:
    for a in actions:
        if a in RELOADS or (a.startswith(RELOAD_PREFIXES) and a.split(":", 1)[1]):
            continue
        raise ManifestError(f"{where}: unknown reload action {a!r}")


def _check_roles(roles: tuple[str, ...], where: str) -> None:
    if not roles:
        raise ManifestError(f"{where}: roles is empty")
    for r in roles:
        if r not in model.ROLES:
            raise ManifestError(f"{where}: unknown role {r!r}")


def parse_manifest(data: dict) -> Manifest:
    if not isinstance(data, dict):
        raise ManifestError("manifest must be a mapping")
    m = Manifest()
    for name, spec in (data.get("strip_profiles") or {}).items():
        m.strip_profiles[name] = StripProfile(
            sections=_tuple(spec.get("sections")),
            keys=_tuple(spec.get("keys")),
            keep=_tuple(spec.get("keep")),
            volatile=_tuple(spec.get("volatile")),
        )
    targets: dict[tuple[str, str], str] = {}
    for i, raw in enumerate(data.get("files") or []):
        where = f"files[{i}]"
        for key in ("repo", "target", "roles"):
            if key not in raw:
                raise ManifestError(f"{where}: missing {key!r}")
        e = FileEntry(
            repo=str(raw["repo"]),
            target=str(raw["target"]),
            roles=_tuple(raw["roles"]),
            mode=str(raw.get("mode", "0644")),
            owner=str(raw.get("owner", "root:root")),
            reload=_tuple(raw.get("reload")),
            strip=raw.get("strip"),
            step=str(raw.get("step", "host-config")),
            restore=bool(raw.get("restore", True)),
            legacy=_tuple(raw.get("legacy")),
            why=str(raw.get("why", "")).strip(),
        )
        where = f"files[{i}] ({e.target})"
        if not e.target.startswith("/"):
            raise ManifestError(f"{where}: target must be absolute")
        if not re.fullmatch(r"0?[0-7]{3}", e.mode):
            raise ManifestError(f"{where}: mode {e.mode!r} is not octal")
        if ":" not in e.owner:
            raise ManifestError(f"{where}: owner must be user:group")
        if Path(e.repo).is_absolute() or ".." in Path(e.repo).parts:
            raise ManifestError(f"{where}: repo must be relative to setup/host")
        # The tree mirrors the target: <role-or-common>/<target>.
        head, _, rest = e.repo.partition("/")
        if head not in model.ROLES + ("common",) or "/" + rest != e.target:
            raise ManifestError(
                f"{where}: repo path {e.repo!r} does not mirror the target "
                f"(expected <common|master|orin>{e.target})")
        if head in model.ROLES and e.roles != (head,):
            raise ManifestError(f"{where}: lives under {head}/ but roles={list(e.roles)}")
        _check_roles(e.roles, where)
        _check_reload(e.reload, where)
        if e.strip is not None and e.strip not in m.strip_profiles:
            raise ManifestError(f"{where}: unknown strip profile {e.strip!r}")
        if e.target.endswith(".nmconnection") and e.strip is None:
            raise ManifestError(f"{where}: a .nmconnection must name a strip profile")
        for r in e.roles:
            if (r, e.target) in targets:
                raise ManifestError(f"{where}: target listed twice for role {r}")
            targets[(r, e.target)] = e.repo
        m.files.append(e)
    for i, raw in enumerate(data.get("lines") or []):
        where = f"lines[{i}]"
        for key in ("target", "roles", "match", "line"):
            if key not in raw:
                raise ManifestError(f"{where}: missing {key!r}")
        e = LineEntry(
            target=str(raw["target"]), roles=_tuple(raw["roles"]),
            match=str(raw["match"]), line=str(raw["line"]).strip(),
            reload=_tuple(raw.get("reload")),
            step=str(raw.get("step", "host-config")),
            why=str(raw.get("why", "")).strip(),
        )
        _check_roles(e.roles, where)
        _check_reload(e.reload, where)
        try:
            pattern = re.compile(e.match)
        except re.error as exc:
            raise ManifestError(f"{where}: bad match regex: {exc}") from None
        if not pattern.search(e.line):
            raise ManifestError(f"{where}: the line does not match its own regex")
        m.lines.append(e)
    for i, raw in enumerate(data.get("generated") or []):
        e = GeneratedEntry(target=str(raw["target"]), roles=_tuple(raw["roles"]),
                           by=str(raw["by"]), step=str(raw.get("step", "")))
        _check_roles(e.roles, f"generated[{i}]")
        m.generated.append(e)
    for i, raw in enumerate(data.get("units_disabled") or []):
        d = DisabledUnits(units=_tuple(raw["units"]), roles=_tuple(raw["roles"]),
                          why=str(raw.get("why", "")).strip())
        _check_roles(d.roles, f"units_disabled[{i}]")
        m.disabled.append(d)
    for i, raw in enumerate(data.get("files_absent") or []):
        a = AbsentFiles(targets=_tuple(raw["targets"]), roles=_tuple(raw["roles"]),
                        reload=_tuple(raw.get("reload")),
                        why=str(raw.get("why", "")).strip())
        _check_roles(a.roles, f"files_absent[{i}]")
        for t in a.targets:
            if not t.startswith("/"):
                raise ManifestError(f"files_absent[{i}]: {t} is not an absolute path")
        m.absent.append(a)
    return m


def load_manifest(path: Path | None = None) -> Manifest:
    try:
        import yaml
    except ImportError:
        raise SystemExit("hostcfg needs PyYAML: sudo apt-get install python3-yaml")
    path = path or MANIFEST
    return parse_manifest(yaml.safe_load(path.read_text()))


# --------------------------------------------------------------------------
# secrets
# --------------------------------------------------------------------------
_SECTION = re.compile(r"^\s*\[(?P<name>[^\]]+)\]\s*$")


def strip_text(text: str, profile: StripProfile | None) -> tuple[str, list[tuple[str, str]]]:
    """Remove secret and volatile keys from an INI-style file.

    Returns the kept text and the removed (section, line) pairs, so `install`
    can put a host's own secrets back into the profile it rewrites rather than
    erasing its Wi-Fi password with a repo copy that never had one.
    """
    if profile is None:
        return text, []
    out: list[str] = []
    removed: list[tuple[str, str]] = []
    section = ""
    dropping = False
    for line in text.splitlines(keepends=True):
        m = _SECTION.match(line)
        if m:
            section = m.group("name").strip()
            dropping = section in profile.sections
            if dropping:
                removed.append((section, line))
                continue
        elif dropping:
            if line.strip():
                removed.append((section, line))
            continue
        else:
            key, eq, _ = line.partition("=")
            key = key.strip()
            if eq and key and not key.startswith(("#", ";")) and profile.drops(key):
                removed.append((section, line))
                continue
        out.append(line)
    # A dropped trailing section can leave a dangling blank line.
    kept = "".join(out)
    if text.endswith("\n") and kept.endswith("\n\n") and not text.endswith("\n\n"):
        kept = kept.rstrip("\n") + "\n"
    return kept, removed


def merge_removed(text: str, removed: list[tuple[str, str]]) -> str:
    """Put lines `strip_text` removed back into `text`, section by section."""
    if not removed:
        return text
    lines = text.splitlines(keepends=True)
    if lines and not lines[-1].endswith("\n"):
        lines[-1] += "\n"
    by_section: dict[str, list[str]] = {}
    headers: dict[str, str] = {}
    for section, line in removed:
        if _SECTION.match(line):
            headers[section] = line
            by_section.setdefault(section, [])
        else:
            by_section.setdefault(section, []).append(
                line if line.endswith("\n") else line + "\n")
    for section, extra in by_section.items():
        # last non-blank line of that section, if the section exists
        start = None
        for i, line in enumerate(lines):
            m = _SECTION.match(line)
            if m and m.group("name").strip() == section:
                start = i
                break
        if start is None:
            if lines and lines[-1].strip():
                lines.append("\n")
            lines.append(headers.get(section, f"[{section}]\n"))
            lines.extend(extra)
            continue
        end = start + 1
        last = start
        while end < len(lines) and not _SECTION.match(lines[end]):
            if lines[end].strip():
                last = end
            end += 1
        lines[last + 1:last + 1] = extra
    return "".join(lines)


def secret_lines(text: str) -> list[str]:
    """Non-comment lines in `text` that look like they carry a credential."""
    hits = []
    for line in text.splitlines():
        s = line.strip()
        if not s or s.startswith(("#", ";")):
            continue
        key, eq, _ = s.partition("=")
        key = key.strip()
        if eq and key.endswith("-flags"):
            continue
        # key=value: judge the key, so `key-mgmt=wpa-psk` (a method, not a
        # secret) passes. A section header naming secrets does not.
        if _SECRET_WORD.search(key if eq else s):
            hits.append(line)
    return hits


def scan_tree(root: Path | None = None) -> list[str]:
    """Every credential-looking line under setup/host, manifest excepted.

    The manifest names the patterns it strips, so it is the one file that is
    allowed to say `psk`.
    """
    root = root or HOST_DIR
    out = []
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.resolve() == MANIFEST.resolve():
            continue
        try:
            text = path.read_text(errors="replace")
        except OSError:
            continue
        for hit in secret_lines(text):
            out.append(f"{path.relative_to(root)}: {hit.strip()}")
    return out


# --------------------------------------------------------------------------
# reading a host: this one, or the orin over ssh
# --------------------------------------------------------------------------
@dataclass
class Live:
    path: str
    exists: bool
    text: str | None = None          # None when it exists but could not be read
    mode: str = ""
    owner: str = ""


class LocalReader:
    name = "this host"

    def read(self, paths: list[str]) -> dict[str, Live]:
        out = {}
        for p in paths:
            try:
                st = os.stat(p)
            except FileNotFoundError:
                out[p] = Live(p, False)
                continue
            except PermissionError:
                st = None
            mode = owner = ""
            if st is not None:
                import grp
                import pwd
                mode = f"{st.st_mode & 0o7777:o}"
                try:
                    owner = f"{pwd.getpwuid(st.st_uid).pw_name}:{grp.getgrgid(st.st_gid).gr_name}"
                except KeyError:
                    owner = f"{st.st_uid}:{st.st_gid}"
            text = None
            try:
                text = Path(p).read_text()
            except PermissionError:
                proc = subprocess.run(["sudo", "-n", "cat", "--", p],
                                      capture_output=True, text=True)
                if proc.returncode == 0:
                    text = proc.stdout
            out[p] = Live(p, True, text, mode, owner)
        return out

    def unit_states(self, units: list[str]) -> dict[str, str]:
        return {u: _unit_state(subprocess.run, u) for u in units}


def _unit_state(run, unit: str) -> str:
    en = run(["systemctl", "is-enabled", unit], capture_output=True, text=True)
    ac = run(["systemctl", "is-active", unit], capture_output=True, text=True)
    enabled = (en.stdout.strip() or "not-found")
    return f"{enabled}/{ac.stdout.strip() or 'unknown'}"


# Runs on the orin with `bash -s -- PATH...`. Read only: stat, cat, and
# `sudo -n cat` for root-only files, which fails instead of prompting.
_REMOTE_READ = r"""
set -o pipefail
for p in "$@"; do
  case "$p" in
    unit:*)
      u="${p#unit:}"
      e=$(systemctl is-enabled "$u" 2>/dev/null); e=${e:-not-found}
      a=$(systemctl is-active "$u" 2>/dev/null); a=${a:-unknown}
      printf '@@U\t%s\t%s/%s\n' "$u" "$e" "$a"; continue ;;
  esac
  if [ ! -e "$p" ]; then printf '@@\t%s\tmissing\n' "$p"; continue; fi
  st=$(stat -c '%a %U:%G' -- "$p")
  if [ -r "$p" ]; then data=$(base64 -w0 < "$p")
  elif data=$(sudo -n cat -- "$p" 2>/dev/null | base64 -w0); then :
  else printf '@@\t%s\tunreadable\t%s\n' "$p" "$st"; continue; fi
  printf '@@\t%s\tok\t%s\t%s\n' "$p" "$st" "$data"
done
"""


class OrinReader:
    name = "orin"

    def __init__(self) -> None:
        self._units: dict[str, str] = {}

    def _call(self, args: list[str]) -> str:
        proc = subprocess.run([str(ON_ORIN), "bash", "-s", "--", *args],
                              input=_REMOTE_READ, capture_output=True, text=True,
                              timeout=60)
        if proc.returncode != 0:
            raise SystemExit(f"could not read the orin (exit {proc.returncode}):\n"
                             f"{proc.stderr.strip()}")
        return proc.stdout

    def read(self, paths: list[str]) -> dict[str, Live]:
        out = {p: Live(p, False) for p in paths}
        if not paths:
            return out
        for line in self._call(paths).splitlines():
            if not line.startswith("@@\t"):
                continue
            parts = line.split("\t")
            p, status = parts[1], parts[2]
            if status == "missing":
                out[p] = Live(p, False)
                continue
            mode, owner = parts[3].split(" ", 1)
            text = None
            if status == "ok":
                text = base64.b64decode(parts[4] if len(parts) > 4 else "").decode()
            out[p] = Live(p, True, text, mode, owner)
        return out

    def unit_states(self, units: list[str]) -> dict[str, str]:
        out = {u: "unknown" for u in units}
        if not units:
            return out
        for line in self._call([f"unit:{u}" for u in units]).splitlines():
            if line.startswith("@@U\t"):
                _, u, state = line.split("\t")
                out[u] = state
        return out


# --------------------------------------------------------------------------
# comparing
# --------------------------------------------------------------------------
IDENTICAL, DIFFERS, MISSING_HOST, MISSING_REPO, UNREADABLE = (
    "identical", "differs", "missing on host", "missing in repo", "could not read")


@dataclass
class Result:
    target: str
    status: str
    detail: list[str] = field(default_factory=list)
    diff: str = ""
    source: str = ""                  # which live path was read (legacy names)
    live_text: str | None = None      # stripped
    removed: list[tuple[str, str]] = field(default_factory=list)


def _norm_mode(mode: str) -> str:
    return f"{int(mode, 8):o}" if mode else ""


def _pick_live(entry: FileEntry, live: dict[str, Live]) -> Live:
    first = live.get(entry.target) or Live(entry.target, False)
    if first.exists:
        return first
    for alt in entry.legacy:
        if live.get(alt) and live[alt].exists:
            return live[alt]
    return first


def compare_file(entry: FileEntry, live: dict[str, Live], profile: StripProfile | None) -> Result:
    cur = _pick_live(entry, live)
    repo_exists = entry.repo_path.is_file()
    res = Result(entry.target, IDENTICAL, source=cur.path)
    if cur.path != entry.target:
        res.detail.append(f"found under its old name {cur.path!r}")
    if not cur.exists:
        res.status = MISSING_HOST if repo_exists else MISSING_REPO
        if not repo_exists:
            res.detail.append("and not on the host either")
        return res
    if cur.text is None:
        res.status = UNREADABLE
        res.detail.append(f"mode {cur.mode} {cur.owner}; root-only and sudo -n "
                          f"is not available: capture by hand")
        return res
    stripped, removed = strip_text(cur.text, profile)
    res.live_text, res.removed = stripped, removed
    secrets = [ln for _, ln in removed
               if not (profile and any(fnmatch.fnmatchcase(ln.partition("=")[0].strip(), v)
                                       for v in profile.volatile))]
    if secrets:
        res.detail.append(f"{len(secrets)} secret line(s) on the host, not tracked")
    if not repo_exists:
        res.status = MISSING_REPO
        return res
    want = entry.repo_path.read_text()
    if stripped != want:
        res.status = DIFFERS
        res.diff = "".join(difflib.unified_diff(
            want.splitlines(keepends=True), stripped.splitlines(keepends=True),
            f"repo:{entry.repo}", f"host:{cur.path}"))
    if cur.mode and _norm_mode(cur.mode) != _norm_mode(entry.mode):
        res.status = DIFFERS
        res.detail.append(f"mode {cur.mode}, manifest says {entry.mode}")
    if cur.owner and cur.owner != entry.owner:
        res.status = DIFFERS
        res.detail.append(f"owner {cur.owner}, manifest says {entry.owner}")
    return res


def _squash(s: str) -> str:
    return " ".join(s.split())


def compare_line(entry: LineEntry, cur: Live) -> Result:
    res = Result(entry.target + "  [line]", IDENTICAL)
    if not cur.exists or cur.text is None:
        res.status = MISSING_HOST if not cur.exists else UNREADABLE
        return res
    pattern = re.compile(entry.match)
    found = [ln for ln in cur.text.splitlines() if pattern.search(ln)]
    if not found:
        res.status = MISSING_HOST
        res.detail.append(f"no line matching {entry.match!r}")
    elif _squash(found[0]) != _squash(entry.line):
        res.status = DIFFERS
        res.diff = f"-{entry.line}\n+{found[0]}\n"
    if len(found) > 1:
        res.status = DIFFERS
        res.detail.append(f"{len(found)} lines match {entry.match!r}")
    return res


def ensure_line(text: str, entry: LineEntry) -> str:
    """`text` with exactly one line matching `entry.match`, equal to `entry.line`.

    An existing matching line is replaced in place (keeping its position in
    fstab, which matters for mount order); none is appended. Further matching
    lines are removed: two fstab lines for one mount point is the bug.
    """
    pattern = re.compile(entry.match)
    out, placed = [], False
    for line in text.splitlines():
        if pattern.search(line):
            if not placed:
                out.append(entry.line if _squash(line) != _squash(entry.line) else line)
                placed = True
            continue
        out.append(line)
    if not placed:
        out.append(entry.line)
    return "\n".join(out) + "\n"


# --------------------------------------------------------------------------
# commands
# --------------------------------------------------------------------------
def _role(args) -> str:
    role = args.role or model.read_host_role()
    if args.orin:
        role = "orin"
    if role not in model.ROLES:
        raise SystemExit(f"no role: config/host says {role!r}. "
                         f"Pass --role {'|'.join(model.ROLES)}.")
    return role


def _reader(args):
    return OrinReader() if getattr(args, "orin", False) else LocalReader()


def _paths(m: Manifest) -> list[str]:
    paths: list[str] = []
    for e in m.files:
        paths += [e.target, *e.legacy]
    paths += sorted({e.target for e in m.lines})
    paths += [e.target for e in m.generated]
    paths += [t for a in m.absent for t in a.targets]
    return list(dict.fromkeys(paths))


def cmd_diff(args) -> int:
    role = _role(args)
    m = load_manifest().for_role(role)
    reader = _reader(args)
    live = reader.read(_paths(m))
    drift = 0
    print(f"host config, role {role}, read from {reader.name}\n")
    for e in m.files:
        res = compare_file(e, live, m.strip_profiles.get(e.strip or ""))
        tag = "" if e.restore else f"  (installed by step {e.step})"
        print(f"  {res.status:<16} {e.target}{tag}")
        for d in res.detail:
            print(f"  {'':<16}   {d}")
        if res.diff and not args.quiet:
            print("".join("      " + ln for ln in res.diff.splitlines(keepends=True)))
        drift += res.status != IDENTICAL
    for e in m.lines:
        res = compare_line(e, live.get(e.target) or Live(e.target, False))
        print(f"  {res.status:<16} {res.target}")
        for d in res.detail:
            print(f"  {'':<16}   {d}")
        if res.diff and not args.quiet:
            print("".join("      " + ln for ln in res.diff.splitlines(keepends=True)))
        drift += res.status != IDENTICAL
    for g in m.generated:
        here = "present" if live.get(g.target) and live[g.target].exists else "MISSING"
        print(f"  {'generated':<16} {g.target}  ({here}; source is {g.by})")
        drift += here != "present"
    for a in m.absent:
        for t in a.targets:
            gone = not (live.get(t) and live[t].exists)
            print(f"  {'absent' if gone else 'PRESENT':<16} {t}  (retired"
                  + (f": {a.why}" if a.why and not gone else "") + ")")
            drift += not gone
    units = [u for d in m.disabled for u in d.units]
    if units:
        states = reader.unit_states(units)
        for u in units:
            state = states[u]
            ok = state.startswith(("disabled", "not-found", "masked")) and "/active" not in state
            print(f"  {'disabled' if ok else 'NOT DISABLED':<16} unit {u} ({state})")
            drift += not ok
    print(f"\n{drift} item(s) differ" if drift else "\nall identical")
    return 1 if (drift and args.exit_code) else 0


def cmd_capture(args) -> int:
    role = _role(args)
    full = load_manifest()
    if args.targets:
        full.check_allowed(args.targets)
    m = full.for_role(role, targets=args.targets or None)
    if args.targets:
        wanted = set(args.targets)
        m.files = [e for e in full.for_role(role).files
                   if e.target in wanted or wanted & set(e.legacy)]
    live = _reader(args).read(_paths(m))
    changed = 0
    for e in m.files:
        res = compare_file(e, live, m.strip_profiles.get(e.strip or ""))
        if res.status in (IDENTICAL, MISSING_HOST, UNREADABLE) or res.live_text is None:
            note = {MISSING_HOST: "missing on host, nothing to capture",
                    UNREADABLE: "could not read, capture by hand"}.get(res.status, "unchanged")
            print(f"  {note:<36} {e.target}")
            continue
        if res.live_text == (e.repo_path.read_text() if e.repo_path.is_file() else None):
            print(f"  {'unchanged (mode/owner differ only)':<36} {e.target}")
            continue
        e.repo_path.parent.mkdir(parents=True, exist_ok=True)
        e.repo_path.write_text(res.live_text)
        changed += 1
        print(f"  {'captured':<36} {e.target} -> setup/host/{e.repo}"
              + (f" (from {res.source!r})" if res.source != e.target else ""))
        if res.removed:
            print(f"  {'':<36}   stripped {len(res.removed)} line(s)")
        if res.diff and not args.quiet:
            print("".join("      " + ln for ln in res.diff.splitlines(keepends=True)))
    for e in m.lines:
        res = compare_line(e, live.get(e.target) or Live(e.target, False))
        if res.status != IDENTICAL:
            print(f"  {res.status:<36} {e.target} [line]: edit `lines:` in "
                  f"manifest.yaml by hand\n{res.diff}")
    hits = scan_tree()
    if hits:
        print("\nSECRETS IN setup/host -- do not commit:", file=sys.stderr)
        for h in hits:
            print("  " + h, file=sys.stderr)
        return 2
    print(f"\n{changed} file(s) captured; secret scan clean")
    return 0


class Installer:
    """Writes files with sudo unless already root. Reload actions are queued."""

    def __init__(self, dry_run: bool = False, log=print) -> None:
        self.dry_run = dry_run
        self.log = log
        self.sudo = [] if os.geteuid() == 0 else ["sudo"]
        self.actions: list[str] = []

    def run(self, argv: list[str], check: bool = True) -> int:
        if self.dry_run:
            self.log("    would run: " + " ".join(shlex.quote(a) for a in argv))
            return 0
        rc = subprocess.run(self.sudo + argv).returncode
        if rc and check:
            raise SystemExit(f"failed ({rc}): {' '.join(argv)}")
        return rc

    def put(self, target: str, text: str, mode: str, owner: str) -> None:
        user, group = owner.split(":", 1)
        with tempfile.NamedTemporaryFile("w", delete=False) as tmp:
            tmp.write(text)
        try:
            self.run(["install", "-D", "-m", mode, "-o", user, "-g", group,
                      tmp.name, target])
        finally:
            os.unlink(tmp.name)

    def queue(self, actions) -> None:
        for a in actions:
            if a != "none" and a not in self.actions:
                self.actions.append(a)

    def reload(self) -> None:
        # hostname before the restart:<unit> actions, so avahi-daemon restarts
        # with the new name and publishes <name>.local.
        order = ["systemd-daemon-reload", "networkd-reload", "nmcli-reload",
                 "udev-reload", "sysctl", "hostname"]
        ranked = sorted(self.actions, key=lambda a: (order.index(a) if a in order
                                                    else len(order), a))
        for a in ranked:
            self.log(f"  reload: {a}")
            if a == "systemd-daemon-reload":
                self.run(["systemctl", "daemon-reload"])
            elif a == "networkd-reload":
                self.run(["networkctl", "reload"], check=False)
            elif a == "nmcli-reload":
                self.run(["nmcli", "connection", "reload"])
            elif a == "udev-reload":
                self.run(["udevadm", "control", "--reload-rules"])
                self.run(["udevadm", "trigger"])
            elif a == "sysctl":
                self.run(["sysctl", "--system"], check=False)
            elif a == "hostname":
                # /etc/hostname was just installed; make it the running name too.
                self.run(["sh", "-c", 'hostnamectl set-hostname "$(cat /etc/hostname)"'])
            elif a.startswith("enable:"):
                self.run(["systemctl", "enable", a.split(":", 1)[1]])
            elif a.startswith("restart:"):
                self.run(["systemctl", "restart", a.split(":", 1)[1]])


def install(m: Manifest, inst: Installer, reader=None, reload: bool = True,
            owned_by: str | None = None) -> int:
    """Make the host match `m`. Returns the number of things changed.

    Entries with `restore: false` are skipped unless `owned_by` names their
    step: that step calls this for its own files once it has done the work
    they depend on.
    """
    reader = reader or LocalReader()
    log = inst.log
    live = reader.read(_paths(m))
    changed = 0
    for e in m.files:
        if not e.restore and e.step != owned_by:
            continue
        if not e.repo_path.is_file():
            log(f"  skip       {e.target}: not captured yet (setup/host/{e.repo} missing)")
            continue
        profile = m.strip_profiles.get(e.strip or "")
        res = compare_file(e, live, profile)
        if res.status == UNREADABLE:
            raise SystemExit(f"cannot read {res.source} to compare; run with sudo")
        want = e.repo_path.read_text()
        if res.status == IDENTICAL and res.source == e.target:
            log(f"  unchanged  {e.target}")
            continue
        content_same = res.live_text == want
        if content_same and res.source == e.target:
            user, group = e.owner.split(":", 1)
            log(f"  fix mode   {e.target} -> {e.mode} {e.owner}")
            inst.run(["chmod", e.mode, e.target])
            inst.run(["chown", f"{user}:{group}", e.target])
        else:
            # Keep this host's own secrets and timestamps in the file we rewrite.
            text = merge_removed(want, res.removed) if res.removed else want
            log(f"  install    {e.target}")
            inst.put(e.target, text, e.mode, e.owner)
            if res.source != e.target:
                log(f"  remove     {res.source} (old name of {e.target})")
                inst.run(["rm", "-f", "--", res.source])
        changed += 1
        inst.queue(e.reload)
    for e in m.lines:
        cur = live.get(e.target) or Live(e.target, False)
        res = compare_line(e, cur)
        if res.status == IDENTICAL:
            log(f"  unchanged  {e.target} [{e.line.split()[1] if len(e.line.split()) > 1 else 'line'}]")
            continue
        if cur.exists and cur.text is None:
            raise SystemExit(f"cannot read {e.target}")
        text = ensure_line(cur.text or "", e)
        log(f"  ensure     {e.target}: {e.line}")
        if cur.exists:
            inst.run(["cp", "-a", e.target, e.target + ".golfcart-bak"])
        inst.put(e.target, text, _norm_mode(cur.mode) if cur.mode else "644",
                 cur.owner or "root:root")
        changed += 1
        inst.queue(e.reload)
    for a in m.absent:
        for t in a.targets:
            if not (live.get(t) and live[t].exists):
                log(f"  unchanged  {t} (absent)")
                continue
            log(f"  remove     {t} (retired{': ' + a.why if a.why else ''})")
            inst.run(["rm", "-f", "--", t])
            changed += 1
            inst.queue(a.reload)
    for d in m.disabled:
        for u in d.units:
            state = reader.unit_states([u])[u]
            if state.startswith("not-found"):
                continue
            if state.startswith(("disabled", "masked")) and "/active" not in state \
                    and "/failed" not in state:
                log(f"  unchanged  unit {u} ({state})")
                continue
            log(f"  disable    unit {u} ({state}){': ' + d.why if d.why else ''}")
            inst.run(["systemctl", "disable", "--now", u], check=False)
            inst.run(["systemctl", "reset-failed", u], check=False)
            changed += 1
    if reload:
        inst.reload()
    return changed


def cmd_install(args) -> int:
    role = args.role or model.read_host_role()
    if role not in model.ROLES:
        if not args.step:
            raise SystemExit(f"no role: config/host says {role!r}. "
                             f"Pass --role {'|'.join(model.ROLES)}.")
        role = None
    full = load_manifest()
    if args.target:
        full.check_allowed(args.target)
    m = full.for_role(role, step=args.step, targets=args.target or None)
    if not (m.files or m.lines or m.disabled or m.absent):
        print(f"  nothing for role {role}"
              + (f", step {args.step}" if args.step else ""))
        return 0
    n = install(m, Installer(dry_run=args.dry_run), reload=not args.no_reload,
                owned_by=args.step)
    print(f"  {n} change(s)")
    return 0


def cmd_scan(args) -> int:
    load_manifest()                     # validates it
    hits = scan_tree()
    if hits:
        print("SECRETS IN setup/host:", file=sys.stderr)
        for h in hits:
            print("  " + h, file=sys.stderr)
        return 1
    print("manifest valid; no secrets under setup/host")
    return 0


def cmd_list(args) -> int:
    m = load_manifest()
    for e in m.files:
        flags = [] if e.restore else [f"by {e.step}"]
        if e.step != "host-config" and e.restore:
            flags.append(f"step {e.step}")
        print(f"{','.join(e.roles):<13} {e.mode} {e.owner:<15} {e.target}"
              + (f"  [{'; '.join(flags)}]" if flags else ""))
    for e in m.lines:
        print(f"{','.join(e.roles):<13} line           {e.target}: {e.line}")
    for g in m.generated:
        print(f"{','.join(g.roles):<13} generated      {g.target} (by {g.by})")
    for d in m.disabled:
        print(f"{','.join(d.roles):<13} disabled       {' '.join(d.units)}")
    for a in m.absent:
        print(f"{','.join(a.roles):<13} absent         {' '.join(a.targets)}")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="hostcfg", description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)

    def common(p, remote=True):
        p.add_argument("--role", choices=model.ROLES,
                       help="default: config/host")
        if remote:
            p.add_argument("--orin", action="store_true",
                           help="read the orin's live files over ssh (read only)")

    p = sub.add_parser("diff", help="repo vs live, read only")
    common(p)
    p.add_argument("--quiet", "-q", action="store_true", help="no diff bodies")
    p.add_argument("--exit-code", action="store_true", help="exit 1 on any drift")
    p.set_defaults(fn=cmd_diff)

    p = sub.add_parser("capture", help="live -> repo for manifest entries")
    common(p)
    p.add_argument("--quiet", "-q", action="store_true")
    p.add_argument("targets", nargs="*", metavar="TARGET",
                   help="limit to these target paths (must be in the manifest)")
    p.set_defaults(fn=cmd_capture)

    p = sub.add_parser("install", help="repo -> live (the host-config step)")
    common(p, remote=False)
    p.add_argument("--step", help="only entries owned by this setup step")
    p.add_argument("--target", action="append", help="only this target (repeatable)")
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--no-reload", action="store_true")
    p.set_defaults(fn=cmd_install, orin=False)

    p = sub.add_parser("scan", help="validate the manifest, grep the tree for secrets")
    p.set_defaults(fn=cmd_scan)
    p = sub.add_parser("list", help="every tracked entry")
    p.set_defaults(fn=cmd_list)

    args = ap.parse_args(argv)
    try:
        return args.fn(args)
    except (ManifestError, NotAllowed) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
