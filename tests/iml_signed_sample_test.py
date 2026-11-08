#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Real macOS codesign fixtures, expected dictionaries fixed by producer README."""
import plistlib
import contextlib
import datetime as dt
import io
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "pack"))
import iml_check
import iml_formats


class SignedSamples(unittest.TestCase):
    def test_four_real_signed_samples(self):
        iml = iml_check.IML_KEY
        cases = {"iml_ok": ({iml:True}, True, 1),
                 "iml_missing": ({"get-task-allow":True}, False, 1),
                 "iml_banned": ({iml:True,"dynamic-codesigning":True}, False, 1),
                 "iml_ok_fat": ({iml:True}, True, 2)}
        for name, (want, accepted, count) in cases.items():
            with self.subTest(sample=name):
                actual = iml_formats.read_macho_entitlements((ROOT / "tests/fixtures/iml_signed" / name).read_bytes())
                self.assertEqual([want]*count, actual)
                self.assertEqual([accepted]*count, [iml_check.check_entitlements_plist(plistlib.dumps(x))[0] for x in actual])
        print("真实签名样本组分母：4 件、5 个切片；此处只读权限，未验证密码学签名或设备安装")

    def test_real_sample_app_entrypoints(self):
        with tempfile.TemporaryDirectory() as directory:
            app = Path(directory) / "Probe.app"
            app.mkdir()
            (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable":"Probe", "CFBundleIdentifier":"org.s2arm.synthetic"}))
            for name, want in (("iml_ok",0),("iml_missing",1),("iml_banned",1),("iml_ok_fat",0)):
                with self.subTest(sample=name), contextlib.redirect_stdout(io.StringIO()):
                    shutil.copyfile(ROOT / "tests/fixtures/iml_signed" / name, app / "Probe")
                    self.assertEqual(want, iml_check._check_app(str(app)))

    def test_openssl_signed_synthetic_profile(self):
        value = iml_formats.read_profile((ROOT / "tests/fixtures/iml_signed/profile_synthetic.cms").read_bytes())
        self.assertEqual({"Entitlements": {
            iml_check.IML_KEY: True, "application-identifier": "TESTTEAM.org.s2arm.*",
            "com.apple.developer.team-identifier": "TESTTEAM"},
            "TeamIdentifier": ["TESTTEAM"], "ApplicationIdentifierPrefix": ["TESTTEAM"],
            "ProvisionedDevices": ["SYNTHETIC-DEVICE"], "ExpirationDate": dt.datetime(2099,1,1)}, value)


def mac_parity():
    if sys.platform != "darwin":
        print("未运行：codesign 新旧对照需要 macOS",file=sys.stderr)
        return 2
    folder = ROOT / "tests/fixtures/iml_signed"
    for name in ("iml_ok","iml_missing","iml_banned","iml_ok_fat"):
        actual = iml_formats.read_macho_entitlements((folder / name).read_bytes())
        arches = ["arm64","arm64e"] if name.endswith("fat") else ["arm64"]
        for arch, ents in zip(arches,actual,strict=True):
            old = subprocess.run(["codesign","-d","--arch",arch,"--entitlements","-","--xml",str(folder/name)],capture_output=True)
            if old.returncode != 0 or not iml_formats.same_value(ents,iml_formats.read_plist(old.stdout)):
                print(f"【红】{name} / {arch} 新旧权限不一致")
                return 1
    old = subprocess.run(["security","cms","-D","-i",str(folder/"profile_synthetic.cms")],capture_output=True)
    new = iml_formats.read_profile((folder/"profile_synthetic.cms").read_bytes())
    if old.returncode != 0 or not iml_formats.same_value(new,iml_formats.read_plist(old.stdout)):
        print("【红】合成 CMS 的 security / Python 读数不一致")
        return 1
    print("Mac 新旧读取一致：4 个真实签名样本 / 5 个切片 + 1 个合成 CMS；不包含真实描述文件 App")
    return 0


if __name__ == "__main__":
    if sys.argv[1:] == ["--mac-parity"]:
        sys.exit(mac_parity())
    unittest.main(verbosity=2)
