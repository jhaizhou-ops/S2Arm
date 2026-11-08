#!/usr/bin/env python3
# 门禁手动：要传参数：--app / --library-dir 预构建的 ReadonlyCopy.Tests 与只读拷贝库；同组 dma 模式已由 texture_read_test.py 在 android/test.sh 门禁跑
"""Run actual DMA preserve-read consumer and negative controls; no downloads."""
import argparse
import json
import os
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--dotnet", default="dotnet")
parser.add_argument("--app", type=Path, required=True)
parser.add_argument("--library-dir", type=Path, required=True)
parser.add_argument("--out", type=Path, required=True)
args = parser.parse_args()
root = Path(__file__).resolve().parents[4]
out = args.out.resolve()
if out == root or root in out.parents:
    parser.error("--out must be outside the checkout")
out.mkdir(parents=True, exist_ok=True)
results = []
# dma-default is the production path after the fix (platform readonly copy).
# dma-red is the old default (borrowed span) forced by a diagnostic env; it must AV
# on a tracker-protected destination page. dma-green is the explicit provider path.
for mode in ["dma-default", "dma-red", "dma-green", "dma-untracked-fallback", "dma-negative", "dma-missing-provider"]:
    env = os.environ.copy()
    env.pop("S2A_DMA_PRESERVE_READ", None)
    env.pop("S2A_DMA_BORROWED_READ", None)
    if mode == "dma-red":
        env["S2A_DMA_BORROWED_READ"] = "1"
    for name in ["LD_LIBRARY_PATH", "DYLD_LIBRARY_PATH"]:
        env[name] = str(args.library_dir.resolve()) + os.pathsep + env.get(name, "")
    command = [args.dotnet, str(args.app.resolve()), mode]
    result = subprocess.run(command, env=env, capture_output=True, text=True, timeout=30)
    output = result.stdout + result.stderr
    expected_red = mode == "dma-red"
    passed = (result.returncode != 0 and "ENTER protected actual DmaClass.LaunchDma" in output
              and "AccessViolation" in output) if expected_red else (
                  result.returncode == 0 and "PASS " + mode + ":" in output)
    (out / (mode + ".log")).write_text(output, encoding="utf-8")
    results.append(dict(case=mode, command=command, exit_code=result.returncode,
                        expected_red=expected_red, passed=passed))
    print(mode, result.returncode, passed, flush=True)
(out / "results.json").write_text(json.dumps(results, indent=2), encoding="utf-8")
raise SystemExit(0 if all(result["passed"] for result in results) else 1)
