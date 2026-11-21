"""The Autoware catalogue (versions.yaml), the selected version, and the
install script's version selection.

    python3 -m unittest discover -s setup/tests

The install script runs only with --dry-run, against stub dpkg-query,
apt-get and sudo on PATH; a real sudo or apt is never reached (the sudo stub
fails the test if it is called).
"""

from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path

SETUP = Path(__file__).resolve().parents[1]
REPO = SETUP.parent
sys.path.insert(0, str(SETUP))

from golfcart_setup import autoware  # noqa: E402

INSTALL = SETUP / "scripts" / "install-autoware-debian.sh"


class ParseTest(unittest.TestCase):
    def test_nested_scalars_comments_quotes(self) -> None:
        data = autoware.parse(textwrap.dedent("""\
            # head
            a:
              "1.5.0":            # trailing comment
                release: "1.5.0-3"
                url: 'x#y'
              plain: bare value
            b: 1
            """))
        self.assertEqual(data, {"a": {"1.5.0": {"release": "1.5.0-3", "url": "x#y"},
                                      "plain": "bare value"}, "b": "1"})

    def test_rejects_lists_and_duplicates(self) -> None:
        with self.assertRaises(autoware.CatalogueError):
            autoware.parse("a:\n  - x\n")
        with self.assertRaises(autoware.CatalogueError):
            autoware.parse("a: 1\na: 2\n")
        with self.assertRaises(autoware.CatalogueError):
            autoware.parse("a: [1, 2]\n")

    def test_agrees_with_pyyaml(self) -> None:
        try:
            import yaml
        except ImportError:
            self.skipTest("PyYAML not installed")
        text = autoware.CATALOGUE.read_text()
        self.assertEqual(autoware.parse(text), yaml.safe_load(text))


class CatalogueTest(unittest.TestCase):
    def test_repo_catalogue(self) -> None:
        self.assertEqual(autoware.versions(), ["1.5.0", "2.1.0"])
        for ver in autoware.versions():
            for plat in ("ubuntu2204", "jetpack62"):
                r = autoware.release(ver, plat)
                self.assertEqual(r.suffix, ver.replace(".", "-"))
                self.assertTrue(r.release.startswith(ver + "-"))
                self.assertEqual(r.deb, f"autoware-localrepo-{r.suffix}_{r.deb_release}{plat}_all.deb")
                self.assertRegex(r.sha256, r"^[0-9a-f]{64}$")
                self.assertTrue(r.url.endswith(f"/{r.release}/{r.deb}"))

    def test_releases_are_the_supported_ones(self) -> None:
        # 1.5.0-1 collides with any second version; 2.1.0 is Humble, not Jazzy.
        self.assertEqual(autoware.release("1.5.0", "ubuntu2204").release, "1.5.0-humble-5")
        self.assertEqual(autoware.release("2.1.0", "jetpack62").release, "2.1.0-1")

    def test_unknown_version_and_platform(self) -> None:
        with self.assertRaisesRegex(autoware.CatalogueError, "not in versions.yaml"):
            autoware.release("1.7.1", "ubuntu2204")
        with self.assertRaisesRegex(autoware.CatalogueError, "no sbsa deb"):
            autoware.release("2.1.0", "sbsa")

    def test_bad_entry(self) -> None:
        with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as f:
            f.write('autoware:\n  "2.1.0":\n    release: "1.5.0-3"\n    suffix: "2-1-0"\n'
                    '    platforms:\n      x: y\n')
        self.addCleanup(os.unlink, f.name)
        with self.assertRaisesRegex(autoware.CatalogueError, "not a 2.1.0 release"):
            autoware.load(Path(f.name))

    def test_shell_output(self) -> None:
        out = autoware.release("2.1.0", "jetpack62").shell()
        env = subprocess.run(["bash", "-c", out + 'printf "%s|%s" "$AW_LOCALREPO_VERSION" "$AW_URL"'],
                             capture_output=True, text=True, check=True).stdout
        ver, url = env.split("|")
        self.assertEqual(ver, "2.1.0-1jetpack62")
        self.assertIn("/releases/download/2.1.0-1/", url)

    def test_distro_tag_is_not_the_deb_revision(self) -> None:
        r = autoware.release("1.5.0", "jetpack62")
        self.assertEqual(r.release, "1.5.0-humble-5")
        self.assertEqual(r.deb_release, "1.5.0-5")
        self.assertEqual(r.localrepo_deb_version, "1.5.0-5jetpack62")
        self.assertIn("/releases/download/1.5.0-humble-5/", r.url)
        env = subprocess.run(["bash", "-c", r.shell() + 'printf "%s" "$AW_DEB_RELEASE"'],
                             capture_output=True, text=True, check=True).stdout
        self.assertEqual(env, "1.5.0-5")


class SelectedVersionTest(unittest.TestCase):
    def test_env_wins(self) -> None:
        env = dict(os.environ, GOLFCART_AUTOWARE_VERSION="2.1.0")
        self.assertEqual(autoware.selected_version(env), "2.1.0")

    def test_default_is_runtime_conf(self) -> None:
        env = {k: v for k, v in os.environ.items() if k != "GOLFCART_AUTOWARE_VERSION"}
        if (REPO / "config" / "autoware-version").is_file():
            self.skipTest("this host pins config/autoware-version")
        self.assertEqual(autoware.selected_version(env), "1.5.0")

    def test_garbage_falls_back(self) -> None:
        env = dict(os.environ, GOLFCART_AUTOWARE_VERSION="latest")
        self.assertEqual(autoware.selected_version(env), "1.5.0")


class InstallScriptDryRunTest(unittest.TestCase):
    """install-autoware-debian.sh --dry-run against stubbed package tools."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.bin = Path(self.tmp.name) / "bin"
        self.bin.mkdir()
        self.sudo_log = Path(self.tmp.name) / "sudo.log"
        # dpkg-query: STUB_PKGS="pkg=version pkg=version"
        self._stub("dpkg-query", """\
            pkg="${@: -1}"
            for kv in ${STUB_PKGS:-}; do
                [ "${kv%%=*}" = "$pkg" ] && { echo "ii  ${kv#*=}"; exit 0; }
            done
            exit 1
            """)
        self._stub("apt-get", 'echo "Inst something"; exit 0\n')
        self._stub("sudo", f'echo "$@" >> {self.sudo_log}; exit 99\n')

    def _stub(self, name: str, body: str) -> None:
        p = self.bin / name
        p.write_text("#!/bin/bash\n" + textwrap.dedent(body))
        p.chmod(0o755)

    def run_script(self, *args: str, pkgs: str = "", version: str | None = None,
                   platform: str = "ubuntu2204") -> subprocess.CompletedProcess:
        env = dict(os.environ, PATH=f"{self.bin}:{os.environ['PATH']}",
                   STUB_PKGS=pkgs, AUTOWARE_PLATFORM=platform,
                   DATA_DIR=self.tmp.name)
        env.pop("GOLFCART_AUTOWARE_VERSION", None)
        if version:
            env["GOLFCART_AUTOWARE_VERSION"] = version
        res = subprocess.run(["bash", str(INSTALL), *args], capture_output=True,
                             text=True, env=env, check=False)
        self.assertFalse(self.sudo_log.exists(), f"sudo was called: {self.sudo_log.read_text()}"
                         if self.sudo_log.exists() else "")
        return res

    def test_fresh_install_plan_follows_version_and_platform(self) -> None:
        res = self.run_script("2.1.0", "--dry-run", platform="jetpack62")
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("localrepo 2.1.0-1 (jetpack62)", res.stdout)
        self.assertIn("releases/download/2.1.0-1/autoware-localrepo-2-1-0_2.1.0-1jetpack62_all.deb",
                      res.stdout)
        self.assertIn("/usr/share/autoware/2.1.0/setup-prerequisites.sh", res.stdout)
        self.assertIn("sudo apt install autoware-full-2-1-0", res.stdout)

    def test_default_version_is_the_selected_one(self) -> None:
        res = self.run_script("--dry-run", version="2.1.0")
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("Autoware 2.1.0: localrepo 2.1.0-1", res.stdout)
        res = self.run_script("--dry-run", version="1.5.0")
        self.assertIn("Autoware 1.5.0: localrepo 1.5.0-humble-5", res.stdout)

    def test_older_revision_is_seen_and_needs_reinstall(self) -> None:
        pkgs = "autoware-localrepo-1-5-0=1.5.0-1ubuntu2204 autoware-full-1-5-0=1.5.0-1"
        res = self.run_script("1.5.0", "--dry-run", pkgs=pkgs)
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("(older)", res.stdout)
        self.assertIn("--reinstall", res.stderr)
        self.assertNotIn("already installed", res.stdout)
        res = self.run_script("1.5.0", "--dry-run", "--reinstall", pkgs=pkgs)
        self.assertIn("uninstall-autoware.sh -y", res.stdout)
        self.assertIn("sudo apt install", res.stdout)

    def test_older_revision_refused_without_reinstall(self) -> None:
        pkgs = "autoware-localrepo-1-5-0=1.5.0-1ubuntu2204 autoware-full-1-5-0=1.5.0-1"
        res = self.run_script("1.5.0", pkgs=pkgs)
        self.assertEqual(res.returncode, 1)
        self.assertIn("--reinstall", res.stderr)

    def test_newer_revision_is_kept(self) -> None:
        pkgs = "autoware-localrepo-2-1-0=2.1.0-2ubuntu2204"
        res = self.run_script("2.1.0", "--dry-run", pkgs=pkgs)
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("(newer)", res.stdout)
        self.assertIn("keep autoware-localrepo-2-1-0 2.1.0-2ubuntu2204", res.stdout)

    def test_current_and_installed_is_skipped(self) -> None:
        if not Path("/opt/autoware/2.1.0/setup.bash").is_file():
            self.skipTest("needs /opt/autoware/2.1.0/setup.bash")
        pkgs = "autoware-localrepo-2-1-0=2.1.0-1ubuntu2204 autoware-full-2-1-0=2.1.0-1"
        res = self.run_script("2.1.0", "--dry-run", pkgs=pkgs)
        self.assertEqual(res.returncode, 0, res.stderr)
        self.assertIn("already installed; nothing to do", res.stdout)

    def test_refuses_a_plan_that_removes_another_version(self) -> None:
        self._stub("apt-get", 'echo "Remv ros-humble-autoware-core-1-5-0 [0.48.0]"; exit 0\n')
        pkgs = "autoware-localrepo-2-1-0=2.1.0-1ubuntu2204"
        res = self.run_script("2.1.0", "--dry-run", pkgs=pkgs)
        self.assertIn("would remove packages of another Autoware version", res.stderr)

    def test_unknown_version(self) -> None:
        res = self.run_script("1.7.1", "--dry-run")
        self.assertEqual(res.returncode, 2)
        self.assertIn("not in versions.yaml", res.stderr)


class RegistryTest(unittest.TestCase):
    def test_version_bound_steps_carry_the_version(self) -> None:
        env = dict(os.environ, GOLFCART_AUTOWARE_VERSION="2.1.0")
        code = textwrap.dedent("""\
            import sys; sys.path.insert(0, sys.argv[1])
            from golfcart_setup.registry import BY_ID
            for i in ("autoware-debian", "autoware-data", "tensorrt-engines", "rviz-theme"):
                print(i, " ".join(BY_ID[i].run))
            """)
        out = subprocess.run([sys.executable, "-c", code, str(SETUP)], env=env,
                             capture_output=True, text=True, check=True).stdout
        lines = dict(line.split(" ", 1) for line in out.splitlines() if line[:1].isalpha()
                     and line.split(" ", 1)[0] in {"autoware-debian", "autoware-data",
                                                   "tensorrt-engines", "rviz-theme"})
        self.assertTrue(lines["autoware-debian"].endswith("install-autoware-debian.sh 2.1.0"))
        self.assertIn("GOLFCART_AUTOWARE_VERSION=2.1.0", lines["autoware-data"])
        self.assertIn("GOLFCART_AUTOWARE_VERSION=2.1.0", lines["rviz-theme"])
        self.assertIn("/opt/autoware/2.1.0/setup.bash", out)
        self.assertNotIn("/opt/autoware/1.5.0", out)


if __name__ == "__main__":
    unittest.main()
