"""--role handling and the hand-work checklist.

    python3 -m unittest discover -s setup/tests

Stdlib unittest, like setup itself. Nothing here touches the real config/host,
the real unit directory or sysctl: every path a check reads is redirected into
a temporary directory.
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SETUP = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SETUP))

import main  # noqa: E402
from golfcart_setup import checklist, model  # noqa: E402
from golfcart_setup.registry import BY_ID  # noqa: E402


class TempHost(unittest.TestCase):
    """Points config/host at a scratch file for the duration of a test."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.host = self.dir / "host"
        patcher = mock.patch.object(model, "HOST_FILE", self.host)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.addCleanup(self.tmp.cleanup)


class RoleFile(TempHost):
    def test_no_file_accepts_any_role(self) -> None:
        self.assertIsNone(model.check_role("orin", force=False))

    def test_same_role_accepted(self) -> None:
        self.host.write_text("orin\n")
        self.assertEqual(model.check_role("orin", force=False), "orin")

    def test_different_role_refused(self) -> None:
        self.host.write_text("master\n")
        with self.assertRaises(model.RoleConflict) as ctx:
            model.check_role("orin", force=False)
        self.assertIn("--force-role", str(ctx.exception))

    def test_different_role_forced(self) -> None:
        self.host.write_text("master\n")
        self.assertEqual(model.check_role("orin", force=True), "master")

    def test_unknown_role_rejected(self) -> None:
        with self.assertRaises(ValueError):
            model.check_role("loopback", force=True)

    def test_write_reports_change(self) -> None:
        self.assertTrue(model.write_host_role("orin"))
        self.assertEqual(self.host.read_text(), "orin\n")
        self.assertFalse(model.write_host_role("orin"))


class RoleSelection(unittest.TestCase):
    def ticked(self, profile: str, role: str | None) -> set[str]:
        return {s.id for s in BY_ID.values() if s.default_for(profile, role)}

    def test_orin_adds_its_steps_and_drops_the_masters(self) -> None:
        got = self.ticked("vehicle", "orin")
        self.assertTrue({"orin-can0", "chrony-orin", "host-services"} <= got)
        self.assertFalse({"chrony-master", "hardware-config"} & got)

    def test_master_adds_its_steps(self) -> None:
        got = self.ticked("vehicle", "master")
        self.assertTrue({"chrony-master", "host-services", "hardware-config"} <= got)
        self.assertFalse({"orin-can0", "chrony-orin"} & got)

    def test_no_role_is_the_profile_alone(self) -> None:
        got = self.ticked("vehicle", None)
        self.assertFalse({"host-services", "chrony-master", "chrony-orin",
                          "orin-can0"} & got)
        self.assertIn("hardware-config", got)

    def test_none_and_ci_gain_nothing(self) -> None:
        self.assertEqual(self.ticked("none", "orin"), set())
        self.assertNotIn("host-services", self.ticked("ci", "master"))

    def test_applicability_names_the_role(self) -> None:
        machine = model.Machine("master")
        ok, reason = machine.applicable(BY_ID["orin-can0"])
        self.assertFalse(ok)
        self.assertIn("orin host only", reason)


class Cli(TempHost):
    def run_main(self, *argv: str) -> tuple[int, str, str]:
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try:
                rc = main.main(list(argv))
            except SystemExit as exc:
                rc = exc.code
        return rc, out.getvalue(), err.getvalue()

    def test_dry_run_json_for_orin(self) -> None:
        rc, out, _ = self.run_main("--dry-run", "--json", "--role", "orin", "--force")
        self.assertEqual(rc, 0)
        steps = json.loads(out)
        self.assertIn("host-services", steps)
        self.assertIn("orin-can0", steps)
        self.assertNotIn("chrony-master", steps)
        self.assertFalse(self.host.exists(), "a dry run must not write config/host")

    def test_conflict_refused_before_anything(self) -> None:
        self.host.write_text("master\n")
        rc, out, err = self.run_main("--dry-run", "--json", "--role", "orin")
        self.assertEqual(rc, 2)
        self.assertEqual(out, "")
        self.assertIn("config/host says 'master'", err)

    def test_force_role_needs_role(self) -> None:
        rc, _, _ = self.run_main("--run", "--force-role")
        self.assertEqual(rc, 2)

    def test_role_implies_vehicle(self) -> None:
        rc, out, _ = self.run_main("--list", "--json", "--role", "master")
        self.assertEqual(rc, 0)
        data = json.loads(out)
        self.assertEqual((data["profile"], data["role"]), ("vehicle", "master"))
        rc, out, _ = self.run_main("--list", "--json", "--role", "master",
                                   "--profile", "dev")
        self.assertEqual(json.loads(out)["profile"], "dev")


class Requirements(unittest.TestCase):
    def test_memsize_is_binary(self) -> None:
        self.assertEqual(checklist._memsize("16MB"), 16 << 20)
        self.assertEqual(checklist._memsize("10 MiB"), 10 << 20)
        self.assertEqual(checklist._memsize("512kB"), 512 << 10)
        self.assertIsNone(checklist._memsize("lots"))

    def test_rmem_floor_comes_from_the_profiles(self) -> None:
        floor = checklist.dds_rmem_min()
        self.assertIsNotNone(floor)
        self.assertGreaterEqual(floor, 10 << 20)

    def test_sysctl_target_read_from_script(self) -> None:
        self.assertGreaterEqual(checklist.sysctl_target(), checklist.dds_rmem_min())

    def test_unit_lists_read_from_installer(self) -> None:
        self.assertIn("golfcart-watchdog.service", checklist.units_for("orin"))
        self.assertNotIn("golfcart-watchdog.service", checklist.units_for("master"))


class Checks(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.dir = Path(self.tmp.name)

    def test_host_role(self) -> None:
        self.assertTrue(checklist.check_host_role("orin").ok)
        missing = checklist.check_host_role(None)
        self.assertFalse(missing.ok)
        self.assertTrue(any("--role orin" in line for line in missing.fix))
        self.assertFalse(checklist.check_host_role("loopback").ok)

    def test_dbc(self) -> None:
        absent = self.dir / "none.dbc"
        with mock.patch.object(checklist, "DBC_PATH", absent), \
                mock.patch.dict(os.environ, {}, clear=False):
            os.environ.pop("CAX_ADS_DBC", None)
            item = checklist.check_dbc()
        self.assertFalse(item.ok)
        self.assertIn("    just build", item.fix)
        dbc = self.dir / "x.dbc"
        dbc.write_text("VERSION \"\"\n")
        with mock.patch.dict(os.environ, {"CAX_ADS_DBC": str(dbc)}):
            self.assertTrue(checklist.check_dbc().ok)

    def test_zed(self) -> None:
        with mock.patch.object(checklist, "ZED_GLOBS", (str(self.dir / "zed-config*.cmake"),)):
            item = checklist.check_zed_sdk()
            self.assertFalse(item.ok)
            self.assertTrue(any("--rerun cyclonedds-sysctl" in line for line in item.fix))
            (self.dir / "zed-config.cmake").write_text("")
            self.assertTrue(checklist.check_zed_sdk().ok)

    def _units(self, role: str, workspace: Path) -> None:
        for unit in checklist.units_for(role):
            (self.dir / unit).write_text("[Service]\n")
            (self.dir / f"{unit}.d").mkdir(exist_ok=True)
            (self.dir / f"{unit}.d" / "override.conf").write_text(
                f"[Service]\nEnvironment=GOLFCART_HOST={role}\n"
                f"Environment=GOLFCART_WORKSPACE={workspace}\n")

    def test_host_services(self) -> None:
        with mock.patch.object(checklist, "USER_UNIT_DIR", self.dir), \
                mock.patch.object(checklist, "_lingering", return_value=True):
            item = checklist.check_host_services("orin")
            self.assertFalse(item.ok)
            self.assertIn("    ./setup.sh --rerun host-services", item.fix)

            self._units("orin", checklist.REPO_ROOT)
            self.assertTrue(checklist.check_host_services("orin").ok)

            # Units for the other role, or for a checkout that moved.
            self.assertFalse(checklist.check_host_services("master").ok)
            self._units("orin", Path("/elsewhere"))
            self.assertIn("not this checkout",
                          checklist.check_host_services("orin").summary)

        with mock.patch.object(checklist, "USER_UNIT_DIR", self.dir), \
                mock.patch.object(checklist, "_lingering", return_value=False):
            self._units("orin", checklist.REPO_ROOT)
            item = checklist.check_host_services("orin")
            self.assertFalse(item.ok)
            self.assertIn("lingering off", item.summary)


if __name__ == "__main__":
    unittest.main()
