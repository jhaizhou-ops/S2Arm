#!/bin/bash
# 真机交互运行器的计划解析单测（tools/xcui/Runner/Plan.swift，Mac 上直接编，不碰设备 / XCTest）：bash tests/xcui_plan_test.sh
# 门禁覆盖：tools/xcui/Runner/Plan.swift
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d "${TMPDIR:-/tmp}/xcui_plan.XXXXXX"); trap 'rm -rf "$T"' EXIT
xcrun swiftc -O -o "$T/t" "$H/tools/xcui/Runner/Plan.swift" "$H/tests/xcui/main.swift" 2> "$T/cc.log" || { cat "$T/cc.log"; echo "xcui_plan 单测有不通（编译）"; exit 1; }
"$T/t" && echo "xcui_plan 单测全过" || { echo "xcui_plan 单测有不通"; exit 1; }
