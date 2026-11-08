#!/usr/bin/env python3
"""运行实际 Buffer/BufferHolder 消费者；构建产物和崩溃证据均在外部输出目录。"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time

parser = argparse.ArgumentParser()
parser.add_argument("--out", type=Path, required=True)
parser.add_argument("--dotnet", default=os.environ.get("DOTNET", "dotnet"))
args = parser.parse_args()
dotnet = shutil.which(args.dotnet)
if dotnet is None:
    parser.error("dotnet not found; pass --dotnet or set DOTNET/PATH")
out = args.out.resolve()
app = out / "build/bin/BufferRead.Tests/debug/S2A.SpecTest.dll"
# 夹具放到测试程序同目录，DllImport 按应用目录找到（#199）：不靠 DYLD_LIBRARY_PATH——dotnet 是脚本壳（Homebrew）时经 /bin/bash 转一手，
#   系统会剥掉 DYLD_*，13 例全 abort(-6)；也不从壳的位置推 DOTNET_ROOT（壳的父目录不是 SDK 根），交给 dotnet 自己定位
shutil.copy2(out / "libreadonly_fixture.dylib", app.parent / "libreadonly_fixture.dylib")
env = dict(os.environ)
red_cases = {"red-source", "destination-none", "one-byte-source", "whole-red"}
cases = ["readable", "red-source", "source-readable", "destination-none", "one-byte-source", "whole-red",
         "safe", "whole-safe", "copy-failure", "upload-failure", "wrong-thread", "lease", "pure-no-signal"]
results = []
for case in cases:
    command = [dotnet, str(app), case]
    started = time.monotonic()
    result = subprocess.run(command, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, timeout=20)
    red = case in red_cases
    passed = (result.returncode == -6 and "System.AccessViolationException" in result.stdout
              and "System.SpanHelpers.Memmove" in result.stdout
              and "Ryujinx.Graphics.Vulkan.BufferHolder.SetData" in result.stdout
              and "ENTER actual BufferHolder.SetData" in result.stdout) if red else (
                  result.returncode == 0 and f"PASS {case}:" in result.stdout)
    assertions = re.search(r"PASS .*: (\d+) assertions", result.stdout)
    (out / f"{case}.log").write_text(result.stdout)
    results.append(dict(case=case, expected_red=red, passed=passed, exit_code=result.returncode,
                        assertions=int(assertions[1]) if assertions else 0,
                        seconds=time.monotonic() - started, command=command, log=str(out / f"{case}.log")))
    (out / "results.json").write_text(json.dumps(results, ensure_ascii=False, indent=2) + "\n")
    print(case, "PASS" if passed else "FAIL", result.returncode, flush=True)
raise SystemExit(0 if all(item["passed"] for item in results) else 1)
