"""Xcode 的 iOS 平台组件自检与一键补（11-07 总指挥：启动器零配置；pack/jobs/toolchain.py ios_platform / download_ios_platform）。
期望按 11-07 两台机器对照写死：本机 Xcode 26.6（iOS SDK 26.5，构建 23F81a）装了运行时 23F77 → 编得过；
mini 同版只装了 iOS 27.1 运行时（24A94425）→ xcodebuild 报「iOS 26.5 is not installed」。配套表（SDKToSimulatorIndexMapping.plist）里 23F81a 只配 23F77。"""
import plistlib
import subprocess
import unittest
from pathlib import Path
from unittest.mock import patch

from jobcase import JobCase
from errors import RECOVERY, log_cause
import toolchain

REAL_RUN = subprocess.run

MINI_LINE = ("{ platform:iOS, id:dvtdevice-DVTiPhonePlaceholder-iphoneos:placeholder, name:Any iOS Device, "
             "error:iOS 26.5 is not installed. Please download and install the platform from Xcode > Settings > Components. }")


class IosPlatform(JobCase):
    def setUp(self):
        super().setUp()
        self.mapping = self.root / "SDKToSimulatorIndexMapping.plist"
        self.mapping.write_bytes(plistlib.dumps([
            dict(sdkIdentifier="iphoneos26.5", sdkBuildUpdate="23F81a", simulatorBuildUpdate="23F77"),
            dict(sdkIdentifier="iphoneos26.5", sdkBuildUpdate="23F73", simulatorBuildUpdate="23F73"),
            dict(sdkIdentifier="iphoneos27.1", sdkBuildUpdate="24A94232", simulatorBuildUpdate="24A94425")]))
        self.sdk = ("26.5", "23F81a")
        self.runtimes = []

    def _probe(self, c, args, timeout=15):
        if args[:3] == ["xcrun", "--sdk", "iphoneos"]:
            return True, self.sdk[0]
        if args[:2] == ["xcodebuild", "-version"]:
            return True, self.sdk[1]
        if "metal" in args:
            return True, "Apple metal version fixture"
        return True, "10.0.403"

    def _run(self, args, **kw):
        if list(args[:4]) == ["xcrun", "simctl", "list", "runtimes"]:
            import json
            rows = [dict(platform="iOS", isAvailable=True, version=v, buildversion=b) for v, b in self.runtimes]
            return subprocess.CompletedProcess(args, 0, json.dumps({"runtimes": rows}), "")
        return REAL_RUN(args, **kw)   # 其余（df 等）照真跑

    def judge(self):
        with patch.object(toolchain, "probe", self._probe), patch.object(toolchain, "SDK_SIM_MAPPING", self.mapping), \
             patch.object(toolchain.subprocess, "run", self._run):
            return toolchain.ios_platform(self.c)

    def test_mapped_runtime_decides(self):
        self.runtimes = [("27.1", "24A94425")]                       # mini 现场：只有 27.1
        self.assertEqual(self.judge()[:2], (False, "26.5"))
        self.runtimes = [("26.5", "23F77"), ("27.1", "24A94232")]   # 本机：有配套的 23F77
        self.assertEqual(self.judge()[:2], (True, "26.5"))
        self.runtimes = [("26.5", "23F73")]                         # 同版本号、但不是 23F81a 配的构建 → 按表判没装
        self.assertFalse(self.judge()[0])
        self.sdk = ("27.1", "24A94232"); self.runtimes = [("27.1", "24A94425")]   # mini 的 27.1：表里配得上
        self.assertTrue(self.judge()[0])

    def test_no_mapping_falls_back_to_version(self):
        self.mapping.unlink()
        self.runtimes = [("27.1", "24A94425")]
        self.assertFalse(self.judge()[0])
        self.runtimes = [("26.5", "23F77")]
        self.assertTrue(self.judge()[0])
        self.sdk = ("", ""); self.assertIsNone(self.judge()[0])   # 读不到 iOS SDK：不判（交「Xcode」那项）

    def test_preflight_item_and_one_click(self):
        developer = self.root / "Xcode.app/Contents/Developer"
        (developer / "usr/bin").mkdir(parents=True); (developer / "usr/bin/xcodebuild").touch()
        self.c.r["developerDir"] = str(developer)
        def checks():
            with patch.object(toolchain, "probe", self._probe), patch.object(toolchain, "SDK_SIM_MAPPING", self.mapping), \
                 patch.object(toolchain.subprocess, "run", self._run), patch.object(toolchain, "reader", return_value=Path("x.dll")), \
                 patch.object(toolchain, "input_interface", return_value=(True, "")), patch("platform.mac_ver", return_value=("26.0", (), "")):
                return {r["name"]: r for r in toolchain.preflight(self.c)["checks"]}
        self.runtimes = [("27.1", "24A94425")]
        miss = checks()["iOS 平台组件"]
        self.assertFalse(miss["ok"]); self.assertEqual(miss["action"], "downloadIosPlatform")
        self.assertEqual(miss["requiredFor"], ["ipa"])                     # 只挡打 iPhone 包，不挡 Mac 打包与启动
        self.assertEqual(miss["diagnostic"]["code"], "ios_platform_missing")
        self.assertIn("约 8 GB", miss["message"]); self.assertIn("iOS 26.5", miss["message"])
        self.runtimes = [("26.5", "23F77")]
        ok = checks()["iOS 平台组件"]
        self.assertTrue(ok["ok"]); self.assertIsNone(ok["action"]); self.assertNotIn("diagnostic", ok)

    def test_download_job_command_and_progress(self):
        seen, events = [], []
        def run(args, on_line=None, **kw):
            seen.append([str(a) for a in args])
            for text in ("Downloading iOS 26.5 Simulator (23F77): 12.5%", "Downloading iOS 26.5 Simulator (23F77): 100%"):
                on_line(text)
        with patch.object(self.c, "run", run), patch.object(self.c, "emit", lambda *a, **k: events.append(k)):
            toolchain.download_ios_platform(self.c)
        self.assertEqual(seen, [["xcodebuild", "-downloadPlatform", "iOS", "-architectureVariant", "arm64"]])   # Apple 芯片只下 arm64 版（8.5 GB，不下 10.6 GB 通用版）
        self.assertEqual([e.get("done") for e in events if "done" in e], [12.5, 100.0])

    def test_xcodebuild_text_classified_and_recovery(self):
        self.assertEqual(log_cause([("ensure_profile", MINI_LINE)])[0], "ios_platform_missing")
        self.assertIn("一键下载", RECOVERY["ios_platform_missing"])


if __name__ == "__main__":
    unittest.main()
