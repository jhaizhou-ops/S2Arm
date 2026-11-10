#!/usr/bin/env python3
"""Require every discovered XCTest to finish; a trailing Swift Testing '0 tests' is not evidence."""
from collections import Counter
from pathlib import Path
import re
import sys


def main():
    discovery, execution = (Path(p).read_text() for p in sys.argv[1:])
    # 旧启动器与 S2Arm × NX2Apple 适配层（launchers/macos/adapter）两个 XCTest 模块都要跑完
    modules = r"(?:S2ArmLauncherTests|S2ArmAppleAdapterTests)"
    expected = set(re.findall(rf"^{modules}\.([^\s/]+/[^\s]+)$", discovery, re.M))
    finished = re.findall(rf"^Test Case '-\[{modules}\.([^\s]+) ([^\s]+)\]' (passed|failed|skipped)", execution, re.M)
    observed = Counter(f"{suite}/{method}" for suite, method, _ in finished)
    missing = sorted(expected - observed.keys())
    unexpected = sorted(observed.keys() - expected)
    repeated = sorted(name for name, count in observed.items() if count != 1)
    failed = sum(state == "failed" for _, _, state in finished)
    skipped = sum(state == "skipped" for _, _, state in finished)
    if not expected or missing or unexpected or repeated or failed or skipped:   # 跳过也不算通过（11-01 审计 P2-51：原先只打印）
        print(f"XCTest 未完整通过：发现 {len(expected)}，完成 {len(finished)}，失败 {failed}，跳过 {skipped}", file=sys.stderr)
        skipped_names = [f"{suite}/{method}" for suite, method, state in finished if state == "skipped"]
        # 失败的用例点名 + 断言原文（11-09：合入后全量红只报「失败 1」、没有用例名，定位只能二分，把一次不稳定失败归到了只改文档的提交上）
        failed_names = [f"{suite}/{method}" for suite, method, state in finished if state == "failed"]
        for name in failed_names:
            suite, method = name.split("/", 1)
            why = re.findall(rf"^(.*error: -\[{modules}\.{re.escape(suite)} {re.escape(method)}\] : .*)$", execution, re.M)
            print(f"失败：{name}" + "".join(f"\n    {line.strip()[:400]}" for line in why[:3]), file=sys.stderr)
        for label, names in (("未完成", missing), ("未登记", unexpected), ("重复", repeated), ("跳过", skipped_names)):
            if names:
                print(f"{label}：" + ", ".join(names), file=sys.stderr)
        return 1
    print(f"XCTest 完成核对：发现 {len(expected)}，完成 {len(finished)}，失败 {failed}，跳过 {skipped}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
