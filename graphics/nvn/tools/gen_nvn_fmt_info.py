#!/usr/bin/env python3
"""从 nvn.h 的格式名生成中立格式信息表（D7 B）。

不手写 128 条：规则来自格式名自述语义（R/RG/RGB/RGBA、8/16/32、UI/I/SN/F、SRGB、DEPTH/STENCIL、
DXT/BC/RGTC/BPTC/ASTC），生成结果由 t_nvn_fmt_info_core 与 nvn_tex 的 bpb 交叉核对。

用法：
  python3 graphics/nvn/tools/gen_nvn_fmt_info.py            # 重写 graphics/nvn/gfx/nvn/nvn_fmt_info.h
  python3 graphics/nvn/tools/gen_nvn_fmt_info.py --check    # 只检查生成头是否与当前 nvn.h 一致
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
NVN_H = ROOT / "graphics/nvn/gfx/nvn/include/nvn.h"
OUT = ROOT / "graphics/nvn/gfx/nvn/nvn_fmt_info.h"
UNORM, SNORM, UINT, SINT, FLOAT = 0, 1, 2, 3, 4
# 上传时展开目标（缺口族 30）：三分量 → 同类四分量；*UI2F / *I2F → 浮点；RGB10A2 有符号 → 16 位
EXPAND = {
    0x19: 0x25, 0x1A: 0x26, 0x1B: 0x27, 0x1C: 0x28, 0x1D: 0x29, 0x1E: 0x2A,
    0x1F: 0x2B, 0x20: 0x2C, 0x21: 0x2D, 0x22: 0x2E, 0x23: 0x2F, 0x24: 0x30,
    0x51: 0x05, 0x52: 0x05, 0x53: 0x0A, 0x54: 0x0A, 0x55: 0x0A, 0x56: 0x0A,
    0x57: 0x11, 0x58: 0x11, 0x59: 0x16, 0x5A: 0x16, 0x5B: 0x16, 0x5C: 0x16,
    0x5D: 0x29, 0x5E: 0x29, 0x5F: 0x2E, 0x60: 0x2E, 0x61: 0x2E, 0x62: 0x2E,
    0x63: 0x29, 0x64: 0x29, 0x65: 0x2E, 0x66: 0x2E, 0x67: 0x2E, 0x68: 0x2E,
    0x69: 0x2B, 0x6A: 0x2D, 0x6B: 0x29, 0x6C: 0x29,
}
KIND_NAME = {UNORM: "NVN_FMT_UNORM", SNORM: "NVN_FMT_SNORM", UINT: "NVN_FMT_UINT",
             SINT: "NVN_FMT_SINT", FLOAT: "NVN_FMT_FLOAT"}


def classify(name):
    n = name[len("NVN_FORMAT_"):]
    bw = bh = 1
    srgb = "SRGB" in n
    depth = n.startswith("DEPTH")
    stencil = "STENCIL" in n
    if depth or stencil:
        kind = FLOAT if n.startswith("DEPTH32F") else UNORM
    elif "UI2F" in n or n.endswith("UI"):
        kind = UINT
    elif "I2F" in n or (n.endswith("I") and not n.endswith("UI")):
        kind = SINT
    elif "SN" in n:
        kind = SNORM
    elif n.endswith("F") or "FLOAT" in n:
        kind = FLOAT
    else:
        kind = UNORM
    if depth or stencil:
        ch = 1
    elif "ASTC" in n or n.startswith(("BPTC", "RGTC")):
        ch = 4
    elif "DXT" in n:
        ch = 3 if n.startswith("RGB_DXT1") else 4
    elif "R11G11B10" in n or "RGB9E5" in n:
        ch = 3
    elif n.startswith("A1BGR"):
        ch = 4
    elif n.startswith("BGR"):
        ch = 4 if n.startswith(("BGRX", "BGRA", "BGR5A1")) else 3
    elif n.startswith("RGBX"):
        ch = 4
    elif n.startswith("RGB10A2"):
        ch = 4
    elif n.startswith("RGBA"):
        ch = 4
    elif n.startswith("RGB"):
        ch = 3
    elif n.startswith("RG"):
        ch = 2
    elif n.startswith("R"):
        ch = 1
    else:
        ch = 0
    m = re.search(r"ASTC_(\d+)x(\d+)", n)
    if m:
        bw, bh = int(m.group(1)), int(m.group(2))
        b = 16
    elif "DXT1" in n or "RGTC1" in n:
        b = 8
        bw = bh = 4
    elif "DXT3" in n or "DXT5" in n or "RGTC2" in n or "BPTC" in n:
        b = 16
        bw = bh = 4
    elif stencil and not depth:
        b = 1
    elif n.startswith("DEPTH16"):
        b = 2
    elif n.startswith("DEPTH24_STENCIL8"):
        b = 4
    elif n.startswith("DEPTH32F_STENCIL8"):
        b = 8
    elif n.startswith(("DEPTH24", "DEPTH32F")):
        b = 4
    elif "RGB10A2" in n:
        b = 4
    elif "R11G11B10" in n or "RGB9E5" in n:
        b = 4
    elif n.startswith(("RGB565", "BGR565", "RGB5", "BGR5", "RGBA4", "ABGR4", "A1BGR5", "BGR5A1")):
        b = 2
    else:
        m = re.search(r"(\d+)", n)
        bits = int(m.group(1)) if m else 0
        b = bits // 8 * ch
    return ch, b, bw, bh, kind, int(srgb), int(depth), int(stencil)


def render():
    text = NVN_H.read_text(encoding="utf-8")
    names = {name: int(value, 16) for name, value in
             re.findall(r"(NVN_FORMAT_[A-Za-z0-9_]+)\s*=\s*(0x[0-9A-Fa-f]+)", text)}
    entries = []
    for name, fmt in names.items():
        if fmt in (0, 0x7FFFFFFF):
            continue
        ch, b, bw, bh, kind, srgb, depth, stencil = classify(name)
        if not ch or not b:
            raise SystemExit(f"无法分类：{name}")
        entries.append((fmt, ch, b, bw, bh, kind, srgb, depth, stencil, EXPAND.get(fmt, 0)))
    entries.sort()
    max_fmt = max(f for f, *_ in entries)
    lines = [
        "// NVN 格式信息（D7 B）：Metal 与 Vulkan 映射共用的中立元数据。",
        "// 由 graphics/nvn/tools/gen_nvn_fmt_info.py 从 nvn.h 的格式名生成，勿手改；",
        "// t_nvn_fmt_info_core 会与 nvn_tex 的 bpb / 块宽高交叉核对。",
        "#pragma once",
        "#include <stdint.h>",
        "",
        "enum { NVN_FMT_UNORM = 0, NVN_FMT_SNORM = 1, NVN_FMT_UINT = 2, NVN_FMT_SINT = 3, NVN_FMT_FLOAT = 4 };",
        f"enum {{ NVN_FMT_MAX = 0x{max_fmt:X}, NVN_FMT_COUNT = {len(entries)} }};",
        "typedef struct { uint8_t channels, bytes, bw, bh, kind, srgb, depth, stencil; uint8_t expand; } nvn_fmt_info;",
        "",
        "static const nvn_fmt_info nvn_fmt_info_table[NVN_FMT_MAX + 1] = {",
    ]
    by_fmt = {e[0]: e for e in entries}
    for fmt, ch, b, bw, bh, kind, srgb, depth, stencil, exp in entries:
        if exp:
            if exp not in by_fmt:
                raise SystemExit(f"展开目标 0x{exp:02X} 不在表里（源 0x{fmt:02X}）")
            t = by_fmt[exp]
            want_ch = 4 if ch == 3 else ch
            if t[1] != want_ch or t[9] != 0:
                raise SystemExit(f"展开目标 0x{exp:02X} 通道 {t[1]} != {want_ch} 或仍会再展开（源 0x{fmt:02X}）")
            if fmt in (0x69, 0x6A):
                want = SNORM if fmt == 0x69 else SINT
            elif 0x51 <= fmt <= 0x68 or fmt in (0x6B, 0x6C):
                want = FLOAT
            else:
                want = kind
            if t[5] != want:
                raise SystemExit(f"展开目标 0x{exp:02X} kind {t[5]} != 期望 {want}（源 0x{fmt:02X}）")
        lines.append(f"    [0x{fmt:02X}] = {{{ch}, {b}, {bw}, {bh}, {KIND_NAME[kind]}, {srgb}, {depth}, {stencil}, 0x{exp:02X}}},")
    lines += [
        "};",
        "",
        "static inline int nvn_fmt_info_of(uint32_t f, nvn_fmt_info *out) {",
        "    if (f > NVN_FMT_MAX || !nvn_fmt_info_table[f].bytes) return 0;",
        "    if (out) *out = nvn_fmt_info_table[f];",
        "    return 1;",
        "}",
        "",
    ]
    return "\n".join(lines)


def main():
    want = render()
    if "--check" in sys.argv[1:]:
        if not OUT.exists() or OUT.read_text(encoding="utf-8") != want:
            print("【红】nvn_fmt_info.h 与 nvn.h 不同步：跑 python3 graphics/nvn/tools/gen_nvn_fmt_info.py")
            return 1
        print(f"✓ nvn_fmt_info.h 与 nvn.h 同步（{want.count(chr(91)+'0x')} 条）")
        return 0
    OUT.write_text(want, encoding="utf-8")
    print(f"已生成 {OUT.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
