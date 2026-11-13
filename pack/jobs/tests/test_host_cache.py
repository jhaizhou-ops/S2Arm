"""Mac 宿主缓存复用判定（build.host_cache_ok，10-24 issue #100 作者场景）：
缓存的 S2ArmGame.app 里删掉 / 改掉地址窗口护栏库或 Joy-Con 动态库，或 ready.json 没记库摘要，都不许判命中。
期望按规则手写：完整且签名有效 → 命中；缺库、篡改或旧格式 → 不命中。用 clang 现编一个最小可执行文件与动态库、codesign 临时签名"""
import shutil
import json
import plistlib
from types import SimpleNamespace
from unittest.mock import patch
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

JOBS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(JOBS))
from core import digest
import build


@unittest.skipUnless(shutil.which("clang") and shutil.which("codesign"), "需要 clang 与 codesign（Mac）")
class HostCacheTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="s2arm host cache ")
        root = Path(self.tmp.name)
        self.app = root / "S2ArmGame.app"
        mac = self.app / "Contents/MacOS"
        mac.mkdir(parents=True)
        src = root / "m.c"
        src.write_text("int main(void) { return 0; }\n")
        subprocess.run(["clang", "-o", str(mac / "s2arm-host"), str(src)], check=True)
        lib = root / "g.c"
        lib.write_text("void s2a_vaguard_open(void) {}\n")
        subprocess.run(["clang", "-dynamiclib", "-o", str(mac / build.VAGUARD), str(lib)], check=True)
        (self.app / "Contents/Info.plist").write_text(
            '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleExecutable</key><string>s2arm-host</string>'
            '<key>CFBundleIdentifier</key><string>org.s2arm.test</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>')
        subprocess.run(["clang", "-dynamiclib", "-o", str(mac / build.SDL3), str(lib)], check=True)
        for name in (build.VAGUARD, build.SDL3):
            subprocess.run(["codesign", "--force", "--sign", "-", str(mac / name)], check=True, capture_output=True)
        subprocess.run(["codesign", "--force", "--sign", "-", str(self.app)], check=True, capture_output=True)
        self.stamp = dict(schema=1, sha256=digest(mac / "s2arm-host"), guard_sha256=digest(mac / build.VAGUARD),
                          sdl3_sha256=digest(mac / build.SDL3))
        self.guard = mac / build.VAGUARD
        self.sdl = mac / build.SDL3

    def tearDown(self):
        self.tmp.cleanup()

    def test_generated_game_bundle_supports_macos15(self):
        private = self.app.parent / "private"
        host_build = private / "tools/mac-host/fixture/build"
        fixture = self.app / "Contents/MacOS"
        def run(args, log, env):
            if args[0] == "make":
                host_build.mkdir(parents=True)
                for name in ("s2arm-host", build.VAGUARD, build.SDL3):
                    shutil.copy2(fixture / name, host_build / name)
                (host_build / "SDL3-LICENSE.txt").write_text("Synthetic SDL license fixture\n")
            else:
                subprocess.run([str(x) for x in args], check=True, capture_output=True)
        context = SimpleNamespace(private=private, engine=self.app.parent / "engine",
                                  run=run, emit=lambda *a, **k: None)
        with patch("embedded.artifact", return_value=None):
            app = build.compile_host(context, "fixture", {"DEVELOPER_DIR": "fixture"}, self.app.parent)
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        self.assertEqual(info["LSMinimumSystemVersion"], "15.0")
        self.assertEqual(info["CFBundleExecutable"], "s2arm-host")
        self.assertEqual(digest(app / "Contents/MacOS" / build.SDL3), digest(self.sdl))
        self.assertEqual((app / "Contents/Resources/SDL3-LICENSE.txt").read_text(), "Synthetic SDL license fixture\n")
        self.assertTrue(build.host_cache_ok(app, json.loads((host_build.parent / "ready.json").read_text())))

    def test_complete_signed_cache_hits(self):
        self.assertTrue(build.host_cache_ok(self.app, self.stamp))

    def test_deleted_guard_misses(self):   # 作者的复现：删掉副本里的护栏库
        self.guard.unlink()
        self.assertFalse(build.host_cache_ok(self.app, self.stamp))

    def test_modified_guard_misses(self):
        with self.guard.open("ab") as f:
            f.write(b"\0")
        self.assertFalse(build.host_cache_ok(self.app, self.stamp))

    def test_deleted_sdl_misses(self):
        self.sdl.unlink()
        self.assertFalse(build.host_cache_ok(self.app, self.stamp))

    def test_modified_sdl_misses(self):
        with self.sdl.open("ab") as f:
            f.write(b"\0")
        self.assertFalse(build.host_cache_ok(self.app, self.stamp))

    def test_old_stamp_without_sdl_digest_misses(self):
        self.assertFalse(build.host_cache_ok(self.app, {k: v for k, v in self.stamp.items() if k != "sdl3_sha256"}))

    def test_old_stamp_without_guard_digest_misses(self):
        self.assertFalse(build.host_cache_ok(self.app, dict(schema=1, sha256=self.stamp["sha256"])))

    def test_broken_app_signature_misses(self):   # 摘要都对、App 签名被破坏（往 Contents 加了没签进去的文件）
        (self.app / "Contents/extra.txt").write_text("x")
        self.assertFalse(build.host_cache_ok(self.app, self.stamp))


if __name__ == "__main__":
    unittest.main()
