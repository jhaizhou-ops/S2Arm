#!/usr/bin/env python3
"""中立格式表 vs Metal 映射（nvn_fmt_mtl.c，纯 C 表，可在 Linux 检查）。

只比 exact 项（E / X / EV / ER / XR：EV 数据原样、分量反着读，ER / XR 数据原样、r/b 互换）：格式名必须与中立表的 kind / sRGB / 深度模板一致；
substitute（S）是刻意的近似映射（精度 / 位序 / 读法不同），只计数；
expanded（XP，上传时展开成另一格式：三分量补四分量、*UI2F/*I2F 转浮点、RGB10A2 有符号转 16 位）只计数；
N 是没有 Metal 对应，也只计数。这样 Metal 侧不用等 Mac 就能被中立表约束。
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
INFO = ROOT / "graphics/nvn/gfx/nvn/nvn_fmt_info.h"
MTL = ROOT / "graphics/nvn/gfx/tex/nvn_fmt_mtl.c"
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


def parse_metal():
    src = MTL.read_text(encoding="utf-8")
    start = src.index("static const ent T[0x9D] = {") + len("static const ent T[0x9D] = {")
    body = src[start:]
    body = body[:body.index("};")]
    body = re.sub(r"//[^\n]*", "", body)
    table, idx = {}, 0
    for m in re.finditer(r"\[0x([0-9A-Fa-f]+)\]|\b(E|EV|ER|XR|X|S|XP)\(([A-Za-z0-9_]+)\)|\bN\b", body):
        desig, macro, arg = m.groups()
        if desig is not None:
            idx = int(desig, 16)
        elif macro:
            table[idx] = (macro, arg)
            idx += 1
        else:
            table[idx] = ("N", None)
            idx += 1
    return table


def metal_kind(name):
    if name.endswith("Uint"):
        return 2
    if name.endswith("Sint"):
        return 3
    if name.endswith("Snorm"):
        return 1
    if name.endswith("Float"):
        return 4
    if name.endswith("Unorm") or name.endswith("Unorm_sRGB"):
        return 0
    return None


def main():
    info, metal = parse_info(), parse_metal()
    problems, exact, substitute, expanded, none = [], 0, 0, 0, 0
    for f, (macro, arg) in sorted(metal.items()):
        if f not in info:
            problems.append(f"Metal 表有 0x{f:02X}，中立表没有")
            continue
        if macro == "N":
            none += 1
            continue
        if macro == "S":
            substitute += 1
            continue
        if macro == "XP":
            expanded += 1
            continue
        exact += 1
        k = metal_kind(arg)
        if k is not None and k != info[f]["kind"]:
            problems.append(f"0x{f:02X} {arg}：Metal kind {k} != 中立表 {info[f]['kind']}")
        srgb = 1 if "_sRGB" in arg else 0
        if srgb != info[f]["srgb"]:
            problems.append(f"0x{f:02X} {arg}：Metal sRGB {srgb} != 中立表 {info[f]['srgb']}")
        depth = 1 if arg.startswith("Depth") else 0
        stencil = 1 if "Stencil" in arg else 0
        if depth != info[f]["depth"] or stencil != info[f]["stencil"]:
            problems.append(f"0x{f:02X} {arg}：Metal 深度/模板 {depth}/{stencil} != 中立表 {info[f]['depth']}/{info[f]['stencil']}")

    print(f"中立表 vs Metal：exact {exact} / substitute {substitute} / 上传时展开 {expanded} / 无对应 {none}")
    for p in problems:
        print("✗ " + p)
    if problems:
        return 1
    print("✓ nvn_fmt_metal：exact 项的 kind / sRGB / 深度模板与中立表一致")
    return 0


if __name__ == "__main__":
    sys.exit(main())
