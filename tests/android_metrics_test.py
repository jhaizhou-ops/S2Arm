#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# Adapted from PR #209 (wdjwxh); main integration for #208.
"""运行真实C#写出器及跨语言导出链。复用实际生产接缝正反例；隔离空NuGet源，不下载依赖。"""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    dotnet = os.environ.get("DOTNET") or shutil.which("dotnet")
    if not dotnet:
        raise SystemExit("缺.NET 10 SDK；未运行生产写出器检查")
    with tempfile.TemporaryDirectory(prefix="s2a-metrics-test-") as temporary:
        output = Path(temporary) / "proof"
        subprocess.run([sys.executable, str(ROOT / "android/core-runtime/metrics-tests/run.py"),
                        "--dotnet", dotnet, "--output", str(output)], check=True, cwd=ROOT)
        producer = output / "producer" / "capture"
        subprocess.run([sys.executable, str(ROOT / "tests/android_metrics_pipeline_test.py"), str(producer)], check=True, cwd=ROOT)


if __name__ == "__main__":
    main()
