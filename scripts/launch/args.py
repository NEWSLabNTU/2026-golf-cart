#!/usr/bin/env python3
"""Resolve the launch argument list every launcher passes to play_launch.

    scripts/launch/args.py [--host ROLE|auto] [--no-rviz] [--require KEY]
                           [--from FILE] [--write FILE] [--label TEXT] [--quiet]
                           [TOKEN...]

One place for the two things every launcher used to do for itself, slightly
differently each time:

1. Arg files. A TOKEN of the form ``@name`` is replaced, in place, by the
   arguments in ``config/launch/<name>.args``. Those files hold one or more
   ``key:=value`` per line; ``#`` starts a comment, blank lines are ignored, and
   a line may itself name another ``@file``. Every other TOKEN is split on
   whitespace, so ``just up "a:=1 b:=2"`` and ``just up a:=1 b:=2`` are the same.

2. Host arguments. ``--host master|orin`` (the unit) or ``--host auto`` (``just
   run``: config/host via scripts/env.sh, else ``all``) prepends ``host:=ROLE``
   and, for master and orin, ``master_ip:=`` from config/multi_machine.conf and
   ``link_topics:=`` the repo's config/link/topics.yaml. These are launch
   arguments, not environment: the launch files take no env fallback for them.

Later arguments win. The list is de-duplicated by key, keeping the LAST value
at the position of the first occurrence, so ``@mingda-loop
planning_speed_limit:=0.5`` overrides the file and an explicit ``host:=`` beats
the derived one. What is printed is therefore exactly what play_launch gets.

Output: the final list, one argument per line, on stdout (or into ``--write``
FILE, replaced atomically). A one-line summary goes to stderr, so the operator
sees what ran even when stdout is captured. ``--from FILE`` reads tokens from a
file written earlier by ``--write`` (how systemd's unit gets them).

Standard library only.
"""

import argparse
import os
import shlex
import subprocess
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
ARGS_DIR = REPO / "config" / "launch"
MULTI_MACHINE_CONF = REPO / "config" / "multi_machine.conf"
LINK_TOPICS = REPO / "config" / "link" / "topics.yaml"
TWO_HOST_ROLES = ("master", "orin")


class ArgError(Exception):
    pass


def available():
    return sorted(p.stem for p in ARGS_DIR.glob("*.args"))


def strip_comment(line):
    """Drop a `#` comment: the whole line, or from ` #` onwards."""
    if line.lstrip().startswith("#"):
        return ""
    for i, ch in enumerate(line):
        if ch == "#" and i > 0 and line[i - 1].isspace():
            return line[:i]
    return line


def expand(tokens, stack=()):
    out = []
    for raw in tokens:
        for tok in raw.split():
            if not tok.startswith("@"):
                out.append(tok)
                continue
            name = tok[1:]
            path = ARGS_DIR / f"{name}.args"
            if not name or not path.is_file():
                raise ArgError(
                    f"unknown arg file '@{name}' (no {path.relative_to(REPO)}). "
                    f"Available: {' '.join('@' + n for n in available()) or '(none)'}"
                )
            if name in stack:
                raise ArgError(f"arg file cycle: {' -> '.join('@' + s for s in stack + (name,))}")
            lines = [strip_comment(line) for line in path.read_text().splitlines()]
            out.extend(expand(lines, stack + (name,)))
    return out


def key_of(arg):
    return arg.split(":=", 1)[0] if ":=" in arg else None


def dedupe(args):
    """Last value wins, at the position the key first appeared."""
    order, values, plain = [], {}, []
    for i, a in enumerate(args):
        k = key_of(a)
        if k is None:
            order.append(("plain", i))
            plain.append(a)
            continue
        if k not in values:
            order.append(("key", k))
        values[k] = a
    result, it = [], iter(plain)
    for kind, v in order:
        result.append(next(it) if kind == "plain" else values[v])
    return result


def shell_value(script, *argv):
    res = subprocess.run(
        ["bash", "-c", script, "_", *argv],
        capture_output=True, text=True, check=False,
    )
    return res.stdout.strip() if res.returncode == 0 else ""


def configured_host():
    """config/host as scripts/env.sh resolves it; empty if it cannot say."""
    env = dict(os.environ, GOLFCART_ENV_RESOLVE_ONLY="1", GOLFCART_ENV_QUIET="1")
    res = subprocess.run(
        ["bash", "-c", 'source "$1"; printf "%s" "${GOLFCART_HOST:-}"', "_",
         str(REPO / "scripts" / "env.sh")],
        capture_output=True, text=True, env=env, check=False,
    )
    return res.stdout.strip() if res.returncode == 0 else ""


def master_ip():
    if not MULTI_MACHINE_CONF.is_file():
        raise ArgError(f"no {MULTI_MACHINE_CONF.relative_to(REPO)}: cannot derive master_ip:=")
    ip = shell_value('. "$1"; printf "%s" "${MASTER_IP:-}"', str(MULTI_MACHINE_CONF))
    if not ip:
        raise ArgError(f"MASTER_IP is empty in {MULTI_MACHINE_CONF.relative_to(REPO)}")
    return ip


def host_args(host, user):
    explicit = next((a.split(":=", 1)[1] for a in reversed(user) if key_of(a) == "host"), None)
    if host == "auto":
        role = configured_host()
        host = role if role in TWO_HOST_ROLES else "all"
    effective = explicit or host
    args = [f"host:={host}"]
    if effective in TWO_HOST_ROLES:
        args += [f"master_ip:={master_ip()}", f"link_topics:={LINK_TOPICS}"]
    return args


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    p.add_argument("--host", help="master | orin | all | auto: prepend host-derived args")
    p.add_argument("--no-rviz", action="store_true", help="prepend rviz:=false")
    p.add_argument("--require", action="append", default=[], metavar="KEY",
                   help="fail unless KEY:= is in the final list")
    p.add_argument("--from", dest="from_file", metavar="FILE",
                   help="read tokens from FILE (one per line) before TOKENs")
    p.add_argument("--write", metavar="FILE", help="write the list to FILE, not stdout")
    p.add_argument("--label", default="launch args", help="prefix of the stderr summary")
    p.add_argument("--quiet", action="store_true", help="no stderr summary")
    p.add_argument("tokens", nargs="*", metavar="TOKEN")
    opts = p.parse_args()

    try:
        tokens = list(opts.tokens)
        if opts.from_file and Path(opts.from_file).is_file():
            tokens = Path(opts.from_file).read_text().splitlines() + tokens
        user = expand(tokens)
        prefix = host_args(opts.host, user) if opts.host else []
        if opts.no_rviz:
            prefix.append("rviz:=false")
        final = dedupe(prefix + user)
        keys = {key_of(a) for a in final}
        for k in opts.require:
            if k not in keys:
                raise ArgError(
                    f"{k}:= is required. Pass it, or an arg file that sets it: "
                    f"{' '.join('@' + n for n in available())}"
                )
    except ArgError as e:
        print(f"args.py: {e}", file=sys.stderr)
        return 2

    if not opts.quiet:
        print(f"{opts.label}: {' '.join(shlex.quote(a) for a in final) or '(none)'}",
              file=sys.stderr)
    text = "".join(a + "\n" for a in final)
    if opts.write:
        dst = Path(opts.write)
        dst.parent.mkdir(parents=True, exist_ok=True)
        tmp = dst.with_name(dst.name + ".tmp")
        tmp.write_text(text)
        tmp.replace(dst)
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
