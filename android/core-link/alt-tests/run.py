#!/usr/bin/env python3
"""Offline host regression for the real shared alt.c provider, not an Android run."""

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    cc = os.environ.get("CC", "cc")
    if not shutil.which(cc):
        raise RuntimeError(f"missing compiler: {cc}")
    records = []

    def run(name, command, *, alt=None, succeeds=True):
        env = os.environ.copy()
        env.pop("S2A_ALT", None)
        if alt is not None:
            env["S2A_ALT"] = alt
        result = subprocess.run([str(value) for value in command], env=env,
                                capture_output=True, text=True, check=False)
        (out / f"{name}.log").write_text(result.stdout + result.stderr)
        records.append({"name": name, "command": [str(value) for value in command],
                        "S2A_ALT": alt, "returncode": result.returncode,
                        "expected_success": succeeds})
        (out / "commands.json").write_text(json.dumps(records, indent=2) + "\n")
        if (result.returncode == 0) != succeeds:
            raise RuntimeError(f"{name} unexpected result {result.returncode}: {result.stdout}{result.stderr}")
        print(f"PASS {name}")
        return result

    flags = [cc, "-std=c11", "-D_POSIX_C_SOURCE=200809L", "-O2", "-Wall", "-Wextra", "-Werror",
             "-I", ROOT / "runtime/include"]
    if sys.platform == "darwin":
        # 真实 Apple 平台层还使用 BSD / Mach 扩展，不能仅暴露 POSIX 声明。
        flags.append("-D_DARWIN_C_SOURCE")
    owner = out / "alt-owner.o"
    # 公共实现无平台分支；可控 now_ns 只用于纳秒边界反证。
    run("compile-shared-owner", [*flags, "-c", ROOT / "runtime/src/alt.c", "-o", owner])
    fixture = out / "phase-test.o"
    run("compile-consumer", [*flags, "-c", HERE / "phase_test.c", "-o", fixture])
    missing = run("missing-owner-rejected", [cc, fixture, "-o", out / "missing-owner"], succeeds=False)
    if "s2a_alt_phase" not in missing.stderr or "s2a_alt_mark" not in missing.stderr:
        raise RuntimeError("missing-owner control failed for an unrelated reason")
    exe = out / "phase-test"
    run("link-real-owner", [cc, fixture, owner, "-o", exe])
    run("boundaries-and-remark", [exe, "enabled"], alt="2")
    for name, value in [("unset", None), ("zero", "0"), ("negative", "-1"), ("invalid", "word")]:
        run(f"disabled-{name}", [exe, "disabled"], alt=value)

    if sys.platform == "darwin":
        # 真时钟验收必须包含公共 owner 及实际 Apple 平台实现，不能沿用测试时钟。
        clock_sources = [ROOT / "runtime/src/os.c", ROOT / "platform/apple/plat_apple.c"]
        apple = out / "t-alt-apple"
        run("compile-apple-owner", [*flags, ROOT / "runtime/tests/t_alt.c",
                                   ROOT / "runtime/src/alt.c", *clock_sources, "-o", apple])
        run("apple-phase-boundaries", [apple])
        ap_host = out / "t-ap-host"
        run("compile-apple-mark-consumer", [*flags, "-DS2A_UNIT_TEST", ROOT / "runtime/tests/t_ap_host.c",
                                           ROOT / "runtime/src/ap_host.c", "-o", ap_host])
        run("apple-mark-consumer", [ap_host])
        # 独立进程再验首次 MARK 后的真实信号查询；不冒充 Bionic / Android 验收。
        real = out / "phase-real-clock"
        run("compile-apple-signal-query", [*flags, "-DREAL_PLATFORM_CLOCK", HERE / "phase_test.c",
                                           ROOT / "runtime/src/alt.c", *clock_sources, "-o", real])
        run("apple-real-clock-signal-query", [real, "enabled"], alt="3600")
    print("PASS shared alt owner host regression; Android link/device acceptance remains separate")


if __name__ == "__main__":
    main()
