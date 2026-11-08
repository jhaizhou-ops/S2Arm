"""devicectl 调用（pack/jobs/diag.py）单测（从 test_error_recovery.py 拆出，10-26；夹具 jobcase.JobCase）。"""
import subprocess
import unittest
from unittest.mock import patch

from jobcase import JobCase


class DevicectlTests(JobCase):
    def test_devicectl_uses_installed_coredevice_not_xcode_wrapper(self):
        # Xcode 的 usr/bin/devicectl 是包装脚本，CoreDevice 版本对不上就跑 xcodebuild -runFirstLaunch 弹管理员密码框（10-26 Air 启动器里每次卡 60 秒）：
        #   直接调已装 CoreDevice 框架里的 devicectl，xcrun 一次都不碰；框架不在 → 退 127、给能照做的提示，同样不碰 xcrun
        import diag
        fw = self.root / "CoreDevice"; (fw / "Resources/bin").mkdir(parents=True)
        tool = fw / "Resources/bin/devicectl"
        tool.write_text('#!/bin/sh\nfor a; do o=$a; done\necho \'{"result":{"devices":[]}}\' > "$o"\necho "$@" > "$(dirname "$0")/called"\n')
        tool.chmod(0o755)
        bindir = self.root / "fakebin"; bindir.mkdir()
        (bindir / "xcrun").write_text(f'#!/bin/sh\ntouch "{self.root}/xcrun-called"\nexit 1\n'); (bindir / "xcrun").chmod(0o755)
        env = dict(self.c.env(), PATH=f"{bindir}:/usr/bin:/bin")
        with patch.object(diag, "COREDEVICE", fw), patch.object(self.c, "env", return_value=env):
            rc, data, _ = diag.devicectl(self.c, "list", "devices", timeout=10)
        self.assertEqual((rc, data), (0, {"result": {"devices": []}}))
        self.assertTrue((fw / "Resources/bin/called").read_text().startswith("list devices --json-output"))
        with patch.object(diag, "COREDEVICE", self.root / "missing"), patch.object(self.c, "env", return_value=env):
            rc, data, err = diag.devicectl(self.c, "list", "devices", timeout=10)
        self.assertEqual((rc, data, err), (127, {}, diag.NO_COREDEVICE))
        self.assertFalse((self.root / "xcrun-called").exists())

    def test_devicectl_does_not_trigger_component_install_on_version_mismatch(self):
        # 模拟用户机「所选 Xcode 期望的 CoreDevice 版本 ≠ 已装的」（10-26 Air：Xcode 27.1 要 651.13.5、装的是 642.16）：
        #   Xcode 的 usr/bin/devicectl 包装脚本这时先跑 xcodebuild -runFirstLaunch（装组件、弹管理员密码框，启动器里卡满 60 秒）。
        #   夹具照 Xcode 27.1 包装脚本的判法搭一个假 Xcode（xcrun 解析到它的 usr/bin/devicectl、版本不符就调 xcodebuild -runFirstLaunch），
        #   新代码直接调已装框架里的 devicectl：xcodebuild 一次都没被调；旧代码（xcrun devicectl）会走到 -runFirstLaunch
        import diag
        fw = self.root / "CoreDevice"; (fw / "Resources/bin").mkdir(parents=True)
        (fw / "Resources/Info.plist").write_text('<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleVersion</key><string>642.16</string></dict></plist>')
        tool = fw / "Resources/bin/devicectl"
        tool.write_text('#!/bin/sh\nfor a; do o=$a; done\necho \'{"result":{"devices":[]}}\' > "$o"\n'); tool.chmod(0o755)
        xcode = self.root / "Xcode-27.1.app/Contents/Developer"; (xcode / "usr/bin").mkdir(parents=True)
        (xcode / "usr/bin/xcodebuild").write_text(f'#!/bin/sh\necho "$@" >> "{self.root}/xcodebuild-called"\n'); (xcode / "usr/bin/xcodebuild").chmod(0o755)
        (xcode / "usr/bin/devicectl").write_text(   # 同 Xcode 27.1 的包装脚本：版本不符 → xcodebuild -runFirstLaunch → exec 框架里的 devicectl
            '#!/bin/zsh\nEXPECTED_VERSION="651.13.5"\n'
            f'CURRENT_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "{fw}/Resources/Info.plist" 2>&1)"\n'
            'if [[ "${EXPECTED_VERSION}" != "${CURRENT_VERSION}" ]]; then "${DEVELOPER_DIR}/usr/bin/xcodebuild" -runFirstLaunch; fi\n'
            f'exec "{fw}/Resources/bin/devicectl" "$@"\n')
        (xcode / "usr/bin/devicectl").chmod(0o755)
        bindir = self.root / "fakebin"; bindir.mkdir()
        (bindir / "xcrun").write_text('#!/bin/sh\nt=$1; shift; exec "$DEVELOPER_DIR/usr/bin/$t" "$@"\n'); (bindir / "xcrun").chmod(0o755)
        env = dict(self.c.env(), PATH=f"{bindir}:/usr/bin:/bin", DEVELOPER_DIR=str(xcode))
        # 夹具自证：经 xcrun 走 Xcode 包装脚本（旧代码的路）确实会调 -runFirstLaunch
        subprocess.run(["xcrun", "devicectl", "list", "devices", "--json-output", str(self.root / "probe.json")], env=env, capture_output=True, timeout=20)
        self.assertEqual((self.root / "xcodebuild-called").read_text().split(), ["-runFirstLaunch"])
        (self.root / "xcodebuild-called").unlink()
        with patch.object(diag, "COREDEVICE", fw), patch.object(self.c, "env", return_value=env):
            rc, data, _ = diag.devicectl(self.c, "list", "devices", timeout=10)
        self.assertEqual((rc, data), (0, {"result": {"devices": []}}))
        self.assertFalse((self.root / "xcodebuild-called").exists())


if __name__ == "__main__":
    unittest.main()
