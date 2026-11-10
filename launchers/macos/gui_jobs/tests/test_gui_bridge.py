"""Frontend integration checks use tiny source scripts, no SDK/network/game data."""
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[4]
ENTRY = ROOT / "launchers/macos/gui_jobs/main.py"
spec = importlib.util.spec_from_file_location("gui_bridge", ENTRY)
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="s2arm-gui-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.source = self.root / "source with spaces"
        self.source.mkdir()
        self.request = dict(schema=1, taskId="fixture", operation="platformBuild", target="ohos",
                            privateRoot=str(self.root / "private"), engineDir=str(self.source),
                            developerDir="/fixture/Xcode.app/Contents/Developer",
                            inputDir=str(self.root / "games $literal"), keysPath=str(self.root / "prod.keys"),
                            fontsDir=str(self.root / "fonts"))

    def context(self, **overrides):
        self.request.update(overrides)
        return bridge.Context(self.request)

    def script(self, target, text):
        entry = self.source / bridge.ENTRIES[target]
        entry.parent.mkdir(parents=True, exist_ok=True)
        entry.write_text(text)

    def test_ohos_dispatch_calls_existing_entry_with_literal_paths(self):
        args_file = self.root / "args"
        self.script("ohos", 'printf "%s\\n" "$@" > "' + str(args_file) + '"\nmkdir -p "$1"\n')
        c = self.context(sourceDir="/legacy/source", outputDir="/legacy/output")
        with patch.object(bridge, "environment_checks", return_value=[dict(ok=True)]):
            result = bridge.dispatch_build(c)
        self.assertEqual(args_file.read_text().splitlines(), [result["outputPath"]])
        self.assertTrue(Path(result["outputPath"]).is_relative_to(c.private / "exports/ohos"))
        self.assertEqual(bridge.platform_source(c), self.source)

    def test_android_dispatch_uses_selected_game_adapter(self):
        self.script("android", "exit 0\n")
        c = self.context(target="android", gameId="0100000000000000")
        with patch.object(bridge, "environment_checks", return_value=[dict(ok=True)]), \
             patch.object(bridge, "android_build", return_value=dict(apk="a", resources="r")) as build:
            result = bridge.dispatch_build(c)
        build.assert_called_once_with(c)
        self.assertEqual(c.r["gameId"], "0100000000000000")
        self.assertEqual(result, dict(apk="a", resources="r"))

    def test_missing_entry_or_ndk_is_unavailable_without_downloading(self):
        c = self.context(target="ohos")
        # This fixture models an absent SDK, even on a developer Mac with DevEco.
        with patch.object(bridge, "ohos_ndk", return_value=None), \
             patch.object(c, "run", side_effect=AssertionError("checks must not download or compile")):
            checks = bridge.environment_checks(c)
        self.assertFalse(checks[0]["ok"])
        self.assertFalse(checks[1]["ok"])
        with self.assertRaises(bridge.Failure):
            bridge.dispatch_build(c)
        self.assertFalse((c.private / "platform-sources").exists())

    def test_installed_ndk_is_reported_without_downloading_or_compiling(self):
        c = self.context(target="ohos")
        ndk = self.root / "synthetic-ndk"
        with patch.object(bridge, "ohos_ndk", return_value=ndk), \
             patch.object(c, "run", side_effect=AssertionError("checks must not download or compile")):
            checks = bridge.environment_checks(c)
        self.assertTrue(checks[1]["ok"])

    def test_download_is_explicit_selects_only_requested_branch_and_never_overwrites(self):
        c = self.context(target="ohos", operation="platformSource")
        calls = []

        def clone(args, **_):
            calls.append(args)
            entry = Path(args[-1]) / bridge.ENTRIES["ohos"]
            entry.parent.mkdir(parents=True)
            entry.touch()

        with patch.object(c, "run", side_effect=clone):
            result = bridge.download_source(c)
        self.assertIn("ohos/harmony-port", calls[0])
        self.assertIn("--single-branch", calls[0])
        self.assertTrue(result["componentsReady"])
        self.assertEqual(bridge.platform_source(c), c.private / "platform-sources/ohos")
        with patch.object(c, "run", side_effect=AssertionError("must not update existing checkout")):
            self.assertTrue(bridge.download_source(c)["componentsReady"])

    def test_existing_engine_feature_is_reused_without_downloading(self):
        self.script("android", "exit 0\n")
        c = self.context(target="android")
        with patch.object(c, "run", side_effect=AssertionError("must reuse built-in feature")):
            self.assertTrue(bridge.download_source(c)["componentsReady"])
        self.assertFalse((c.private / "platform-sources").exists())

    def test_old_sdk_selection_does_not_override_managed_toolchain(self):
        c = self.context(target="ohos", ndkDir="/legacy/ndk")
        ndk = c.private / "toolchains/ohos/native"
        (ndk / "llvm/bin").mkdir(parents=True)
        (ndk / "sysroot").mkdir()
        (ndk / "llvm/bin/clang").touch(mode=0o700)
        with patch.dict(os.environ, {"OHOS_NDK": ""}):
            self.assertEqual(bridge.ohos_ndk(c), ndk)

    def test_packaged_bridge_uses_existing_shared_jobs(self):
        resources = self.root / "Resources"
        (resources / "GUIJobs").mkdir(parents=True)
        (resources / "Jobs").mkdir()
        import shutil
        shutil.copy2(ENTRY, resources / "GUIJobs/main.py")
        # 与 launchers/macos/build_app.py 一样：整份 pack/jobs 的 .py + tools/redact.py 进 Resources/Jobs（只拷 core.py 时 core 依赖的 errors / redact 缺失）
        for f in (ROOT / "pack/jobs").glob("*.py"):
            shutil.copy2(f, resources / "Jobs" / f.name)
        shutil.copy2(ROOT / "tools/redact.py", resources / "Jobs/redact.py")
        result = subprocess.run([sys.executable, "-B", "-I", str(resources / "GUIJobs/main.py"), "--help"],
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_android_adapter_failure_is_not_reported_as_completed(self):
        self.script("android", "exit 0\n")
        c = self.context(target="android")
        with patch.object(bridge, "environment_checks", return_value=[dict(ok=True)]), \
             patch.object(bridge, "android_build", side_effect=bridge.Failure("缺少 APK")):
            with self.assertRaises(bridge.Failure):
                bridge.dispatch_build(c)

    def test_real_cli_cancels_its_source_script_and_records_target(self):
        ndk = self.root / "private/toolchains/ohos/native"
        (ndk / "llvm/bin").mkdir(parents=True)
        (ndk / "sysroot").mkdir()
        (ndk / "llvm/bin/clang").write_text("#!/bin/sh\nexit 0\n")
        (ndk / "llvm/bin/clang").chmod(0o700)
        marker = self.root / "child-pid"
        self.script("ohos", 'echo $$ > "' + str(marker) + '"\nwhile true; do sleep 1; done\n')
        self.request.update(target="ohos")
        import shutil
        (self.source / "tools").mkdir()
        shutil.copy2(ROOT / "tools/safe_killpg.sh", self.source / "tools/safe_killpg.sh")
        request_file = self.root / "request.json"
        request_file.write_text(json.dumps(self.request))
        request_file.chmod(0o600)
        with (self.root / "events").open("w+") as events, (self.root / "stderr").open("w+") as errors:
            process = subprocess.Popen([sys.executable, "-B", "-I", str(ENTRY), "--request", str(request_file)], stdout=events, stderr=errors)
            try:
                deadline = time.monotonic() + 10
                while not marker.exists() and process.poll() is None and time.monotonic() < deadline:
                    time.sleep(.05)
                self.assertTrue(marker.exists())
                child = int(marker.read_text())
                process.send_signal(signal.SIGTERM)
                self.assertEqual(process.wait(timeout=12), 130)
                with self.assertRaises(ProcessLookupError):
                    os.kill(child, 0)
                events.seek(0)
                terminal = json.loads(events.read().splitlines()[-1])
                self.assertEqual(terminal["state"], "cancelled")
                saved = json.loads((Path(self.request["privateRoot"]) / "logs/jobs/fixture.json").read_text())   # 没有游戏库：任务记录退回 <私有目录>/logs/jobs
                self.assertEqual(saved["target"], "ohos")
                self.assertEqual(saved["state"], "cancelled")
            finally:
                if process.poll() is None:
                    process.terminate()
                    process.wait(timeout=12)


if __name__ == "__main__":
    unittest.main()
