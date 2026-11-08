#!/usr/bin/env python3
"""出包收尾（pack/ipa_tail.py）单测；期望按规则手写，不跑被测实现推。
① 画面模式（原 tests/gfx_mode_test.sh 五例，按宿主运行时判法「NVN b-<链> 或 Vulkan vk/」）：NVN b-<链>/ + keys.tsv → direct、b-<链>；缺 keys.tsv → generic；
   Vulkan 同 GL 以表为准：vk/vk_shaders.tsv（+ metallib）→ direct、vk，只有表头（RomFS 没有 SPIR-V 的款，出包不起局）→ direct、vk，只有 metallib 没有表 → generic；OpenGL gl/gl_shaders.metallib + .tsv → direct、gl，离线 0 支（只有表头 gl_shaders.tsv、没有 metallib）→ direct、gl，只有 metallib 没有表 → generic；什么都没有 → generic、空；S2A_DUAL=0 → 一律 generic
② 着色器目标：gal_pso.applegpu_g18p.ios27.0.bin / .1.bin、gal_pso.applegpu_g17p.ios26.0.bin、gal_dl.* → 「applegpu_g17p.ios26,applegpu_g18p.ios27」；没有归档 → 空
③ 包号 = <提交号>-<sha256(包键 + 换行) 前 8 位>（本文件另算）
④ 实跑 Info.plist 写入（app_bundle.py update_metadata，同 ipa_tail 用的调用）：包号与着色器目标读回一致、未知布尔键保留；空着色器目标 → 删掉旧键
⑥ 开发设施开关（S2ADevFacilities）：S2A_PACK_PURPOSE=user → "0"（玩家包关）；没设 / 别的用途 → 空串（删键 = 开发设施开）
⑤ 签名方式：非 Mac 上 adhoc / dev → 退 1 报红；dev 没给团队 → 退 1
"""
import hashlib, os, plistlib, subprocess, sys, tempfile, unittest
from pathlib import Path
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "pack"))
import ipa_tail  # noqa: E402


class Tail(unittest.TestCase):
    def setUp(self):
        self.t = Path(tempfile.mkdtemp())

    def mk(self, name, files):
        r = self.t / name
        for f, b in files.items():
            (r / f).parent.mkdir(parents=True, exist_ok=True)
            if b is None: (r / f).mkdir(exist_ok=True)
            else: (r / f).write_bytes(b)
        (r / "shaders").mkdir(parents=True, exist_ok=True)
        return str(r)

    def test_gfx_mode(self):
        nvn = self.mk("nvn", {"shaders/direct/b-2b1fd180ed01": None, "shaders/direct/keys.tsv": b"k"})
        nok = self.mk("nok", {"shaders/direct/b-2b1fd180ed01": None})
        vk = self.mk("vk", {"shaders/direct/keys.tsv": b"k", "shaders/direct/vk/vk_shaders.metallib": b"lib", "shaders/direct/vk/vk_shaders.tsv": b"# s2arm-vk-lib 3\nk\tvert\t\t-\n"})
        vk0 = self.mk("vk0", {"shaders/direct/keys.tsv": b"", "shaders/direct/vk/vk_shaders.tsv": b"# s2arm-vk-lib 3\n"})   # RomFS 没有 SPIR-V（银河）：只有表头、没有库
        vknotab = self.mk("vknotab", {"shaders/direct/vk/vk_shaders.metallib": b"lib"})
        gl = self.mk("gl", {"shaders/direct/gl/gl_shaders.metallib": b"lib", "shaders/direct/gl/gl_shaders.tsv": b"# s2arm-gl-lib 2\n"})
        gl0 = self.mk("gl0", {"shaders/direct/gl/gl_shaders.tsv": b"# s2arm-gl-lib 2\n"})
        glnotab = self.mk("glnotab", {"shaders/direct/gl/gl_shaders.metallib": b"lib"})
        none = self.mk("none", {})
        self.assertEqual(ipa_tail.gfx_mode(nvn, True), ("direct", "b-2b1fd180ed01"))
        self.assertEqual(ipa_tail.gfx_mode(nok, True), ("generic", ""))
        self.assertEqual(ipa_tail.gfx_mode(vk, True), ("direct", "vk"))
        self.assertEqual(ipa_tail.gfx_mode(vk0, True), ("direct", "vk"))
        self.assertEqual(ipa_tail.gfx_mode(vknotab, True), ("generic", ""))
        self.assertEqual(ipa_tail.gfx_mode(gl, True), ("direct", "gl"))
        self.assertEqual(ipa_tail.gfx_mode(gl0, True), ("direct", "gl"))
        self.assertEqual(ipa_tail.gfx_mode(glnotab, True), ("generic", ""))
        self.assertEqual(ipa_tail.gfx_mode(none, True), ("generic", ""))
        self.assertEqual((ipa_tail.gfx_mode(nvn, False), ipa_tail.gfx_mode(vk, False)), (("generic", ""), ("generic", "")))

    def test_pso_target_and_build_id(self):
        d = self.mk("pt", {f"shaders/{f}": b"" for f in ("gal_pso.applegpu_g18p.ios27.0.bin", "gal_pso.applegpu_g18p.ios27.1.bin",
                                                         "gal_pso.applegpu_g17p.ios26.0.bin", "gal_dl.applegpu_g18p.ios27")})
        self.assertEqual(ipa_tail.pso_target(d), "applegpu_g17p.ios26,applegpu_g18p.ios27")
        self.assertEqual(ipa_tail.pso_target(self.mk("e", {})), "")
        pk = "8cf4073a1 cur=/x/roots/botw@sh-1 vamm=alias sign=adhoc"
        self.assertEqual(ipa_tail.build_id(pk), "8cf4073a1-" + hashlib.sha256((pk + "\n").encode()).hexdigest()[:8])

    def test_plist_write(self):
        app = self.t / "S2Arm.app"; app.mkdir(); (app / "S2Arm").write_bytes(b"x")
        with open(app / "Info.plist", "wb") as f: plistlib.dump({"CFBundleExecutable": "S2Arm", "KeepBoolean": True, "S2APsoTarget": "old"}, f)
        d = self.mk("pt2", {"shaders/gal_pso.applegpu_g18p.ios27.0.bin": b""})
        for k, v in (("S2ABuildID", "c1-abcdef12"), ("S2APsoTarget", ipa_tail.pso_target(d))):
            subprocess.run([sys.executable, str(ROOT / "pack/app_bundle.py"), "update_metadata", str(app), "--set", f"{k}={v}"], check=True)
        p = plistlib.load(open(app / "Info.plist", "rb"))
        self.assertEqual((p["S2ABuildID"], p["S2APsoTarget"], p["KeepBoolean"]), ("c1-abcdef12", "applegpu_g18p.ios27", True))
        subprocess.run([sys.executable, str(ROOT / "pack/app_bundle.py"), "update_metadata", str(app), "--set", f"S2APsoTarget={ipa_tail.pso_target(self.mk('e2', {}))}"], check=True)
        p = plistlib.load(open(app / "Info.plist", "rb"))
        self.assertNotIn("S2APsoTarget", p); self.assertEqual(p["S2ABuildID"], "c1-abcdef12")

    def test_sign_mode_guard(self):
        base = [sys.executable, str(ROOT / "pack/ipa_tail.py"), "--work", str(self.t), "--game", "g", "--shell", str(self.t), "--bundle-id", "b",
                "--key", "c k", "--title", "t"]
        r = subprocess.run(base + ["--sign", "dev"], capture_output=True, text=True)
        self.assertEqual(r.returncode, 1); self.assertIn("【红】", r.stdout)
        if sys.platform != "darwin":
            r = subprocess.run(base + ["--sign", "adhoc"], capture_output=True, text=True)
            self.assertEqual(r.returncode, 1); self.assertIn("只能在 Mac", r.stdout)


class DevFacilities(unittest.TestCase):
    def _with(self, v):
        old = os.environ.pop('S2A_PACK_PURPOSE', None)
        try:
            if v is not None: os.environ['S2A_PACK_PURPOSE'] = v
            return ipa_tail.dev_facilities()
        finally:
            os.environ.pop('S2A_PACK_PURPOSE', None)
            if old is not None: os.environ['S2A_PACK_PURPOSE'] = old

    def test_user_pack_off(self):   # 启动器给玩家出包：写 "0"，宿主 s2a_dev_on 判关
        self.assertEqual(self._with('user'), '0')

    def test_dev_packs_keep_on(self):   # 实验 / 普查 / 手测（不设或别的值）：空串 = update_metadata 删键 = 开
        self.assertEqual(self._with(None), '')
        self.assertEqual(self._with('exp'), '')

if __name__ == "__main__":
    unittest.main()
