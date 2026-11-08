#!/usr/bin/env python3
"""tools/widen_accept.py 单测：合成「世界」纹理按不同方式出宽屏图，期望结论按构造写死，不跑被测实现推导。

世界 = 平滑随机纹理（模板匹配要两方向都有信息）。好图 = 同一缩放下取更宽的一段（视野变宽、不拉伸）；
16:9 对照 = 世界中间 16:9 一段。反例按 10-26 / 10-27 真机现象构造：整幅横拉 1.222（银河2）、扩展带横向插值（巫师3 W3WV）、
两侧黑边、上下黑带占高 89%。
"""

import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / "tools/widen_accept.py"
H = 720
W_WIDE = round(H * 19.5 / 9)   # 1560
W_169 = H * 16 // 9             # 1280


def world(width, height, seed=7):
    rng = np.random.default_rng(seed)
    noise = rng.integers(0, 256, (height // 4, width // 4, 3), dtype=np.uint8)
    img = Image.fromarray(noise).resize((width, height), Image.BICUBIC)
    return img.filter(ImageFilter.GaussianBlur(0.8))


class WidenAcceptTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix="widen-accept-test-")
        d = Path(cls.tmp.name)
        w = world(2400, H)
        x0 = (2400 - W_WIDE) // 2
        cls.paths = {}

        def save(name, img):
            cls.paths[name] = d / f"{name}.png"
            img.save(cls.paths[name])

        save("reference", w.crop((1200 - W_169 // 2, 0, 1200 + W_169 // 2, H)))
        save("good", w.crop((x0, 0, x0 + W_WIDE, H)))
        narrow = round(W_WIDE / 1.222)   # 内容只有 W_WIDE/1.222 宽，被横拉到满屏
        save("stretched", w.crop((1200 - narrow // 2, 0, 1200 + narrow // 2, H)).resize((W_WIDE, H), Image.BILINEAR))
        center = w.crop((1200 - W_169 // 2, 0, 1200 + W_169 // 2, H))
        band = (W_WIDE - W_169) // 2
        interp = Image.new("RGB", (W_WIDE, H))
        interp.paste(center, (band, 0))
        interp.paste(center.crop((0, 0, band // 4, H)).resize((band, H), Image.BILINEAR), (0, 0))
        interp.paste(center.crop((W_169 - band // 4, 0, W_169, H)).resize((W_WIDE - band - W_169, H), Image.BILINEAR), (band + W_169, 0))
        save("interp", interp)
        bars = Image.new("RGB", (W_WIDE, H))
        bars.paste(center, (band, 0))
        save("bars", bars)
        off = Image.new("RGB", (W_WIDE, H))
        off.paste(center, (0, 0))
        save("offcenter", off)
        # 两侧带与中间不连续（10-29 马车8 选轮胎页）：两侧是另一帧（另一张世界图）/ 铺满画布的蓝色底纹只画了中间 16:9
        good, o = w.crop((x0, 0, x0 + W_WIDE, H)), world(2400, H, seed=11).crop((x0, 0, x0 + W_WIDE, H))
        stale = good.copy()
        stale.paste(o.crop((0, 0, band, H)), (0, 0)); stale.paste(o.crop((band + W_169, 0, W_WIDE, H)), (band + W_169, 0))
        save("stale", stale)
        tint = good.copy()
        tint.paste(Image.blend(good.crop((band, 0, band + W_169, H)), Image.new("RGB", (W_169, H), (60, 170, 240)), 0.7), (band, 0))
        save("tint", tint)
        low = w.crop((x0, 0, x0 + W_WIDE, H)).copy()
        low.paste((0, 0, 0), (0, 0, W_WIDE, 40))
        low.paste((0, 0, 0), (0, H - 39, W_WIDE, H))
        save("low", low)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def run_tool(self, image, reference=True, page=False):
        cmd = [sys.executable, str(TOOL), "--game", "t", "--tid", "0100000000000000", "--build", "0" * 32,
               "--profile", "19.5:9", "--image", str(self.paths[image])]
        if reference:
            cmd += ["--reference", str(self.paths["reference"])]
        if page:
            cmd += ["--page"]
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=300)
        return r.returncode, r.stdout + r.stderr

    def test_good_passes(self):
        rc, out = self.run_tool("good")
        self.assertEqual(rc, 0, out)
        self.assertIn("\t过\t", out)

    def test_horizontal_stretch_fails(self):
        rc, out = self.run_tool("stretched")
        self.assertEqual(rc, 1, out)
        self.assertIn("非等比拉伸", out)

    def test_interpolated_bands_fail(self):
        rc, out = self.run_tool("interp")
        self.assertEqual(rc, 1, out)
        self.assertIn("扩展带拉丝", out)

    def test_stale_or_middle_only_sides_fail(self):
        # 两侧不黑、却不是本帧内容：旧判据（只认纯黑）判过，现在按 16:9 边界接缝判不过；当菜单页判（--page）也不过
        for name in ("stale", "tint"):
            for page in (False, True):
                with self.subTest(name=name, page=page):
                    rc, out = self.run_tool(name, page=page)
                    self.assertEqual(rc, 1, out)
                    self.assertIn("侧带与中间不连续", out)

    def test_black_bars_fail(self):
        rc, out = self.run_tool("bars")
        self.assertEqual(rc, 1, out)
        self.assertIn("黑边", out)

    def test_low_coverage_fails_even_without_reference(self):
        rc, out = self.run_tool("low", reference=False)
        self.assertEqual(rc, 1, out)
        self.assertIn("占高", out)

    def test_page_letterbox_by_design_not_fail(self):
        # 菜单页 16:9 居中、两侧纯黑（bars）：按设计留边，不判不过（无对照 → 未验）；同一张当 MARK 场景帧判就是不过
        rc, out = self.run_tool("bars", reference=False, page=True)
        self.assertEqual(rc, 2, out)
        self.assertIn("按设计 16:9 居中留边", out)
        rc, out = self.run_tool("bars", reference=False)
        self.assertEqual(rc, 1, out)

    def test_page_off_center_or_non_169_still_fails(self):
        # 居中但内容不是 16:9（上下黑带让占高 89%）、或内容偏一侧：都不是按设计留边
        rc, out = self.run_tool("low", reference=False, page=True)
        self.assertEqual(rc, 1, out)
        rc, out = self.run_tool("offcenter", reference=False, page=True)
        self.assertEqual(rc, 1, out)

    def test_good_without_reference_unverified(self):
        rc, out = self.run_tool("good", reference=False)
        self.assertEqual(rc, 2, out)
        self.assertIn("\t未验\t", out)


class RealScreens(unittest.TestCase):
    """真截图正反对照（人工看过，10-29）：马车8 轮胎页两侧旧帧 → 不过；马车8 赛道 / MARK、八方2 读档 / MARK 正常 → 不许报接缝。
    本机没有截图就跳过并写明跑了几张（射程）"""
    RUN = Path.home() / ".s2arm/run/s2arm"
    CASES = [("wire-c/mk8tires/r2/shots/tires.png", True), ("lists_jobs/ab_pair/mk8d_1028b/19_5_9/on/shots/tires.png", True),
             ("sched/jobs/mk8d_1029061459_1/out_1029061459/shots/tires.png", True),
             ("wire-c/mk8tires/r2/shots/scene_race.png", False), ("sched/jobs/mk8d_1029061459_1/out_1029061459/shots/scene_race.png", False),
             ("lists_jobs/ab_pair/mk8d_1028b/19_5_9/on/ap_mark.png", False), ("lists_jobs/ab_pair/o2_1028b/19_5_9/on/shots/loaded.png", False),
             ("lists_jobs/ab_pair/o2_1028b/19_5_9/on/ap_mark.png", False)]

    def test_real_screens(self):
        have = [(p, bad) for p, bad in self.CASES if (self.RUN / p).is_file()]
        print(f"\n  真截图 {len(have)}/{len(self.CASES)} 张在本机（缺的跳过）")
        if not have:
            self.skipTest(f"本机没有真截图，真图正反对照 0/{len(self.CASES)} 未跑")
        sys.path.insert(0, str(ROOT / "tools"))
        import widen_accept as wa
        wa.np, wa.Image = np, Image   # 量具在 main() 里才导入 NumPy / Pillow
        for p, bad in have:
            with self.subTest(p):
                seam = wa.measure_side_seam(Image.open(self.RUN / p).convert("RGB"))
                worst = max(v for k, v in seam.items() if not k.endswith("_col") and v is not None)
                print(f"  {p}：接缝行 左 {seam['left']} / 右 {seam['right']}")
                self.assertEqual(worst >= wa.SEAM_ROWS_MAX, bad, seam)


class SideHole(unittest.TestCase):
    """两侧扩展带空洞（10-30）。期望按构造：2346×1080，中间 1920 宽是逐像素噪声纹理；
    ① 两侧也是噪声 → 空洞超出 0、band_checks 无不过；② 右带整片纯青（清屏色）→ 右超出 = 1.0 ≥ 0.20、判不过；
    ③ 两侧是带噪点的暗色夜空（亮度 8–14 随机）→ 没有完全纯色块、不判空洞；④ 中间和两侧都有同样比例的纯黑块 → 相互抵消、不判"""
    def setUp(self):
        sys.path.insert(0, str(ROOT / "tools"))
        import widen_accept as wa
        wa.np, wa.Image = np, Image
        self.wa = wa
        rng = np.random.default_rng(5)
        self.base = rng.integers(40, 220, (1080, 2346, 3), dtype=np.uint8)
        self.ins = (2346 - 1920) // 2

    def hole(self, a):
        return self.wa.measure_side_hole(Image.fromarray(a))

    def test_noise_ok(self):
        h = self.hole(self.base)
        self.assertEqual((h["left"], h["right"]), (0.0, 0.0))
        self.assertEqual(self.wa.band_checks(Image.fromarray(self.base))[0], [])

    def test_clear_color_band_fails(self):
        a = self.base.copy(); a[:, -self.ins:] = (0, 200, 220)
        h = self.hole(a)
        self.assertEqual(h["right"], 1.0)
        bad, _ = self.wa.band_checks(Image.fromarray(a))
        self.assertTrue(any("右侧扩展带空洞" in x for x in bad), bad)

    def test_noisy_dark_sky_ok(self):
        a = self.base.copy(); rng = np.random.default_rng(6)
        a[:, :self.ins] = rng.integers(8, 15, (1080, self.ins, 3), dtype=np.uint8)
        a[:, -self.ins:] = rng.integers(8, 15, (1080, self.ins, 3), dtype=np.uint8)
        h = self.hole(a)
        self.assertLess(max(h["left"], h["right"]), 0.20, h)

    def test_shared_black_cancels(self):
        a = self.base.copy()
        a[:540, :] = 0   # 上半幅整行纯黑（中间与两侧同比例）
        h = self.hole(a)
        self.assertLess(max(h["left"], h["right"]), 0.20, h)


class UiRatio(unittest.TestCase):
    """界面横向比（10-30 画面线口径 (b)）。期望按构造：对照 = 1920×1080 合成界面页（随机大色块 + 细纹理）；满屏图 = 2340 宽画布中间贴对照：
    ① 原样 → 横向比 1、过；② 横压 3%（超 2%）→ 不过；③ 横压 1%（未超）→ 过；④ 换一张别的随机页 → 不是同一页、未验"""
    @classmethod
    def setUpClass(cls):
        sys.path.insert(0, str(ROOT / "tools"))
        import widen_accept as wa
        wa.np, wa.Image = np, Image
        cls.wa = wa; cls.tmp = tempfile.TemporaryDirectory(); cls.d = Path(cls.tmp.name)
        def page(seed):
            rng = np.random.default_rng(seed); a = rng.integers(20, 60, (1080, 1920, 3), dtype=np.uint8)
            for _ in range(40):   # 界面元素：大色块，块内带细纹理（给缩放搜索梯度）
                x, y, w, h = rng.integers(0, 1700), rng.integers(0, 950), rng.integers(80, 260), rng.integers(40, 160)
                a[y:y + h, x:x + w] = rng.integers(60, 240, 3) + rng.integers(0, 12, (min(h, 1080 - y), min(w, 1920 - x), 3))
            return Image.fromarray(a.astype(np.uint8))
        cls.ref = cls.d / "ref.png"; page(11).save(cls.ref); cls.other = page(12)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def wide(self, img, sq, name):
        c = Image.new("RGB", (2340, 1080), (30, 30, 30)); s = img.resize((round(1920 * sq), 1080))
        c.paste(s, ((2340 - s.width) // 2, 0)); p = self.d / name; c.save(p); return p

    def test_same_page_pass(self):
        st, rd = self.wa.ui_ratio(self.ref, self.wide(Image.open(self.ref), 1.0, "w1.png"))
        self.assertEqual(st, "pass", rd)

    def test_squeeze_3pct_fail(self):
        st, rd = self.wa.ui_ratio(self.ref, self.wide(Image.open(self.ref), 0.97, "w97.png"))
        self.assertEqual(st, "fail", rd)

    def test_squeeze_1pct_pass(self):
        st, rd = self.wa.ui_ratio(self.ref, self.wide(Image.open(self.ref), 0.99, "w99.png"))
        self.assertEqual(st, "pass", rd)

    def test_other_page_unverified(self):
        st, rd = self.wa.ui_ratio(self.ref, self.wide(self.other, 1.0, "wo.png"))
        self.assertEqual(st, "unverified", rd)


class HostLogAndWrite(unittest.TestCase):
    """上屏层判据（host.log）与 --write 写表；期望按宿主日志语义写死"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="widen-accept-log-")
        self.d = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def log(self, *lines):
        p = self.d / "host.log"
        p.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return p

    def judge(self, *lines):
        sys.path.insert(0, str(ROOT / "tools"))
        import widen_accept as wa
        return wa.judge_host_log(self.log(*lines))

    def test_host_log_cases(self):
        on = "[画] 满屏判据 已开"
        red, back = "【红】出图未满屏 两侧 260 像素", "出图恢复满屏"
        cases = [((on,), [], []), ((on, red, back), [], []), (("没有判据行",), [], 1),
                 ((on, red), 1, []), ((on, red, back, red, back), 1, [])]
        for lines, bad, unv in cases:
            with self.subTest(lines=lines):
                _, b, u = self.judge(*lines)
                self.assertEqual(len(b) > 0, bool(bad), b)
                self.assertEqual(len(u) > 0, bool(unv), u)

    def test_host_log_vs_base(self):
        """③b 按对照局边际判（10-30 马车8 第二层闭环：主局与不开点对照局同在第 510 / 2460 次出图起未满屏）：上限 = max(1, 对照局次数)"""
        sys.path.insert(0, str(ROOT / "tools"))
        import widen_accept as wa
        on, red, back = "[画] 满屏判据 已开", "【红】出图未满屏 两侧", "出图恢复满屏"
        def logf(name, *lines):
            p = self.d / name; p.write_text("\n".join(lines) + "\n", encoding="utf-8"); return p
        main2 = logf("m2.log", on, red, back, red, back)
        main3 = logf("m3.log", on, red, back, red, back, red, back)
        base2 = logf("b2.log", on, red, back, red, back)
        base0 = logf("b0.log", on)
        base_off = logf("boff.log", red, back, red, back)   # 对照局判据没开：不采用
        cases = [(main2, base2, False), (main3, base2, True), (main2, None, True), (main2, base_off, True),
                 (main2, base0, True), (main2, self.d / "缺.log", True)]
        for m, b, want_bad in cases:
            with self.subTest(main=m.name, base=getattr(b, "name", None)):
                _, bad, unv = wa.judge_host_log(m, b)
                self.assertEqual(bool(bad), want_bad, bad); self.assertEqual(unv, [])
        _, bad, _ = wa.judge_host_log(main3, base2)
        self.assertIn("对照局 2 次", bad[0])

    def test_write_tables_upsert_and_verified(self):
        sys.path.insert(0, str(ROOT / "tools"))
        import widen_accept as wa
        (self.d / "docs").mkdir(); (self.d / "graphics/widen/tables").mkdir(parents=True)
        head = "# 注\n程序号\t构建号\t款\t档位\t平台\t结论\t日期\t读数\t依据\n"
        import reglist   # 比例表按款登记目录（10-30）：经 reglist 写入 / 合并读
        ver = self.d / wa.VERIFIED_TABLE
        reglist.write(str(self.d), "名单_满屏比例", head + "0100000000000001\t" + "a" * 32 + "\tt\t4:3\tMac\t不过\t2026-10-27\t旧\t旧\n")
        class _R:   # 合并读，接口同原来的 Path.read_text
            def read_text(self, encoding=None): return reglist.text(str(wa_d), "名单_满屏比例")
        wa_d = self.d; ratio = _R()
        ver.write_text("# 程序号\t构建号\t款\t平台\t登记日期\t依据\n", encoding="utf-8")
        row = lambda ratio_, verdict: "\t".join(["0100000000000001", "a" * 32, "t", ratio_, "Mac", verdict, "2026-10-28", "读数", "依据"])
        wa.write_tables(self.d, row("19.5:9", "过"))   # 新增一档过，但 4:3 仍不过 → 不进 verified
        self.assertNotIn("0100000000000001", ver.read_text(encoding="utf-8"))
        wa.write_tables(self.d, row("4:3", "过"))      # 就地更新 4:3 → 全过 → 进 verified
        body = [l for l in ratio.read_text(encoding="utf-8").split("\n") if l.startswith("0100")]
        self.assertEqual([l.split("\t")[3:6] for l in body], [["4:3", "Mac", "过"], ["19.5:9", "Mac", "过"]])
        self.assertEqual(ver.read_text(encoding="utf-8").count("0100000000000001"), 1)
        wa.write_tables(self.d, row("4:3", "不过"))    # 只加不删
        self.assertEqual(ver.read_text(encoding="utf-8").count("0100000000000001"), 1)


class AbPairRejudge(unittest.TestCase):
    """tools/ab_pair.sh --rejudge 选判据对：两局都有 shots/scene_<名>.png（路线定帧、同一时刻）就用它当主判据对，
    MARK 帧（两局不同时刻）只认「不过」；没有场景对才退回 MARK 帧。MARK 两张用不同种子的世界 = 对不上的两个时刻"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="ab-pair-rejudge-")
        self.d = Path(self.tmp.name)
        w, other = world(2400, H), world(2400, H, seed=11)
        x0 = (2400 - W_WIDE) // 2
        self.ref = w.crop((1200 - W_169 // 2, 0, 1200 + W_169 // 2, H))
        self.good = w.crop((x0, 0, x0 + W_WIDE, H))
        narrow = round(W_WIDE / 1.222)
        self.stretched = w.crop((1200 - narrow // 2, 0, 1200 + narrow // 2, H)).resize((W_WIDE, H), Image.BILINEAR)
        for m in ("off", "on"):
            (self.d / m / "shots").mkdir(parents=True)
            (self.d / m / "host.log").write_text("[画] 满屏判据 已开\n", encoding="utf-8")
        self.ref.save(self.d / "off/ap_mark.png")
        other.crop((x0, 0, x0 + W_WIDE, H)).save(self.d / "on/ap_mark.png")

    def tearDown(self):
        self.tmp.cleanup()

    def rejudge(self):
        r = subprocess.run(["bash", str(ROOT / "tools/ab_pair.sh"), "--rejudge", "t", "widen:19.5:9", str(self.d)],
                           capture_output=True, text=True, timeout=600, env={**__import__("os").environ, "S2A_PY": sys.executable})
        return r.returncode, r.stdout + r.stderr

    def test_mark_only_mismatch_unverified(self):
        rc, out = self.rejudge()
        self.assertEqual(rc, 2, out)

    def test_scene_pair_is_primary(self):
        self.ref.save(self.d / "off/shots/scene_race.png")
        self.good.save(self.d / "on/shots/scene_race.png")
        rc, out = self.rejudge()
        self.assertEqual(rc, 0, out)
        self.assertIn("\t过\t", out)

    def test_scene_pair_stretch_fails(self):
        self.ref.save(self.d / "off/shots/scene_race.png")
        self.stretched.save(self.d / "on/shots/scene_race.png")
        rc, out = self.rejudge()
        self.assertEqual(rc, 1, out)
        self.assertIn("非等比拉伸", out)



class AndroidMeasureTest(unittest.TestCase):
    """F10 first slice: real image CLI, unchanged thresholds, no Android ledger writes."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix="android-widen-measure-")
        cls.directory = Path(cls.tmp.name)
        image = world(2400, H)
        cls.reference = cls.directory / "reference.png"
        image.crop((1200 - W_169 // 2, 0, 1200 + W_169 // 2, H)).save(cls.reference)
        cls.images = {}
        for profile, width in (("20:9", 1600), ("21:9", 1680)):
            path = cls.directory / (profile.replace(":", "x") + ".png")
            image.crop((1200 - width // 2, 0, 1200 + width // 2, H)).save(path)
            cls.images[profile] = path
        cls.bordered = cls.directory / "bordered.png"
        border = Image.new("RGB", (1600, H), (0, 0, 0))
        border.paste(Image.open(cls.reference), (160, 0))
        border.save(cls.bordered)

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def command(self, profile="20:9", image=None, reference=True, extra=()):
        args = [sys.executable, str(TOOL), "--game", "synthetic",
                "--tid", "0100000000ABCDEF", "--build", "a" * 32,
                "--profile", profile, "--platform", "Android",
                "--image", str(image or self.images[profile]), "--json"]
        if reference:
            args += ["--reference", str(self.reference)]
        return subprocess.run(args + list(extra), capture_output=True, text=True, timeout=90)

    def test_android_20_and_21_good_images_use_original_judgment(self):
        import json
        for profile in ("20:9", "21:9"):
            with self.subTest(profile=profile):
                result = self.command(profile)
                self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
                report = json.loads(result.stdout)
                self.assertEqual((report["platform"], report["profile"]), ("Android", profile))
                self.assertEqual(report["judgment"]["result"], "pass")

    def test_android_black_borders_are_still_red(self):
        import json
        result = self.command(image=self.bordered)
        self.assertEqual(result.returncode, 1, result.stderr + result.stdout)
        report = json.loads(result.stdout)
        self.assertEqual(report["judgment"]["result"], "fail")
        self.assertEqual(report["platform"], "Android")

    def test_android_missing_reference_is_unverified(self):
        import json
        result = self.command(reference=False)
        self.assertEqual(result.returncode, 2, result.stderr + result.stdout)
        report = json.loads(result.stdout)
        self.assertEqual(report["judgment"]["result"], "unverified")
        self.assertEqual(report["platform"], "Android")

    def test_android_tsv_keeps_platform_profile_and_unknown(self):
        sys.path.insert(0, str(ROOT / "tools"))
        import widen_accept as wa
        args = wa.parser().parse_args([
            "--game", "synthetic", "--tid", "0100000000ABCDEF", "--build", "a" * 32,
            "--profile", "21:9", "--platform", "Android", "--image", "synthetic.png"])
        row = wa.format_tsv_row(args, {"result": "unverified", "measurements": {},
                                       "reasons": ["missing reference"]})
        self.assertEqual(row.split("\t")[3:6], ["21:9", "Android", "未验"])

    def test_android_write_cli_refuses_before_any_output_or_mutation(self):
        with tempfile.TemporaryDirectory(prefix="android-write-refused-") as tmp:
            directory = Path(tmp)
            sentinel = directory / "keep.txt"
            sentinel.write_text("original ledger must remain unchanged\n")
            result = self.command(image=directory / "not-read.png", extra=("--write", tmp))
            self.assertEqual(result.returncode, 2)
            self.assertIn("Android", result.stderr)
            self.assertIn("只读", __import__("json").loads(result.stderr)["error"])
            self.assertEqual(result.stdout, "")
            self.assertEqual(list(directory.iterdir()), [sentinel])
            self.assertEqual(sentinel.read_text(), "original ledger must remain unchanged\n")

    def test_android_write_api_refuses_before_apple_verified_or_ratio_mutation(self):
        sys.path.insert(0, str(ROOT / "tools"))
        import widen_accept as wa
        with tempfile.TemporaryDirectory(prefix="android-ledger-refused-") as tmp:
            repo = Path(tmp)
            (repo / "docs").mkdir()
            verified = repo / wa.VERIFIED_TABLE
            verified.parent.mkdir(parents=True)
            verified.write_text("# existing Apple verification\n")
            before = {str(p.relative_to(repo)): p.read_bytes()
                      for p in repo.rglob("*") if p.is_file()}
            row = "\t".join(["0100000000ABCDEF", "a" * 32, "synthetic", "20:9",
                              "Android", "过", "2026-11-06", "synthetic", "test"])
            with self.assertRaisesRegex(ValueError, "Android.*只读"):
                wa.write_tables(repo, row)
            after = {str(p.relative_to(repo)): p.read_bytes()
                     for p in repo.rglob("*") if p.is_file()}
            self.assertEqual(after, before)


if __name__ == "__main__":
    unittest.main()
