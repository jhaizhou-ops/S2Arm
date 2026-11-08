#!/usr/bin/env python3
"""两端 NVN→Vulkan 格式契约（D7「格式信息表」的前置检查，不改生产代码）。

规则来自 NVN 格式名的自述语义，而不是被测实现的输出：
- `*UI` → Vulkan 存储必须是 `*_UINT`；
- `*UI2F` → `*_UINT` 或 `*_USCALED`（整数存储、读进着色器转浮点，两种实现都可）；
- `*I` → `*_SINT`；
- `*I2F` → `*_SINT` 或 `*_SSCALED`；
- 带 `_SRGB` → `*_SRGB`；
- `DEPTH*` / `*STENCIL*` → `VK_FORMAT_D*`（或含 `_S8`）。

另外把当前尚未映射的格式钉成显式清单：新增 NVN 格式却没加映射时这里会红，必须同笔更新清单或映射。
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
NVN_H = ROOT / "graphics/nvn/gfx/nvn/include/nvn.h"
VK_FMT = ROOT / "android/native/nvn/nvn_vk_format.c"

# 当前已知缺口（补映射时同笔删掉对应行）。UI2F/I2F 走 USCALED/SSCALED、BGR 家族与
# RGBX 补齐后当前没有缺口。
KNOWN_UNMAPPED = set()
SENTINELS = {"NVN_FORMAT_NONE", "NVN_FORMAT_LARGE"}


def parse_nvn(path):
    text = path.read_text(encoding="utf-8")
    return {name: int(value, 16)
            for name, value in re.findall(r"(NVN_FORMAT_[A-Za-z0-9_]+)\s*=\s*(0x[0-9A-Fa-f]+)", text)}


def parse_mapping(path):
    pairs, pending = {}, []
    for line in path.read_text(encoding="utf-8").splitlines():
        pending += re.findall(r"case\s+(NVN_FORMAT_[A-Za-z0-9_]+)\s*:", line)
        m = re.search(r"return\s+(VK_FORMAT_[A-Za-z0-9_]+)\s*;", line)
        if m and pending:
            for n in pending:
                pairs[n] = m.group(1)
            pending = []
    return pairs


def main():
    names = parse_nvn(NVN_H)
    mapping = parse_mapping(VK_FMT)
    problems = []

    for nvn, vk in sorted(mapping.items()):
        if nvn not in names:
            problems.append(f"{nvn} 不在 nvn.h 里（改名了？）")
            continue
        if nvn.endswith("UI2F"):
            if "_UINT" not in vk and "_USCALED" not in vk:
                problems.append(f"{nvn} 是整数存储（2F），映射到 {vk}（缺 _UINT / _USCALED）")
        elif nvn.endswith("UI"):
            if "_UINT" not in vk:
                problems.append(f"{nvn} 是整数存储，映射到 {vk}（缺 _UINT）")
        elif nvn.endswith("I2F"):
            if "_SINT" not in vk and "_SSCALED" not in vk:
                problems.append(f"{nvn} 是整数存储（2F），映射到 {vk}（缺 _SINT / _SSCALED）")
        elif nvn.endswith("I"):
            if "_SINT" not in vk:
                problems.append(f"{nvn} 是整数存储，映射到 {vk}（缺 _SINT）")
        if "SRGB" in nvn and "_SRGB" not in vk:
            problems.append(f"{nvn} 是 sRGB，映射到 {vk}（缺 _SRGB）")
        if nvn.startswith("NVN_FORMAT_DEPTH") or "STENCIL" in nvn:
            if not (vk.startswith("VK_FORMAT_D") or "D24" in vk or "_S8" in vk):
                problems.append(f"{nvn} 是深度/模板，映射到 {vk}")

    real_names = {n for n in names if n not in SENTINELS}
    unmapped = real_names - set(mapping)
    missing = KNOWN_UNMAPPED - unmapped
    extra = unmapped - KNOWN_UNMAPPED
    for n in sorted(missing):
        problems.append(f"KNOWN_UNMAPPED 里的 {n} 已经有映射了：请同笔删掉这一行")
    for n in sorted(extra):
        problems.append(f"{n} 没有 Vulkan 映射，也不在 KNOWN_UNMAPPED 里：补映射或登记缺口")

    print(f"两端格式契约：{len(mapping)} 个已映射 / {len(unmapped)} 个已知缺口 / {len(real_names)} 个 NVN 格式")
    for p in problems:
        print("✗ " + p)
    if problems:
        return 1
    print("✓ nvn_fmt_contract：整型 / sRGB / 深度模板规则全符，缺口清单一致")
    return 0


if __name__ == "__main__":
    sys.exit(main())
