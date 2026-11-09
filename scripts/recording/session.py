#!/usr/bin/env python3
"""Recording sessions: ROS bags and raw packets (CAN, Ethernet) under one ID.

    session.py new-id [NAME]                 print a fresh session id
    session.py scopes                        list config/recording/scopes.yaml
    session.py is-scope WORD                 exit 0 if WORD names a scope
    session.py plan [--scope S] [--role R]   what this host would record
    session.py preflight [--scope S]         free space under recordings/; exit 3 = refuse
    session.py write-args --id ID --scope S  rewrite .golfcart-record.args (the unit's input)
    session.py run [--unit] [--args-file F | --id ID] [--scope S] [--name N]
                   [--role R] [--can IFACE ...]
                                             the session runner (unit or foreground)
    session.py show [ID]                     one session on this host, from its session.yaml
    session.py status                        sessions recording on this host, sizes and rates
    session.py list                          sessions here, with which halves are present
    session.py active                        ids with a live runner here; exit 1 if none
    session.py newest-id                     newest session id here (for collect)
    session.py latest bag|can                newest finalized bag dir / non-empty CAN log
    session.py resolve-bag ARG               session id or path -> bag directory

Layout, on both hosts:  recordings/<id>/<role>/{bag/, <can>.log, <eth>.pcapng,
session.yaml, log/}. The id is ``YYYYmmdd_HHMMSS[_NAME]`` and is generated once,
on the master, so both halves of a two-host session carry the same one.

The runner starts every recorder of the scope as a child in its own process
group, and on SIGINT/SIGTERM/SIGHUP stops them: one SIGINT each (ros2 bag
finalizes metadata.yaml on it; candump and tshark close their files), then
SIGTERM and SIGKILL only after a per-kind grace. Under systemd (``--unit``) the
first SIGINT is NOT forwarded: golfcart-record.service has KillMode=control-group
and KillSignal=SIGINT, so systemd has already delivered it to every child, and a
second SIGINT during bag finalization is exactly what must not happen.

ROS environment: the caller sources scripts/env.sh (record_unit_exec.sh does,
and so do the just recipes); ros2 is inherited from that.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import shutil
import signal
import socket
import subprocess
import sys
import time
from pathlib import Path

import yaml

REPO = Path(__file__).resolve().parents[2]
SCOPES_FILE = REPO / "config" / "recording" / "scopes.yaml"
TOPICS_SH = REPO / "scripts" / "recording" / "topics.sh"
ENSURE_SH = REPO / "scripts" / "rmw" / "ensure.sh"
ARGS_FILE = REPO / ".golfcart-record.args"
LAUNCH_ARGS_FILE = REPO / ".golfcart-launch.args"
ROLES = ("master", "orin")

ID_RE = re.compile(r"^\d{8}_\d{6}(_[A-Za-z0-9-]+)?$")
NAME_RE = re.compile(r"^[A-Za-z0-9-]+$")

# Seconds a recorder gets after SIGINT before SIGTERM, then SIGKILL 10 s later.
# The bag's is under golfcart-record.service's TimeoutStopSec=300 so the runner,
# not systemd, decides; closing a multi-GB bag on the SSD can take minutes.
GRACE = {"ros": 270, "can": 10, "pcap": 15}
START_CHECK_S = 2.0


def recordings_dir() -> Path:
    return Path(os.environ.get("GOLFCART_RECORDINGS_DIR", REPO / "recordings"))


def utcnow() -> str:
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def warn(msg: str) -> None:
    print(f"session: WARNING: {msg}", file=sys.stderr, flush=True)


def info(msg: str) -> None:
    print(f"session: {msg}", flush=True)


# ── ids, roles, scopes ───────────────────────────────────────────────────────
def new_id(name: str = "", now: dt.datetime | None = None) -> str:
    if name and not NAME_RE.match(name):
        raise ValueError(f"session name '{name}' may use only letters, digits and '-'")
    stamp = (now or dt.datetime.now()).strftime("%Y%m%d_%H%M%S")
    return f"{stamp}_{name}" if name else stamp


def valid_id(sid: str) -> bool:
    return bool(ID_RE.match(sid))


def resolve_role(explicit: str | None = None) -> str:
    if explicit:
        return explicit
    env = os.environ.get("GOLFCART_HOST", "").strip()
    if env in ROLES:
        return env
    try:
        word = (REPO / "config" / "host").read_text().strip()
    except OSError:
        word = ""
    return word if word in ROLES else "local"


def load_scopes(path: Path = SCOPES_FILE) -> dict:
    data = yaml.safe_load(path.read_text()) or {}
    scopes = data.get("scopes") or {}
    if not scopes:
        raise ValueError(f"{path}: no scopes")
    default = data.get("default")
    if default not in scopes:
        raise ValueError(f"{path}: default '{default}' is not a scope")
    for name, body in scopes.items():
        for role in ROLES:
            entry = (body or {}).get(role) or {}
            ros = entry.get("ros", "none")
            if ros not in ("all", "list", "none"):
                raise ValueError(f"{path}: scope {name}.{role}.ros is '{ros}', "
                                 "want all | list | none")
            for p in entry.get("pcap") or []:
                if not isinstance(p, dict) or "iface" not in p:
                    raise ValueError(f"{path}: scope {name}.{role}.pcap entries need iface:")
    return data


def scope_entry(data: dict, scope: str, role: str) -> dict:
    """The scope's recorders for role, normalised. Unknown role: master ∪ orin."""
    if scope not in data["scopes"]:
        raise ValueError(f"unknown scope '{scope}'; scopes: {', '.join(data['scopes'])}")
    body = data["scopes"][scope] or {}
    roles = [role] if role in ROLES else list(ROLES)
    ros, can, pcap = "none", [], []
    for r in roles:
        e = body.get(r) or {}
        rr = e.get("ros", "none")
        if rr == "all" or (rr == "list" and ros == "none"):
            ros = rr
        for c in e.get("can") or []:
            if c not in can:
                can.append(c)
        for p in e.get("pcap") or []:
            if p["iface"] not in [q["iface"] for q in pcap]:
                pcap.append(dict(p))
    topic_files = [REPO / "config" / "recording" / f"{r}_topics.txt" for r in roles]
    return {"ros": ros, "can": can, "pcap": pcap, "topic_files": topic_files,
            "disk": body.get("disk", "warn"), "description": body.get("description", "")}


# ── host probes ──────────────────────────────────────────────────────────────
def iface_state(name: str, sys_net: Path = Path("/sys/class/net")) -> str:
    """'up', 'down' or 'missing'. operstate 'unknown' (lo, some CAN) counts as up."""
    d = sys_net / name
    if not d.exists():
        return "missing"
    try:
        op = (d / "operstate").read_text().strip()
    except OSError:
        op = "unknown"
    if op == "up":
        return "up"
    if op == "unknown":
        try:
            return "up" if int((d / "flags").read_text().strip(), 16) & 0x1 else "down"
        except (OSError, ValueError):
            return "up"
    return "down"


def rx_packets(name: str) -> int | None:
    try:
        return int(Path(f"/sys/class/net/{name}/statistics/rx_packets").read_text())
    except (OSError, ValueError):
        return None


def capture_ready() -> str | None:
    """None when tshark can capture without root, else why not."""
    if not shutil.which("tshark"):
        return "tshark not installed (sudo apt install tshark)"
    dumpcap = shutil.which("dumpcap") or "/usr/bin/dumpcap"
    if os.geteuid() == 0:
        return None
    if not os.access(dumpcap, os.X_OK):
        return (f"{dumpcap} not executable by {os.environ.get('USER', 'this user')}: "
                "not in group wireshark, or not logged in again since being added")
    return None


def free_bytes(path: Path) -> int:
    p = path
    while not p.exists():
        p = p.parent
    st = os.statvfs(p)
    return st.f_bavail * st.f_frsize


def gb(n: int) -> str:
    return f"{n / 1e9:.1f} GB"


def human(n: int) -> str:
    for unit in ("B", "kB", "MB", "GB", "TB"):
        if abs(n) < 1000 or unit == "TB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1000
    return str(n)


def run_text(cmd: list[str], timeout: float = 5) -> tuple[int, str]:
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return r.returncode, r.stdout
    except (OSError, subprocess.SubprocessError) as e:
        return 127, str(e)


def chrony_line() -> str:
    rc, out = run_text(["chronyc", "tracking"])
    if rc != 0:
        return "chronyc unavailable"
    for line in out.splitlines():
        if line.startswith("System time"):
            return line.split(":", 1)[1].strip()
    return "no 'System time' line"


def git_info() -> dict:
    rc, head = run_text(["git", "-C", str(REPO), "rev-parse", "HEAD"])
    _, branch = run_text(["git", "-C", str(REPO), "rev-parse", "--abbrev-ref", "HEAD"])
    rc2, dirty = run_text(["git", "-C", str(REPO), "status", "--porcelain",
                           "--untracked-files=no"], timeout=20)
    return {"commit": head.strip() if rc == 0 else None,
            "branch": branch.strip() or None,
            "dirty": bool(dirty.strip()) if rc2 == 0 else None}


def launch_args() -> list[str] | None:
    try:
        return [ln.strip() for ln in LAUNCH_ARGS_FILE.read_text().splitlines() if ln.strip()]
    except OSError:
        return None


def read_topics(files: list[Path]) -> list[str]:
    r = subprocess.run(
        ["bash", "-c", 'source "$1"; shift; golfcart_recording_topics "$@"', "_",
         str(TOPICS_SH), *map(str, files)],
        capture_output=True, text=True, check=False)
    if r.returncode != 0:
        raise ValueError(r.stderr.strip() or "topic list unreadable")
    return [t for t in r.stdout.splitlines() if t]


def path_size(p: Path) -> int:
    if p.is_file():
        return p.stat().st_size
    if p.is_dir():
        return sum(f.stat().st_size for f in p.rglob("*") if f.is_file())
    return 0


def bag_summary(bag: Path) -> dict:
    meta = bag / "metadata.yaml"
    out = {"finalized": meta.is_file() and meta.stat().st_size > 0}
    if out["finalized"]:
        try:
            m = yaml.safe_load(meta.read_text())["rosbag2_bagfile_information"]
            topics = m.get("topics_with_message_count") or []
            out.update(topic_count=len(topics),
                       message_count=sum(t["message_count"] for t in topics),
                       storage=m.get("storage_identifier"))
        except Exception as e:  # noqa: BLE001 - a damaged bag is still a result
            out["error"] = str(e)
    return out


# ── the plan: which recorders, and which are skipped ────────────────────────
def plan(data: dict, scope: str, role: str, out: Path,
         can_only: list[str] | None = None) -> list[dict]:
    e = scope_entry(data, scope, role)
    recs: list[dict] = []
    if e["ros"] != "none":
        rec = {"name": "ros", "kind": "ros", "mode": e["ros"], "file": "bag"}
        cmd = ["ros2", "bag", "record", "-o", str(out / "bag")]
        if e["ros"] == "all":
            cmd += ["-a", "--include-hidden-topics"]
        else:
            try:
                topics = read_topics(e["topic_files"])
            except ValueError as err:
                topics, rec["reason"] = [], str(err)
            if not topics and "reason" not in rec:
                rec["reason"] = "topic list is empty"
            rec["topic_list"] = [str(f.relative_to(REPO)) for f in e["topic_files"]]
            rec["topics_requested"] = len(topics)
            cmd += topics
        rec["cmd"] = cmd
        rec["status"] = "skipped" if "reason" in rec else "planned"
        recs.append(rec)
    cans = can_only if can_only else e["can"]
    for iface in cans:
        rec = {"name": iface, "kind": "can", "iface": iface, "file": f"{iface}.log",
               "cmd": ["candump", "-L", iface]}
        st = iface_state(iface)
        if not shutil.which("candump"):
            rec.update(status="skipped", reason="candump not installed (can-utils)")
        elif st != "up":
            rec.update(status="skipped", reason=f"interface {st}")
        else:
            rec["status"] = "planned"
        recs.append(rec)
    why_not = capture_ready() if e["pcap"] else None
    for p in e["pcap"]:
        iface = p["iface"]
        rec = {"name": iface, "kind": "pcap", "iface": iface, "file": f"{iface}.pcapng",
               "cmd": ["tshark", "-i", iface, "-w", str(out / f"{iface}.pcapng"), "-q"]}
        if p.get("filter"):
            rec["filter"] = p["filter"]
            rec["cmd"] += ["-f", p["filter"]]
        if p.get("snaplen"):
            rec["snaplen"] = int(p["snaplen"])
            rec["cmd"] += ["-s", str(int(p["snaplen"]))]
        st = iface_state(iface)
        if why_not:
            rec.update(status="skipped", reason=why_not)
        elif st != "up":
            rec.update(status="skipped", reason=f"interface {st}")
        else:
            rec["status"] = "planned"
        recs.append(rec)
    return recs


# ── session.yaml ─────────────────────────────────────────────────────────────
def write_yaml(path: Path, doc: dict) -> None:
    tmp = path.with_suffix(".yaml.tmp")
    tmp.write_text(yaml.safe_dump(doc, sort_keys=False, default_flow_style=False))
    os.replace(tmp, path)


def public(rec: dict) -> dict:
    return {k: v for k, v in rec.items() if not k.startswith("_")}


# ── the runner ───────────────────────────────────────────────────────────────
class Runner:
    def __init__(self, sid: str, scope: str, role: str, unit: bool,
                 can_only: list[str] | None = None):
        self.sid, self.scope, self.role, self.unit = sid, scope, role, unit
        self.dir = recordings_dir() / sid / role
        self.can_only = can_only
        self.stop_signal: int | None = None
        self.doc: dict = {}

    def _on_signal(self, signum, _frame):
        if self.stop_signal is None:
            self.stop_signal = signum

    def save(self) -> None:
        self.doc["recorders"] = [public(r) for r in self.recs]
        write_yaml(self.dir / "session.yaml", self.doc)

    def run(self) -> int:
        for s in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(s, self._on_signal)
        data = load_scopes()
        if self.dir.exists() and any(self.dir.iterdir()):
            print(f"session: {self.dir} already exists and is not empty", file=sys.stderr)
            return 2
        (self.dir / "log").mkdir(parents=True, exist_ok=True)
        self.recs = plan(data, self.scope, self.role, self.dir, self.can_only)
        free = free_bytes(self.dir)
        self.t_start = time.time()
        self.doc = {
            "id": self.sid, "scope": self.scope, "role": self.role,
            "hostname": socket.gethostname(), "state": "starting",
            "runner": {"pid": os.getpid(), "mode": "unit" if self.unit else "foreground"},
            "start_utc": utcnow(), "stop_utc": None, "duration_s": None,
            "git": git_info(), "launch_args": launch_args(),
            "chrony_system_time": {"start": chrony_line(), "stop": None},
            "disk": {"path": str(self.dir), "free_at_start": gb(free)},
        }
        for r in self.recs:
            if r["status"] == "skipped":
                warn(f"{r['name']}: skipped - {r['reason']}")

        if any(r["kind"] == "ros" and r["status"] == "planned" for r in self.recs):
            # Same gate as before sessions: under zenoh with no router, ros2 bag
            # record starts cleanly and writes zero messages on every topic.
            rc = subprocess.run([str(ENSURE_SH)], check=False).returncode
            if rc != 0:
                for r in self.recs:
                    r.update(status="failed", reason="scripts/rmw/ensure.sh failed; nothing started")
                self.doc.update(state="failed", stop_utc=utcnow())
                self.save()
                print("session: middleware precondition failed; not recording", file=sys.stderr)
                return 1

        can_rx0 = {r["iface"]: rx_packets(r["iface"]) for r in self.recs
                   if r["kind"] == "can" and r["status"] == "planned"}
        for r in self.recs:
            if r["status"] != "planned":
                continue
            err = open(self.dir / "log" / f"{r['name']}.stderr", "wb")
            stdout = open(self.dir / r["file"], "wb") if r["kind"] == "can" else err
            try:
                p = subprocess.Popen(r["cmd"], stdout=stdout, stderr=err,
                                     stdin=subprocess.DEVNULL, start_new_session=True,
                                     cwd=self.dir)
            except OSError as e:
                r.update(status="failed", reason=str(e))
                continue
            r.update(status="running", pid=p.pid, _proc=p, _files=(stdout, err))

        # Early exits: a missing permission or interface fails within a second.
        deadline = time.monotonic() + START_CHECK_S
        while time.monotonic() < deadline and self.stop_signal is None:
            time.sleep(0.1)
        for r in self.recs:
            p = r.get("_proc")
            if p is not None and p.poll() is not None:
                r.update(status="failed", exit_code=p.returncode,
                         reason=self._stderr_tail(r) or f"exited {p.returncode} at start")
                warn(f"{r['name']}: failed at start - {r['reason']}")
        for iface, rx0 in can_rx0.items():
            rx1 = rx_packets(iface)
            rec = next(r for r in self.recs if r["kind"] == "can" and r["iface"] == iface)
            if rx0 is not None and rx1 is not None:
                rec["rx_frames_first_2s"] = rx1 - rx0
                if rx1 == rx0 and rec["status"] == "running":
                    warn(f"{iface}: no frames in {START_CHECK_S:.0f} s - is this bus wired here? "
                         "(the VCU bus is on the orin)")

        running = [r for r in self.recs if r["status"] == "running"]
        if not running:
            self.doc.update(state="failed", stop_utc=utcnow())
            self.save()
            print("session: no recorder is running; session failed", file=sys.stderr)
            return 1
        self.doc["state"] = "recording"
        self.save()
        info(f"{self.sid} ({self.scope}) recording on {self.doc['hostname']} -> {self.dir}")
        for r in self.recs:
            info(f"  {r['kind']:<4} {r['name']:<10} {r['status']}"
                 + (f" ({r['reason']})" if r.get("reason") else ""))

        while self.stop_signal is None:
            alive = False
            for r in running:
                p = r["_proc"]
                if r["status"] == "running" and p.poll() is not None:
                    r.update(status="exited", exit_code=p.returncode,
                             reason=self._stderr_tail(r) or "exited on its own")
                    warn(f"{r['name']}: exited on its own ({p.returncode}) - {r['reason']}")
                    self.save()
                alive = alive or r["status"] == "running"
            if not alive:
                break
            time.sleep(0.5)

        info(f"stopping {self.sid} "
             f"({signal.Signals(self.stop_signal).name if self.stop_signal else 'all recorders exited'})")
        self.doc["state"] = "stopping"
        self.save()
        self._stop(running)
        self.doc["chrony_system_time"]["stop"] = chrony_line()
        self.doc["stop_utc"] = utcnow()
        self.doc["duration_s"] = round(time.time() - self.t_start, 1)
        self.doc["state"] = "stopped" if self.stop_signal else "ended"
        for r in self.recs:
            path = self.dir / r["file"]
            if path.exists():
                r["size_bytes"] = path_size(path)
            if r["kind"] == "ros" and path.exists():
                r["bag"] = bag_summary(path)
            if r["kind"] == "pcap":
                r.update(self._tshark_counts(r))
        self.save()
        for r in self.recs:
            size = human(r["size_bytes"]) if "size_bytes" in r else "-"
            info(f"  {r['name']:<10} {r['status']:<8} {size}"
                 + (f" exit {r['exit_code']}" if "exit_code" in r else ""))
        info(f"session.yaml: {self.dir / 'session.yaml'}")
        return 0

    def _tshark_counts(self, r: dict) -> dict:
        """tshark's own end-of-capture counts: 'N packets captured', '... dropped'."""
        out = {}
        try:
            text = (self.dir / "log" / f"{r['name']}.stderr").read_text(errors="replace")
        except OSError:
            return out
        for key, pat in (("packets_captured", r"(\d+) packets? captured"),
                         ("packets_dropped", r"(\d+) packets? dropped")):
            m = re.findall(pat, text)
            if m:
                out[key] = int(m[-1])
        return out

    def _stderr_tail(self, r: dict) -> str:
        try:
            lines = (self.dir / "log" / f"{r['name']}.stderr").read_text(
                errors="replace").strip().splitlines()
        except OSError:
            return ""
        lines = [ln for ln in lines if ln.strip() and not ln.startswith("Capturing on")]
        return lines[-1].strip()[:300] if lines else ""

    def _stop(self, running: list[dict]) -> None:
        live = [r for r in running if r["status"] == "running"]
        # Under systemd every child already got KillSignal=SIGINT from the
        # control group; a second one could interrupt the bag's finalization.
        forward = not (self.unit and self.stop_signal == signal.SIGINT)
        t0 = time.monotonic()
        for r in live:
            r["_t"] = t0
            if forward:
                self._kill(r, signal.SIGINT)
        stage = {id(r): 0 for r in live}
        while True:
            pending = False
            for r in live:
                p = r["_proc"]
                if p.poll() is not None:
                    if r["status"] == "running":
                        r.update(status="stopped", exit_code=p.returncode)
                    continue
                pending = True
                waited = time.monotonic() - r["_t"]
                g = GRACE[r["kind"]]
                if stage[id(r)] == 0 and waited > g:
                    warn(f"{r['name']}: no exit {g} s after SIGINT, sending SIGTERM")
                    self._kill(r, signal.SIGTERM)
                    stage[id(r)] = 1
                elif stage[id(r)] == 1 and waited > g + 10:
                    warn(f"{r['name']}: still alive, SIGKILL (file may be incomplete)")
                    self._kill(r, signal.SIGKILL)
                    r["killed"] = True
                    stage[id(r)] = 2
            if not pending:
                break
            time.sleep(0.2)
        for r in live:
            for f in set(r.get("_files", ())):
                f.close()

    @staticmethod
    def _kill(r: dict, sig: int) -> None:
        try:
            os.killpg(r["_proc"].pid, sig)
        except ProcessLookupError:
            pass


# ── reading sessions back ────────────────────────────────────────────────────
def session_docs(role: str | None = None) -> list[tuple[str, str, Path, dict]]:
    out = []
    base = recordings_dir()
    if not base.is_dir():
        return out
    for sdir in sorted(p for p in base.iterdir() if p.is_dir() and valid_id(p.name)):
        for half in sorted(p for p in sdir.iterdir() if p.is_dir()):
            if role and half.name != role:
                continue
            try:
                doc = yaml.safe_load((half / "session.yaml").read_text()) or {}
            except (OSError, yaml.YAMLError):
                doc = {}
            out.append((sdir.name, half.name, half, doc))
    return out


def pid_alive(pid) -> bool:
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, TypeError, ValueError):
        return False


def is_live(doc: dict) -> bool:
    return (doc.get("state") in ("starting", "recording", "stopping")
            and doc.get("hostname") == socket.gethostname()
            and pid_alive((doc.get("runner") or {}).get("pid")))


def file_sizes(half: Path, doc: dict) -> dict[str, int]:
    names = [r["file"] for r in doc.get("recorders", []) if r.get("status") != "skipped"]
    return {n: path_size(half / n) for n in names}


def cmd_show(args) -> int:
    role = resolve_role(args.role)
    sid = args.id or read_args_file().get("id") or newest_id(role)
    if not sid:
        print("no session here", file=sys.stderr)
        return 1
    half = recordings_dir() / sid / role
    try:
        doc = yaml.safe_load((half / "session.yaml").read_text())
    except OSError:
        print(f"no {half}/session.yaml", file=sys.stderr)
        return 1
    print(f"{socket.gethostname()}: session {sid}  scope {doc.get('scope')}  "
          f"state {doc.get('state')}  dir {half}")
    for r in doc.get("recorders", []):
        size = human(path_size(half / r["file"])) if (half / r["file"]).exists() else "-"
        print(f"  {r['kind']:<4} {r['name']:<10} {r['status']:<8} {r['file']:<16} {size}"
              + (f"  ({r['reason']})" if r.get("reason") else ""))
    return 0


def cmd_status(args) -> int:
    role = resolve_role(args.role)
    live = [(s, h, p, d) for s, h, p, d in session_docs(role) if is_live(d)]
    host = socket.gethostname()
    stale = [(s, d) for s, h, p, d in session_docs(role)
             if d.get("state") in ("starting", "recording", "stopping")
             and d.get("hostname") == host and not is_live(d)]
    for sid, d in stale:
        print(f"{host}: session {sid} says '{d.get('state')}' but its runner is gone "
              "(killed? files may be unfinalized)")
    if not live:
        print(f"{host}: not recording")
        return 0
    before = {s: file_sizes(p, d) for s, h, p, d in live}
    time.sleep(args.interval)
    for sid, half, path, doc in live:
        after = file_sizes(path, doc)
        print(f"{host}: recording {sid}  scope {doc.get('scope')}  since {doc.get('start_utc')}"
              f"  ({(doc.get('runner') or {}).get('mode')})")
        for r in doc.get("recorders", []):
            if r.get("status") == "skipped":
                print(f"  {r['name']:<10} skipped ({r.get('reason')})")
                continue
            n = r["file"]
            rate = (after.get(n, 0) - before[sid].get(n, 0)) / args.interval
            print(f"  {r['name']:<10} {r['status']:<8} {n:<16} {human(after.get(n, 0)):>10}"
                  f"  +{human(rate)}/s")
    return 0


def cmd_list(args) -> int:
    base = recordings_dir()
    rows = {}
    for sid, half, path, doc in session_docs():
        rows.setdefault(sid, {})[half] = (path, doc)
    if not rows:
        print(f"no sessions in {base}")
        return 0
    print(f"{'session':<34} {'scope':<6} {'master':<9} {'orin':<11} {'merged':<6} size")
    for sid in sorted(rows):
        halves = rows[sid]
        scope = next((d.get("scope") for _, d in halves.values() if d.get("scope")), "?")

        def st(role):
            if role not in halves:
                return "-"
            d = halves[role][1]
            return ("LIVE" if is_live(d) else d.get("state", "?")) if d else "partial"
        orin = st("orin")
        if "orin" in halves and halves["orin"][1].get("hostname") != socket.gethostname():
            orin = f"{orin}*"     # a copy: collected from the orin
        size = sum(path_size(p) for p, _ in halves.values())
        merged = "yes" if (base / sid / "merged" / "metadata.yaml").is_file() else "-"
        print(f"{sid:<34} {scope:<6} {st('master'):<9} {orin:<11} {merged:<6} {human(size)}")
    if resolve_role(None) == "master":
        print("orin: '-' = not collected yet (just record collect ID); '*' = collected copy")
    return 0


def newest_id(role: str | None) -> str | None:
    ids = sorted({s for s, h, p, d in session_docs(role)})
    return ids[-1] if ids else None


def finalized_bag(p: Path) -> bool:
    m = p / "metadata.yaml"
    return m.is_file() and m.stat().st_size > 0


def latest(kind: str) -> Path | None:
    base = recordings_dir()
    if not base.is_dir():
        return None
    if kind == "bag":
        cands = [p for p in base.glob("*/merged") if finalized_bag(p)]
        cands += [p for p in base.glob("*/*/bag") if finalized_bag(p)]
        key = lambda p: (p.parents[0].name if p.name == "merged" else p.parents[1].name,
                         p.name == "merged")
    else:
        cands = [p for p in base.glob("*/*/*.log") if p.stat().st_size > 0]
        key = lambda p: (p.parents[1].name, p.stat().st_mtime)
    cands = [p for p in cands if valid_id((p.parents[0] if p.name == "merged" else p.parents[1]).name)]
    return max(cands, key=key) if cands else None


def resolve_bag(arg: str, role: str) -> Path | None:
    p = Path(arg)
    if p.is_dir():
        if (p / "bag").is_dir():
            return p / "bag"
        return p
    sdir = recordings_dir() / arg
    if sdir.is_dir():
        for c in [sdir / "merged", sdir / role / "bag", *sorted(sdir.glob("*/bag"))]:
            if finalized_bag(c):
                return c
    return None


def read_args_file(path: Path = ARGS_FILE) -> dict:
    out = {}
    try:
        for line in path.read_text().splitlines():
            if "=" in line:
                k, v = line.split("=", 1)
                out[k.strip()] = v.strip()
    except OSError:
        pass
    return out


def write_args_file(sid: str, scope: str, path: Path = ARGS_FILE) -> None:
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(f"id={sid}\nscope={scope}\n")
    os.replace(tmp, path)


# ── cli ──────────────────────────────────────────────────────────────────────
def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("new-id"); s.add_argument("name", nargs="?", default="")
    sub.add_parser("scopes")
    s = sub.add_parser("is-scope"); s.add_argument("word")
    for name in ("plan", "preflight"):
        s = sub.add_parser(name); s.add_argument("--scope"); s.add_argument("--role")
    s = sub.add_parser("write-args"); s.add_argument("--id", required=True)
    s.add_argument("--scope", required=True)
    s = sub.add_parser("run")
    s.add_argument("--unit", action="store_true")
    s.add_argument("--args-file", type=Path)
    s.add_argument("--id"); s.add_argument("--scope"); s.add_argument("--name", default="")
    s.add_argument("--role"); s.add_argument("--can", nargs="*")
    s = sub.add_parser("show"); s.add_argument("id", nargs="?"); s.add_argument("--role")
    s = sub.add_parser("status"); s.add_argument("--role")
    s.add_argument("--interval", type=float, default=2.0)
    sub.add_parser("list")
    s = sub.add_parser("active"); s.add_argument("--role")
    s = sub.add_parser("newest-id"); s.add_argument("--role")
    s = sub.add_parser("latest"); s.add_argument("kind", choices=("bag", "can"))
    s = sub.add_parser("resolve-bag"); s.add_argument("arg"); s.add_argument("--role")
    a = ap.parse_args(argv)

    try:
        if a.cmd == "new-id":
            print(new_id(a.name))
        elif a.cmd == "scopes":
            data = load_scopes()
            for name, body in data["scopes"].items():
                mark = " (default)" if name == data["default"] else ""
                print(f"{name:<6} {(body or {}).get('description', '')}{mark}")
        elif a.cmd == "is-scope":
            return 0 if a.word in load_scopes()["scopes"] else 1
        elif a.cmd == "plan":
            data = load_scopes()
            scope, role = a.scope or data["default"], resolve_role(a.role)
            out = recordings_dir() / "<id>" / role
            for r in plan(data, scope, role, out):
                what = {"ros": f"ros2 bag ({r.get('mode')}"
                               + (f", {r.get('topics_requested')} topics)" if r.get("mode") == "list" else ")"),
                        "can": "candump -L", "pcap": "tshark"
                               + (f" -f '{r['filter']}'" if r.get("filter") else "")}[r["kind"]]
                st = "" if r["status"] == "planned" else f"  SKIP: {r['reason']}"
                print(f"  {r['file']:<16} {what}{st}")
        elif a.cmd == "preflight":
            data = load_scopes()
            scope = a.scope or data["default"]
            e = scope_entry(data, scope, resolve_role(a.role))
            need = float(data.get("min_free_gb", 20)) * 1e9
            free = free_bytes(recordings_dir())
            print(f"{socket.gethostname()}: {gb(free)} free under {recordings_dir()}")
            if free < need:
                msg = f"{gb(free)} free, below min_free_gb {data.get('min_free_gb')}"
                if e["disk"] == "refuse":
                    print(f"REFUSED: scope '{scope}' needs {gb(int(need))}: {msg}", file=sys.stderr)
                    return 3
                warn(msg)
        elif a.cmd == "write-args":
            if not valid_id(a.id):
                raise ValueError(f"bad session id '{a.id}'")
            if a.scope not in load_scopes()["scopes"]:
                raise ValueError(f"unknown scope '{a.scope}'")
            write_args_file(a.id, a.scope)
        elif a.cmd == "run":
            data = load_scopes()
            fa = read_args_file(a.args_file) if a.args_file else {}
            sid = a.id or fa.get("id") or new_id(a.name)
            scope = a.scope or fa.get("scope") or data["default"]
            if not valid_id(sid):
                raise ValueError(f"bad session id '{sid}'")
            scope_entry(data, scope, "master")      # validates the scope name
            return Runner(sid, scope, resolve_role(a.role), a.unit, a.can).run()
        elif a.cmd == "show":
            return cmd_show(a)
        elif a.cmd == "status":
            return cmd_status(a)
        elif a.cmd == "list":
            return cmd_list(a)
        elif a.cmd == "active":
            # Any half on this host whose runner is alive, whatever its role.
            live = [s for s, h, p, d in session_docs() if is_live(d)]
            for sid in live:
                print(sid)
            return 0 if live else 1
        elif a.cmd == "newest-id":
            sid = newest_id(a.role)
            if not sid:
                return 1
            print(sid)
        elif a.cmd == "latest":
            p = latest(a.kind)
            if not p:
                return 1
            print(p)
        elif a.cmd == "resolve-bag":
            p = resolve_bag(a.arg, resolve_role(a.role))
            if not p:
                return 1
            print(p)
    except (ValueError, OSError, yaml.YAMLError) as e:
        print(f"session.py: {e}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
