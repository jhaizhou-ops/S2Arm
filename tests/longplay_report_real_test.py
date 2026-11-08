#!/usr/bin/env python3
"""用本机真实进程 RSS 验证报告链路；不构造游戏、FPS 或功耗读数。"""

import csv
import json
import math
import os
import platform
import subprocess
import sys
import tempfile
import time
from datetime import datetime
from pathlib import Path
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tools"))
import longplay_report as report  # noqa: E402


def main():
    if platform.system() != "Darwin":
        raise SystemExit("本验证记录 macOS 的真实 ps RSS；其他平台请使用自己的真实导出验证")
    with tempfile.TemporaryDirectory(prefix="s2a-longplay-real-") as directory:
        root = Path(directory)
        started = datetime.now().astimezone()
        anchor = time.monotonic()
        points = []
        retained = []
        for _ in range(5):
            rss = int(subprocess.check_output(["ps", "-o", "rss=", "-p", str(os.getpid())], text=True).strip())
            points.append((time.monotonic() - anchor, rss))
            retained.append(bytearray(2 * 1024 * 1024))
            time.sleep(0.25)
        ended = datetime.now().astimezone()
        # 断档上限按本次实测最大采样间隔取（被测是报告链路不是采样节奏）：写死 3 秒时 mini 负载 200+ 一次 ps 就超，覆盖率 < 1 报红（11-02 a55b5c839 无缓存实跑）
        max_gap = max(b[0] - a[0] for a, b in zip(points, points[1:])) + 3
        with (root / "rss.csv").open("w", newline="") as stream:
            writer = csv.writer(stream)
            writer.writerow(("elapsed_s", "rss_kib"))
            writer.writerows(points)
        meta = report.template("macos")
        meta.update({
            "session_id": "real-host-rss-verification",
            "tester": "local integration check",
            "started_at": started.isoformat(),
            "ended_at": ended.isoformat(),
            "device": {"model": platform.machine(), "soc": "host CPU", "ram_gib": "not queried", "os_build": platform.platform()},
            "build": {"commit": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=ROOT, text=True).strip(), "package_id": "python RSS check", "graphics_mode": "no game"},
            "game": {"name": "非游戏：本机 Python 进程", "title_id": "not applicable", "version": platform.python_version(), "updates_dlc": "not applicable"},
            "conditions": {key: "非游戏工具链验证；不作为基准" for key in meta["conditions"]},
            "play_segments_s": [[points[0][0], points[-1][0]]],
            "status": "diagnostic",
            "outcome": "只验证真实 RSS 导入，不是游戏测试",
            "unavailable": {"fps": "未运行游戏", "power_w": "未采集"},
            "sources": [{"metric": "memory_mib", "path": "rss.csv", "delimiter": ",", "time_column": "elapsed_s", "value_column": "rss_kib", "time_scale": 1, "time_offset_s": 0, "unit": "KiB", "sampling": "instantaneous", "max_gap_s": f"{max_gap:.3f}", "tool_version": "system ps", "scope": "process RSS", "method": "ps -o rss"}],
        })
        meta_path = root / "metadata.json"
        meta_path.write_text(json.dumps(meta), encoding="utf-8")
        subprocess.run([sys.executable, str(ROOT / "tools/longplay_report.py"), "report", "--metadata", str(meta_path), "--out", str(root / "result")], check=True)
        summary = json.loads((root / "result/summary.json").read_text())
        memory = summary["metrics"]["memory_mib"]
        assert math.isclose(memory["coverage"], 1)
        assert memory["unit"] == "MiB"
        assert math.isclose(memory["sample_max"], max(r for _, r in points) / 1024)
        assert min(r for _, r in points) / 1024 <= memory["time_weighted_mean"] <= max(r for _, r in points) / 1024
        assert not summary["human_60min"] and not summary["collection_complete_60min"]
        assert not summary["three_metrics_coverage_95pct"]
        assert summary["status"] == "diagnostic" and summary["outcome"] == meta["outcome"]
        assert meta["outcome"] in (root / "result/report.md").read_text()
        with ZipFile(root / "result/result.zip") as bundle:
            assert len(bundle.namelist()) == 5 and bundle.testzip() is None
        # 删除一个真实采样值，必须成为覆盖缺口，不能沿用或补零。
        with (root / "rss.csv").open("w", newline="") as stream:
            writer = csv.writer(stream)
            writer.writerow(("elapsed_s", "rss_kib"))
            writer.writerows((t, "" if i == 2 else v) for i, (t, v) in enumerate(points))
        report.report(meta_path, root / "missing")
        missing = json.loads((root / "missing/summary.json").read_text())["metrics"]["memory_mib"]
        expected_covered = (points[1][0] - points[0][0]) + (points[4][0] - points[3][0])
        assert math.isclose(missing["covered_s"], expected_covered)
        # 重启后时间倒退：仅把真实记录倒序，报告应拒绝。
        with (root / "rss.csv").open("w", newline="") as stream:
            writer = csv.writer(stream)
            writer.writerow(("elapsed_s", "rss_kib"))
            writer.writerows(reversed(points))
        try:
            report.report(meta_path, root / "reversed")
        except ValueError as error:
            assert "时间重复/倒退" in str(error)
        else:
            raise AssertionError("倒退时间未被拒绝")
        print(f"PASS: {len(points)} real RSS samples; units, coverage, missing data, restart rejection, ZIP, no gameplay qualification")


if __name__ == "__main__":
    main()
