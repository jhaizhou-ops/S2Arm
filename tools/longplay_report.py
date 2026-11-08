#!/usr/bin/env python3
"""跨平台长时游玩报告：显式映射 CSV/TSV，按有效游玩区间汇总，不连接设备。"""

import argparse
import csv
import hashlib
import json
import math
from datetime import datetime
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile

UNITS = {
    "fps": {"fps": 1},
    "memory_mib": {"MiB": 1, "MB": 1_000_000 / 1_048_576, "KiB": 1 / 1024, "bytes": 1 / 1_048_576},
    "power_w": {"W": 1, "mW": 0.001},
    "battery_pct": {"percent": 1},
    "power_proxy": {"relative": 1, "percent_per_hour": 1},
}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def number(value, name):
    require(not isinstance(value, bool), f"{name} 不能是布尔值")
    result = float(value)
    require(math.isfinite(result), f"{name} 必须是有限数字")
    return result


def template(platform):
    return {
        "schema_version": 1,
        "session_id": None,
        "platform": platform,
        "tester": None,
        "started_at": None,
        "ended_at": None,
        "device": {"model": None, "soc": None, "ram_gib": None, "os_build": None},
        "build": {"commit": None, "package_id": None, "graphics_mode": None},
        "game": {"name": None, "title_id": None, "version": None, "updates_dlc": None},
        "conditions": {
            "background_cleanup": None,
            "brightness": None,
            "refresh_hz": None,
            "resolution_settings": None,
            "power_mode": None,
            "charging_connection": None,
            "ambient_cooling_case": None,
            "network_audio_controller": None,
            "cache_state": None,
        },
        "human_gameplay_confirmed": False,
        "play_segments_s": [],
        "events": [],
        "status": None,
        "outcome": None,
        "unavailable": {"power_w": "填写不能获得整机瓦数的原因；可另报 power_proxy"},
        "sources": [
            {
                "metric": "fps",
                "path": "fps.csv",
                "delimiter": ",",
                "time_column": "elapsed_s",
                "value_column": "fps",
                "time_scale": 1,
                "time_offset_s": 0,
                "unit": "fps",
                "sampling": "interval_mean",
                "max_gap_s": 3,
                "tool_version": None,
                "scope": None,
                "method": None,
            }
        ],
    }


def validate(meta):
    require(meta["schema_version"] == 1, "仅支持 schema_version=1")
    require(meta["platform"] in ("ios", "macos", "android", "harmony"), "未知目标平台")
    require(meta["status"] in ("completed", "failed", "interrupted", "diagnostic"), "须声明 completed/failed/interrupted/diagnostic 状态")
    for key in ("session_id", "tester", "outcome"):
        require(isinstance(meta[key], str) and meta[key].strip(), f"请填写 {key}")
    for group in ("device", "build", "game", "conditions"):
        require(bool(meta[group]), f"请填写 {group}")
        require(template(meta["platform"])[group].keys() <= meta[group].keys(), f"{group} 缺必要字段")
        for key, value in meta[group].items():
            require(value is not None and str(value).strip(), f"请填写 {group}.{key}")
    start = datetime.fromisoformat(meta["started_at"])
    end = datetime.fromisoformat(meta["ended_at"])
    require(start.utcoffset() is not None and end.utcoffset() is not None, "时间必须含时区")
    duration = (end - start).total_seconds()
    require(duration > 0, "结束时间必须晚于开始时间")
    require(type(meta["human_gameplay_confirmed"]) is bool, "游玩确认必须为布尔值")
    segments = []
    for start_s, end_s in meta["play_segments_s"]:
        a, b = number(start_s, "游玩起点"), number(end_s, "游玩终点")
        require(0 <= a < b <= duration, "游玩区间须位于本局时间内")
        require(not segments or a >= segments[-1][1], "游玩区间须升序且不重叠")
        segments.append((a, b))
    require(bool(segments), "须注明至少一个有效游玩区间（不能自动证明人工游玩）")
    for event in meta["events"]:
        require(0 <= number(event["elapsed_s"], "事件时间") <= duration, "事件在局外")
        require(bool(event["description"]), "事件须有说明")
    return duration, segments


def read_source(source, root, duration):
    metric = source["metric"]
    require(metric in UNITS, f"未知指标 {metric}")
    require(source["unit"] in UNITS[metric], f"{metric} 不接受单位 {source['unit']}")
    for key in ("tool_version", "scope", "method"):
        require(bool(source[key]), f"{metric} 须声明 {key}")
    if metric == "power_w":
        require(source["scope"] == "device_total", "power_w 只接受整机功率；CPU/GPU 分项不能冒充整机")
    require(source["sampling"] in ("interval_mean", "instantaneous"), "未知采样语义")
    scale = number(source["time_scale"], "time_scale")
    offset = number(source["time_offset_s"], "time_offset_s")
    gap = number(source["max_gap_s"], "max_gap_s")
    require(scale > 0 and gap > 0, "时间比例和最大采样间隔须为正数")
    require(source["delimiter"] in (",", "\t", ";"), "delimiter 只接受逗号、TAB、分号")
    path = root / source["path"]
    points = []
    missing = 0
    with path.open(encoding="utf-8-sig", newline="") as stream:
        reader = csv.DictReader(stream, delimiter=source["delimiter"])
        require(reader.fieldnames is not None, f"{path.name} 缺表头")
        require(len(reader.fieldnames) == len(set(reader.fieldnames)), "CSV 有重复列名")
        for key in (source["time_column"], source["value_column"]):
            require(key in reader.fieldnames, f"{path.name} 缺列 {key}")
        for row in reader:
            require(None not in row, f"{path.name}:{reader.line_num} 列数不符")
            t = number(row[source["time_column"]], "采样时间") * scale + offset
            require(0 <= t <= duration, f"{path.name}:{reader.line_num} 采样时间在局外")
            require(not points or t > points[-1][0], "时间重复/倒退：请拆分重启后的局")
            cell = row[source["value_column"]]
            value = None if cell in (None, "") else number(cell, metric) * UNITS[metric][source["unit"]]
            require(value is None or value >= 0, "读数不可为负；缺测请留空")
            if metric == "battery_pct":
                require(value is None or value <= 100, "电量超出百分比范围")
            points.append((t, value))
            missing += value is None
    require(len(points) >= 2, f"{path.name} 须有至少两个时间点")
    with path.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    output_unit = source["unit"] if metric == "power_proxy" else next(iter(UNITS[metric]))
    provenance = {**source, "path": path.name, "sha256": digest, "max_gap_s": gap, "output_unit": output_unit}
    provenance["missing_samples"] = missing
    return points, provenance


def summarize(points, source, segments, left, right):
    covered, integral = 0.0, 0.0
    values = []
    for (t0, v0), (t1, v1) in zip(points, points[1:], strict=False):
        if t1 - t0 > source["max_gap_s"] or v1 is None:
            continue
        if source["sampling"] == "instantaneous" and v0 is None:
            continue
        for a, b in segments:
            lo, hi = max(t0, a, left), min(t1, b, right)
            if hi <= lo:
                continue
            if source["sampling"] == "interval_mean":
                mean = v1
                values.append(v1)
            else:
                vl = v0 + (v1 - v0) * (lo - t0) / (t1 - t0)
                vh = v0 + (v1 - v0) * (hi - t0) / (t1 - t0)
                mean = (vl + vh) / 2
                values.extend((vl, vh))
            covered += hi - lo
            integral += mean * (hi - lo)
    expected = sum(max(0, min(b, right) - max(a, left)) for a, b in segments)
    result = {
        "unit": source["output_unit"],
        "covered_s": covered,
        "expected_play_s": expected,
        "coverage": covered / expected if expected else None,
        "time_weighted_mean": integral / covered if covered else None,
        "sample_min": min(values) if values else None,
        "sample_max": max(values) if values else None,
    }
    if source["metric"] == "power_w":
        result["covered_energy_wh"] = integral / 3600 if covered else None
    return result


def report(meta_path, output):
    with meta_path.open(encoding="utf-8") as stream:
        meta = json.load(stream)
    duration, segments = validate(meta)
    series, provenance = {}, []
    for source in meta["sources"]:
        metric = source["metric"]
        require(metric not in series, f"同局每指标只接受一个来源：{metric}")
        points, info = read_source(source, meta_path.parent, duration)
        series[metric] = (points, info)
        provenance.append(info)
    require(bool(series), "没有采样来源")
    metrics = {k: summarize(p, s, segments, 0, duration) for k, (p, s) in series.items()}
    play_s = sum(b - a for a, b in segments)
    required = ("fps", "memory_mib", "power_w")
    for key in required:
        require(key in metrics or bool(meta["unavailable"].get(key)), f"缺少 {key}，请声明缺测原因")
        require(key not in metrics or key not in meta["unavailable"], f"{key} 同时声明有采样和缺测，请修正")
    summary = {
        "schema_version": 1,
        "session_id": meta["session_id"],
        "wall_duration_s": duration,
        "declared_play_s": play_s,
        "human_gameplay_confirmed": meta["human_gameplay_confirmed"],
        "status": meta["status"],
        "outcome": meta["outcome"],
        "events": meta["events"],
        "human_60min": meta["human_gameplay_confirmed"] and play_s >= 3600,
        "human_120min": meta["human_gameplay_confirmed"] and play_s >= 7200,
        "three_metrics_coverage_95pct": all(k in metrics and metrics[k]["coverage"] >= 0.95 for k in required),
        "metrics": metrics,
        "unavailable": meta["unavailable"],
    }
    summary["data_complete_60min"] = summary["human_60min"] and summary["three_metrics_coverage_95pct"]
    summary["data_complete_120min"] = summary["human_120min"] and summary["three_metrics_coverage_95pct"]
    summary["collection_complete_60min"] = meta["status"] == "completed" and summary["data_complete_60min"]
    summary["collection_complete_120min"] = meta["status"] == "completed" and summary["data_complete_120min"]
    windows = []
    for left in range(0, math.ceil(duration), 300):
        right = min(left + 300, duration)
        for metric, (points, source) in series.items():
            windows.append({"start_s": left, "end_s": right, "metric": metric, **summarize(points, source, segments, left, right)})
    require(not output.exists(), f"输出目录已存在，拒绝覆盖：{output}")
    output.mkdir(parents=True)
    meta["sources"] = provenance
    for name, data in (("metadata.json", meta), ("summary.json", summary)):
        (output / name).write_text(json.dumps(data, ensure_ascii=False, indent=2, allow_nan=False) + "\n", encoding="utf-8")
    with (output / "windows.csv").open("w", encoding="utf-8", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(dict.fromkeys(k for w in windows for k in w)))
        writer.writeheader()
        writer.writerows(windows)
    with (output / "samples.csv").open("w", encoding="utf-8", newline="") as stream:
        writer = csv.writer(stream)
        writer.writerow(("metric", "unit", "elapsed_s", "value"))
        for metric, (points, source) in series.items():
            writer.writerows((metric, source["output_unit"], t, v) for t, v in points)
    lines = [
        f"# 长时游玩报告：{meta['session_id']}",
        "",
        f"平台：{meta['platform']}；设备：{meta['device']['model']}；游戏：{meta['game']['name']}",
        f"实际结果：{meta['status']}；{meta['outcome']}",
        f"声明有效游玩 {play_s / 60:.2f} 分钟；人工确认：{meta['human_gameplay_confirmed']}。",
        f"60 分钟：{summary['human_60min']}；120 分钟：{summary['human_120min']}；三项覆盖 ≥95%：{summary['three_metrics_coverage_95pct']}。",
        f"完成采集（时长、覆盖、completed 状态）：60min={summary['collection_complete_60min']}；120min={summary['collection_complete_120min']}。",
        "",
        "| 指标 / 输出单位 | 时间加权均值 | 区间峰值（采样/插值） | 覆盖率 |",
        "|---|---:|---:|---:|",
    ]
    for metric, result in metrics.items():
        def fmt(value):
            return "未测" if value is None else f"{value:.4g}"
        lines.append(f"| {metric} / {result['unit']} | {fmt(result['time_weighted_mean'])} | {fmt(result['sample_max'])} | {fmt(result['coverage'])} |")
    lines += ["", "事件记录："]
    lines.extend(f"- {event['elapsed_s']}s：{event['description']}" for event in meta["events"])
    lines += ["", "缺测原因：" + json.dumps(meta["unavailable"], ensure_ascii=False), "", "脚本只核对声明和采样，不证明人工游玩、画面正确或游戏稳定通过。采样 FPS 不生成逐帧 P99 / 1% low；未覆盖区间不补零、不外推能量。原始文件由参与者保留，哈希见 metadata。"]
    (output / "report.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    archive = output / "result.zip"
    with ZipFile(archive, "x", ZIP_DEFLATED) as bundle:
        for name in ("metadata.json", "summary.json", "windows.csv", "samples.csv", "report.md"):
            bundle.write(output / name, name)
    print(archive)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    init = commands.add_parser("init", help="生成待填写的元数据模板；不生成测试读数")
    init.add_argument("--platform", required=True, choices=("ios", "macos", "android", "harmony"))
    init.add_argument("--out", required=True, type=Path)
    build = commands.add_parser("report", help="读取真实导出文件，一键汇总并打包")
    build.add_argument("--metadata", required=True, type=Path)
    build.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    if args.command == "init":
        with args.out.open("x", encoding="utf-8") as stream:
            json.dump(template(args.platform), stream, ensure_ascii=False, indent=2)
            stream.write("\n")
    else:
        report(args.metadata, args.out)


if __name__ == "__main__":
    main()
