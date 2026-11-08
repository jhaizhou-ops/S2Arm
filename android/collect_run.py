#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# Adapted from PR #209 (wdjwxh); main integration for #208.
"""复制显式导出的局文件；不另建哈希快照/认证格式，不连接设备。"""
import argparse
import json
import os
from pathlib import Path
import shutil
import tempfile
from metrics_contract import runtime_files


def collect(output, files):
    output = Path(output).absolute()
    if os.path.lexists(output): raise ValueError("输出目录已存在")
    allowed = {"host.log", "frames.tsv", "runtime-metrics.json", "run-manifest.json", "run.log", "logcat.txt",
               "battery.txt", "thermal.txt", "cold_start.txt", "truth.tsv", "battery.tsv", "battery-source.json",
               "runtime-library.json", "NOT-A-READING.txt"}
    if set(files) - allowed: raise ValueError("只允许约定的局文件")
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".android-run-", dir=output.parent) as temp:
        stage = Path(temp) / "run"
        stage.mkdir()
        for name, source in files.items():
            if source is not None: shutil.copyfile(source, stage / name)
        if (stage / "runtime-metrics.json").exists(): runtime_files(stage, stage / "host.log")
        if os.path.lexists(output): raise ValueError("输出目录已存在")
        os.rename(stage, output)
    return {"files": [name for name, source in files.items() if source is not None]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--host-log", type=Path, required=True)
    parser.add_argument("--metrics-directory", type=Path)
    parser.add_argument("--power-samples", type=Path)
    parser.add_argument("--runtime-library", type=Path)
    parser.add_argument("--not-a-reading", type=Path)
    for flag in ("frames", "run-manifest", "run-log", "logcat", "battery", "thermal", "cold-start", "truth"):
        parser.add_argument("--" + flag, type=Path)
    args = parser.parse_args()
    files = {"host.log": args.host_log, "frames.tsv": args.frames, "run-manifest.json": args.run_manifest,
             "run.log": args.run_log, "logcat.txt": args.logcat, "battery.txt": args.battery,
             "thermal.txt": args.thermal, "cold_start.txt": args.cold_start, "truth.tsv": args.truth,
             "runtime-library.json": args.runtime_library, "NOT-A-READING.txt": args.not_a_reading}
    try:
        if args.metrics_directory:
            if args.frames: raise ValueError("不能混用手工帧表和生产目录")
            # A local re-export must retain the producer's runtime identity and
            # development marker, not silently turn raw dev evidence into a reading.
            produced = runtime_files(args.metrics_directory, args.host_log)
            for name in ("runtime-library.json", "NOT-A-READING.txt"):
                if name in produced and files.get(name) is not None:
                    raise ValueError("不能覆盖生产目录的身份或开发局标记")
            files.update(produced)
        if args.power_samples:
            files.update({"battery.tsv": args.power_samples, "battery-source.json": Path(str(args.power_samples) + ".source.json")})
        print(json.dumps(collect(args.output, files), ensure_ascii=False))
    except (OSError, ValueError, KeyError) as error: parser.exit(2, f"导出失败：{error}\n")


if __name__ == "__main__": main()
