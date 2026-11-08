# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# Adapted from PR #209 (wdjwxh); main integration for #208.
"""Android production output contract; validation belongs at export, not in scoring policy."""
import csv
import json
from pathlib import Path
import re

COLUMNS = ("frame", "wall_us", "alloc_b", "gc0", "gc1", "gc2", "gc_pause_us", "boot_us")


def frame_rows(path):
    with Path(path).open(encoding="utf-8", newline="") as f:
        reader = csv.DictReader(f, delimiter="\t")
        headers = reader.fieldnames or []
        if len(headers) != len(set(headers)) or not set(COLUMNS) <= set(headers):
            raise ValueError("生产帧表缺列或列名重复")
        rows = list(reader)
    for i, row in enumerate(rows):
        if None in row or None in row.values() or any(not re.fullmatch(r"[0-9]+", row[c]) for c in COLUMNS):
            raise ValueError("生产帧表存在空值、非法数值或列数不匹配")
        if int(row["frame"]) != i or (i == 0 and int(row["wall_us"]) != 0):
            raise ValueError("生产帧号必须从0连续，首行wall_us必须为0")
        if i and (int(row["wall_us"]) <= 0 or int(row["boot_us"]) - int(rows[i - 1]["boot_us"]) != int(row["wall_us"])):
            raise ValueError("生产时钟与帧间隔不一致")
    return rows


def runtime_files(directory, host_log):
    directory = Path(directory)
    meta = json.loads((directory / "runtime-metrics.json").read_text(encoding="utf-8"))
    if not isinstance(meta, dict):
        raise ValueError("生产元数据必须是对象")
    ident = meta.get("id", "")
    identity = re.fullmatch(r"metrics-([0-9]+)-([0-9]+)-[a-f0-9]{32}", ident) if isinstance(ident, str) else None
    if (identity is None
            or meta.get("status") != "completed" or meta.get("clock") != "CLOCK_BOOTTIME"
            or meta.get("frameSource") != "guest-present" or meta.get("error")):
        raise ValueError("生产采集未正常完成或来源不符")
    log = Path(host_log).read_text(encoding="utf-8")
    captures = re.findall(r"\[Android metrics\] id=([^;\r\n]+);", log)
    if captures != [ident]:
        raise ValueError("host.log与逐帧采集id不同，禁止拼局")
    rows = frame_rows(directory / "frames.tsv")
    last = meta.get("lastFrameBootUs", meta.get("endBootUs"))
    if (any(type(meta.get(key)) is not int for key in ("frames", "startBootUs", "endBootUs", "markFrame", "markBootUs"))
            or type(last) is not int or not rows or meta["frames"] != len(rows)
            or not 0 <= meta["startBootUs"] <= int(rows[0]["boot_us"])
            or last != int(rows[-1]["boot_us"]) or meta["endBootUs"] < last):
        raise ValueError("生产元数据与末帧/帧数不同")
    marks = re.findall(r"S2A 标记 MARK：帧 ([0-9]+)", log)
    mark = int(marks[0]) if marks else -1
    if len(marks) > 1 or meta.get("markFrame") != mark or mark >= len(rows):
        raise ValueError("MARK与生产帧表不同")
    if meta.get("markBootUs") != (int(rows[mark]["boot_us"]) if mark >= 0 else -1):
        raise ValueError("MARK时钟与生产帧表不同")
    library = directory / "runtime-library.json"
    if library.exists():
        record = json.loads(library.read_text(encoding="utf-8"))
        if (not isinstance(record, dict) or type(record.get("pid")) is not int
                or record["pid"] != int(identity[2]) or not isinstance(record.get("runtimeLibrary"), dict)
                or record["runtimeLibrary"].get("kind") not in ("apk", "dev-override")):
            raise ValueError("运行库身份与生产采集不符")
        if record["runtimeLibrary"]["kind"] == "dev-override" and not (directory / "NOT-A-READING.txt").is_file():
            raise ValueError("开发局必须保留 NOT-A-READING 标记")
    files = {"runtime-metrics.json": directory / "runtime-metrics.json", "frames.tsv": directory / "frames.tsv"}
    # Validation and collection are one contract: callers must not lose the
    # development identity merely by using this helper's returned file set.
    for name in ("runtime-library.json", "NOT-A-READING.txt"):
        if (directory / name).exists():
            files[name] = directory / name
    return files
