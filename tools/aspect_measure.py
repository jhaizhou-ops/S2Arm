#!/usr/bin/env python3
"""只读界面元素拉伸量具（I2）；不接运行时 / 判官 / 启用表。

用法：python3 tools/aspect_measure.py reference.png target.png template.png \
    --max-stretch-pct 1
需要当前解释器已有 NumPy、Pillow；不自动安装，不读取隐式环境配置。
标准输出只有 JSON；退出 0=通过，1=已量出超阈值，2=无法可靠测量或输入错误。

模型：一个完整、不透明、轴对齐的矩形模板，整数像素位置与尺寸，独立 x/y
缩放；缩放比较器是 Pillow BILINEAR。粗层对全部平移及对数尺度网格做 RGB
归一化相关，保留分离候选，再在原分辨率优化四条边。输出的是模板整个矩形
（包括模板自带留白），不是按某种颜色分割的可见内容框。

这是有界搜索，不是任意图像的识别保证：不支持旋转、透视、遮挡、透明合成、
亚像素位姿、动画变化；重采样差别 / 噪声可能使结果无法测量。未匹配不诊断
具体原因。模板须在两方向有空间信息；重复元素、低对比度、近等价的不同
尺寸均不能悄悄判绿。置信度读数是拟合诊断，不是校准的概率。近邻拟合的
尺寸区间只在上述整数像素模型内成立，不是物理 / 亚像素测量误差保证。

资源界限：每图最多 4M 像素 / 边长 4096，模板最多 65536 像素 / 边长 512，
候选框最多 262144 像素。粗图边长 <=768；粗层 FFT 边长 <=1024。定位后按
量出的尺寸逐块扫描原图，确认无第二个位置（包括重叠框）；分块 FFT 最多
2M 格，逐通道串行。最多 32 个位置候选，缓存 32 个模板尺寸 / 8192 个分数，
每图精修最多累计 500M 像素。超界 / 候选预算耗尽 / 粗层信息太少退出 2；
不能把合成夹具通过当成真实游戏正确率或 Mac / GPU 验收。
"""

from __future__ import annotations

import argparse
import itertools
import json
import math
import sys
from collections import OrderedDict


class Unmeasurable(Exception):
    """输入可读，但不能在已声明的模型内作可靠结论。"""


def read_image(path, role):
    try:
        with Image.open(path) as source:
            width, height = source.size
            if max(width, height) > 4096 or width * height > 4_194_304:
                raise Unmeasurable(f"{role}: image_resource_limit")
            if getattr(source, "n_frames", 1) != 1:
                raise Unmeasurable(f"{role}: animated_image_unsupported")
            if source.mode not in ("RGB", "RGBA", "L", "LA", "P"):
                raise ValueError(f"{role}: unsupported_pixel_mode: {source.mode}")
            # Do not silently flatten alpha, orient, crop, or rewrite callers' inputs.
            if "A" in source.getbands() or "transparency" in source.info:
                if source.convert("RGBA").getchannel("A").getextrema() != (255, 255):
                    raise ValueError(f"{role}: transparency_unsupported")
            if source.getexif().get(274, 1) != 1:
                raise Unmeasurable(f"{role}: exif_orientation_unsupported")
            return source.convert("RGB")
    except (OSError, ValueError, Image.DecompressionBombError) as exc:
        raise ValueError(f"{role}: cannot_read_image: {exc}") from exc


def pixels(image):
    return np.asarray(image, dtype=np.float32) / 255.0


def check_template(template):
    width, height = template.size
    if min(width, height) < 16:
        raise Unmeasurable("template: insufficient_resolution (minimum dimension 16)")
    if width * height > 65_536 or max(width, height) > 512:
        raise Unmeasurable("template: template_resource_limit")
    data = pixels(template)
    contrast = float(np.std(data, axis=(0, 1)).mean())
    dx = float(np.sqrt(np.mean(np.diff(data, axis=1) ** 2)))
    dy = float(np.sqrt(np.mean(np.diff(data, axis=0) ** 2)))
    if contrast < 0.025 or min(dx, dy) < 0.002:
        raise Unmeasurable("template: insufficient_spatial_information")


def integral(data):
    return np.pad(data.cumsum(0, dtype=np.float64).cumsum(1), ((1, 0), (1, 0), (0, 0)))


def window_sum(table, width, height):
    return (
        table[height:, width:]
        - table[:-height, width:]
        - table[height:, :-width]
        + table[:-height, :-width]
    )


def overlap(a, b):
    ax, ay, aw, ah = a
    bx, by, bw, bh = b
    area = max(0, min(ax + aw, bx + bw) - max(ax, bx)) * max(0, min(ay + ah, by + bh) - max(ay, by))
    return area / min(aw * ah, bw * bh)


def same_location(a, b):
    ax, ay, aw, ah = a
    bx, by, bw, bh = b
    return (
        overlap(a, b) > 0.65
        and abs(ax + aw / 2 - bx - bw / 2) < min(aw, bw) * 0.25
        and abs(ay + ah / 2 - by - bh / 2) < min(ah, bh) * 0.25
    )


def coarse_candidates(image, template, minimum, maximum):
    width, height = image.size
    tw, th = template.size
    factor = max(1.0, max(width, height) / 384, max(tw, th) / 64)
    factor = min(factor, min(tw, th) * minimum / 8)
    if factor < 1 or max(width, height) / factor > 768:
        raise Unmeasurable("search_resolution_limit: use a larger, distinctive template")
    small_size = (round(width / factor), round(height / factor))
    small = pixels(image.resize(small_size, Image.Resampling.BILINEAR))
    sh, sw = small.shape[:2]
    fx, fy = width / sw, height / sh
    fft_shape = (1 << (sh - 1).bit_length(), 1 << (sw - 1).bit_length())
    transformed = np.fft.rfft2(small, s=fft_shape, axes=(0, 1))
    sums, squares = integral(small), integral(small * small)
    steps = max(1, math.ceil(math.log(maximum / minimum) / math.log(1.18)))
    scales = np.geomspace(minimum, maximum, steps + 1).tolist()
    if minimum <= 1 <= maximum:
        scales.append(1.0)
    widths = sorted({round(tw * scale / fx) for scale in scales})
    heights = sorted({round(th * scale / fy) for scale in scales})
    candidates = []
    for cw, ch in itertools.product(widths, heights):
        if cw < 8 or ch < 8 or cw > sw or ch > sh:
            continue
        resized = pixels(template.resize((cw, ch), Image.Resampling.BILINEAR))
        centered = resized - resized.mean(axis=(0, 1), keepdims=True)
        energy = float(np.sum(centered * centered))
        if energy < 0.01:
            continue
        kernel = np.fft.rfft2(centered, s=fft_shape, axes=(0, 1))
        numerator = np.fft.irfft2((transformed * kernel.conj()).sum(axis=2), s=fft_shape)
        numerator = numerator[: sh - ch + 1, : sw - cw + 1]
        total = window_sum(sums, cw, ch)
        variance = (window_sum(squares, cw, ch) - total * total / (cw * ch)).sum(axis=2)
        score = numerator / np.sqrt(np.maximum(variance * energy, 1e-12))
        score[variance < 1e-5] = -1
        # Multiple peaks at every scale are required: one global maximum would hide duplicates.
        for _ in range(3):
            flat_index = int(np.argmax(score))
            y, x = np.unravel_index(flat_index, score.shape)
            correlation = float(score[y, x])
            if correlation < 0.45:
                break
            box = (round(x * fx), round(y * fy), round(cw * fx), round(ch * fy))
            candidates.append((correlation, box))
            score[max(0, y - ch // 2) : y + ch // 2 + 1, max(0, x - cw // 2) : x + cw // 2 + 1] = -1
    chosen = []
    for score, box in sorted(candidates, reverse=True):
        if not any(same_location(box, previous) for _, previous in chosen):
            chosen.append((score, box))
            if len(chosen) > 32:
                raise Unmeasurable("coarse_candidate_budget_exhausted")
    return chosen


class Fitter:
    def __init__(self, image, template, minimum, maximum):
        self.data = pixels(image)
        self.template = template
        self.bounds = (
            max(16, math.ceil(template.width * minimum)),
            math.floor(template.width * maximum),
            max(16, math.ceil(template.height * minimum)),
            math.floor(template.height * maximum),
        )
        self.cache = OrderedDict()
        self.scores = OrderedDict()
        self.work_pixels = 0

    def fit(self, box):
        x, y, width, height = box
        minw, maxw, minh, maxh = self.bounds
        ih, iw = self.data.shape[:2]
        if (
            x < 0
            or y < 0
            or x + width > iw
            or y + height > ih
            or width * height > 262_144
            or not minw <= width <= maxw
            or not minh <= height <= maxh
        ):
            return (float("inf"), -1.0)
        if box in self.scores:
            return self.scores[box]
        self.work_pixels += width * height
        if self.work_pixels > 500_000_000:
            raise Unmeasurable("refinement_work_limit")
        size = (width, height)
        if size not in self.cache:
            model = pixels(self.template.resize(size, Image.Resampling.BILINEAR))
            centered = model - model.mean(axis=(0, 1), keepdims=True)
            self.cache[size] = (model, centered, float(np.sum(centered * centered)))
            if len(self.cache) > 32:
                self.cache.popitem(last=False)
        self.cache.move_to_end(size)
        model, centered, energy = self.cache[size]
        patch = self.data[y : y + height, x : x + width]
        rmse = float(np.sqrt(np.mean((patch - model) ** 2)))
        patch_centered = patch - patch.mean(axis=(0, 1), keepdims=True)
        denominator = math.sqrt(energy * float(np.sum(patch_centered * patch_centered)))
        correlation = (
            float(np.sum(patch_centered * centered)) / denominator if denominator > 1e-12 else -1.0
        )
        value = rmse, min(1.0, correlation)
        self.scores[box] = value
        if len(self.scores) > 8192:
            self.scores.popitem(last=False)
        return value

    def refine(self, box):
        # Optimize left/top/right/bottom, not width alone: scale error moves both edges.
        x, y, width, height = box
        minw, maxw, minh, maxh = self.bounds
        ih, iw = self.data.shape[:2]
        width = max(minw, min(width, maxw, iw))
        height = max(minh, min(height, maxh, ih))
        x, y = max(0, min(x, iw - width)), max(0, min(y, ih - height))
        box = (x, y, width, height)
        edges = (x, y, x + width, y + height)
        best = self.fit(box)
        step = max(2, round(max(width, height) * 0.12))
        converged = False
        while step >= 1:
            converged = False
            for _ in range(8):
                next_edges, next_box, next_best = edges, box, best
                # A scale correction can move BOTH opposing edges. Single-axis
                # descent can get trapped even on an exact 2x bilinear image.
                for offsets in itertools.product((-step, 0, step), repeat=4):
                    left, top, right, bottom = tuple(
                        a + b for a, b in zip(edges, offsets, strict=True)
                    )
                    candidate = (left, top, right - left, bottom - top)
                    value = self.fit(candidate)
                    if value[0] < next_best[0] - 1e-10:
                        next_edges, next_box, next_best = (
                            (left, top, right, bottom),
                            candidate,
                            value,
                        )
                if next_box == box:
                    converged = True
                    break
                edges, box, best = next_edges, next_box, next_best
            step = step // 2
        return best, box, converged


def confirm_unique_position(fitter, box, args, role):
    """Exhaustively check translations at measured dimensions, without overlap NMS.

    FFT is only a permissive prefilter; all potentially admissible matches are
    confirmed by the same full-resolution direct RGB fit. Valid-output tiles
    partition top-left coordinates, so no position is skipped at tile borders.
    """
    _, _, width, height = box
    data = fitter.data
    ih, iw = data.shape[:2]
    fw = 1 << (max(256, 2 * width) - 1).bit_length()
    fh = 1 << (max(256, 2 * height) - 1).bit_length()
    if fw * fh > 2_097_152:
        raise Unmeasurable(f"{role}: uniqueness_verification_resource_limit")
    model = pixels(fitter.template.resize((width, height), Image.Resampling.BILINEAR))
    model_square = float(np.sum(model * model, dtype=np.float64))
    model_means = model.mean(axis=(0, 1), dtype=np.float64)
    model_energy = float(np.sum((model - model_means) ** 2))
    kernels = [np.fft.rfft2(model[:, :, channel], s=(fh, fw)) for channel in range(3)]
    samples = width * height
    confirmed = 0
    for top in range(0, ih - height + 1, fh - height + 1):
        for left in range(0, iw - width + 1, fw - width + 1):
            tile = data[top : top + fh, left : left + fw]
            vh, vw = tile.shape[0] - height + 1, tile.shape[1] - width + 1
            dot = np.zeros((vh, vw), dtype=np.float64)
            square = np.zeros_like(dot)
            mean_square = np.zeros_like(dot)
            mean_model = np.zeros_like(dot)
            for channel in range(3):
                plane = tile[:, :, channel]
                transformed = np.fft.rfft2(plane, s=(fh, fw))
                dot += np.fft.irfft2(transformed * kernels[channel].conj(), s=(fh, fw))[:vh, :vw]
                total = window_sum(integral(plane[:, :, None]), width, height)[:, :, 0]
                square += window_sum(integral((plane * plane)[:, :, None]), width, height)[:, :, 0]
                mean_square += total * total / samples
                mean_model += total * model_means[channel]
            mse = (square + model_square - 2 * dot) / (samples * 3)
            correlation = (dot - mean_model) / np.sqrt(
                np.maximum((square - mean_square) * model_energy, 1e-12)
            )
            # Numeric slack only broadens the FFT prefilter, never the direct
            # acceptance thresholds (including --max-rmse 0).
            possible = np.flatnonzero(
                (mse <= args.max_rmse**2 + 1e-4) & (correlation >= args.min_correlation - 0.002)
            )
            for index in possible:
                y, x = divmod(int(index), vw)
                candidate = (left + x, top + y, width, height)
                if candidate == box:
                    continue
                confirmed += 1
                if confirmed > 4096:
                    raise Unmeasurable(f"{role}: uniqueness_confirmation_budget_exhausted")
                rmse, corr = fitter.fit(candidate)
                if rmse <= args.max_rmse and corr >= args.min_correlation:
                    raise Unmeasurable(f"{role}: ambiguous_match")


def measure(image, template, args, role):
    fitter = Fitter(image, template, args.min_scale, args.max_scale)
    seeds = coarse_candidates(image, template, args.min_scale, args.max_scale)
    if not seeds:
        raise Unmeasurable(f"{role}: no_match")
    fitted = sorted(fitter.refine(box) for _, box in seeds)
    (rmse, correlation), box, converged = fitted[0]
    if rmse > args.max_rmse or correlation < args.min_correlation:
        raise Unmeasurable(
            f"{role}: low_confidence (correlation={correlation:.6f}, rmse={rmse:.6f})"
        )
    if not converged:
        raise Unmeasurable(f"{role}: refinement_did_not_converge")
    competitors = [
        (value, other) for value, other, _ in fitted[1:] if not same_location(box, other)
    ]
    for (other_rmse, other_correlation), _ in competitors:
        if other_rmse <= args.max_rmse and other_correlation >= args.min_correlation:
            raise Unmeasurable(f"{role}: ambiguous_match")
        if other_rmse <= rmse + 0.01 and other_correlation >= correlation - 0.01:
            raise Unmeasurable(f"{role}: ambiguous_match")
    confirm_unique_position(fitter, box, args, role)

    # Near-equivalent integer rectangles define a measured aspect interval. Do not
    # report 0% uncertainty just because the optimizer happened to return one box.
    x, y, width, height = box
    aspects = [width / height]
    near_boxes = 1
    precision_slack = 0.002
    offsets = set(itertools.product(range(-1, 2), repeat=4))
    for axis in range(4):
        for shift in range(-8, 9):
            offset = [0, 0, 0, 0]
            offset[axis] = shift
            offsets.add(tuple(offset))
    for dx, dy, dw, dh in sorted(offsets):
        if dx == dy == dw == dh == 0:
            continue
        candidate = (x + dx, y + dy, width + dw, height + dh)
        alt_rmse, alt_correlation = fitter.fit(candidate)
        if alt_rmse <= rmse + precision_slack and alt_correlation >= correlation - precision_slack:
            aspects.append((width + dw) / (height + dh))
            near_boxes += 1
    center = [x + width / 2, y + height / 2]
    return {
        "image_size": list(image.size),
        "bbox": {"x": x, "y": y, "width": width, "height": height},
        "aspect_ratio": width / height,
        "aspect_interval": [min(aspects), max(aspects)],
        "center_px": center,
        "center_normalized": [center[0] / image.width, center[1] / image.height],
        "confidence": {
            "correlation": correlation,
            "normalized_rmse": rmse,
            "near_equivalent_boxes": near_boxes,
            "precision_rmse_slack": precision_slack,
            "searched_location_candidates": len(seeds),
        },
    }


def parser():
    result = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    result.add_argument("reference", help="16:9 基准截图（只读）")
    result.add_argument("target", help="另一比例截图（只读）")
    result.add_argument("template", help="完整不透明界面元素矩形模板（只读）")
    result.add_argument(
        "--max-stretch-pct",
        required=True,
        type=float,
        help="显式允许的绝对拉伸百分比；例如 1，超过即红；不是全局游戏策略",
    )
    result.add_argument(
        "--min-scale", type=float, default=0.5, help="相对模板各轴最小缩放，默认 0.5"
    )
    result.add_argument("--max-scale", type=float, default=2.0, help="相对模板各轴最大缩放，默认 2")
    result.add_argument(
        "--min-correlation",
        type=float,
        default=0.985,
        help="原分辨率 RGB 相关下限，默认 0.985（只能调严）",
    )
    result.add_argument(
        "--max-rmse",
        type=float,
        default=0.03,
        help="[0,1] RGB 均方根误差上限，默认 0.03（只能调严）",
    )
    return result


def run(args):
    values = [
        args.max_stretch_pct,
        args.min_scale,
        args.max_scale,
        args.min_correlation,
        args.max_rmse,
    ]
    if not all(math.isfinite(value) for value in values):
        raise ValueError("thresholds must be finite")
    if not 0 < args.max_stretch_pct < 100:
        raise ValueError("--max-stretch-pct must be >0 and <100")
    if not 0.25 <= args.min_scale < args.max_scale <= 4:
        raise ValueError("scale range must satisfy 0.25 <= min < max <= 4")
    if not 0.985 <= args.min_correlation <= 1 or not 0 <= args.max_rmse <= 0.03:
        raise ValueError("confidence thresholds may only tighten defaults")
    reference = read_image(args.reference, "reference")
    target = read_image(args.target, "target")
    template = read_image(args.template, "template")
    if abs(reference.width / reference.height / (16 / 9) - 1) > 0.005:
        raise ValueError("reference must be 16:9 (within 0.5% pixel-rounding tolerance)")
    check_template(template)
    ref = measure(reference, template, args, "reference")
    tgt = measure(target, template, args, "target")
    stretch = 100 * (tgt["aspect_ratio"] / ref["aspect_ratio"] - 1)
    low = 100 * (tgt["aspect_interval"][0] / ref["aspect_interval"][1] - 1)
    high = 100 * (tgt["aspect_interval"][1] / ref["aspect_interval"][0] - 1)
    limit = args.max_stretch_pct
    if (
        max(ref["confidence"]["near_equivalent_boxes"], tgt["confidence"]["near_equivalent_boxes"])
        > 1
    ):
        # A stable ratio alone cannot certify a center displacement: translations
        # can be indistinguishable even when every candidate has the same ratio.
        status, reason, code = "inconclusive", "insufficient_geometric_precision", 2
    elif low > limit + 1e-9 or high < -limit - 1e-9:
        status, reason, code = "fail", "stretch_exceeds_threshold", 1
    elif low >= -limit - 1e-9 and high <= limit + 1e-9:
        status, reason, code = "pass", "within_threshold", 0
    else:
        status, reason, code = "inconclusive", "insufficient_precision_at_threshold", 2
    return {
        "schema_version": 1,
        "status": status,
        "reason": reason,
        "model": "opaque_axis_aligned_integer_bbox_bilinear",
        "coordinate_system": "top-left pixel edges; center=(x+w/2,y+h/2); normalized per image W,H; delta=target-reference",
        "thresholds": {
            "max_stretch_pct": limit,
            "min_correlation": args.min_correlation,
            "max_normalized_rmse": args.max_rmse,
        },
        "search": {"min_scale": args.min_scale, "max_scale": args.max_scale},
        "reference": ref,
        "target": tgt,
        "comparison": {
            "stretch_pct": stretch,
            "absolute_stretch_pct": abs(stretch),
            "stretch_interval_pct": [low, high],
            "center_delta_px": [tgt["center_px"][i] - ref["center_px"][i] for i in range(2)],
            "center_delta_normalized": [
                tgt["center_normalized"][i] - ref["center_normalized"][i] for i in range(2)
            ],
        },
    }, code


def main():
    args = parser().parse_args()
    try:
        global np, Image
        import numpy as np
        from PIL import Image

        result, code = run(args)
    except ImportError as exc:
        result, code = (
            {
                "status": "error",
                "reason": f"missing_dependency: {exc}; use an interpreter with NumPy and Pillow",
            },
            2,
        )
    except Unmeasurable as exc:
        result, code = {"status": "inconclusive", "reason": str(exc)}, 2
    except (ValueError, OSError) as exc:
        result, code = {"status": "error", "reason": str(exc)}, 2
    except MemoryError:
        result, code = {"status": "error", "reason": "memory_resource_limit"}, 2
    print(json.dumps(result, ensure_ascii=False, allow_nan=False, sort_keys=True))
    return code


if __name__ == "__main__":
    sys.exit(main())
