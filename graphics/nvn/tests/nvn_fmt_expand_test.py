#!/usr/bin/env python3
"""上传展开目标的三处一致：中立表 expand ↔ Metal XP 条目 ↔ Vulkan 重定向。

Vulkan 的实际映射由 C 用例（t_backend_vk C29）调用 nvn_vk_format 逐码验证；这里静态核对
Metal 的 XP 目标必须等于目标格式的 E 映射，防止两处各写一份。
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
INFO = ROOT / "graphics/nvn/gfx/nvn/nvn_fmt_info.h"
MTL = ROOT / "graphics/nvn/gfx/tex/nvn_fmt_mtl.c"
VK = ROOT / "android/native/nvn/nvn_vk_format.c"


def parse_info():
    out = {}
    for m in re.finditer(r"\[0x([0-9A-Fa-f]+)\] = \{([^}]*)\}", INFO.read_text(encoding="utf-8")):
        parts = [p.strip() for p in m.group(2).split(",")]
        out[int(m.group(1), 16)] = int(parts[8], 16)
    return out


def parse_metal():
    src = MTL.read_text(encoding="utf-8")
    start = src.index("static const ent T[0x9D] = {") + len("static const ent T[0x9D] = {")
    body = src[start:src.index("};", start)]
    body = re.sub(r"//[^\n]*", "", body)
    enum = {n: int(v) for n, v in re.findall(r"^\s*([A-Za-z0-9_]+) = (\d+),", src, re.M)}
    table, idx = {}, 0
    for m in re.finditer(r"\[0x([0-9A-Fa-f]+)\]|(E|X|S|SX|SR|SXR|XP)\(([A-Za-z0-9_]+)\)|\bN\b", body):
        desig, macro, arg = m.groups()
        if desig is not None:
            idx = int(desig, 16)
        elif macro:
            table[idx] = (macro, arg, enum.get(arg, 0))
            idx += 1
        else:
            table[idx] = ("N", None, 0)
            idx += 1
    return table


def main():
    info, metal = parse_info(), parse_metal()
    problems, expanded = [], 0
    for f, exp in sorted(info.items()):
        if not exp:
            if metal.get(f, ("N",))[0] == "XP":
                problems.append(f"0x{f:02X} 中立表不展开，Metal 却标了 XP")
            continue
        expanded += 1
        m = metal.get(f)
        if not m or m[0] != "XP":
            problems.append(f"0x{f:02X} 中立表展开到 0x{exp:02X}，Metal 不是 XP（{m}）")
            continue
        target = metal.get(exp)
        if not target or target[0] not in ("E", "X"):
            problems.append(f"0x{f:02X} 目标 0x{exp:02X} 在 Metal 不是 E/X（{target}）")
        elif m[2] != target[2]:
            problems.append(f"0x{f:02X} XP({m[1]}={m[2]}) != 目标 0x{exp:02X} E({target[1]}={target[2]})")
    src = VK.read_text(encoding="utf-8")
    if "return info.expand ? nvn_vk_format(info.expand) : nvn_vk_format(f);" not in src:
        problems.append("Vulkan nvn_vk_tex_format 没有按表重定向")
    if "if (info.expand) return nvn_vk_format(info.expand);" in src:
        problems.append("Vulkan 全局 nvn_vk_format 又被重定向（会改坏顶点格式）")
    print(f"上传展开：中立表 {expanded} 个，Metal XP 对齐")
    for p in problems:
        print("✗ " + p)
    if problems:
        return 1
    print("✓ nvn_fmt_expand：展开目标与 Metal XP 逐码一致，Vulkan 按表重定向")
    return 0


if __name__ == "__main__":
    sys.exit(main())
