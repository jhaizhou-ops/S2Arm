#!/usr/bin/env python3
"""C3 前置：核对共享 NVN 前端的记录布局与回放 decoder 是否同源一致（不跑 GPU）。

检查项（全部从真实源码读出，不读游戏数据）：
  · nvn_obj.h 的 BIND_BUF_DEFER 标记；hle_nvn.c 用它在录制时保存 NVNbufferRange 地址；
    nvn_mtl.m 的回放 cb（bb_fresh）在执行到该记录时才读 guest 范围。
  · p_clear_tex 的 value_type 三态（float / uint / int）；三个 ClearTexture 入口写入对应
    联合体成员；nvn_mtl.m 按 value_type 选择取值，不再有旧 is_uint 语义。
  · nvn_obj.h 的每个记录 opcode 都有 nvn_mtl.m 的 case（Metal 回放覆盖；不等于 Vulkan 已实现）。
输出严格 JSON；`--check` 任一项不满足退出 1。

注意：本工具只证明 Metal 回放与共享记录一致，不能证明 Android Vulkan 后端已实现这些语义，
也不把 Metal 的 no-op / 忽略状态当作 Vulkan 可接受行为。
"""
import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
NVN = ROOT / "graphics" / "nvn" / "gfx" / "nvn"
OBJ = NVN / "nvn_obj.h"
HLE = NVN / "hle_nvn.c"
MTL = NVN / "nvn_mtl.m"


def line_of(text, pattern):
    match = re.search(pattern, text, re.MULTILINE)
    return (text[:match.start()].count("\n") + 1, match.group(0).strip()) if match else (None, None)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--check")
    parser.add_argument("--output")
    args = parser.parse_args()
    obj, hle, mtl = OBJ.read_text(encoding="utf-8"), HLE.read_text(encoding="utf-8"), MTL.read_text(encoding="utf-8")

    checks = []
    def add(name, ok, file, line, evidence):
        checks.append({"name": name, "ok": bool(ok), "file": file, "line": line, "evidence": evidence})

    line, text = line_of(obj, r"^#define BIND_BUF_DEFER 0x100.*$")
    add("defer-marker-defined", line is not None, "graphics/nvn/gfx/nvn/nvn_obj.h", line, text)

    line, text = line_of(hle, r"bind_bufs_deferred\(NVNcommandBuffer \*c.*$")
    body = hle[text and hle.find(text):] if text else ""
    defer_record = re.search(r"\(int32_t\)st \| BIND_BUF_DEFER", body)
    add("defer-marker-recorded", bool(defer_record), "graphics/nvn/gfx/nvn/hle_nvn.c", line,
        defer_record.group(0) if defer_record else "missing (int32_t)st | BIND_BUF_DEFER")
    add("defer-saves-range-address",
        bool(re.search(r"\(uint64_t\)\(uintptr_t\)\(rg \+ i\)", body)),
        "graphics/nvn/gfx/nvn/hle_nvn.c", line, "addr = address of NVNbufferRange, read at replay")

    line, text = line_of(mtl, r"static inline const p_bind_buf \*bb_fresh\(.*$")
    fresh = mtl[line * 0 - 0:] if line is None else mtl[mtl.find(text):mtl.find(text) + 800]
    add("defer-read-at-execution",
        "BIND_BUF_DEFER" in fresh and "NVNbufferRange" in fresh and "r->address" in fresh and "r->size" in fresh,
        "graphics/nvn/gfx/nvn/nvn_mtl.m", line, "bb_fresh reads the guest NVNbufferRange when the record executes")

    line, text = line_of(obj, r"^enum \{ CLEAR_TEX_FLOAT, CLEAR_TEX_UINT, CLEAR_TEX_INT \};.*$")
    add("clear-value-types-defined", line is not None, "graphics/nvn/gfx/nvn/nvn_obj.h", line, text)
    add("clear-record-has-value-type",
        bool(re.search(r"uint8_t has_view, value_type;.*?union \{ float f\[4\]; uint32_t u\[4\]; int32_t i\[4\]; \} c;", obj)),
        "graphics/nvn/gfx/nvn/nvn_obj.h", None, "p_clear_tex.value_type + c.f/c.u/c.i")

    for symbol, member, kind in (("nvnCommandBufferClearTexture", "c.f", "CLEAR_TEX_FLOAT"),
                                 ("nvnCommandBufferClearTexturei", "c.i", "CLEAR_TEX_INT"),
                                 ("nvnCommandBufferClearTextureui", "c.u", "CLEAR_TEX_UINT")):
        line, _ = line_of(hle, rf"^NVN\({symbol},.*$")
        body = hle[hle.find(f"NVN({symbol},"):]
        body = body[:body.find("\n}\n") + 3] if body else ""
        add(f"clear-{kind.lower()}-recorded",
            f"o->value_type = {kind}" in body and f"o->{member}" in body,
            "graphics/nvn/gfx/nvn/hle_nvn.c", line, f"{symbol} records value_type={kind} and copies from {member}")

    add("clear-old-is-uint-gone",
        "is_uint" not in obj and "is_uint" not in hle and "is_uint" not in mtl,
        "graphics/nvn/gfx/nvn/{nvn_obj.h,hle_nvn.c,nvn_mtl.m}", None, "no classifier may read the removed is_uint field")
    add("clear-metal-selects-type",
        "c->value_type == CLEAR_TEX_UINT" in mtl and "c->value_type == CLEAR_TEX_INT" in mtl and
        "c->c.u[" in mtl and "c->c.i[" in mtl,
        "graphics/nvn/gfx/nvn/nvn_mtl.m", line_of(mtl, r"MTLClearColor color = .*$")[0],
        "Metal clear picks float/uint/int from value_type; Vulkan must use the matching VkClearColorValue member")

    code = re.sub(r"//[^\n]*", "", obj)
    enum = re.search(r"OP_END,(.*?)OP_COUNT_", code, re.DOTALL)
    opcodes = ["OP_END"] + re.findall(r"\bOP_[A-Z0-9_]+\b", enum.group(1)) if enum else []
    handled = set(re.findall(r"case (OP_[A-Z0-9_]+):", mtl))
    unhandled = sorted(set(opcodes) - handled)
    add("metal-handles-all-records", not unhandled, "graphics/nvn/gfx/nvn/nvn_mtl.m", None,
        "unhandled=" + ",".join(unhandled) if unhandled else f"all {len(opcodes)} opcodes have a case")

    document = {
        "schema": "s2a-nvn-record-consistency-v1",
        "sources": ["graphics/nvn/gfx/nvn/nvn_obj.h", "graphics/nvn/gfx/nvn/hle_nvn.c", "graphics/nvn/gfx/nvn/nvn_mtl.m"],
        "checks": checks,
        "vulkanExecution": "not-implemented: this tool only proves the shared record layout and the Metal replay agree",
    }
    text = json.dumps(document, ensure_ascii=False, indent=1, sort_keys=True) + "\n"
    if args.check:
        expected = Path(args.check).read_text(encoding="utf-8")
        if text != expected:
            print("nvn record consistency: STALE (source changed; regenerate the JSON)", file=sys.stderr)
            return 1
    if args.output:
        Path(args.output).write_text(text, encoding="utf-8")
    else:
        sys.stdout.write(text)
    failed = [c for c in checks if not c["ok"]]
    if failed:
        for c in failed:
            print(f"FAIL {c['name']} ({c['file']}:{c['line']}): {c['evidence']}", file=sys.stderr)
        return 1
    print(f"nvn record consistency: ok ({len(checks)} checks; Vulkan execution not claimed)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
