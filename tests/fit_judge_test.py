#!/usr/bin/env python3
"""宿主上屏满屏判据 graphics/metal/fit_judge.h 单测：编 tests/fit_judge_test.c，喂合成图与（本机有就喂）真截图，期望按构造 / 人工看图写死，不跑被测实现推期望。

合成图同 tests/widen_accept_test.py：世界 = 平滑随机纹理，好图 = 同一缩放下取更宽的一段。反例按 10-29 马车8 选轮胎页构造：
  旧帧（两侧换成另一张世界图）、界面层只铺中间（中间 16:9 压一层蓝色底纹，两侧是没压的场景）；对照：16:9 居中两侧纯黑 + 标原比例页（g=1）不报，
  不标（g=0）报黑带；游戏自己出宽图的纯 2D 帧（g=4）、两侧是放宽内容画的（g=2）不判接缝。
两侧是放宽内容画的（g=2，11-02 植物大战僵尸协议页：压暗层已推满整幅，游戏在压暗之后又在画布外画侧饰）：接缝前提「旧帧 / 铺满层没铺满」被否，
  同一张接缝图 g=2 不报、g=0 照报（负对照：信号决定免判，不是放宽了阈值）；真截图 evidence/fit_seam/pvz_protocol_bands.png 同样一对。
放大上屏的原比例页（10-30 普查 c1029c：RCG / Let's Get Fit / Mario Tennis 等 6 款判成「16:9 边界第 212 列接缝贯穿 100% 行」）：
  游戏画 1564×720（放宽后），16:9 内容 [142, 1422)、两侧纯黑，上屏双线性放大 1.5 倍到 2346×1080——边界那一列混进约 17% 的内容、不再整列纯黑，
  黑边与内容的交界被当成接缝。标原比例页（g=1）/ 两侧是游戏画的（g=2）不许报；同一张图 tools/widen_accept.py measure_side_seam 该侧也不量（None）。
真截图（人工看过，10-29）：马车8 轮胎页 Mac 两张 / 真机一张两侧是旧帧 → 必须报；马车8 赛道 / MARK、八方2 读档 / MARK 正常 → 不许报。
本机没有真截图时跳过并在输出里写明跳过几张（射程）。"""

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np
from PIL import Image, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
H = 720
W_WIDE = round(H * 19.5 / 9)   # 1560
W_169 = H * 16 // 9             # 1280
RUN = Path.home() / ".s2arm/run/s2arm"
# (相对 RUN 的路径, 该不该报未满屏)
REAL = [
    ("wire-c/mk8tires/r2/shots/tires.png", True),
    ("lists_jobs/ab_pair/mk8d_1028b/19_5_9/on/shots/tires.png", True),
    ("sched/jobs/mk8d_1029061459_1/out_1029061459/shots/tires.png", True),
    ("wire-c/mk8tires/r2/shots/scene_race.png", False),
    ("sched/jobs/mk8d_1029061459_1/out_1029061459/shots/scene_race.png", False),
    ("lists_jobs/ab_pair/mk8d_1028b/19_5_9/on/ap_mark.png", False),
    ("lists_jobs/ab_pair/o2_1028b/19_5_9/on/shots/loaded.png", False),
    ("lists_jobs/ab_pair/o2_1028b/19_5_9/on/ap_mark.png", False),
]


def world(width, height, seed=7):
    rng = np.random.default_rng(seed)
    noise = rng.integers(0, 256, (height // 4, width // 4, 3), dtype=np.uint8)
    return Image.fromarray(noise).resize((width, height), Image.BICUBIC).filter(ImageFilter.GaussianBlur(0.8))


def raw(img, path):
    a = np.asarray(img.convert("RGB"), dtype=np.uint8)
    bgra = np.concatenate([a[:, :, ::-1], np.full(a.shape[:2] + (1,), 255, np.uint8)], axis=2)
    with open(path, "wb") as f:
        f.write(f"{a.shape[1]} {a.shape[0]}\n".encode())
        f.write(bgra.tobytes())


class FitJudge(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(prefix="fit-judge-test-")
        d = Path(cls.tmp.name)
        cls.bin = d / "fit_judge_test"
        cc = subprocess.run(["clang", "-O2", "-std=c11", "-o", str(cls.bin), str(ROOT / "tests/fit_judge_test.c")], capture_output=True, text=True)
        if cc.returncode:
            raise RuntimeError("编不过 tests/fit_judge_test.c：" + cc.stderr)
        w, other = world(2400, H), world(2400, H, seed=11)
        x0, band = (2400 - W_WIDE) // 2, (W_WIDE - W_169) // 2
        good = w.crop((x0, 0, x0 + W_WIDE, H))
        stale = good.copy()   # 两侧是另一帧（另一张世界图）：中间是本帧
        o = other.crop((x0, 0, x0 + W_WIDE, H))
        stale.paste(o.crop((0, 0, band, H)), (0, 0)); stale.paste(o.crop((band + W_169, 0, W_WIDE, H)), (band + W_169, 0))
        tint = good.copy()    # 铺满画布的蓝色底纹只画了中间 16:9（马车8 轮胎页 Mac 那样）
        mid = Image.blend(good.crop((band, 0, band + W_169, H)), Image.new("RGB", (W_169, H), (60, 170, 240)), 0.7)
        tint.paste(mid, (band, 0))
        bars = Image.new("RGB", (W_WIDE, H)); bars.paste(good.crop((band, 0, band + W_169, H)), (band, 0))
        src = Image.new("RGB", (1564, 720)); src.paste(world(1280, 720, seed=5), (142, 0))   # 放宽后的 1564 宽目标，16:9 内容居中、两侧清黑
        cls.bars_up = src.resize((2346, 1080), Image.BILINEAR)   # 上屏双线性放大（像素中心对齐，同 Metal 全屏四边形采样）
        cls.raw = {}
        for name, img in (("good", good), ("stale", stale), ("tint", tint), ("bars", bars), ("bars_up", cls.bars_up)):
            cls.raw[name] = d / f"{name}.raw"; raw(img, cls.raw[name])
        cls.d = d

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def judge(self, path, g=0, geo=0):
        r = subprocess.run([str(self.bin), f"{path}:{g}:{geo}"], capture_output=True, text=True, timeout=120)
        self.assertEqual(r.returncode, 0, r.stderr)
        line = r.stdout.strip()
        print(f"  {Path(path).name} g={g}: {line.split(' ', 1)[1]}")
        return int(line.split(" 未满屏 ")[1].split()[0]), line

    def test_good_not_reported(self):
        n, line = self.judge(self.raw["good"])
        self.assertEqual(n, 0, line)

    def test_stale_sides_reported(self):
        n, line = self.judge(self.raw["stale"])
        self.assertEqual(n, 1, line)
        self.assertIn("接缝", line)

    def test_middle_only_layer_reported(self):
        n, line = self.judge(self.raw["tint"])
        self.assertEqual(n, 1, line)
        self.assertIn("接缝", line)

    def test_page_black_sides(self):
        n, line = self.judge(self.raw["bars"], 1)   # 标了原比例页：两侧纯黑不报，也不当接缝
        self.assertEqual(n, 0, line)
        n, line = self.judge(self.raw["bars"], 0)   # 没标：照旧报黑带（不是接缝）
        self.assertEqual(n, 1, line)
        self.assertIn("黑带", line)

    def test_page_black_sides_upscaled(self):
        a = np.asarray(self.bars_up, dtype=np.int32).sum(axis=2)
        self.assertTrue(a[:, 211].max() == 0 and a[:, 212].max() > 0, "构造前提：第 212 列混进了内容、第 211 列纯黑")
        for g in (1, 2):
            n, line = self.judge(self.raw["bars_up"], g)
            self.assertEqual(n, 0, line)
        sys.path.insert(0, str(ROOT / "tools"))
        import widen_accept as wa
        wa.np, wa.Image = np, Image   # 量具在 main() 里才导入 NumPy / Pillow
        seam = wa.measure_side_seam(self.bars_up)
        self.assertEqual((seam["left"], seam["right"]), (None, None), seam)

    def test_kind_last(self):   # 11-02 最近一次判定种类（体验线读 1–3 算扩展区异常）：期望按判据定义——正常 0、接缝 2、黑带 1、标了原比例页 5、游戏自己出宽图的纯 2D 帧不判接缝 0；连判两次计 2
        for name, g, want in (("good", 0, 0), ("stale", 0, 2), ("tint", 0, 2), ("bars", 0, 1), ("bars", 1, 5), ("stale", 4, 0)):
            _, line = self.judge(self.raw[name], g)
            self.assertIn(f" 种类 {want} 判定 2 ", line, f"{name} g={g}")

    def test_geometry_letterbox_not_content(self):   # 11-02 饥荒误弹「满屏不稳定」：画面本身 16:9、出图层居中留边时，几何已判没满屏 → 两侧边不当黑带（1），只记几何（4）
        _, line = self.judge(self.raw["bars"], 0, 0)
        self.assertIn(" 种类 1 判定 2 ", line, "没有几何结论：照旧判黑带")
        _, line = self.judge(self.raw["bars"], 0, 1)
        self.assertIn(" 种类 4 判定 2 ", line, "几何已判没满屏：只记几何、不当扩展区异常")

    def test_mid_black_void(self):   # 11-09 哈迪斯 II 强制整套放宽：中段整列纯黑、两侧是场景，旧判据报满屏 0 红。期望按构造写死
        good = Image.open(self.d / "good.png") if (self.d / "good.png").exists() else None
        w0 = world(2400, H, seed=21).crop((0, 0, W_WIDE, H))
        void = w0.copy(); void.paste(Image.new("RGB", (300, H)), (900, 0))          # 中间 300 列纯黑，两侧紧挨是场景（断崖）
        vign = w0.copy(); a = np.asarray(vign, dtype=np.float32)                   # 游戏自己的暗角：右侧约 500 列渐暗到纯黑，黑区里零星亮点（丝之歌萤火虫）
        ramp = np.clip((1480 - np.arange(W_WIDE)) / 500.0, 0, 1)[None, :, None] ** 1.5; a = (a * ramp).astype(np.uint8); a[300, 1500] = (200, 220, 90); a[500, 1530] = (200, 220, 90)
        vign = Image.fromarray(a)
        page = Image.new("RGB", (W_WIDE, H)); page.paste(world(650, 120, seed=4), (0, 560)); page.paste(world(260, 140, seed=6), (1300, 540))   # 黑底页：左对话框、右小图（动森）
        for name, im, want, word in (("mid_void", void, 1, "中间第"), ("mid_vign", vign, 0, ""), ("mid_page", page, 0, "")):
            q = self.d / f"{name}.raw"; raw(im, q)
            n, line = self.judge(q, 0)
            self.assertEqual(n, want, f"{name}: {line}")
            if word: self.assertIn(word, line)
        q = self.d / "mid_void.raw"   # 只在常规帧判：标了原比例页 / 两侧是游戏画的 / 纯 2D 合成 / 回退不判
        for g in (1, 2, 4, 5):
            n, line = self.judge(q, g)
            self.assertNotIn("中间第", line, f"g={g}: {line}")
        # 真截图（本机有才跑；哈迪斯那局自动玩家截图把 2.17:1 画面上下加黑边缩进 1280×720，先裁掉上下全黑行再喂）：人工看过——哈迪斯强制整套放宽两张必须报；丝之歌暗角、动森黑底对话页不许报
        real = [("hades2_wide_mid.png", 1, 1), ("hades2_wide_mark.png", 1, 1), ("silk_vignette_a.png", 0, 0), ("silk_vignette_b.png", 0, 0),
                ("acnh_black_page.png", 0, 0)]   # (RUN/evidence/fit_mid 下的文件, 该不该报, 要不要裁掉截图缩放加的上下黑边：只有哈迪斯那局窗口 16:9、画面 2.17:1)
        ran = 0
        for name, want, crop in real:
            p = RUN / "evidence/fit_mid" / name
            if not p.is_file(): continue
            im = Image.open(p).convert("RGB")
            if crop: a = np.asarray(im, dtype=np.int32).sum(axis=2); rows = np.where(a.max(axis=1) > 0)[0]; im = im.crop((0, int(rows.min()), im.width, int(rows.max()) + 1))
            q = self.d / "mid_real.raw"; raw(im, q)
            _, line = self.judge(q, 0); ran += 1
            self.assertEqual("中间第" in line, bool(want), f"{p}: {line}")
        print(f"  中间整列纯黑真截图：跑了 {ran} / {len(real)} 张")

    def test_game_wide_2d_exempt(self):
        n, line = self.judge(self.raw["stale"], 4)
        self.assertEqual(n, 0, line)

    def test_bands_seam_exempt(self):   # g=2 只免接缝：合成接缝两张、真截图一张，g=2 不报、g=0 照报；黑带照判（g=2 两侧黑由 bars_up 那条管，这里看纯黑整带）
        for name in ("stale", "tint"):
            for g, want in ((2, 0), (0, 1)):
                n, line = self.judge(self.raw[name], g)
                self.assertEqual(n, want, line)
        p = RUN / "evidence/fit_seam/pvz_protocol_bands.png"
        if not p.is_file():
            self.skipTest(f"本机没有 {p}，真截图 g=2 对照 0/1 未跑")
        q = self.d / "pvz_bands.raw"; raw(Image.open(p), q)
        for g, want in ((2, 0), (0, 1)):
            n, line = self.judge(q, g)
            self.assertEqual(n, want, line)
            if want: self.assertIn("接缝", line)

    def test_pure2d_fallback(self):   # 原比例回退（5，11-01 根因族 1）：整帧退回 16:9 居中，两侧黑带不报、记原比例回退；没标（0）照旧报
        for g, want in ((5, 0), (0, 1)):
            n, line = self.judge(self.raw["bars"], g)
            self.assertEqual(n, want, line)
        n, line = self.judge(self.raw["bars"], 5)
        self.assertIn("原比例回退", line)

    def tall_imgs(self):   # 高屏（Duo 内屏 1.42）：1280×900 画布，16:9 内容区 [90, 810) 行
        W, Hh, top = 1280, 900, 90
        scene = world(W, 720, seed=3)
        full = world(W, Hh, seed=3)                                   # 加高铺满（好）
        page = Image.new("RGB", (W, Hh)); page.paste(scene, (0, top))  # 16:9 原比例页：上下纯黑、页内铺满
        cut = Image.new("RGB", (W, Hh)); cut.paste(scene.crop((0, 0, W, 542)), (0, top))   # 旷野之息 Duo：页里场景只到第 632 行，下面纯黑……
        cut.paste(world(300, 16, seed=9), (490, 670))                  # ……黑区里一行操作提示（真截图 1494–1527 行那条）
        logo = Image.new("RGB", (W, Hh)); logo.paste(world(400, 120, seed=4), (440, 390))   # 黑底居中 logo 页：页内上下内沿都黑
        out = {}
        for name, im in (("tall_full", full), ("tall_page", page), ("tall_cut", cut), ("tall_logo", logo)):
            out[name] = self.d / f"{name}.raw"; raw(im, out[name])
        return out

    def test_tall_screen(self):   # 11-05 高屏没有竖向判法（旷野之息 Duo 场景只占 60% 判不出）：期望按构造写死
        r = self.tall_imgs()
        for name, g, want, word in (("tall_full", 0, 0, ""), ("tall_page", 1, 0, ""), ("tall_page", 5, 0, ""), ("tall_page", 0, 1, "黑带"),
                                    ("tall_cut", 1, 1, "内容没铺满页"), ("tall_cut", 5, 1, "内容没铺满页"), ("tall_cut", 0, 1, "黑带"), ("tall_logo", 1, 0, "")):
            with self.subTest(f"{name} g={g}"):
                n, line = self.judge(r[name], g)
                self.assertEqual(n, want, line)
                if word: self.assertIn(word, line)

    def test_tall_real_botw_duo(self):   # 真截图（人工看过，11-05）：旷野之息 Duo 局内，场景只占 [200,1409) 行、底部 268 行纯黑——不论标没标原比例页都必须报
        ps = [RUN / "evidence/hzline_1105/botw_duo/shots_ap" / n for n in ("ap_mark.png", "ap_mid.png")]
        have = [p for p in ps if p.is_file()]
        print(f"  旷野之息 Duo 真截图 {len(have)}/{len(ps)} 张在本机")
        if not have:
            self.skipTest("本机没有旷野之息 Duo 真截图，0/2 未跑")
        for p in have:
            q = self.d / (p.stem + "_duo.raw"); raw(Image.open(p), q)
            for g in (0, 1):
                with self.subTest(f"{p.name} g={g}"):
                    n, line = self.judge(q, g)
                    self.assertEqual(n, 1, line)

    def test_tall_seam(self):   # 11-05 竖向接缝：合成——上下带是同一张场景、中间一层压暗只盖 16:9 行（反例，必须报接缝）；同一张不压暗（正例，不报）
        W, Hh, top = 1280, 900, 90
        full = world(W, Hh, seed=21)
        dim = full.copy(); mid = Image.blend(full.crop((0, top, W, Hh - top)), Image.new("RGB", (W, Hh - 2 * top)), 0.55); dim.paste(mid, (0, top))
        for name, im, want in (("tall_dim_mid", dim, 1), ("tall_full_seam0", full, 0)):
            q = self.d / f"{name}.raw"; raw(im, q)
            for g in (0, 1):
                with self.subTest(f"{name} g={g}"):
                    n, line = self.judge(q, g)
                    self.assertEqual(n, want, line)
                    if want: self.assertIn("接缝", line)

    def test_tall_seam_real(self):   # 真截图（人工看过，11-05 Duo 内屏 1280×900）：哆啦A梦剧情对话框 / 同意页、旷野之息标题页（层只盖中间 16:9 行）→ 报接缝；同局标题 / 加载页、我的世界自己画的高屏、条款页页签上沿（游戏排版）→ 不报
        E = RUN / "evidence/hzline_1105/verify"
        cases = [(E / "v_dora_duo/v24.png", 1), (E / "v_dora_duo/v02.png", 1), (E / "v_botw_duo/v01.png", 1), (E / "v_dora_duo/v18.png", 0), (E / "v_dora_duo/v25.png", 0), (E / "v_mc_duo/v18.png", 0), (E / "v_dora_duo/v04.png", 0)]   # v04：条款页页签上沿 42%，游戏自己的排版，不许报
        have = [(p, w) for p, w in cases if p.is_file()]
        print(f"  竖向接缝真截图 {len(have)}/{len(cases)} 张在本机")
        if not have:
            self.skipTest("本机没有 11-05 Duo 真截图，0/7 未跑")
        for p, want in have:
            q = self.d / (p.parent.name + "_" + p.stem + ".raw"); raw(Image.open(p), q)
            for g in (0, 1):
                with self.subTest(f"{p.parent.name}/{p.name} g={g}"):
                    n, line = self.judge(q, g)
                    self.assertEqual(n > 0, bool(want), line)
                    if want: self.assertIn("接缝", line)

    def test_real_screens(self):
        have = [(p, bad) for p, bad in REAL if (RUN / p).is_file()]
        print(f"  真截图 {len(have)}/{len(REAL)} 张在本机（缺的跳过）")
        if not have:
            self.skipTest(f"本机没有真截图（{RUN}），真图正反对照 0/{len(REAL)} 未跑")
        for p, bad in have:
            with self.subTest(p):
                q = self.d / (p.replace("/", "_") + ".raw"); raw(Image.open(RUN / p), q)
                n, line = self.judge(q)
                self.assertEqual(n > 0, bad, line)


if __name__ == "__main__":
    unittest.main(verbosity=2)
