#!/usr/bin/env python3
"""TensorRT engine packs, cached in git and keyed by host compatibility.

An engine is valid only on the TensorRT version and the GPU type it was built
on, and only for the ONNX file it was built from. So a pack is keyed by

    (Autoware release, full TensorRT version, board)

for example `aw1.5.0-trt10.3.0.30-agx-orin-64gb`, and lives at

    data/engines/<key>/manifest.yaml
    data/engines/<key>/<model_dir>/<stem>.engine.zst  (plain git blob, zstd -19)
    data/engines/<key>/<model_dir>/<stem>.json     (Autoware's sidecar)

L4T, CUDA, JetPack and the hostname are recorded in the manifest but are not
part of the key: TensorRT itself only checks its own version and the device.

Subcommands:
    key       print this machine's key and the recorded-only fields
    save      copy the engines in the data dir into this key's pack
    install   copy this key's engines into the data dir, where the ONNX matches
    list      packs in the repo, and which one matches this host
    verify    compare the installed engines with this key's pack

`install` never makes things worse: an engine is copied only when the ONNX
next to its target hashes to what the pack was built from, and anything it
skips is built on first launch, as without a pack. Engines are COPIED, never
symlinked: on a mismatch Autoware rebuilds and writes through the path, which
would overwrite the pack.

Design and reasoning: docs/research/perception/tensorrt-engine-prebuild.md.
Standard library plus PyYAML, and the `zstd` CLI.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import hashlib
import json
import os
import re
import shutil
import socket
import subprocess
import sys
import tempfile
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parents[2]
PACKS_DIR = REPO_ROOT / "data" / "engines"
AUTOWARE_ROOT = Path("/opt/autoware")

# Jetson module part numbers, from the device tree's `compatible` list.
# Source: NVIDIA Jetson Linux developer guide, module/carrier part numbers.
BOARDS = {
    "p3701-0000": "agx-orin-32gb",
    "p3701-0004": "agx-orin-32gb",
    "p3701-0005": "agx-orin-64gb",
    "p3701-0008": "agx-orin-industrial-64gb",
    "p3767-0000": "orin-nx-16gb",
    "p3767-0001": "orin-nx-8gb",
    "p3767-0003": "orin-nano-8gb",
    "p3767-0004": "orin-nano-4gb",
    "p3767-0005": "orin-nano-8gb-devkit",
}


# ── host identity ──────────────────────────────────────────────────────────


def _run(cmd: list[str]) -> str | None:
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=20)
    except (OSError, subprocess.SubprocessError):
        return None
    return out.stdout.strip() if out.returncode == 0 and out.stdout.strip() else None


def _read(path: str) -> str | None:
    try:
        return Path(path).read_text(errors="replace")
    except OSError:
        return None


def autoware_release() -> str | None:
    """The release under /opt/autoware; with several, the one env.sh sources."""
    try:
        versions = sorted(
            d.name for d in AUTOWARE_ROOT.iterdir()
            if d.is_dir() and re.fullmatch(r"\d+\.\d+(\.\d+)*", d.name)
        )
    except OSError:
        return None
    if len(versions) == 1:
        return versions[0]
    env = _read(str(REPO_ROOT / "scripts" / "env.sh")) or ""
    m = re.search(r"source\s+/opt/autoware/([0-9.]+)/setup\.bash", env)
    if m and m.group(1) in versions:
        return m.group(1)
    return None


def tensorrt_package() -> str | None:
    for pkg in ("libnvinfer10", "libnvinfer8"):
        v = _run(["dpkg-query", "-W", "-f=${Version}", pkg])
        if v:
            return v
    return None


def board() -> tuple[str | None, str | None]:
    """(board slug, raw compatible string). Jetson by device tree, else GPU."""
    raw = _read("/proc/device-tree/compatible")
    if raw:
        entries = [e for e in raw.split("\0") if e]
        for e in entries:
            m = re.fullmatch(r"nvidia,(p\d{4}-\d{4})", e)
            if m:
                return BOARDS.get(m.group(1), m.group(1)), " ".join(entries)
    # Not a Jetson: the discrete GPU's name and compute capability, so a
    # workstation gets a key of its own and never matches a Jetson pack.
    smi = _run(["nvidia-smi", "--query-gpu=name,compute_cap",
                "--format=csv,noheader"])
    if smi:
        name, _, cap = smi.splitlines()[0].partition(",")
        slug = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
        slug = re.sub(r"^nvidia-(geforce-)?", "", slug)
        return f"{slug}-sm{cap.strip().replace('.', '')}", smi.splitlines()[0]
    return None, raw


def host_info() -> dict:
    aw = autoware_release()
    trt_pkg = tensorrt_package()
    trt = trt_pkg.split("-")[0] if trt_pkg else None
    brd, compatible = board()
    l4t = None
    rel = _read("/etc/nv_tegra_release")
    if rel:
        m = re.search(r"R(\d+)\s*\(release\),\s*REVISION:\s*([0-9.]+)", rel)
        if m:
            l4t = f"R{m.group(1)}.{m.group(2)}"
    cuda = None
    try:
        cuda = json.loads(_read("/usr/local/cuda/version.json") or "{}")["cuda"]["version"]
    except (ValueError, KeyError, TypeError):
        pass
    model = (_read("/proc/device-tree/model") or "").strip("\0\n ") or None
    missing = [n for n, v in (("autoware", aw), ("tensorrt", trt), ("board", brd)) if not v]
    key = None if missing else f"aw{aw}-trt{trt}-{brd}"
    return {
        "key": key,
        "missing": missing,
        "autoware": aw,
        "tensorrt": trt,
        "board": brd,
        "recorded": {
            "tensorrt_package": trt_pkg,
            "l4t": l4t,
            "cuda": cuda,
            "jetpack": _run(["dpkg-query", "-W", "-f=${Version}", "nvidia-jetpack"]),
            "model": model,
            "compatible": compatible,
        },
        "hostname": socket.gethostname(),
    }


def require_key(info: dict) -> str:
    if not info["key"]:
        sys.exit(f"cannot form this host's key: unknown {', '.join(info['missing'])}")
    return info["key"]


# ── files ──────────────────────────────────────────────────────────────────

_sha_cache: dict[Path, str] = {}


def sha256(path: Path) -> str:
    real = path.resolve()
    if real not in _sha_cache:
        h = hashlib.sha256()
        with open(real, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        _sha_cache[real] = h.hexdigest()
    return _sha_cache[real]


def copy_atomic(src: Path, dst: Path) -> None:
    """Copy as a real file, replacing whatever is at dst (a symlink included)."""
    dst.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=dst.parent, prefix=f".{dst.name}.")
    os.close(fd)
    try:
        shutil.copyfile(src, tmp)
        os.chmod(tmp, 0o664)
        os.replace(tmp, dst)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


# zstd -19 through the CLI: these hosts' Python (3.10) has no zstd module and
# `zstandard` is not installed. Measured on the CenterPoint-tiny engines,
# --ultra -22 and --long gain nothing. Output is a pure function of input and
# level, so an unchanged engine re-packs to the same bytes; save avoids even
# that by comparing sha256 first.
COMPRESSION = "zstd-19"
PACK_SUFFIX = ".zst"
ZSTD = shutil.which("zstd")
NO_ZSTD = "no zstd CLI; install it: sudo apt install zstd"


def pack_zst(src: Path, dst: Path) -> None:
    if not ZSTD:
        sys.exit(NO_ZSTD)
    dst.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=dst.parent, prefix=f".{dst.name}.")
    try:
        with os.fdopen(fd, "wb") as out:
            subprocess.run([ZSTD, "-19", "-q", "--no-progress", "-c", str(src)],
                           stdout=out, check=True)
        os.chmod(tmp, 0o664)
        os.replace(tmp, dst)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def unpack_zst(src: Path, dst: Path, want_sha: str) -> str | None:
    """Decompress next to dst, check the sha256, rename into place.
    Returns None on success, else why it did not install."""
    dst.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=dst.parent, prefix=f".{dst.name}.")
    try:
        with os.fdopen(fd, "wb") as out:
            r = subprocess.run([ZSTD, "-d", "-q", "-c", str(src)], stdout=out,
                               stderr=subprocess.PIPE, text=True)
        if r.returncode != 0:
            Path(tmp).unlink(missing_ok=True)
            return f"pack file does not decompress ({r.stderr.strip() or r.returncode})"
        if sha256(Path(tmp)) != want_sha:
            _sha_cache.pop(Path(tmp).resolve(), None)
            Path(tmp).unlink(missing_ok=True)
            return "decompressed engine does not match its manifest sha256"
        _sha_cache.pop(Path(tmp).resolve(), None)
        os.chmod(tmp, 0o664)
        os.replace(tmp, dst)
        return None
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def onnx_for(engine: Path) -> Path | None:
    """The ONNX an engine was built from: same stem, else the longest stem the
    engine name extends with a dot (`model.fp16-batch6.engine`)."""
    same = engine.with_suffix(".onnx")
    if same.exists():
        return same
    best = None
    for cand in engine.parent.glob("*.onnx"):
        if engine.stem.startswith(cand.stem + ".") and cand.exists():
            if best is None or len(cand.stem) > len(best.stem):
                best = cand
    return best


def load_manifest(pack: Path) -> dict | None:
    f = pack / "manifest.yaml"
    if not f.exists():
        return None
    return yaml.safe_load(f.read_text()) or {}


def dump_manifest(m: dict) -> str:
    return ("# TensorRT engine pack. Written by `just engines save`; "
            "see scripts/engines/engines.py.\n"
            + yaml.safe_dump(m, sort_keys=False, default_flow_style=False))


# ── commands ───────────────────────────────────────────────────────────────


def cmd_key(args, info) -> int:
    print(info["key"] or f"(none: unknown {', '.join(info['missing'])})")
    print(f"  autoware   {info['autoware']}")
    print(f"  tensorrt   {info['tensorrt']}")
    print(f"  board      {info['board']}")
    print("recorded, not keyed:")
    for k, v in info["recorded"].items():
        print(f"  {k:<16} {v}")
    print(f"  {'hostname':<16} {info['hostname']}")
    return 0 if info["key"] else 1


def cmd_save(args, info) -> int:
    key = require_key(info)
    data: Path = args.data_dir
    pack = PACKS_DIR / key
    old = load_manifest(pack) or {}
    old_entries = {e["path"]: e for e in old.get("engines", [])}
    entries = dict(old_entries)
    changed = refused = 0

    engines = sorted(p for p in data.rglob("*.engine") if p.is_file())
    if not engines:
        print(f"no .engine files under {data}")
    for eng in engines:
        rel = eng.relative_to(data).as_posix()
        onnx = onnx_for(eng)
        if onnx is None:
            print(f"  refused    {rel}: no ONNX beside it")
            refused += 1
            continue
        sidecar = eng.with_suffix(".json")
        entry = {
            "path": rel,
            "onnx": onnx.relative_to(data).as_posix(),
            "onnx_sha256": sha256(onnx),
            "engine_sha256": sha256(eng),
            "size": eng.stat().st_size,
            "compression": COMPRESSION,
            "packed": rel + PACK_SUFFIX,
            "packed_sha256": None,
            "packed_size": None,
            "sidecar": sidecar.relative_to(data).as_posix() if sidecar.is_file() else None,
            "sidecar_sha256": sha256(sidecar) if sidecar.is_file() else None,
        }
        dst = pack / entry["packed"]
        prev = old_entries.get(rel) or {}
        # Unchanged = the live engine, ONNX and sidecar hash to what the
        # manifest says and the packed file is intact: no recompression.
        same = (
            all(prev.get(k) == entry[k] for k in
                ("onnx", "onnx_sha256", "engine_sha256", "size", "compression", "packed",
                 "sidecar", "sidecar_sha256"))
            and dst.is_file() and sha256(dst) == prev.get("packed_sha256")
            and (entry["sidecar"] is None
                 or ((pack / entry["sidecar"]).is_file()
                     and sha256(pack / entry["sidecar"]) == entry["sidecar_sha256"]))
        )
        # Earlier formats of this pack: the bare engine, then .engine.xz.
        legacy = [p for p in (pack / rel, pack / (rel + ".xz")) if p.exists()]
        if same and not legacy:
            print(f"  unchanged  {rel}")
            continue
        if same:
            entry = prev
        else:
            pack_zst(eng, dst)
            _sha_cache.pop(dst.resolve(), None)
            entry["packed_sha256"] = sha256(dst)
            entry["packed_size"] = dst.stat().st_size
        for p in legacy:
            p.unlink()
        if entry["sidecar"]:
            copy_atomic(sidecar, pack / entry["sidecar"])
        print(f"  {'changed' if rel in old_entries else 'added':<10} {rel}"
              f"  ({entry['size']} -> {entry['packed_size']} B zst)")
        entries[rel] = entry
        changed += 1

    for rel in sorted(set(old_entries) - {e.relative_to(data).as_posix() for e in engines}):
        print(f"  kept       {rel} (in the pack, not in {data})")

    if changed:
        manifest = {
            "key": key,
            "autoware": info["autoware"],
            "tensorrt": info["tensorrt"],
            "board": info["board"],
            "recorded": info["recorded"],
            "built_on": info["hostname"],
            "saved_at": _dt.datetime.now(_dt.timezone.utc).replace(microsecond=0).isoformat(),
            "engines": [entries[k] for k in sorted(entries)],
        }
        pack.mkdir(parents=True, exist_ok=True)
        (pack / "manifest.yaml").write_text(dump_manifest(manifest))
        print(f"pack {pack.relative_to(REPO_ROOT)}: {changed} written, manifest updated")
    else:
        print(f"pack {pack.relative_to(REPO_ROOT) if pack.exists() else key}: nothing changed")
    return 1 if refused else 0


def cmd_install(args, info) -> int:
    key = require_key(info)
    data: Path = args.data_dir
    pack = PACKS_DIR / key
    manifest = load_manifest(pack)
    if manifest is None:
        print(f"no pack for {key}: engines build on first launch (or `just build-engines`)")
        return 0
    installed = skipped = 0
    for e in manifest.get("engines", []):
        rel = e["path"]
        src = pack / e["packed"]
        dst = data / rel
        onnx = data / e["onnx"]
        if (not src.is_file() or src.stat().st_size == 0
                or sha256(src) != e["packed_sha256"]):
            print(f"  skip  {rel}: pack file missing or does not match its manifest")
            skipped += 1
            continue
        if not onnx.exists():
            print(f"  skip  {rel}: no ONNX at {e['onnx']} (run `just setup-autoware-data`)")
            skipped += 1
            continue
        if sha256(onnx) != e["onnx_sha256"]:
            print(f"  skip  {rel}: ONNX differs from the one the pack was built from")
            skipped += 1
            continue
        side_src = pack / e["sidecar"] if e.get("sidecar") else None
        side_dst = data / e["sidecar"] if e.get("sidecar") else None
        eng_same = dst.is_file() and not dst.is_symlink() and sha256(dst) == e["engine_sha256"]
        side_same = side_src is None or (
            side_dst.is_file() and not side_dst.is_symlink()
            and sha256(side_dst) == e["sidecar_sha256"])
        if eng_same and side_same:
            print(f"  ok    {rel} (already installed)")
            continue
        if dst.exists() and not eng_same and not args.force:
            print(f"  keep  {rel}: a different local engine is there; --force replaces it")
            skipped += 1
            continue
        if not ZSTD:
            print(f"  skip  {rel}: {NO_ZSTD}")
            skipped += 1
            continue
        why = unpack_zst(src, dst, e["engine_sha256"])
        if why:
            print(f"  skip  {rel}: {why}")
            skipped += 1
            continue
        if side_src is not None:
            copy_atomic(side_src, side_dst)
        _sha_cache.pop(dst.resolve(), None)
        print(f"  copy  {rel}")
        installed += 1
    print(f"{key}: {installed} installed, {skipped} skipped; "
          "anything skipped is built on first launch")
    return 0


def cmd_list(args, info) -> int:
    packs = sorted(p.parent for p in PACKS_DIR.glob("*/manifest.yaml"))
    if not packs:
        print(f"no packs under {PACKS_DIR.relative_to(REPO_ROOT)}")
    for pack in packs:
        m = load_manifest(pack) or {}
        mark = "   <- this host" if pack.name == info["key"] else ""
        print(f"{pack.name}{mark}")
        print(f"  built_on {m.get('built_on')}  saved_at {m.get('saved_at')}  "
              f"l4t {(m.get('recorded') or {}).get('l4t')}")
        for e in m.get("engines", []):
            print(f"    {e['path']}  {e['size']} bytes ({e.get('packed_size')} {e.get('compression')})")
    print(f"this host: {info['key'] or 'no key'}"
          + ("" if info["key"] in {p.name for p in packs} else "  (no pack)"))
    return 0


def cmd_verify(args, info) -> int:
    key = require_key(info)
    data: Path = args.data_dir
    manifest = load_manifest(PACKS_DIR / key)
    if manifest is None:
        print(f"no pack for {key}")
        return 1
    bad = 0
    listed = set()
    for e in manifest.get("engines", []):
        rel = e["path"]
        listed.add(rel)
        dst, onnx = data / rel, data / e["onnx"]
        if not dst.is_file():
            state = "missing"
        elif sha256(dst) != e["engine_sha256"]:
            state = "differs from pack"
        elif not onnx.exists() or sha256(onnx) != e["onnx_sha256"]:
            state = "engine matches, ONNX does not (Autoware may rebuild)"
        else:
            state = "match"
        bad += state != "match"
        print(f"  {state:<18} {rel}")
    for eng in sorted(data.rglob("*.engine")):
        rel = eng.relative_to(data).as_posix()
        if rel not in listed:
            print(f"  {'not in pack':<18} {rel}")
    print(f"{key}: {len(listed) - bad}/{len(listed)} match")
    return 1 if bad else 0


def main(argv=None) -> int:
    default_data = Path(os.environ.get("GOLFCART_DATA_PATH")
                        or REPO_ROOT / "data" / "autoware_data")
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--data-dir", type=Path, default=default_data,
                    help="Autoware data_path (default: $GOLFCART_DATA_PATH or data/autoware_data)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for name in ("key", "save", "list", "verify"):
        sub.add_parser(name)
    p = sub.add_parser("install")
    p.add_argument("--force", action="store_true",
                   help="replace a local engine that differs from the pack")
    args = ap.parse_args(argv)
    args.data_dir = args.data_dir.absolute()
    info = host_info()
    return {"key": cmd_key, "save": cmd_save, "install": cmd_install,
            "list": cmd_list, "verify": cmd_verify}[args.cmd](args, info)


if __name__ == "__main__":
    sys.exit(main())
