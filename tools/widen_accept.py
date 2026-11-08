#!/usr/bin/env python3
"""满屏任意比例自动验收工具（只读量具，不改任何表）。

用法：
  python3 tools/widen_accept.py --game <款> --tid <程序号> --build <构建号> \\
      --profile 19.5:9 --image widescreen.png [--reference ref_16x9.png] \\
      [--template template.png]（不给模板时从对照图中间自动挑高纹理块） [--platform Mac|iPhone|iPad|Duo|Android]

输出：
  每档一行，列与 docs/名单_满屏比例/ 相同
  （程序号 / 构建号 / 款 / 档位 / 平台 / 结论 / 日期 / 读数 / 依据）
  结论：过 / 不过 / 未验
  --json 机读输出
  Android 的 20:9 / 21:9 读数目前只导出，不支持 --write；台账与已验证名单的平台隔离另片接线。

判据（阈值见 docs/名单_满屏比例/ 表头）：
1. 占宽 / 占高 ≥99%：非黑内容外框占画布比例
2. 黑边 0：四边整列 / 整行纯黑（容差自定、写清）为 0
3. 非等比拉伸 <1%：有对照截图时，从对照图中间 16:9 区自动挑高纹理块当模板，
   在宽屏图里搜最佳 x / y 缩放，|sx/sy−1| <1%（复用 tools/aspect_measure.py）
4. 插值拉伸（扩展带拉丝）：扩展带（中间 高×16/9 以外两侧）与中间区的
   「横向相邻差 / 纵向相邻差」比值之比，偏低 = 被横向插值拉伸
   阈值从正反例实测定，写进表头注释
5. 两侧带连续：16:9 边界上跨边台阶远大于邻列台阶的行占比 <30%（两侧不黑却是旧帧 / 没铺满的界面层，见 SEAM_ROWS_MAX）
6. 两侧扩展带空洞：完全纯色块占比比中间多 <0.20（清屏色 / 旧缓冲 / 无地面，见 HOLE_EXCESS）

全过 → 过；任一项明确不过 → 不过（写哪项、读数）；缺输入 → 未验

需要当前解释器已有 NumPy、Pillow；不自动安装。
标准输出只有 JSON；退出 0=通过，1=不通过，2=未验或错误。
"""

from __future__ import annotations

import argparse
import json
import math
import os
import subprocess
import sys
from datetime import date
from pathlib import Path

# 判据阈值（与 docs/名单_满屏比例/ 表头一致）
COVERAGE_THRESHOLD = 0.99  # 占宽 / 占高 ≥99%
UNFILLED_MAX = 1  # 上屏层「【红】出图未满屏」累计上限（#822 s-leeq 标定：botw jhz 认可局 1 次、八方2 旧链不合格局 4 次）
BLACK_BORDER_MAX = 0  # 黑边像素数上限
STRETCH_THRESHOLD_PCT = 1.0  # 非等比拉伸 <1%
SCALE_MIN_PEAK = 0.35  # 整图缩放搜索可信：峰值梯度相关下限（真宽屏图 0.53 / 0.83，反例 ≥0.96）
SCALE_MIN_MARGIN = 0.05  # 且峰值比「横 ×1.03、纵 ÷1.03」至少高这么多（真图 0.074，平坦无纹理时接近 0）
INTERPOLATION_RATIO_THRESHOLD = 0.65  # 扩展带 / 中间区横纵细节比低于此 = 横向插值拉伸。只有合成反例（0.34）与合成好图（1.01）标定，待 Mac 实跑巫师3 强开宽屏（已知拉丝）等真实反例复标
BLACK_TOLERANCE = 10  # 黑色容差（RGB 每通道 ≤10 视为黑）
# 两侧带与中间不连续（10-29 马车8 选轮胎页：两侧留旧帧 / 没铺满的底纹，整列不黑，旧判据只认纯黑、判过）：16:9 边界（内缩 in = (宽 − 高×16/9)/2）
# 左右各在 ±SEAM_SEARCH 列里找接缝最强的一列 b，逐行比跨边台阶 |I[b] − I[b−1]|（RGB 和）与它两侧各 7 列相邻台阶的中位数：台阶 > max(3 × 中位, 24) 的行 = 接缝行。
# 接缝行占比 ≥ SEAM_ROWS_MAX 判不过。宿主上屏判据 graphics/metal/fit_judge.h fj_seam 同一判法、同一阈值。
# 标定（10-29 真截图）：反例 马车8 轮胎页 Mac 2868×1080 左 54% / 右 48%、Mac 2340×1080 55% / 50%、真机 2867×1320 85% / 91%；
#   正例 马车8 赛道 / MARK / 中途、八方2 读档 / MARK / 中途 / 收局 共 9 张最高 15%。阈值取中 30%
SEAM_SEARCH = 3
SEAM_ROWS_MAX = 0.30
# 两侧扩展带空洞（10-30 总指挥 / grokbot 按引擎满屏 S 级②：旧缓冲 / 清屏色 / 无地面）：扩展带（中间 高×16/9 以外两侧）里「完全纯色」的
# HOLE_TILE×HOLE_TILE 块（RGB 各通道极差 ≤ HOLE_FLAT）占比，减去中间 16:9 区同口径占比，任一侧超出 ≥ HOLE_EXCESS 判不过。
# 只认完全纯色：渲染出来的暗角 / 夜空 / 天空总有噪点和渐变，清屏色和没画的旧缓冲是一整片同一个颜色；中间区同样有的纯色（界面底板、纯黑剪影）相互抵消。
# 标定（10-30 真机截图）：反例 马车8 比赛（sched/jobs/mk8d_1030014240_2 收局，两侧青 / 黑色块）右 0.53、轮胎页 左 0.55 / 右 0.32；
#   正例 12 款五问截图 21 张（five_q_1029）最高 0.07（丝之歌暗处）；暗黑3 暗角、马车8 开场夜空 ≤ 0.05。阈值取 0.20。
#   tests/visual/shot_holes.py（闭环 ⑤，8×8 极差 ≤2 连片、0.5%）在这批正例上读 10–18%，太严，五问不用它
HOLE_TILE, HOLE_FLAT, HOLE_EXCESS = 16, 1, 0.20
# 界面横向比（10-30 画面线定口径 (b)）：同一界面页 k=1（不开满屏）对照截图与满屏截图，measure_scale 量满屏图中间 16:9 区相对对照的横 / 纵缩放，
# |sx/sy − 1| > UI_RATIO_MAX 判不过（字变扁 = 核心没认出界面正交投影、把界面当 3D 按 k 放宽）。两条护栏：
#   ① 先认页：两张图中间 16:9 区的认页摘要（page_digest，32×18 亮度格）均差 ≤ UI_PAGE_TOL 才比，不同页记未验；
#   ② 只用菜单 / 暂停 / 结算这类静止界面页（调用方保证：ab_pair 菜单页循环），3D 场景帧 Hor+ 本来就多出两侧，sx 不该是 1。
#   宿主日志里的界面投影比量不到这个错（认出的界面本来就按原尺寸画，比恒为 16/9），所以不用日志
UI_RATIO_MAX, UI_PAGE_TOL = 0.02, 8.0

# 档位比例定义
PROFILES = {
    "19.5:9": 2340 / 1080,
    "20:9": 20 / 9,
    "21:9": 21 / 9,
    "16:10": 1920 / 1200,
    "1.42": 1920 / 1350,
    "4:3": 1920 / 1440,
    "16:9": 1920 / 1080,
}


def read_image(path, role):
    """读取图像，返回 PIL Image 对象。"""
    try:
        with Image.open(path) as source:
            width, height = source.size
            if max(width, height) > 4096 or width * height > 4_194_304:
                raise ValueError(f"{role}: image too large")
            if getattr(source, "n_frames", 1) != 1:
                raise ValueError(f"{role}: animated image unsupported")
            # 转换为 RGB，丢弃 alpha
            if "A" in source.getbands() or "transparency" in source.info:
                if source.convert("RGBA").getchannel("A").getextrema() != (255, 255):
                    # 有透明像素，转为 RGB 时会和白色混合，可能影响判定
                    pass
            return source.convert("RGB")
    except Exception as exc:
        raise ValueError(f"{role}: cannot read image: {exc}") from exc


def pixels(image):
    """将 PIL Image 转为 NumPy 数组 [0, 1]。"""
    return np.asarray(image, dtype=np.float32) / 255.0


def measure_coverage(image):
    """测量非黑内容占画布比例。

    返回 (占宽, 占高, 左黑边, 右黑边, 上黑边, 下黑边)。
    黑色定义：RGB 三通道都 ≤ BLACK_TOLERANCE。
    """
    arr = np.array(image)
    height, width = arr.shape[:2]

    # 判定每个像素是否为黑色
    is_black = np.all(arr <= BLACK_TOLERANCE, axis=2)

    # 找到非黑内容的边界
    non_black_rows = np.where(~np.all(is_black, axis=1))[0]
    non_black_cols = np.where(~np.all(is_black, axis=0))[0]

    if len(non_black_rows) == 0 or len(non_black_cols) == 0:
        # 全黑图像
        return 0.0, 0.0, 0, 0, 0, 0

    top = int(non_black_rows[0])
    bottom = int(height - 1 - non_black_rows[-1])
    left = int(non_black_cols[0])
    right = int(width - 1 - non_black_cols[-1])

    content_width = len(non_black_cols)
    content_height = len(non_black_rows)

    coverage_width = content_width / width
    coverage_height = content_height / height

    return coverage_width, coverage_height, left, right, top, bottom


def measure_black_borders(image):
    """测量四边黑边宽度（整列/整行纯黑）。

    返回 (左, 右, 上, 下) 黑边像素数。
    """
    arr = np.array(image)
    height, width = arr.shape[:2]

    is_black = np.all(arr <= BLACK_TOLERANCE, axis=2)

    # 左边黑边：从左往右找第一列非全黑
    left = 0
    for x in range(width):
        if not np.all(is_black[:, x]):
            break
        left += 1

    # 右边黑边
    right = 0
    for x in range(width - 1, -1, -1):
        if not np.all(is_black[:, x]):
            break
        right += 1

    # 上边黑边
    top = 0
    for y in range(height):
        if not np.all(is_black[y, :]):
            break
        top += 1

    # 下边黑边
    bottom = 0
    for y in range(height - 1, -1, -1):
        if not np.all(is_black[y, :]):
            break
        bottom += 1

    return int(left), int(right), int(top), int(bottom)


def measure_side_seam(image):
    """两侧带与中间区在 16:9 边界的跨边连续性（判法见 SEAM_ROWS_MAX 注释）。
    返回 {"left": 占比, "right": 占比, "left_col": b, "right_col": b}；图不比 16:9 宽（内缩 < 12 列）返回 None。
    除接缝搜索窗（边界 ±SEAM_SEARCH+1 列）外整列纯黑的一侧（原比例页 / 黑边）不量（记 None）：黑边归黑边判据和按设计留边管；
    上屏双线性放大时边界那一列混进内容不再纯黑（10-30 普查 1564→2346 原比例页 6 款误报），窗外全黑时窗里的台阶只可能是黑边本身"""
    arr = np.asarray(image, dtype=np.int32)
    height, width = arr.shape[:2]
    inset = (width - round(height * 16 / 9)) // 2
    if inset < 12:
        return None
    black = np.all(arr <= BLACK_TOLERANCE, axis=2)
    out = {}
    for side, b0, band in (("left", inset, slice(0, inset)), ("right", width - inset, slice(width - inset, width))):
        if np.all(black[:, band][:, [x - band.start for x in range(band.start, band.stop) if x < b0 - SEAM_SEARCH - 1 or x > b0 + SEAM_SEARCH]]):
            out[side], out[side + "_col"] = None, None
            continue
        best, best_b = 0.0, b0
        for b in range(b0 - SEAM_SEARCH, b0 + SEAM_SEARCH + 1):
            step = np.abs(arr[:, b] - arr[:, b - 1]).sum(axis=1)
            near = np.stack([np.abs(arr[:, b + k] - arr[:, b + k - 1]).sum(axis=1) for k in (*range(-8, -1), *range(2, 9))], axis=1)
            frac = float(np.mean(step > np.maximum(3 * np.median(near, axis=1), 24)))
            if frac > best:
                best, best_b = frac, b
        out[side], out[side + "_col"] = round(best, 4), best_b
    return out


def measure_side_hole(image):
    """两侧扩展带空洞（判法见 HOLE_EXCESS 注释；整侧纯黑记 None）→ {"left": 超出, "right": 超出, "center": 中间纯色占比, "left_flat": …, "right_flat": …}；
    图不比 16:9 宽（内缩 < HOLE_TILE）→ None"""
    arr = np.asarray(image, dtype=np.int16)
    height, width = arr.shape[:2]
    inset = (width - round(height * 16 / 9)) // 2
    if inset < HOLE_TILE:
        return None
    T = HOLE_TILE
    def frac(x0, x1):
        nx, ny = (x1 - x0) // T, height // T
        if nx < 1 or ny < 1: return None
        blk = arr[:ny * T, x0:x0 + nx * T].reshape(ny, T, nx, T, 3)
        return float(((blk.max(axis=(1, 3)) - blk.min(axis=(1, 3))).max(axis=-1) <= HOLE_FLAT).mean())
    c = frac(inset, width - inset); l, r = frac(0, inset), frac(width - inset, width)
    black = np.all(arr <= BLACK_TOLERANCE, axis=2)   # 整侧纯黑（原比例页 / 按设计留边）不量：黑边归黑边判据管，同 measure_side_seam
    sl, sr = (None if np.all(black[:, band]) else v for band, v in ((slice(0, inset), l), (slice(width - inset, width), r)))
    return {"left": None if sl is None else round(sl - c, 4), "right": None if sr is None else round(sr - c, 4), "center": round(c, 4),
            "left_flat": None if sl is None else round(sl, 4), "right_flat": None if sr is None else round(sr, 4)}


def band_checks(image):
    """满屏的画面判据（10-30 总指挥：五问 / 闭环的「满屏过」只看出图宽高比，巫师3 / 丝之歌这类铺满但画面不对的漏掉）：
    不用对照图、单张截图能判的两条——两侧扩展带空洞（measure_side_hole）、全屏层 / 两侧带与中间接缝（measure_side_seam，a04532dbe）。
    → (不过原因列表, 读数串)；图不比 16:9 宽 → ([], '不是加宽图')"""
    hole, seam = measure_side_hole(image), measure_side_seam(image)
    if hole is None and seam is None:
        return [], "不是加宽图"
    bad, read = [], []
    if hole:
        read.append("空洞 " + " / ".join("—" if hole[k] is None else f"{hole[k]:+.2f}" for k in ("left", "right")))
        for side, name in (("left", "左"), ("right", "右")):
            if hole[side] is not None and hole[side] >= HOLE_EXCESS:
                bad.append(f"{name}侧扩展带空洞：纯色块占比比中间多 {hole[side]:.2f} ≥ {HOLE_EXCESS}（{name}带 {hole[side + '_flat']:.2f}、中间 {hole['center']:.2f}）")
    if seam:
        read.append("接缝 " + " / ".join("—" if seam[k] is None else f"{seam[k] * 100:.0f}%" for k in ("left", "right")))
        for side, name in (("left", "左"), ("right", "右")):
            if seam[side] is not None and seam[side] >= SEAM_ROWS_MAX:
                bad.append(f"{name}侧与中间不连续：16:9 边界接缝贯穿 {seam[side] * 100:.0f}% 行 ≥ {SEAM_ROWS_MAX * 100:.0f}%（全屏层没盖满 / 旧帧）")
    return bad, "，".join(read)


def ensure_deps():
    """给别的工具 import 用（main() 里才延迟导入 numpy / PIL）"""
    global np, Image
    import numpy as np
    from PIL import Image


def page_digest(im):
    """认页摘要：整幅图分 64×36 格、每格隔 4 像素取亮度均值（0.299R + 0.587G + 0.114B），再 2×2 合并成 32×18（原 tools/route_page.py digest 同算法）"""
    px = im.convert("RGB").load(); w, h = im.size; tf = [0.0] * (64 * 36)
    for ty in range(36):
        for tx in range(64):
            x0, x1, y0, y1 = tx * w // 64, (tx + 1) * w // 64, ty * h // 36, (ty + 1) * h // 36; s = 0.0; n = 0
            for y in range(y0, y1, 4):
                for x in range(x0, x1, 4):
                    r, g, b = px[x, y]; s += 0.114 * b + 0.587 * g + 0.299 * r; n += 1
            tf[ty * 64 + tx] = s / n if n else 0.0
    return [(tf[2 * gy * 64 + 2 * gx] + tf[2 * gy * 64 + 2 * gx + 1] + tf[(2 * gy + 1) * 64 + 2 * gx] + tf[(2 * gy + 1) * 64 + 2 * gx + 1]) / 4
            for gy in range(18) for gx in range(32)]


def ui_ratio(reference_path, image_path):
    """界面横向比（判法见 UI_RATIO_MAX 注释）→ (status, 读数)，status：pass / fail / unverified。
    先量缩放、再认页：对照图按量出的横 / 纵缩放变换后放在满屏图中间 16:9 区上比认页摘要——直接比摘要时界面一压扁摘要就变（横压 5% 均差 12.5），
    要抓的错反被当成「不是同一页」。纵向在横向定了之后再粗搜一遍（measure_scale 先找统一缩放，横压 3% 时纵向被带偏到 0.989）"""
    ref, img = read_image(reference_path, "reference"), read_image(image_path, "target")
    cw = round(img.height * 16 / 9)
    if img.width > cw:   # 只比中间 16:9 区：满屏图两侧多出的部分不参与
        x0 = (img.width - cw) // 2; img = img.crop((x0, 0, x0 + cw, img.height))
    sx, sy, peak, margin = measure_scale(ref, img)
    for step, span in ((0.0025, 20), (0.0005, 10)):   # 横向定了再搜纵向，再回头细调横向
        sy = max((sy * (1 + k * step) for k in range(-span, span + 1)), key=lambda v: _scale_score(ref, img, sx, v, 640))
        sx = max((sx * (1 + k * step) for k in range(-span, span + 1)), key=lambda v: _scale_score(ref, img, v, sy, 640))
    peak = _scale_score(ref, img, sx, sy, 640)
    # 认页：对照按 (sx, sy) 缩放、居中贴到与 img 同尺寸的画布上（露出的地方用 img 自己的像素），再比两张的认页摘要
    warp = ref.resize((max(1, round(ref.width * sx)), max(1, round(ref.height * sy))))
    canvas = img.copy(); canvas.paste(warp, ((img.width - warp.width) // 2, (img.height - warp.height) // 2))
    da, db = page_digest(canvas), page_digest(img)
    d = sum(abs(x - y) for x, y in zip(da, db)) / len(da)
    read = f"界面横向比 {sx / sy:.4f}（横 {sx:.3f} / 纵 {sy:.3f}，对照按此缩放后认页均差 {d:.1f}，峰值 {peak:.2f}）"
    if d > UI_PAGE_TOL:
        return "unverified", f"不是同一页（对照按量出的缩放变换后认页均差 {d:.1f} > {UI_PAGE_TOL:g}），界面横向比未量"
    if peak < SCALE_MIN_PEAK:
        return "unverified", read + "：缩放搜索不可信，未验"
    return ("fail" if abs(sx / sy - 1) > UI_RATIO_MAX else "pass"), read


def call_aspect_measure(reference_path, target_path, template_path, threshold_pct):
    """调用 tools/aspect_measure.py 测量非等比拉伸。

    缩放搜索窗按两图「宽之比、高之比」取小者定（满屏放宽只多出视野：宽屏档宽变、高不变，变高的档高变、宽不变，
    内容缩放 = 不变那一边的比），上下各留 25%：
    窗口放到 0.5–4 倍时，真实游戏画面的粗层候选会把预算耗尽量不出（八方2 10-28 两档实测）；
    25% 盖得住银河2 那种 1.222 倍横拉，再大的横拉匹配不上判「未验」，不会误判过。

    返回 (status, stretch_pct, reason)。
    status: "pass" | "fail" | "inconclusive" | "error"
    """
    tool_path = Path(__file__).parent / "aspect_measure.py"
    if not tool_path.exists():
        return "error", None, "aspect_measure.py not found"

    with Image.open(reference_path) as ref, Image.open(target_path) as tgt:
        hr = min(tgt.width / ref.width, tgt.height / ref.height)
    try:
        result = subprocess.run(
            [
                sys.executable,
                str(tool_path),
                str(reference_path),
                str(target_path),
                str(template_path),
                "--max-stretch-pct",
                str(threshold_pct),
                "--min-scale",
                f"{hr / 1.25:.4f}",
                "--max-scale",
                f"{hr * 1.25:.4f}",
            ],
            capture_output=True,
            text=True,
            timeout=120,
            check=False,
        )

        if result.returncode not in (0, 1, 2):
            return "error", None, f"aspect_measure.py exit {result.returncode}"

        output = json.loads(result.stdout)
        status = output.get("status")
        stretch_pct = output.get("comparison", {}).get("absolute_stretch_pct")
        reason = output.get("reason", "")

        return status, stretch_pct, reason

    except subprocess.TimeoutExpired:
        return "error", None, "aspect_measure.py timeout"
    except Exception as exc:
        return "error", None, f"aspect_measure.py failed: {exc}"


def measure_interpolation_stretch(image):
    """测量插值拉伸（扩展带拉丝）。

    扩展带定义：中间 高×16/9 以外的两侧。
    返回 (中间区比值, 扩展带比值, 判定)。
    比值 = (横向相邻差的 RMS) / (纵向相邻差的 RMS)。
    扩展带比值明显低于中间区 = 被横向插值拉伸。
    """
    arr = pixels(image)
    height, width = arr.shape[:2]

    # 计算中间 16:9 区域宽度
    center_width = int(height * 16 / 9)

    if center_width >= width:
        # 图像不够宽，没有扩展带
        return None, None, "no_expansion_area"

    # 中间区：水平居中的 16:9 区域
    center_left = (width - center_width) // 2
    center_right = center_left + center_width
    center_region = arr[:, center_left:center_right, :]

    # 扩展带：左右两侧
    if center_left > 0:
        left_expansion = arr[:, :center_left, :]
        right_expansion = arr[:, center_right:, :]
        expansion_region = np.concatenate([left_expansion, right_expansion], axis=1)
    else:
        return None, None, "no_expansion_area"

    def edge_ratio(region):
        """计算区域的横向/纵向相邻差比值。"""
        if region.shape[0] < 2 or region.shape[1] < 2:
            return None

        # 横向相邻差（沿 x 方向）
        horizontal_diff = np.diff(region, axis=1)
        horizontal_rms = float(np.sqrt(np.mean(horizontal_diff ** 2)))

        # 纵向相邻差（沿 y 方向）
        vertical_diff = np.diff(region, axis=0)
        vertical_rms = float(np.sqrt(np.mean(vertical_diff ** 2)))

        if vertical_rms < 1e-9:
            return None

        return horizontal_rms / vertical_rms

    center_ratio = edge_ratio(center_region)
    expansion_ratio = edge_ratio(expansion_region)

    if center_ratio is None or expansion_ratio is None:
        return center_ratio, expansion_ratio, "insufficient_data"

    # 判定：扩展带比值 / 中间区比值 < 阈值 = 拉丝
    ratio_of_ratios = expansion_ratio / center_ratio

    if ratio_of_ratios < INTERPOLATION_RATIO_THRESHOLD:
        verdict = "interpolated"
    else:
        verdict = "ok"

    return center_ratio, expansion_ratio, verdict


def _host_fill(text):
    """host.log 文本 → (判据开没开, 「【红】出图未满屏」次数, 末态 满 / 红)"""
    judge_on, red, last = False, 0, "满"
    for line in text.splitlines():
        if "[画] 满屏判据 已开" in line:
            judge_on = True
        elif "【红】出图未满屏" in line:
            red += 1; last = "红"
        elif "出图恢复满屏" in line:
            last = "满"
    return judge_on, red, last


def judge_host_log(path, base=None):
    """上屏层（宿主每次出图都判几何、已豁免按设计留边的页）——截图只是游戏画幅，量不到上屏画布的黑边（#822 发现）。
    要求：有「[画] 满屏判据 已开」（没有 = 这条出图路径不打判据，没红行不等于满屏），「【红】出图未满屏」累计 ≤ UNFILLED_MAX，
    且末态满屏（最后一条是「出图恢复满屏」或从未红）。返回 (measurement, 不过原因, 未验原因)。
    base：同存档同路线、只差被测改动的对照局 host.log（宽屏第二层闭环的不开点对照局）。给了且对照局判据开着时，次数上限取
    max(UNFILLED_MAX, 对照局次数)——判的是被测改动的边际影响：对照局本来就有的未满屏（10-30 马车8：两局同在第 510 / 2460 次出图起，
    通用模式菜单页 / 过场的界面层缺口）不算到被测点头上，另按独立缺陷跟。末态仍要满。"""
    try:
        text = Path(path).read_text(errors="replace")
    except OSError:
        return {}, [], ["缺 host.log，上屏层未量"]
    judge_on, red, last = _host_fill(text)
    m = {"judge_on": judge_on, "unfilled": red, "last_state": last}
    if not judge_on:
        return m, [], ["host.log 没有「[画] 满屏判据 已开」，上屏层未量"]
    cap = UNFILLED_MAX
    if base is not None:
        try:
            b_on, b_red, _ = _host_fill(Path(base).read_text(errors="replace"))
        except OSError:
            b_on, b_red = False, 0
        if b_on:
            m["base_unfilled"] = b_red; cap = max(UNFILLED_MAX, b_red)
    bad = []
    if red > cap:
        bad.append(f"上屏未满屏累计 {red} 次 > {cap}" + (f"（对照局 {m['base_unfilled']} 次）" if "base_unfilled" in m else ""))
    if last != "满":
        bad.append("上屏未满屏后没恢复（末态仍没铺满）")
    return m, bad, []


def judge_profile(image_path, reference_path=None, template_path=None, page=False, host_log=None, ui_reference=None):
    """判定一档比例的截图。page=True：菜单 / 2D 页截图（不是 MARK 场景帧），允许「按设计留边」。

    返回 {
        "result": "pass" | "fail" | "unverified",
        "reasons": [...],
        "measurements": {...}
    }
    """
    image = read_image(image_path, "target")
    measurements = {}
    reasons = []

    # 1. 占宽 / 占高
    cov_w, cov_h, left_b, right_b, top_b, bottom_b = measure_coverage(image)
    measurements["coverage_width"] = round(cov_w, 4)
    measurements["coverage_height"] = round(cov_h, 4)
    measurements["black_borders"] = {
        "left": left_b,
        "right": right_b,
        "top": top_b,
        "bottom": bottom_b,
    }

    if cov_w < COVERAGE_THRESHOLD:
        reasons.append(f"占宽 {cov_w*100:.2f}% < {COVERAGE_THRESHOLD*100}%")
    if cov_h < COVERAGE_THRESHOLD:
        reasons.append(f"占高 {cov_h*100:.2f}% < {COVERAGE_THRESHOLD*100}%")

    # 2. 黑边
    borders = measure_black_borders(image)
    measurements["black_border_pixels"] = {
        "left": borders[0],
        "right": borders[1],
        "top": borders[2],
        "bottom": borders[3],
    }

    total_border = sum(borders)
    if total_border > BLACK_BORDER_MAX:
        reasons.append(f"黑边 {total_border} px > {BLACK_BORDER_MAX}")

    # 按设计留边（画面线 10-28）：页面本身没有外延内容时宿主按 16:9 居中、两侧 / 上下纯黑，不拉伸、不花屏，
    # 不比宽屏关着差，不判不过。只对菜单页（page）成立：MARK 场景帧留边 = 宽屏没生效，照旧不过。
    # 判法：黑带都是整行 / 整列纯黑（measure_black_borders 只数整条纯黑），内容框居中（两侧差 ≤2 px）且宽高比 = 16:9（±1%）
    if page and total_border > BLACK_BORDER_MAX:
        l, r, t, b = borders
        h, w = image.height - t - b, image.width - l - r
        if h > 0 and w > 0 and abs(l - r) <= 2 and abs(t - b) <= 2 and abs(w / h / (16 / 9) - 1) <= 0.01:
            measurements["letterbox_by_design"] = {"content": [w, h]}
            reasons = [x for x in reasons if not x.startswith(("占宽", "占高", "黑边"))]

    # 3. 非等比拉伸（要 16:9 对照图）：给了模板走 aspect_measure（界面元素）；没给就整图缩放搜索 measure_scale——
    #    两局是不同时刻的画面（灯光脉动、水面、人物待机），模板逐像素匹配到不了 aspect_measure 写死的相关 ≥0.985，量不出（八方2 10-28 实测）
    unverified = []
    if reference_path and template_path:
        status, stretch, reason = call_aspect_measure(reference_path, image_path, template_path, STRETCH_THRESHOLD_PCT)
        measurements["aspect_stretch"] = {"status": status, "stretch_pct": stretch, "reason": reason, "method": "aspect_measure"}
    elif reference_path:
        sx, sy, peak, margin = measure_scale(read_image(reference_path, "reference"), image)
        stretch = abs(sx / sy - 1) * 100
        confident = peak >= SCALE_MIN_PEAK and margin >= SCALE_MIN_MARGIN
        status = ("fail" if stretch >= STRETCH_THRESHOLD_PCT else "pass") if confident else "inconclusive"
        reason = f"横缩放 {sx:.3f} / 纵缩放 {sy:.3f}，梯度相关峰值 {peak:.2f}、比偏 3% 高 {margin:.2f}"
        measurements["aspect_stretch"] = {"status": status, "stretch_pct": stretch, "reason": reason, "method": "measure_scale",
                                          "sx": sx, "sy": sy, "peak": peak, "margin": margin}
    else:
        status, stretch, reason = "not_tested", None, "no_reference"
        measurements["aspect_stretch"] = {"status": status, "reason": reason}
    if status == "fail":
        reasons.append(f"非等比拉伸 {stretch:.1f}% ≥ {STRETCH_THRESHOLD_PCT}%（{reason}）")
    elif status == "not_tested":
        unverified.append("缺 16:9 对照图，非等比拉伸未量")
    elif status != "pass":
        unverified.append(f"非等比拉伸量不出：{status}（{reason}）")

    # 4. 插值拉伸（扩展带拉丝）：不依赖对照图，照样量
    center_r, expansion_r, interp_verdict = measure_interpolation_stretch(image)
    measurements["interpolation"] = {"center_ratio": center_r, "expansion_ratio": expansion_r, "verdict": interp_verdict}
    if interp_verdict == "interpolated":
        reasons.append(f"扩展带拉丝：扩展带 / 中间区 = {expansion_r / center_r:.4f} < {INTERPOLATION_RATIO_THRESHOLD}")
    elif interp_verdict == "insufficient_data":
        unverified.append("扩展带拉丝量不出（纹理不足）")

    # 5. 两侧带与中间不连续（旧帧残留 / 铺满画布的界面层只画了中间）：不依赖对照图
    seam = measure_side_seam(image)
    measurements["side_seam"] = seam
    if seam:
        for side, name in (("left", "左"), ("right", "右")):
            if seam[side] is not None and seam[side] >= SEAM_ROWS_MAX:
                reasons.append(f"{name}侧带与中间不连续：16:9 边界第 {seam[side + '_col']} 列接缝贯穿 {seam[side] * 100:.0f}% 行 ≥ {SEAM_ROWS_MAX * 100:.0f}%（两侧不是本帧内容：旧帧残留 / 界面层没铺满）")

    # 5b. 两侧扩展带空洞（清屏色 / 旧缓冲 / 无地面）：不依赖对照图
    hole = measure_side_hole(image)
    measurements["side_hole"] = hole
    if hole:
        for side, name in (("left", "左"), ("right", "右")):
            if hole[side] is not None and hole[side] >= HOLE_EXCESS:
                reasons.append(f"{name}侧扩展带空洞：纯色块占比比中间多 {hole[side]:.2f} ≥ {HOLE_EXCESS}")

    # 5c. 界面横向比（只对静止界面页、给了同页 k=1 对照时量）
    if page and ui_reference:
        st, rd = ui_ratio(ui_reference, image_path)
        measurements["ui_ratio"] = {"status": st, "reading": rd}
        if st == "fail": reasons.append(f"界面横向比偏离 16:9 > {UI_RATIO_MAX * 100:g}%：{rd}")
        elif st == "unverified": unverified.append(rd)

    # 6. 上屏层（宿主 host.log）
    if host_log:
        hm, hbad, hun = judge_host_log(host_log)
        measurements["host_present"] = hm
        reasons += hbad
        unverified += hun

    # 综合：任一项明确不过 → 不过；否则缺项 → 未验；全过 → 过
    result = "fail" if reasons else ("unverified" if unverified else "pass")
    return {"result": result, "reasons": reasons + unverified, "measurements": measurements}


def _grad(image, width):
    g = np.asarray(image.convert("L").resize((width, round(image.height * width / image.width)), Image.BILINEAR), dtype=np.float32)
    return np.hypot(np.diff(g, axis=1)[:-1], np.diff(g, axis=0)[:, :-1])


def _scale_score(ref, tgt, sx, sy, width):
    """把宽屏图中心按 (sx, sy) 取一块缩回对照图大小，比两图梯度（抗灯光明暗）中间 3/4 区的归一化相关；出界 -1"""
    cw, ch = ref.width * sx, ref.height * sy
    box = ((tgt.width - cw) / 2, (tgt.height - ch) / 2, (tgt.width + cw) / 2, (tgt.height + ch) / 2)
    if box[0] < -0.5 or box[1] < -0.5 or box[2] > tgt.width + 0.5 or box[3] > tgt.height + 0.5:
        return -1.0
    crop = tgt.crop(tuple(round(v) for v in box)).resize(ref.size, Image.BILINEAR)
    a, b = _grad(ref, width), _grad(crop, width)
    h, w = a.shape
    a, b = a[h // 8:h - h // 8, w // 8:w - w // 8], b[h // 8:h - h // 8, w // 8:w - w // 8]
    a, b = a - a.mean(), b - b.mean()
    d = float(np.sqrt((a * a).sum() * (b * b).sum()))
    return float((a * b).sum()) / d if d else 0.0


def measure_scale(ref, tgt):
    """整图缩放搜索：满屏放宽只多出视野，16:9 对照内容在宽屏图中心、缩放 = 宽之比 / 高之比取小者。
    先找统一缩放（±25%，步长 0.5%，梯度图宽 320），再横、纵各自细调两轮（±1%，步长 0.1%，宽 640）。
    返回 (横缩放, 纵缩放, 峰值相关, 峰值比「横 ×1.03、纵 ÷1.03」高多少)。
    标定（10-28，八方2 真截图 + 由它造的反例）：横拉 1% / 2% / 5% / 22.2% 量出 1.0 / 2.1 / 5.1 / 22.0%；真宽屏图峰值 0.53 / 0.83"""
    s0 = min(tgt.width / ref.width, tgt.height / ref.height)
    coarse = [s0 * (1 + k / 200) for k in range(-50, 51)]
    s = max(coarse, key=lambda v: _scale_score(ref, tgt, v, v, 320))
    sx = max(coarse, key=lambda v: _scale_score(ref, tgt, v * s / s0, s, 320))
    sx = sx * s / s0
    sy = s
    for _ in range(2):
        sx = max((sx * (1 + k / 1000) for k in range(-10, 11)), key=lambda v: _scale_score(ref, tgt, v, sy, 640))
        sy = max((sy * (1 + k / 1000) for k in range(-10, 11)), key=lambda v: _scale_score(ref, tgt, sx, v, 640))
    peak = _scale_score(ref, tgt, sx, sy, 640)
    off = _scale_score(ref, tgt, s * 1.03, s / 1.03, 640)
    return sx, sy, peak, peak - max(off, 0.0)


def format_tsv_row(args, judgment):
    """格式化为 TSV 行（与 docs/名单_满屏比例/ 列相同）。"""
    result_map = {"pass": "过", "fail": "不过", "unverified": "未验"}
    result = result_map[judgment["result"]]

    # 读数：从 measurements 提取关键信息
    measurements = judgment["measurements"]
    readings = []

    cov_w = measurements.get("coverage_width", 0) * 100
    cov_h = measurements.get("coverage_height", 0) * 100
    readings.append(f"占宽 / 占高 {cov_w:.1f} / {cov_h:.1f}")

    borders = measurements.get("black_border_pixels", {})
    total_border = sum(borders.values())
    readings.append(f"黑边 {total_border}")
    hp = measurements.get("host_present")
    if hp and hp.get("judge_on"):
        readings.append(f"上屏未满屏 {hp['unfilled']} 次")
    if "letterbox_by_design" in measurements:
        cw, ch = measurements["letterbox_by_design"]["content"]
        readings.append(f"按设计 16:9 居中留边（内容 {cw}×{ch}，页面无外延内容）")

    aspect = measurements.get("aspect_stretch", {})
    if aspect.get("status") == "pass" or aspect.get("status") == "fail":
        stretch = aspect.get("stretch_pct", 0)
        readings.append(f"拉伸 {stretch:.4f}%")

    seam = measurements.get("side_seam")
    if seam:
        readings.append("16:9 边界接缝行 左 / 右 " + " / ".join("—" if seam[k] is None else f"{seam[k] * 100:.0f}%" for k in ("left", "right")))

    interp = measurements.get("interpolation", {})
    if interp.get("center_ratio") and interp.get("expansion_ratio"):
        readings.append(f"扩展带 / 中间区横纵细节比 {interp['expansion_ratio'] / interp['center_ratio']:.3f}")
    if judgment["result"] != "pass":
        readings.append("原因：" + "；".join(judgment["reasons"]))

    reading_str = "；".join(readings)

    # 依据：工具名 + 截图文件名
    dependency = f"tools/widen_accept.py，{Path(args.image).name}"

    # 列：程序号 / 构建号 / 款 / 档位 / 平台 / 结论 / 日期 / 读数 / 依据
    today = date.today().strftime("%Y-%m-%d")
    row = [
        args.tid,
        args.build,
        args.game,
        args.profile,
        args.platform,
        result,
        today,
        reading_str,
        dependency,
    ]

    return "\t".join(row)


RATIO_TABLE = "docs/名单_满屏比例"   # 按款登记目录（docs/名单_满屏比例/<程序号>.tsv，tools/reglist.py）
VERIFIED_TABLE = "graphics/widen/tables/verified.tsv"


def require_write_platform(platform):
    """Android measurement is read-only until ledger and admission consumers are platform-scoped."""
    if platform == "Android":
        raise ValueError("Android 量具当前只读输出；台账与已验证名单的平台隔离尚未接线，暂不支持 --write。")


def write_tables(repo, row):
    """#658「全过自动写入已验证名单」：比例表就地更新这一（程序号, 构建号, 档位, 平台）行，没有就追加在同款最后一行后；
    之后该款（程序号 + 构建号）比例表有「过」、没有「不过」，且 verified.tsv 没有这款 → 追加一行。只加不删：撤 verified 由 jhz 定。"""
    cells = row.split("\t")
    require_write_platform(cells[4])
    key = (cells[0], cells[1], cells[3], cells[4])
    sys.path.insert(0, str(Path(__file__).parent)); import reglist   # 比例表按款拆目录（10-30）：合并读、改行、拆回写
    lines = reglist.text(str(repo), "名单_满屏比例").split("\n")
    out, hit, last_same = [], False, None
    for line in lines:
        c = line.split("\t")
        if not line.startswith("#") and len(c) >= 5 and (c[0], c[1], c[3], c[4]) == key:
            line, hit = row, True
        out.append(line)
        if not line.startswith("#") and len(c) >= 2 and (c[0], c[1]) == key[:2]:
            last_same = len(out) - 1
    if not hit:
        if last_same is None:
            while out and out[-1] == "":
                out.pop()
            out += [row, ""]
        else:
            out.insert(last_same + 1, row)
    reglist.write(str(repo), "名单_满屏比例", "\n".join(out))
    notes = [f"写入 {RATIO_TABLE}：{'更新' if hit else '新增'} {cells[2]} {cells[3]} {cells[4]} {cells[5]}"]
    verdicts = [l.split("\t")[5] for l in out if not l.startswith("#") and l.split("\t")[:2] == list(key[:2])]
    vpath = repo / VERIFIED_TABLE
    vtext = vpath.read_text(encoding="utf-8")
    listed = any(l.split("\t")[:2] == [key[0], key[1]] for l in vtext.split("\n") if not l.startswith("#"))
    if "过" in verdicts and "不过" not in verdicts and not listed:
        # 平台列（F7 #1574）：本工具只在 Mac / iPhone / iPad / Duo 上验收（--platform），都是苹果实现域 → apple
        vrow = "\t".join([key[0], key[1], cells[2], "apple", cells[6], f"tools/widen_accept.py 自动验收：{RATIO_TABLE} 本款各档 过 {verdicts.count('过')}、不过 0"])
        vpath.write_text(vtext.rstrip("\n") + "\n" + vrow + "\n", encoding="utf-8")
        notes.append(f"写入 {VERIFIED_TABLE}：新增 {cells[2]}")
    return notes


def parser():
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    p.add_argument("--game", required=True, help="款名（如 octopath2）")
    p.add_argument("--tid", required=True, help="程序号（16 位大写，如 0100A3501946E000）")
    p.add_argument("--build", required=True, help="主程序构建号（32 位小写，如 0d9649011312f62e93f6a5673a09d7e9）")
    p.add_argument("--profile", required=True, choices=list(PROFILES.keys()), help="档位（如 19.5:9）")
    p.add_argument("--image", required=True, help="宽屏截图路径")
    p.add_argument("--reference", help="16:9 参照截图路径（可选）")
    p.add_argument("--template", help="模板截图路径（用于非等比拉伸测量，可选）")
    p.add_argument("--platform", default="Mac", choices=["Mac", "iPhone", "iPad", "Duo", "Android"], help="平台，默认 Mac")
    p.add_argument("--host-log", help="开局 host.log：读宿主上屏层满屏判据（未满屏红行次数 / 末态）")
    p.add_argument("--write", metavar="仓库根", help="把结论写进 <仓库根>/docs/名单_满屏比例/（同程序号+构建号+档位+平台就地更新）；"
                   "写后该款有过、没有不过、verified.tsv 还没有这款时补一行（只加不删）")
    p.add_argument("--ui-reference", help="同一界面页的 k=1（不开满屏）对照截图：与 --page 同用时量界面横向比（偏离 16:9 > 2%% 不过，不同页记未验）")
    p.add_argument("--page", action="store_true", help="菜单 / 2D 页截图：16:9 居中纯黑留边判「按设计留边」，不判不过")
    p.add_argument("--json", action="store_true", help="输出 JSON 格式（默认 TSV）")
    return p


def main():
    args = parser().parse_args()

    try:
        if args.write:
            require_write_platform(args.platform)
        global np, Image
        import numpy as np
        from PIL import Image

        judgment = judge_profile(args.image, args.reference, args.template, page=args.page, host_log=args.host_log, ui_reference=args.ui_reference)

        if args.json:
            output = {
                "game": args.game,
                "tid": args.tid,
                "build": args.build,
                "profile": args.profile,
                "platform": args.platform,
                "judgment": judgment,
            }
            print(json.dumps(output, ensure_ascii=False, indent=2))
        else:
            print(format_tsv_row(args, judgment))
        if args.write and judgment["result"] in ("pass", "fail"):
            for line in write_tables(Path(args.write), format_tsv_row(args, judgment)):
                print(line, file=sys.stderr)

        # 退出码：0=过，1=不过，2=未验/错误
        if judgment["result"] == "pass":
            return 0
        elif judgment["result"] == "fail":
            return 1
        else:
            return 2

    except ImportError as exc:
        print(json.dumps({"error": f"missing dependency: {exc}"}), file=sys.stderr)
        return 2
    except ValueError as exc:
        print(json.dumps({"error": str(exc)}), file=sys.stderr)
        return 2
    except Exception as exc:
        print(json.dumps({"error": f"unexpected error: {exc}"}), file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
