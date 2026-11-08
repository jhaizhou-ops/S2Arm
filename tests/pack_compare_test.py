"""Prove normalization cannot hide resource or executable changes."""
from __future__ import annotations

import copy
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("pack_compare", ROOT / "pack/contracts/compare.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ComparisonTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="s2arm compare ")
        self.root = Path(self.temp.name)
        self.payload = {"Payload/Fixture.app/Info.plist": b"plist fixture", "Payload/Fixture.app/Fixture": b"code fixture",
                        "Payload/Fixture.app/data": b"resource fixture"}
        for side in ("old", "new"):
            folder = self.root / (side + "-resources")
            folder.mkdir()
            (folder / "manifest.json").write_bytes(b'{"fixture":true}')
            (folder / "part.bin").write_bytes(b"asset")
            self.ipa(side)

    def tearDown(self):
        self.temp.cleanup()

    def ipa(self, side, payload=None, timestamp=(2026, 1, 1, 0, 0, 0)):
        with zipfile.ZipFile(self.root / (side + ".ipa"), "w") as archive:
            for name, value in (self.payload if payload is None else payload).items():
                archive.writestr(zipfile.ZipInfo(name, date_time=timestamp), value)

    def compare(self, **options):
        return module.compare(self.root / "old.ipa", self.root / "new.ipa", self.root / "old-resources",
                              self.root / "new-resources", **options)

    def test_equal_bytes_are_equal_without_exclusions(self):
        report = self.compare()
        self.assertTrue(report["equal"])
        self.assertTrue(report["ipa"]["rawEqual"])
        self.assertEqual(report["ipa"]["excluded"], [])

    def test_zip_timestamp_needs_explicit_permission(self):
        self.ipa("new", timestamp=(2026, 2, 2, 0, 0, 0))
        self.assertFalse(self.compare()["equal"])
        report = self.compare(allow_zip_metadata=True)
        self.assertTrue(report["equal"])
        self.assertEqual(len(report["ipa"]["zipMetadataChanged"]), 3)

    def test_resource_content_is_never_excluded(self):
        (self.root / "new-resources/part.bin").write_bytes(b"different")
        report = self.compare(allow_zip_metadata=True, allow_signatures=True)
        self.assertFalse(report["equal"])
        self.assertEqual(report["resources"]["differences"]["changed"], ["part.bin"])

    def test_resource_file_set_and_permissions_are_compared(self):
        (self.root / "new-resources/extra").write_bytes(b"extra")
        (self.root / "new-resources/part.bin").chmod(0o700)
        report = self.compare()
        self.assertFalse(report["equal"])
        self.assertEqual(report["resources"]["differences"]["onlyNew"], ["extra"])
        self.assertEqual(report["resources"]["differences"]["changed"], ["part.bin"])

    def test_ipa_resource_and_code_changes_are_not_signatures(self):
        for name in ("Payload/Fixture.app/Fixture", "Payload/Fixture.app/data"):
            payload = self.payload | {name: b"different"}
            self.ipa("new", payload)
            report = self.compare(allow_zip_metadata=True, allow_signatures=True)
            self.assertFalse(report["equal"])
            self.assertEqual(report["ipa"]["differences"][0]["path"], name)

    def test_only_recognized_signature_envelopes_are_excluded(self):
        name = "Payload/Fixture.app/_CodeSignature/CodeResources"
        self.ipa("old", self.payload | {name: b"old signature"})
        self.ipa("new", self.payload | {name: b"new signature"})
        self.assertFalse(self.compare(allow_zip_metadata=True)["equal"])
        report = self.compare(allow_zip_metadata=True, allow_signatures=True)
        self.assertTrue(report["equal"])
        self.assertEqual([x["path"] for x in report["ipa"]["excluded"]], [name])
        self.ipa("new", self.payload | {name: b"new signature", "Payload/Fixture.app/CodeResources": b"ordinary resource"})
        self.assertFalse(self.compare(allow_zip_metadata=True, allow_signatures=True)["equal"])

    def test_resource_symlink_is_rejected(self):
        (self.root / "new-resources/link").symlink_to(self.root)
        with self.assertRaises(module.ComparisonError):
            self.compare()

    def test_zip_permission_changes_are_not_metadata_exclusions(self):
        with zipfile.ZipFile(self.root / "new.ipa", "w") as archive:
            for name, value in self.payload.items():
                entry = zipfile.ZipInfo(name, date_time=(2026, 1, 1, 0, 0, 0))
                entry.external_attr = 0o100777 << 16
                archive.writestr(entry, value)
        report = self.compare(allow_zip_metadata=True, allow_signatures=True)
        self.assertFalse(report["equal"])
        self.assertTrue(all(item["reason"] == "permissions" for item in report["ipa"]["differences"]))

    def test_invalid_zip_paths_and_duplicates_are_rejected(self):
        for name in ("../escape", "/absolute", "Payload/Fixture.app/../other", "Payload\\Fixture.app\\data"):
            self.ipa("new", self.payload | {name: b"bad"})
            with self.subTest(name=name), self.assertRaises(module.ComparisonError):
                self.compare()
        self.ipa("new")
        with zipfile.ZipFile(self.root / "new.ipa", "a") as archive:
            import warnings
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", UserWarning)
                archive.writestr("Payload/Fixture.app/data", b"duplicate")
        with self.assertRaises(module.ComparisonError):
            self.compare()

    def test_cli_keeps_private_report_outside_inputs(self):
        report = self.root / "result.json"
        command = [sys.executable, "-I", "-B", str(ROOT / "pack/contracts/compare.py"),
                   "--old-ipa", str(self.root / "old.ipa"), "--new-ipa", str(self.root / "new.ipa"),
                   "--old-resources", str(self.root / "old-resources"), "--new-resources", str(self.root / "new-resources")]
        run = subprocess.run(command + ["--report", str(report)], capture_output=True, text=True, timeout=20)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertTrue(json.loads(report.read_text())["equal"])
        self.assertEqual(report.stat().st_mode & 0o777, 0o600)
        run = subprocess.run(command + ["--report", str(self.root / "old-resources/manifest.json")], capture_output=True, text=True, timeout=20)
        self.assertNotEqual(run.returncode, 0)
        self.assertEqual((self.root / "old-resources/manifest.json").read_bytes(), b'{"fixture":true}')

    def test_real_macho_signatures_are_removed_on_copies_only(self):
        if sys.platform != "darwin" or not shutil.which("codesign") or not shutil.which("clang"):
            self.skipTest("Real Mach-O counterexample needs macOS codesign and clang")
        source = self.root / "source.c"
        source.write_text("int main(void) { return 0; }\n")
        binary = self.root / "binary"
        subprocess.run(["clang", str(source), "-o", str(binary)], check=True, capture_output=True, timeout=60)
        payloads = []
        for identifier in ("s2a.fixture.old", "s2a.fixture.new"):
            subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none", "--identifier", identifier, str(binary)],
                           check=True, capture_output=True, timeout=30)
            payloads.append(binary.read_bytes())
        self.assertNotEqual(*payloads)
        before = copy.copy(payloads)
        self.assertEqual(module.unsigned_digest(payloads[0]), module.unsigned_digest(payloads[1]))
        self.assertEqual(payloads, before)
        for side, content in zip(("old", "new"), payloads):
            self.ipa(side, self.payload | {"Payload/Fixture.app/Fixture": content})
        report = self.compare(allow_zip_metadata=True, allow_signatures=True)
        self.assertTrue(report["equal"])
        self.assertEqual(report["ipa"]["excluded"][0]["reason"], "macho_signature_only")
        source.write_text("int main(void) { return 19; }\n")
        subprocess.run(["clang", str(source), "-o", str(binary)], check=True, capture_output=True, timeout=60)
        self.ipa("new", self.payload | {"Payload/Fixture.app/Fixture": binary.read_bytes()})
        self.assertFalse(self.compare(allow_zip_metadata=True, allow_signatures=True)["equal"])


if __name__ == "__main__":
    unittest.main()
