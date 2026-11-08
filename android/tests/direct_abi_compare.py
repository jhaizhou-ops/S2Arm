#!/usr/bin/env python3
# 门禁手动：辅助脚本，由 android/tools/direct_abi_check.sh 调用对拍 C / C# / ARM64 三份 JSON（要传 JSON 文件；该脚本含 adb 真机段），本身不独立跑
"""C0 布局对拍：C 主机 / C# 托管 / ARM64 真机三份 JSON 必须与契约常量完全一致。

用法：direct_abi_compare.py [--c FILE] [--cs FILE] [--arm64 FILE]
每个文件的第一行是 s2a-direct-abi-v1 JSON；只比较字段与值，不执行被测实现。
期望值在这里独立写死（不从头文件生成），避免实现自证。
"""
import argparse
import json
import sys

EXPECTED_SIZES = {
    "status": 24, "table": 64, "services_request": 64,
    "services_request_v2": 80, "runtime_status": 24, "runtime_request_v2": 160,
}
EXPECTED_OFFSETS = {
    "status.state": 8, "status.blockers": 12, "status.error": 16, "status.reserved": 20,
    "table.session": 8, "table.context": 16, "table.activate": 24,
    "table.request_stop": 32, "table.query": 40, "table.poll": 48, "table.destroy": 56,
    "services_v2.graphics": 64, "services_v2.graphics_mode": 72, "services_v2.flags": 76,
    "runtime_v2.services": 16, "runtime_v2.module_dir": 96, "runtime_v2.module_names": 104,
    "runtime_v2.module_count": 112, "runtime_v2.program_id": 120,
    "runtime_v2.module_source": 128, "runtime_v2.npdm_path": 136, "runtime_v2.graphics": 144,
}


def load(path):
    with open(path, encoding="utf-8") as stream:
        for line in stream:
            line = line.strip()
            if line.startswith("{"):
                return json.loads(line)
    raise ValueError(f"{path}: no JSON line")


def check(label, document, errors):
    if document.get("schema") != "s2a-direct-abi-v1":
        errors.append(f"{label}: wrong schema")
        return
    if document.get("ptr") != 8:
        errors.append(f"{label}: not an LP64 layout")
    for name, want in EXPECTED_SIZES.items():
        got = document.get("sizes", {}).get(name)
        if got != want:
            errors.append(f"{label}: size {name}={got} want {want}")
    for name, want in EXPECTED_OFFSETS.items():
        got = document.get("offsets", {}).get(name)
        if got != want:
            errors.append(f"{label}: offset {name}={got} want {want}")
    extra = set(document.get("sizes", {})) - set(EXPECTED_SIZES)
    if extra:
        errors.append(f"{label}: unreviewed sizes {sorted(extra)}")
    extra = set(document.get("offsets", {})) - set(EXPECTED_OFFSETS)
    if extra:
        errors.append(f"{label}: unreviewed offsets {sorted(extra)}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--c")
    parser.add_argument("--cs")
    parser.add_argument("--arm64")
    args = parser.parse_args()
    inputs = {name: path for name, path in
              (("c", args.c), ("cs", args.cs), ("arm64", args.arm64)) if path}
    if not inputs:
        parser.error("at least one input required")
    documents, errors = {}, []
    for label, path in inputs.items():
        try:
            documents[label] = load(path)
        except (OSError, ValueError) as error:
            errors.append(f"{label}: {error}")
    for label, document in documents.items():
        check(label, document, errors)
    labels = sorted(documents)
    for label in labels[1:]:
        if documents[label] != documents[labels[0]]:
            errors.append(f"{label} layout differs from {labels[0]}")
    if errors:
        print("direct-abi compare: FAIL")
        for error in errors:
            print("  " + error)
        return 1
    print(f"direct-abi compare: ok ({', '.join(labels)}; {len(EXPECTED_SIZES)} sizes, {len(EXPECTED_OFFSETS)} offsets)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
