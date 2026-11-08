#!/usr/bin/env python3
"""中立格式表 vs Android Vulkan 映射（nvn_vk_format.c）。

对每个已映射的 NVN 格式，用 VkFormat 名字判定 kind / sRGB / 深度模板，与中立表比对；
深度/模板格式的 kind 不参与（Vk 侧 D32_SFLOAT_S8_UINT 既有 float 又有 uint，用 depth/stencil 判即可）。
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
INFO = ROOT / "graphics/nvn/gfx/nvn/nvn_fmt_info.h"
VK = ROOT / "android/native/nvn/nvn_vk_format.c"
KINDS = {"NVN_FMT_UNORM": 0, "NVN_FMT_SNORM": 1, "NVN_FMT_UINT": 2, "NVN_FMT_SINT": 3, "NVN_FMT_FLOAT": 4}


def parse_info():
    text = INFO.read_text(encoding="utf-8")
    out = {}
    for m in re.finditer(r"\[0x([0-9A-Fa-f]+)\] = \{([^}]*)\}", text):
        parts = [p.strip() for p in m.group(2).split(",")]
        out[int(m.group(1), 16)] = {
            "kind": KINDS[parts[4]], "srgb": int(parts[5]), "depth": int(parts[6]), "stencil": int(parts[7]),
        }
    return out


def parse_mapping():
    pairs, cur = {}, []
    for line in VK.read_text(encoding="utf-8").splitlines():
        cur += re.findall(r"case\s+(NVN_FORMAT_[A-Za-z0-9_]+)\s*:", line)
        m = re.search(r"return\s+(VK_FORMAT_[A-Za-z0-9_]+)\s*;", line)
        if m and cur:
            for n in cur:
                pairs[n] = m.group(1)
            cur = []
    return pairs


def vk_kind(vk):
    if "_UINT" in vk or "_USCALED" in vk:
        return 2
    if "_SINT" in vk or "_SSCALED" in vk:
        return 3
    if "_SNORM" in vk:
        return 1
    if "_SFLOAT" in vk or "_UFLOAT" in vk:
        return 4
    return 0


def main():
    info, mapping = parse_info(), parse_mapping()
    problems, checked = [], 0
    # 名字→数值
    text = (ROOT / "graphics/nvn/gfx/nvn/include/nvn.h").read_text(encoding="utf-8")
    values = {n: int(v, 16) for n, v in re.findall(r"(NVN_FORMAT_[A-Za-z0-9_]+)\s*=\s*(0x[0-9A-Fa-f]+)", text)}
    # 覆盖：中立表里的所有 NVN 格式在 nvn_vk_format 里都不允许落成 UNDEFINED——
    # 8E Wonder 直连的顶点属性就因未映射格式绘制失败 → SIGABRT（first_draw 崩落）。
    # 只有确实没有对应 VkFormat 的形式才允许进显式豁免清单。
    allowed_unmapped = set()
    names_by_value = {}
    for n, v in values.items():
        names_by_value.setdefault(v, n)
    for f in sorted(info):
        nvn = names_by_value.get(f, f"0x{f:x}")
        if nvn not in mapping and nvn not in allowed_unmapped:
            problems.append(f"{nvn}（0x{f:x}）：中立表にあるのに VkFormat 未対応")
    for nvn, vk in sorted(mapping.items()):
        f = values[nvn]
        if f not in info:
            problems.append(f"{nvn}：中立表没有")
            continue
        i = info[f]
        checked += 1
        if i["depth"] or i["stencil"]:
            if not (vk.startswith("VK_FORMAT_D") or "D24" in vk or "_S8" in vk):
                problems.append(f"{nvn} -> {vk}：中立表是深度/模板，VkFormat 不像")
            continue
        k = vk_kind(vk)
        if k != i["kind"]:
            problems.append(f"{nvn} -> {vk}：kind {k} != 中立表 {i['kind']}")
        srgb = 1 if "_SRGB" in vk else 0
        if srgb != i["srgb"]:
            problems.append(f"{nvn} -> {vk}：sRGB {srgb} != 中立表 {i['srgb']}")
    print(f"中立表 vs Vulkan：{checked} 个已映射格式")
    for p in problems:
        print("✗ " + p)
    if problems:
        return 1
    print("✓ nvn_fmt_vk：已映射格式的 kind / sRGB / 深度模板与中立表一致")
    return 0


if __name__ == "__main__":
    sys.exit(main())
