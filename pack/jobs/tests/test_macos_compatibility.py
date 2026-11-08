"""macOS launcher minimum: real preflight checks with synthetic external probes."""
from pathlib import Path
from unittest.mock import patch

from jobcase import JobCase
import ipa
import toolchain


class MacOSCompatibilityTests(JobCase):
    def preflight(self, *, machine="arm64", version="26.0", sdk=True, system="Darwin"):
        # Mock external probes only; preflight's checks, code mapping and
        # Context.describe_failure remain production code. No Apple tools run.
        developer = self.root / "synthetic-Xcode/Contents/Developer"
        (developer / "usr/bin").mkdir(parents=True, exist_ok=True)
        (developer / "usr/bin/xcodebuild").touch()
        self.c.r["developerDir"] = str(developer)
        def probe(c, args, timeout=15):
            return True, "Apple metal version fixture" if "metal" in args else "10.0.403"
        with patch("platform.system", return_value=system), \
             patch("platform.machine", return_value=machine), \
             patch("platform.mac_ver", return_value=(version, (), "")), \
             patch.object(toolchain, "probe", side_effect=probe), \
             patch.object(toolchain, "reader", return_value=Path("synthetic-reader.dll")), \
             patch.object(toolchain, "input_interface", return_value=(True, "fixture")), \
             patch.object(self.c, "require_source"), \
             patch.object(ipa, "dotnet_sdk", return_value=(developer, developer / "dotnet") if sdk else (None, None)):
            return {row["name"]: row for row in toolchain.preflight(self.c)["checks"]}

    def test_macos15_prepare_launch_minimum_and_unsupported_hosts(self):
        for system, version, expected in [("Darwin", "14.7", False), ("Darwin", "15.0", True),
                                          ("Darwin", "15.7.7", True), ("Darwin", "25.0", True),
                                          ("Darwin", "26.0", True), ("Linux", "26.0", False),
                                          ("Windows", "26.0", False)]:
            with self.subTest(system=system, version=version):
                row = self.preflight(system=system, version=version)["macOS"]
                self.assertEqual(row["ok"], expected)
                self.assertEqual(row["requiredFor"], ["prepare", "launch"])
                if not expected:
                    self.assertEqual(row["diagnostic"]["code"], "os_unsupported")
