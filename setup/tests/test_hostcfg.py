"""setup/host: manifest parsing, secret stripping, allow-list, fstab lines.

    python3 -m unittest discover -s setup/tests

Nothing here reads or writes /etc: readers and the installer are fakes, and
the tree is a temporary directory.
"""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SETUP = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SETUP))

from golfcart_setup import hostcfg as h  # noqa: E402
from golfcart_setup.registry import BY_ID  # noqa: E402

NM = h.StripProfile(
    sections=("vpn-secrets",),
    keys=("psk", "password", "password-raw", "*-password", "*-password-raw",
          "wep-key*", "private-key*", "*-private-key*", "preshared-key", "pin"),
    keep=("*-flags", "wep-key-type"),
    volatile=("timestamp",),
)

WIFI = """\
[connection]
id=Home
uuid=0b3c5d1e-0000-4000-8000-000000000001
type=wifi
timestamp=1785738072

[wifi]
mode=infrastructure
ssid=Home

[wifi-security]
key-mgmt=wpa-psk
psk=hunter2-wifi
psk-flags=0
wep-key0=abcdef
wep-key-type=1

[802-1x]
eap=peap;
identity=user
password=eap-secret
private-key=/home/u/key.pem
private-key-password=pk-secret
phase2-private-key-password=p2-secret

[ipv4]
method=auto
"""

VPN = """\
[connection]
id=lab442VPN
uuid=0b3c5d1e-0000-4000-8000-000000000002
type=vpn

[vpn]
service-type=org.freedesktop.NetworkManager.openvpn
password-flags=0
remote=vpn.example.org

[vpn-secrets]
password=vpn-secret
cert-pass=other-secret

[ipv4]
method=auto
"""

SECRETS = ("hunter2-wifi", "abcdef", "eap-secret", "pk-secret", "p2-secret",
           "vpn-secret", "other-secret", "/home/u/key.pem")


def entry(**kw) -> dict:
    base = {"repo": "master/etc/x.conf", "target": "/etc/x.conf", "roles": ["master"]}
    base.update(kw)
    return base


class ManifestParsing(unittest.TestCase):
    def test_real_manifest_loads(self) -> None:
        m = h.load_manifest()
        self.assertTrue(m.files)
        for e in m.files:
            self.assertTrue(e.target.startswith("/etc/"), e.target)
            if e.target.endswith(".nmconnection"):
                self.assertEqual(e.strip, "nmconnection")
        # linuxptp is the master's; the orin only gets it disabled.
        ptp = [e for e in m.files if e.step == "linuxptp"]
        self.assertTrue(ptp)
        self.assertTrue(all(e.roles == ("master",) for e in ptp))
        orin = m.for_role("orin")
        self.assertIn("ptp4l.service", [u for d in orin.disabled for u in d.units])
        self.assertEqual(m.for_role("master").disabled, [])

    def test_real_manifest_steps_exist(self) -> None:
        m = h.load_manifest()
        for e in m.files + m.lines:
            self.assertIn(e.step, BY_ID, e.target)

    def test_repo_must_mirror_target(self) -> None:
        with self.assertRaises(h.ManifestError):
            h.parse_manifest({"files": [entry(repo="master/etc/y.conf")]})

    def test_role_dir_must_match_roles(self) -> None:
        with self.assertRaises(h.ManifestError):
            h.parse_manifest({"files": [entry(roles=["orin"])]})

    def test_common_may_name_both(self) -> None:
        m = h.parse_manifest({"files": [entry(repo="common/etc/x.conf",
                                              roles=["master", "orin"])]})
        self.assertEqual(m.files[0].roles, ("master", "orin"))

    def test_unknown_reload_rejected(self) -> None:
        with self.assertRaises(h.ManifestError):
            h.parse_manifest({"files": [entry(reload=["reboot"])]})

    def test_enable_reload_accepted(self) -> None:
        m = h.parse_manifest({"files": [entry(reload=["enable:foo.service"])]})
        self.assertEqual(m.files[0].reload, ("enable:foo.service",))

    def test_nmconnection_needs_strip(self) -> None:
        with self.assertRaises(h.ManifestError):
            h.parse_manifest({"files": [entry(repo="master/etc/a.nmconnection",
                                              target="/etc/a.nmconnection")]})

    def test_bad_mode_rejected(self) -> None:
        with self.assertRaises(h.ManifestError):
            h.parse_manifest({"files": [entry(mode="rw-r--r--")]})

    def test_line_must_match_its_regex(self) -> None:
        with self.assertRaises(h.ManifestError):
            h.parse_manifest({"lines": [{"target": "/etc/fstab", "roles": ["master"],
                                         "match": r"^\S+\s+/mnt/other\s",
                                         "line": "UUID=1 /mnt/external ext4 defaults"}]})


class Stripping(unittest.TestCase):
    def test_wifi_secrets_removed(self) -> None:
        kept, removed = h.strip_text(WIFI, NM)
        for s in SECRETS:
            self.assertNotIn(s, kept)
        self.assertIn("psk-flags=0", kept)          # flags are not secrets
        self.assertIn("wep-key-type=1", kept)
        self.assertIn("uuid=", kept)                # uuid stays
        self.assertNotIn("timestamp=", kept)        # volatile goes
        self.assertEqual(h.secret_lines(kept), [])
        self.assertEqual(len(removed), 7)

    def test_vpn_secrets_section_removed(self) -> None:
        kept, removed = h.strip_text(VPN, NM)
        self.assertNotIn("[vpn-secrets]", kept)
        self.assertNotIn("vpn-secret", kept)
        self.assertNotIn("other-secret", kept)      # whole section, any key
        self.assertIn("password-flags=0", kept)
        self.assertIn("[ipv4]", kept)
        self.assertEqual(h.secret_lines(kept), [])

    def test_merge_puts_host_secrets_back(self) -> None:
        kept, removed = h.strip_text(WIFI, NM)
        merged = h.merge_removed(kept, removed)
        self.assertEqual(h.strip_text(merged, NM)[0], kept)
        self.assertIn("psk=hunter2-wifi", merged)
        # into its own section, not the end of the file
        sec = merged.split("[wifi-security]")[1].split("[")[0]
        self.assertIn("psk=hunter2-wifi", sec)

    def test_merge_recreates_dropped_section(self) -> None:
        kept, removed = h.strip_text(VPN, NM)
        merged = h.merge_removed(kept, removed)
        self.assertIn("[vpn-secrets]\npassword=vpn-secret\ncert-pass=other-secret\n", merged)

    def test_no_profile_is_identity(self) -> None:
        self.assertEqual(h.strip_text(WIFI, None), (WIFI, []))

    def test_scan_finds_leftovers(self) -> None:
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / "master/etc").mkdir(parents=True)
            (root / "master/etc/ok.nmconnection").write_text(h.strip_text(WIFI, NM)[0])
            self.assertEqual(h.scan_tree(root), [])
            (root / "master/etc/bad.nmconnection").write_text(WIFI)
            hits = h.scan_tree(root)
            self.assertTrue(any("hunter2-wifi" in x for x in hits))

    def test_real_tree_is_clean(self) -> None:
        self.assertEqual(h.scan_tree(), [])


class FakeReader:
    name = "fake"

    def __init__(self, files: dict[str, tuple[str | None, str, str]], units=None):
        self.files = files
        self.units = units or {}

    def read(self, paths):
        out = {}
        for p in paths:
            if p in self.files:
                text, mode, owner = self.files[p]
                out[p] = h.Live(p, True, text, mode, owner)
            else:
                out[p] = h.Live(p, False)
        return out

    def unit_states(self, units):
        return {u: self.units.get(u, "not-found/inactive") for u in units}


class FakeInstaller(h.Installer):
    def __init__(self):
        super().__init__(dry_run=True, log=lambda *_: None)
        self.puts: dict[str, str] = {}
        self.ran: list[list[str]] = []

    def put(self, target, text, mode, owner):
        self.puts[target] = text

    def run(self, argv, check=True):
        self.ran.append(argv)
        return 0


class TreeCase(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        p = mock.patch.object(h, "HOST_DIR", self.root)
        p.start()
        self.addCleanup(p.stop)

    def manifest(self) -> h.Manifest:
        nm = self.root / "master/etc/NetworkManager/system-connections/cart.nmconnection"
        nm.parent.mkdir(parents=True)
        nm.write_text(h.strip_text(WIFI, NM)[0])
        return h.parse_manifest({
            "strip_profiles": {"nmconnection": {
                "sections": list(NM.sections), "keys": list(NM.keys),
                "keep": list(NM.keep), "volatile": list(NM.volatile)}},
            "files": [{
                "repo": "master/etc/NetworkManager/system-connections/cart.nmconnection",
                "target": "/etc/NetworkManager/system-connections/cart.nmconnection",
                "roles": ["master"], "mode": "0600", "strip": "nmconnection",
                "reload": ["nmcli-reload"],
                "legacy": ["/etc/NetworkManager/system-connections/old name.nmconnection"],
            }],
            "lines": [{"target": "/etc/fstab", "roles": ["master"],
                       "match": r"^\S+\s+/mnt/external\s",
                       "line": "UUID=abc\t/mnt/external\text4\tnofail 0 0"}],
            "units_disabled": [{"units": ["ptp4l.service"], "roles": ["orin"]}],
        })


class AllowList(TreeCase):
    def test_capture_refuses_unlisted(self) -> None:
        m = self.manifest()
        with self.assertRaises(h.NotAllowed):
            m.check_allowed(["/etc/NetworkManager/system-connections/215VPN.nmconnection"])

    def test_capture_accepts_listed_and_legacy(self) -> None:
        m = self.manifest()
        m.check_allowed(["/etc/NetworkManager/system-connections/cart.nmconnection",
                         "/etc/NetworkManager/system-connections/old name.nmconnection"])

    def test_cli_capture_refuses(self) -> None:
        m = self.manifest()
        with mock.patch.object(h, "load_manifest", return_value=m), \
             mock.patch.object(h.model, "read_host_role", return_value="master"):
            rc = h.main(["capture", "/etc/shadow"])
        self.assertEqual(rc, 2)


class Compare(TreeCase):
    T = "/etc/NetworkManager/system-connections/cart.nmconnection"

    def test_secrets_on_host_do_not_count_as_drift(self) -> None:
        m = self.manifest()
        live = FakeReader({self.T: (WIFI, "600", "root:root")}).read([self.T])
        res = h.compare_file(m.files[0], live, NM)
        self.assertEqual(res.status, h.IDENTICAL)
        self.assertTrue(any("secret" in d for d in res.detail))

    def test_mode_drift(self) -> None:
        m = self.manifest()
        live = FakeReader({self.T: (WIFI, "644", "root:root")}).read([self.T])
        self.assertEqual(h.compare_file(m.files[0], live, NM).status, h.DIFFERS)

    def test_diff_never_shows_secrets(self) -> None:
        m = self.manifest()
        changed = WIFI.replace("method=auto", "method=manual")
        live = FakeReader({self.T: (changed, "600", "root:root")}).read([self.T])
        res = h.compare_file(m.files[0], live, NM)
        self.assertEqual(res.status, h.DIFFERS)
        for s in SECRETS:
            self.assertNotIn(s, res.diff)

    def test_unreadable(self) -> None:
        m = self.manifest()
        live = FakeReader({self.T: (None, "600", "root:root")}).read([self.T])
        self.assertEqual(h.compare_file(m.files[0], live, NM).status, h.UNREADABLE)


class Install(TreeCase):
    T = Compare.T
    OLD = "/etc/NetworkManager/system-connections/old name.nmconnection"
    FSTAB = "UUID=6AD7 /boot/efi vfat defaults 0 1\n"

    def test_idempotent_when_identical(self) -> None:
        m = self.manifest()
        inst = FakeInstaller()
        reader = FakeReader({
            self.T: (WIFI, "600", "root:root"),
            "/etc/fstab": (self.FSTAB + "UUID=abc /mnt/external ext4 nofail 0 0\n",
                           "644", "root:root")})
        self.assertEqual(h.install(m.for_role("master"), inst, reader=reader), 0)
        self.assertEqual(inst.puts, {})
        self.assertEqual(inst.actions, [])

    def test_rewrite_keeps_host_secrets_and_renames_legacy(self) -> None:
        m = self.manifest()
        inst = FakeInstaller()
        old = WIFI.replace("method=auto", "method=manual")
        reader = FakeReader({self.OLD: (old, "600", "root:root"),
                             "/etc/fstab": (self.FSTAB, "644", "root:root")})
        h.install(m.for_role("master"), inst, reader=reader)
        written = inst.puts[self.T]
        self.assertIn("psk=hunter2-wifi", written)
        self.assertIn("method=auto", written)
        self.assertIn(["rm", "-f", "--", self.OLD], inst.ran)
        self.assertIn("nmcli-reload", inst.actions)

    def test_orin_disables_ptp(self) -> None:
        m = self.manifest()
        inst = FakeInstaller()
        reader = FakeReader({}, units={"ptp4l.service": "enabled/failed"})
        h.install(m.for_role("orin"), inst, reader=reader)
        self.assertIn(["systemctl", "disable", "--now", "ptp4l.service"], inst.ran)

    def test_orin_leaves_absent_unit_alone(self) -> None:
        m = self.manifest()
        inst = FakeInstaller()
        h.install(m.for_role("orin"), inst, reader=FakeReader({}))
        self.assertEqual(inst.ran, [])


class EnsureLine(unittest.TestCase):
    E = h.LineEntry(target="/etc/fstab", roles=("master",),
                    match=r"^\S+\s+/mnt/external\s",
                    line="UUID=new\t/mnt/external\text4\tnofail")

    def test_appends_when_absent(self) -> None:
        out = h.ensure_line("/dev/root / ext4 defaults 0 1\n", self.E)
        self.assertEqual(out.splitlines()[-1], self.E.line)

    def test_replaces_in_place(self) -> None:
        text = "a / ext4 d 0 1\nUUID=old /mnt/external ext4 defaults\nb /boot vfat d 0 1\n"
        out = h.ensure_line(text, self.E).splitlines()
        self.assertEqual(out[1], self.E.line)
        self.assertEqual(len(out), 3)

    def test_keeps_equivalent_whitespace(self) -> None:
        text = "UUID=new  /mnt/external   ext4 nofail\n"
        self.assertEqual(h.ensure_line(text, self.E), text)

    def test_dedupes(self) -> None:
        text = "UUID=x /mnt/external ext4 d\nUUID=y /mnt/external ext4 d\n"
        out = h.ensure_line(text, self.E).splitlines()
        self.assertEqual(out, [self.E.line])

    def test_compare_line(self) -> None:
        live = h.Live("/etc/fstab", True, "UUID=new /mnt/external ext4 nofail\n", "644", "root:root")
        self.assertEqual(h.compare_line(self.E, live).status, h.IDENTICAL)
        live.text = "/dev/root / ext4 d 0 1\n"
        self.assertEqual(h.compare_line(self.E, live).status, h.MISSING_HOST)


class Steps(unittest.TestCase):
    def test_host_config_and_linuxptp_roles(self) -> None:
        self.assertEqual(BY_ID["host-config"].roles, ("master", "orin"))
        self.assertEqual(BY_ID["linuxptp"].roles, ("master",))
        self.assertEqual(BY_ID["linuxptp"].requires.role, ("master",))
        self.assertFalse(BY_ID["linuxptp"].default_for("vehicle", "orin"))
        self.assertTrue(BY_ID["linuxptp"].default_for("vehicle", "master"))

    def test_tree_edit_makes_step_stale(self) -> None:
        from golfcart_setup.model import Step
        with tempfile.TemporaryDirectory() as d:
            f = Path(d) / "etc" / "x.conf"
            f.parent.mkdir()
            f.write_text("a=1\n")
            step = Step(id="t", label="t", why="", run=["true"], inputs=(d,))
            before = step.digest()
            f.write_text("a=2\n")
            self.assertNotEqual(step.digest(), before)

    def test_moved_steps_hash_their_tree_files(self) -> None:
        for sid in ("host-config", "linuxptp", "hardware-config", "ublox-udev",
                    "chrony-master", "chrony-orin",
                    "cyclonedds-sysctl", "otocam"):
            for item in BY_ID[sid].inputs:
                self.assertTrue(Path(item).exists(), f"{sid}: {item}")


class Absent(unittest.TestCase):
    RULE = "/etc/udev/rules.d/99-old.rules"

    def manifest(self) -> h.Manifest:
        return h.parse_manifest({"files_absent": [
            {"targets": [self.RULE], "roles": ["master"], "reload": ["udev-reload"]}]})

    def test_parse_rejects_relative_path(self) -> None:
        with self.assertRaises(h.ManifestError):
            h.parse_manifest({"files_absent": [{"targets": ["etc/x"], "roles": ["master"]}]})

    def test_install_removes_present_file(self) -> None:
        m = self.manifest().for_role("master")
        inst = FakeInstaller()
        n = h.install(m, inst, FakeReader({self.RULE: ("x\n", "644", "root:root")}),
                      reload=False)
        self.assertEqual(n, 1)
        self.assertIn(["rm", "-f", "--", self.RULE], inst.ran)

    def test_install_leaves_absent_file_alone(self) -> None:
        m = self.manifest().for_role("master")
        inst = FakeInstaller()
        self.assertEqual(h.install(m, inst, FakeReader({}), reload=False), 0)
        self.assertEqual(inst.ran, [])

    def test_other_role_does_not_carry_it(self) -> None:
        self.assertEqual(self.manifest().for_role("orin").absent, [])


class HostnameReload(unittest.TestCase):
    def test_hostname_runs_before_avahi_restart(self) -> None:
        inst = FakeInstaller()
        inst.queue(["restart:avahi-daemon.service", "hostname"])
        inst.reload()
        joined = [" ".join(a) for a in inst.ran]
        hn = next(i for i, a in enumerate(joined) if "hostnamectl" in a)
        rs = next(i for i, a in enumerate(joined) if "restart avahi-daemon" in a)
        self.assertLess(hn, rs)

    def test_manifest_accepts_hostname_reload(self) -> None:
        h.parse_manifest({"files": [{"repo": "master/etc/hostname", "target": "/etc/hostname",
                                     "roles": ["master"], "reload": ["hostname"]}]})

if __name__ == "__main__":
    unittest.main()
