"""The Autoware version and model data on the launch path.

    python3 -m unittest discover -s setup/tests

Here rather than beside scripts/launch/args.py so the one discover command
covers it. Nothing touches a real unit, the orin or play_launch:

* scripts/launch/args.py: data_path:= injection.
* launch_unit_exec.sh: reads .golfcart-launch.env before scripts/env.sh. Run
  in a scratch workspace of symlinks into this checkout, with a play_launch
  stub that prints what it was given.
* `just up`: carries the version to both hosts and refuses before starting
  anything when the orin cannot run it. systemctl is a stub that records its
  calls, and GOLFCART_ON_ORIN replaces on_orin.sh with a fake orin. The repo's
  .golfcart-launch.{args,env} are saved and restored around each test.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
ARGS_PY = REPO / "scripts" / "launch" / "args.py"
UNIT_EXEC = REPO / "scripts" / "multi_machine" / "launch_unit_exec.sh"


def clean_env(**extra: str) -> dict:
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("GOLFCART_", "AMENT_", "COLCON_", "ROS_", "CYCLONEDDS"))}
    env.update(extra)
    return env


def args_py(*argv: str, **env: str) -> list[str]:
    res = subprocess.run(["python3", str(ARGS_PY), "--quiet", *argv], capture_output=True,
                         text=True, env=clean_env(**env), check=True)
    return res.stdout.splitlines()


class ArgsDataPathTest(unittest.TestCase):
    def test_injected_per_version(self) -> None:
        for ver in ("1.5.0", "2.1.0"):
            out = args_py("a:=1", GOLFCART_AUTOWARE_VERSION=ver)
            self.assertEqual(out[0], f"data_path:={REPO}/data/autoware_data-{ver}"
                             if ver != "1.5.0" or (REPO / "data/autoware_data-1.5.0").is_dir()
                             else f"data_path:={REPO}/data/autoware_data")
            self.assertEqual(out[1:], ["a:=1"])

    def test_caller_wins(self) -> None:
        out = args_py("data_path:=/mine", "a:=1", GOLFCART_AUTOWARE_VERSION="2.1.0")
        self.assertEqual(out, ["data_path:=/mine", "a:=1"])
        self.assertEqual([a for a in out if a.startswith("data_path:=")], ["data_path:=/mine"])

    def test_no_data_path(self) -> None:
        self.assertEqual(args_py("--no-data-path", "a:=1"), ["a:=1"])

    def test_hand_set_path_is_kept_but_stale_derived_one_is_not(self) -> None:
        out = args_py(GOLFCART_AUTOWARE_VERSION="2.1.0", GOLFCART_DATA_PATH="/by/hand")
        self.assertEqual(out, ["data_path:=/by/hand"])
        out = args_py(GOLFCART_AUTOWARE_VERSION="2.1.0", GOLFCART_DATA_PATH="/old/1.5.0",
                      GOLFCART_DATA_PATH_FOR="1.5.0")
        self.assertEqual(out, [f"data_path:={REPO}/data/autoware_data-2.1.0"])

    def test_with_host_and_arg_file(self) -> None:
        out = args_py("--host", "master", "--no-rviz", "@mingda-loop",
                      GOLFCART_AUTOWARE_VERSION="2.1.0")
        keys = [a.split(":=", 1)[0] for a in out]
        self.assertEqual(keys[:3], ["host", "master_ip", "link_topics"])
        self.assertIn("rviz:=false", out)
        self.assertIn(f"data_path:={REPO}/data/autoware_data-2.1.0", out)
        self.assertEqual(keys.count("data_path"), 1)


class StubDir(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        self.log = self.tmp / "calls.log"

    def stub(self, name: str, body: str) -> Path:
        p = self.bin / name
        p.write_text("#!/bin/bash\n" + textwrap.dedent(body))
        p.chmod(0o755)
        return p

    def calls(self) -> list[str]:
        return self.log.read_text().splitlines() if self.log.exists() else []


@unittest.skipUnless(Path("/opt/autoware/2.1.0/setup.bash").is_file()
                     and (REPO / "install-2.1.0" / "local_setup.bash").is_file(),
                     "needs Autoware 2.1.0 and install-2.1.0/")
class UnitExecTest(StubDir):
    """launch_unit_exec.sh in a scratch workspace, play_launch stubbed."""

    def setUp(self) -> None:
        super().setUp()
        self.ws = self.tmp / "ws"
        self.ws.mkdir()
        for entry in REPO.iterdir():
            if not entry.name.startswith(".golfcart-launch"):
                (self.ws / entry.name).symlink_to(entry)
        self.stub("play_launch", f"""\
            echo "AW=$GOLFCART_AUTOWARE_VERSION" >> {self.log}
            printf 'ARG=%s\\n' "$@" >> {self.log}
            """)

    def run_unit(self) -> subprocess.CompletedProcess:
        env = clean_env(PATH=f"{self.bin}:{os.environ['PATH']}", GOLFCART_WORKSPACE=str(self.ws),
                        GOLFCART_HOST="master", HOME=os.environ["HOME"])
        return subprocess.run(["bash", str(UNIT_EXEC)], capture_output=True, text=True,
                              env=env, check=False, timeout=120)

    def test_reads_the_version_from_the_env_file(self) -> None:
        (self.ws / ".golfcart-launch.env").write_text("# x\nGOLFCART_AUTOWARE_VERSION=2.1.0\n")
        (self.ws / ".golfcart-launch.args").write_text("a:=1\n")
        res = self.run_unit()
        self.assertEqual(res.returncode, 0, res.stderr[-2000:])
        calls = self.calls()
        self.assertIn("AW=2.1.0", calls)
        self.assertIn(f"ARG=data_path:={self.ws}/data/autoware_data-2.1.0", calls)
        self.assertIn("ARG=a:=1", calls)
        self.assertIn("Autoware 2.1.0", res.stdout + res.stderr)

    def test_bad_env_file_is_ignored(self) -> None:
        (self.ws / ".golfcart-launch.env").write_text("GOLFCART_AUTOWARE_VERSION=$(touch /x)\n")
        res = self.run_unit()
        self.assertIn("no valid GOLFCART_AUTOWARE_VERSION", res.stderr)

    def test_missing_version_stops_the_unit(self) -> None:
        (self.ws / ".golfcart-launch.env").write_text("GOLFCART_AUTOWARE_VERSION=9.9.9\n")
        res = self.run_unit()
        self.assertEqual(res.returncode, 1)
        self.assertEqual(self.calls(), [])
        self.assertIn("Autoware 9.9.9 is not installed", res.stderr)


@unittest.skipUnless(shutil.which("just") and Path("/opt/autoware/2.1.0/setup.bash").is_file()
                     and (REPO / "install-2.1.0" / "local_setup.bash").is_file(),
                     "needs just, Autoware 2.1.0 and install-2.1.0/")
class UpTest(StubDir):
    """`just up` with a fake orin and a recording systemctl."""

    SAVED = (".golfcart-launch.args", ".golfcart-launch.env")

    def setUp(self) -> None:
        super().setUp()
        for name in self.SAVED:
            src = REPO / name
            if src.exists():
                shutil.copy2(src, self.tmp / name)
            self.addCleanup(self._restore, name)
        self.stub("systemctl", f"""\
            echo "systemctl $*" >> {self.log}
            case "$*" in *is-active*) echo active ;; esac
            exit 0
            """)

    def _restore(self, name: str) -> None:
        saved, live = self.tmp / name, REPO / name
        if saved.exists():
            shutil.copy2(saved, live)
        elif live.exists():
            live.unlink()

    def fake_orin(self, check_rc: int) -> Path:
        return self.stub("fake_orin", f"""\
            echo "orin $*" >> {self.log}
            case "$1" in ./scripts/multi_machine/version_check.sh) exit {check_rc} ;; esac
            exit 0
            """)

    def up(self, orin: Path, *args: str) -> subprocess.CompletedProcess:
        env = clean_env(PATH=f"{self.bin}:{os.environ['PATH']}", GOLFCART_ON_ORIN=str(orin),
                        GOLFCART_AUTOWARE_VERSION="2.1.0", HOME=os.environ["HOME"])
        env.pop("DISPLAY", None)
        return subprocess.run(["just", "--justfile", str(REPO / "justfile"), "up", *args],
                              capture_output=True, text=True, env=env, check=False, timeout=120)

    def test_refuses_when_the_orin_lacks_the_version(self) -> None:
        res = self.up(self.fake_orin(1), "a:=1")
        self.assertEqual(res.returncode, 2, res.stderr[-2000:])
        self.assertIn("refusing: the orin cannot run Autoware 2.1.0", res.stderr)
        calls = self.calls()
        self.assertEqual(calls, ["orin ./scripts/multi_machine/version_check.sh 2.1.0"])

    def test_old_orin_checkout_is_refused(self) -> None:
        res = self.up(self.fake_orin(127))
        self.assertEqual(res.returncode, 2)
        self.assertIn("pull it first", res.stderr)
        self.assertFalse(any(c.startswith("systemctl --user restart") for c in self.calls()))

    def test_carries_the_version_to_both_hosts(self) -> None:
        res = self.up(self.fake_orin(0), "a:=1")
        self.assertEqual(res.returncode, 0, res.stderr[-2000:])
        calls = self.calls()
        self.assertIn("systemctl --user restart golfcart-launch.service", calls)
        orin_start = [c for c in calls if "_up-local" in c]
        self.assertEqual(orin_start, ["orin env GOLFCART_AUTOWARE_VERSION=2.1.0 just _up-local a:=1"])
        self.assertIn("GOLFCART_AUTOWARE_VERSION=2.1.0",
                      (REPO / ".golfcart-launch.env").read_text().splitlines())
        # No host's data_path in the shared list: each unit adds its own.
        self.assertEqual((REPO / ".golfcart-launch.args").read_text(), "a:=1\n")

    def test_unreachable_orin_starts_this_host(self) -> None:
        res = self.up(self.fake_orin(255))
        self.assertEqual(res.returncode, 0, res.stderr[-2000:])
        self.assertIn("the orin did not answer", res.stderr)
        self.assertIn("systemctl --user restart golfcart-launch.service", self.calls())


if __name__ == "__main__":
    unittest.main()
