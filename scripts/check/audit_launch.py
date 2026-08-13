#!/usr/bin/env python3
"""Audit the launch files this repo owns for the failure modes that are silent.

    python3 scripts/check/audit_launch.py     # non-zero if anything is a BUG

Every expensive launch bug found in this stack has been a quiet one. Not a
crash: a value that goes somewhere nobody reads, and a default that quietly
wins.

The one that cost the most: gyro_odometer was passed
`output_twist_with_covariance` when the argument is
`output_twist_with_covariance_topic`. ROS 2 accepted it without complaint, the
node kept its default output topic, the EKF subscribed to a topic nobody
published, and the entire fusion chain was dead while every node in `ros2 node
list` reported healthy.

Note what is NOT a bug: passing an argument an include does not DECLARE. That
is legal and load-bearing -- it is how pose_initializer's parameter file
resolves `$(var user_defined_initial_pose/enable)` without pose_initializer
declaring it. The bug is passing a name that nothing downstream READS.

Checks:
  BUG   an argument passed to an include that nothing in the target reads
  BUG   `--` inside an XML comment, which makes the file invalid XML
  BUG   an include or param file that does not exist
  WARN  a referenced package that is not installed
  INFO  an argument declared and not referenced in the same file. Often fine:
        launch configurations flow into includes, so an argument declared high
        and read low is legitimate. Treat as a prompt to check, not a defect.
"""
import glob
import os
import re
import sys
import xml.dom.minidom
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))) + "/"

OWNED = [
    "src/launcher/golfcart_launch/launch/**/*.launch.xml",
    "src/launcher/golfcart_launch/launch/**/*.launch.yaml",
    "src/launcher/golfcart_launch/launch/*.launch.xml",
    "src/launcher/golfcart_launch/launch/*.launch.yaml",
    "src/localization/aruco_sim_detector/launch/*.xml",
    "src/sensor_kit/golfcart_sensor_kit_launch/golfcart_sensor_kit_launch/launch/*.xml",
    "src/vehicle/control_test/launch/*.xml",
    "src/vehicle/golfcart_vehicle_launch/golfcart_vehicle_launch/launch/*.xml",
]

findings = defaultdict(list)


def report(sev, path, msg):
    findings[sev].append((os.path.relpath(path, ROOT), msg))


def files():
    out = []
    for pattern in OWNED:
        out += glob.glob(ROOT + pattern, recursive=True)
    return sorted(set(out))


# ── package share lookup ────────────────────────────────────────────────────

_share_cache = {}


def share_dir(pkg):
    if pkg in _share_cache:
        return _share_cache[pkg]
    for base in (ROOT + "install", "/opt/autoware/1.5.0", "/opt/ros/humble"):
        candidate = os.path.join(base, pkg, "share", pkg)
        if os.path.isdir(candidate):
            _share_cache[pkg] = candidate
            return candidate
        candidate = os.path.join(base, "share", pkg)
        if os.path.isdir(candidate):
            _share_cache[pkg] = candidate
            return candidate
    _share_cache[pkg] = None
    return None


def resolve(expr, src_file):
    """Best-effort resolution of a launch path expression to a real file."""
    m = re.match(r"\$\(find-pkg-share ([\w-]+)\)(.*)", expr)
    if m:
        base = share_dir(m.group(1))
        return None if base is None else base + m.group(2)
    if expr.startswith("$(dirname)"):
        return os.path.dirname(src_file) + expr[len("$(dirname)"):]
    return None


def referenced_names(path, depth=0):
    """Every name the target could plausibly read.

    Passing an argument to an include DOES set a launch configuration in the
    included scope whether or not the include declares it -- that is how
    pose_initializer's param file resolves $(var user_defined_initial_pose/...)
    without pose_initializer declaring them. So "not declared" is not a bug.

    The real failure is passing a name that NOTHING in the target reads. That is
    what happened with gyro_odometer: the launch passed
    `output_twist_with_covariance` while the file reads
    `output_twist_with_covariance_topic`, so the value set a configuration no
    one consumed and the default silently won.

    So collect names the target references, following param files it loads with
    allow_substs and one level of nested include.
    """
    names = set()
    try:
        text = open(path, encoding="utf-8").read()
    except OSError:
        return None
    names |= set(re.findall(r"\$\(var\s+([^)\s]+)\s*\)", text))
    names |= set(re.findall(r"LaunchConfiguration\(\s*['\"]([^'\"]+)", text))
    names |= set(re.findall(r"DeclareLaunchArgument\(\s*['\"]([^'\"]+)", text))
    names |= set(re.findall(r'<arg\s+name="([^"]+)"', text))
    if depth < 2:
        for expr in re.findall(r'<param\s+from="([^"]+)"', text):
            # `<param from="$(var config_file)">` is the common shape, and the
            # names it consumes live in the file that arg defaults to. Without
            # following it, every argument a param file resolves looks unread --
            # which is how pose_initializer's user_defined_initial_pose/* args
            # were first reported as dead when the launch in fact ABORTS without
            # them.
            var = re.match(r"\$\(var\s+([^)\s]+)\s*\)$", expr.strip())
            if var:
                default = re.search(
                    r'<arg\s+name="' + re.escape(var.group(1)) + r'"\s+default="([^"]+)"', text)
                if not default:
                    continue
                expr = default.group(1)
            target = resolve(expr, path)
            if target and os.path.exists(target):
                try:
                    names |= set(re.findall(
                        r"\$\(var\s+([^)\s]+)\s*\)", open(target, encoding="utf-8").read()))
                except OSError:
                    pass
        for expr in re.findall(r'<include\s+file="([^"]+)"', text):
            target = resolve(expr, path)
            if target and os.path.exists(target):
                nested = referenced_names(target, depth + 1)
                if nested:
                    names |= nested
    return names


def declared_args(path):
    """Argument names a launch file declares."""
    try:
        text = open(path, encoding="utf-8").read()
    except OSError:
        return None
    if path.endswith(".yaml"):
        import yaml
        try:
            doc = yaml.safe_load(text)
        except Exception:
            return None
        names = set()

        def walk(node):
            if isinstance(node, dict):
                if "arg" in node and isinstance(node["arg"], dict):
                    names.add(node["arg"].get("name"))
                for v in node.values():
                    walk(v)
            elif isinstance(node, list):
                for v in node:
                    walk(v)
        walk(doc)
        return names
    return set(re.findall(r'<arg\s+name="([^"]+)"', text))


# ── checks ──────────────────────────────────────────────────────────────────

def check_xml_wellformed(path, text):
    if not path.endswith(".xml"):
        return True
    # `--` inside a comment makes the document invalid, and ros2 launch reports
    # it as a generic parse failure at launch time rather than at edit time.
    for body in re.findall(r"<!--(.*?)-->", text, re.S):
        if "--" in body:
            report("BUG", path, "`--` inside an XML comment; the file is not well-formed XML")
    try:
        xml.dom.minidom.parseString(text)
        return True
    except Exception as e:
        report("BUG", path, f"does not parse as XML: {e}")
        return False


def check_include_args(path, text):
    """Arguments handed to an include that the include does not declare.

    ROS 2 accepts these in silence and the include keeps its own default, which
    is how gyro_odometer kept publishing to the wrong topic while the launch
    file looked correct.
    """
    if not path.endswith(".xml"):
        return
    for m in re.finditer(r'<include\s+file="([^"]+)"\s*>(.*?)</include>', text, re.S):
        target_expr, body = m.group(1), m.group(2)
        target = resolve(target_expr, path)
        if target is None:
            pkg = re.match(r"\$\(find-pkg-share ([\w-]+)\)", target_expr)
            if pkg:
                report("WARN", path,
                       f"includes from package '{pkg.group(1)}', not installed here "
                       f"(cannot check its arguments)")
            continue
        if not os.path.exists(target):
            report("BUG", path, f"includes a file that does not exist: {target_expr}")
            continue
        readable = referenced_names(target)
        if readable is None:
            continue
        passed = re.findall(r'<arg\s+name="([^"]+)"', body)
        for name in passed:
            if name not in readable:
                report("BUG", path,
                       f"passes '{name}' to {os.path.basename(target)}, which never reads "
                       f"that name -- the value is set and nobody consumes it, so the "
                       f"target's own default silently wins")


def check_param_files(path, text):
    for m in re.finditer(r'<param\s+from="([^"]+)"', text):
        expr = m.group(1)
        if "$(var" in expr:
            continue
        target = resolve(expr, path)
        if target and not os.path.exists(target):
            report("BUG", path, f"param file does not exist: {expr}")


def check_unused_args(path, text):
    """Arguments declared and never referenced anywhere in the same file.

    Informational: an argument can legitimately exist only to be inherited by an
    include. But every dead launch argument found in this repo so far was dead
    by mistake, so they are worth listing.
    """
    declared = declared_args(path) or set()
    for name in sorted(declared):
        if not name:
            continue
        uses = len(re.findall(r"\$\(var\s+" + re.escape(name) + r"\s*\)", text))
        forwarded = len(re.findall(r'name="' + re.escape(name) + r'"\s+value=', text))
        if uses == 0 and forwarded == 0:
            report("INFO", path, f"argument '{name}' is declared and never referenced")


def check_pkg_refs(path, text):
    for pkg in sorted(set(re.findall(r"\$\(find-pkg-share ([\w-]+)\)", text))):
        if share_dir(pkg) is None:
            report("WARN", path, f"references package '{pkg}', not found in install/ or /opt")
    for pkg in sorted(set(re.findall(r'<node\s+pkg="([\w-]+)"', text))):
        if share_dir(pkg) is None:
            report("WARN", path, f"launches a node from package '{pkg}', not found")


def main():
    paths = files()
    print(f"auditing {len(paths)} launch files\n")
    for path in paths:
        text = open(path, encoding="utf-8").read()
        if check_xml_wellformed(path, text):
            check_include_args(path, text)
        check_param_files(path, text)
        check_unused_args(path, text)
        check_pkg_refs(path, text)

    for sev in ("BUG", "WARN", "INFO"):
        items = findings.get(sev, [])
        if not items:
            continue
        print(f"── {sev} ({len(items)}) " + "─" * 40)
        for path, msg in items:
            print(f"  {path}\n      {msg}")
        print()
    return 1 if findings.get("BUG") else 0


if __name__ == "__main__":
    sys.exit(main())
