#!/usr/bin/env python3
"""C0：从真实源码生成 NVN API / 命令记录覆盖表（不读游戏数据）。

输入（唯一来源）：
  graphics/nvn/gfx/nvn/names.txt     —— 游戏 nvnBootstrapLoader 会查询的 536 个名字
  graphics/nvn/gfx/nvn/hle_nvn.c     —— 实际注册的 NVN(...) / NVN_NOPROTO(...) 实现
  graphics/nvn/gfx/nvn/nvn_obj.h     —— 命令记录 opcode（OP_...，到 OP_COUNT_）
  graphics/nvn/gfx/nvn/nvn_mtl.m     —— Metal 回放实际处理了哪些 opcode（case OP_...）

输出严格 JSON。测试会把重新生成的结果与仓库内 JSON 比较；源码变化必须同批更新覆盖表，
不能靠运行时静默接受未知函数/记录。本工具只做静态清点：实现存在不等于语义正确，也不
代表 Android 后端已实现同名记录。
"""
import argparse
import importlib.util
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
NVN_DIR = ROOT / "graphics" / "nvn" / "gfx" / "nvn"


def function_table():
    names = [line.strip() for line in (NVN_DIR / "names.txt").read_text(encoding="utf-8").splitlines()
             if line.strip()]
    source = (NVN_DIR / "hle_nvn.c").read_text(encoding="utf-8")
    implemented = re.findall(r"^NVN(?:_NOPROTO)?\((\w+)\s*,", source, re.MULTILINE)
    return names, implemented


def record_table():
    header = (NVN_DIR / "nvn_obj.h").read_text(encoding="utf-8")
    # 去掉 // 注释再取名字：注释里提到 OP_BEGIN 不能算第二个枚举值。
    code = re.sub(r"//[^\n]*", "", header)
    match = re.search(r"OP_END,(.*?)OP_COUNT_", code, re.DOTALL)
    if not match:
        raise SystemExit("nvn_obj.h: record opcode enum not found")
    opcodes = ["OP_END"] + re.findall(r"\bOP_[A-Z0-9_]+\b", match.group(1))
    metal = (NVN_DIR / "nvn_mtl.m").read_text(encoding="utf-8")
    handled = sorted(set(re.findall(r"case (OP_[A-Z0-9_]+):", metal)))
    return opcodes, handled


def entry_classes():
    """上游入口分类（已实现/部分/空操作/未实现）：只说明 hle_nvn.c 的入口形态，不是 Vulkan 语义。"""
    path = ROOT / "graphics" / "nvn" / "tools" / "nvn_func_table.py"
    spec = importlib.util.spec_from_file_location("s2a_nvn_func_table", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.classes()


def vulkan_semantics():
    path = ROOT / "android" / "contracts" / "direct" / "nvn-vulkan-semantics-v1.json"
    document = json.loads(path.read_text(encoding="utf-8"))
    if document.get("schema") != "s2a-nvn-vulkan-semantics-v1":
        raise SystemExit(f"{path}: wrong schema")
    functions = document.get("functions", {})
    for name, entry in functions.items():
        if not isinstance(entry, dict) or entry.get("status") not in ("executed", "unsupported"):
            raise SystemExit(f"{path}: {name} needs status executed|unsupported")
        if not entry.get("evidence"):
            raise SystemExit(f"{path}: {name} has no evidence")
    return functions


def build():
    names, implemented = function_table()
    classes = entry_classes()
    if set(classes) != set(names):
        raise SystemExit("entry classification does not cover the frozen name table")
    counts = {kind: sum(value == kind for value in classes.values())
              for kind in ("已实现", "部分", "空操作", "未实现")}
    expected = {"已实现": 538, "部分": 11, "空操作": 18, "未实现": 3}
    if counts != expected:
        raise SystemExit(f"entry classification changed: {counts} != {expected}")
    semantics = vulkan_semantics()
    duplicates = sorted({name for name in implemented if implemented.count(name) > 1})
    unknown = sorted(set(implemented) - set(names))
    missing = sorted(set(names) - set(implemented))
    opcodes, handled = record_table()
    unknown_ops = sorted(set(handled) - set(opcodes))
    unhandled = sorted(set(opcodes) - set(handled))
    return {
        "schema": "s2a-nvn-cover-v1",
        "sources": [
            "graphics/nvn/gfx/nvn/names.txt",
            "graphics/nvn/gfx/nvn/hle_nvn.c",
            "graphics/nvn/gfx/nvn/nvn_obj.h",
            "graphics/nvn/gfx/nvn/nvn_mtl.m",
        ],
        "functions": {
            "total": len(names),
            "implemented": len(implemented),
            "unimplemented": len(missing),
            "duplicateImplementations": duplicates,
            "implementedNotInNameTable": unknown,
            "implementedNames": sorted(implemented),
            "unimplementedNames": missing,
            "entryClassCounts": counts,
            "entryClasses": classes,
            "vulkanSemantics": {
                "executed": sorted(n for n, e in semantics.items() if e["status"] == "executed"),
                "unsupported": sorted(n for n, e in semantics.items() if e["status"] == "unsupported"),
            },
        },
        "records": {
            "opcodes": opcodes,
            "metalHandled": handled,
            "metalUnhandled": unhandled,
            "metalHandlesUnknownOpcode": unknown_ops,
        },
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", help="write JSON here (default: stdout)")
    parser.add_argument("--check", help="compare with this checked-in JSON")
    args = parser.parse_args()
    document = build()
    text = json.dumps(document, ensure_ascii=False, indent=1, sort_keys=True) + "\n"
    if args.check:
        expected = Path(args.check).read_text(encoding="utf-8")
        if text != expected:
            print("nvn cover table: STALE (regenerate after source changes)", file=sys.stderr)
            return 1
        if document["functions"]["duplicateImplementations"] or \
           document["functions"]["implementedNotInNameTable"] or \
           document["records"]["metalHandlesUnknownOpcode"]:
            print("nvn cover table: inconsistent source inventory", file=sys.stderr)
            return 1
        print("nvn cover table: ok ({} functions: {} implemented / {} unimplemented; entry classes "
              "538/11/18/3; Vulkan executed {} / unsupported {}; {} record opcodes: {} metal-handled / {} unhandled)".format(
                  document["functions"]["total"], document["functions"]["implemented"],
                  document["functions"]["unimplemented"],
                  len(document["functions"]["vulkanSemantics"]["executed"]),
                  len(document["functions"]["vulkanSemantics"]["unsupported"]),
                  len(document["records"]["opcodes"]), len(document["records"]["metalHandled"]),
                  len(document["records"]["metalUnhandled"])))
        return 0
    if args.output:
        Path(args.output).write_text(text, encoding="utf-8")
    else:
        sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
