#!/usr/bin/env python3
"""输入能力收局摘要：input_caps_scan.py <局目录…> [--merge-static <T79 JSON>]。

只读 host.log 的程序号和最后一条 [输入能力]；按 #755 公布的 HID 摘要格式。
同程序号（忽略大小写）合并有效局：styles 并集、累计计数取最大，绝不相加。
缺摘要行单独列为未测，不参加合并；末条格式错不能退回早先好行，退出非0。
目录名以分号加空格连接，仅供人读，不是可逆列表或身份协议；原名由 TSV 保留。
输出不是设备实测通过或能力卡的支持/启用判定。

T79 (#754) 的单 exefs JSON：styles/vibration/sixaxis 三个 bool，evidence 是
同名字符串列表，ok/why 表示扫描是否完整。它不含程序号，因此 --merge-static
仅接受所有局都能确定同一个程序号的输入，关联由调用者负责，不能套给多款。
完整 ok=true 的静态 false 与实际调用阳性并存时报「证据冲突」，保留原 JSON
及全部动态数值；静态未命中不等于不支持，ok=false/字段缺失一律静态未知。
震动实际调用用 vib_calls>0（包括只发零幅），不把非零幅当作唯一调用证据。
退出：0=解析完成（可含缺摘要/冲突），1=局日志或摘要错误，2=参数/静态输入错误。
"""

import argparse
import csv
import json
from pathlib import Path
import re
import sys


STYLES = ("ProController", "Handheld", "JoyconPair", "JoyconLeft", "JoyconRight",
          "Invalid", "Pokeball", "SystemExternal", "System")
COUNTERS = ("sixaxis_start", "vib_calls", "vib_nonzero")
HEADER = ["程序号", "局目录名", "styles", *COUNTERS, "手柄样式", "震动", "六轴", "状态"]
PROGRAM = re.compile(r"程序号 ([0-9a-fA-F]{16})(?![0-9a-fA-F])")
SUMMARY = re.compile(
    r"\[输入能力\]\s+styles=(\S+)\s+sixaxis_start=([0-9]+)"
    r"\s+vib_calls=([0-9]+)\s+vib_nonzero=([0-9]+)"
)


def read_run(directory):
    record = {"pid": "-", "runs": [directory.name], "styles": set(), "status": "", "error": False}
    try:
        text = (directory / "host.log").read_text(encoding="utf-8", errors="replace")
    except OSError:
        record.update(status="日志读取失败", error=True)
        return record
    programs = {value.upper() for value in PROGRAM.findall(text)}
    if len(programs) != 1:
        record.update(status="缺程序号" if not programs else "程序号不唯一", error=True)
        return record
    record["pid"] = programs.pop()
    summaries = [line[line.index("[输入能力]"):].strip() for line in text.splitlines() if "[输入能力]" in line]
    if not summaries:
        record["status"] = "缺摘要行"
        return record
    match = SUMMARY.fullmatch(summaries[-1])
    try:
        if match is None:
            raise ValueError("字段格式")
        styles = set() if match[1] == "-" else set(match[1].split(","))
        counts = dict(zip(COUNTERS, map(int, match.groups()[1:])))
        if not styles.issubset(STYLES) or counts["vib_nonzero"] > counts["vib_calls"]:
            raise ValueError("样式或计数范围")
    except ValueError:
        record.update(status="摘要行格式错", error=True)
        return record
    record.update(styles=styles, status="已解析", **counts)
    return record


def merge_runs(records):
    grouped = {}
    unmeasured = []
    for record in records:
        if record["status"] != "已解析":
            unmeasured.append(record)
            continue
        pid = record["pid"]
        if pid not in grouped:
            grouped[pid] = dict(record, styles=set(record["styles"]), runs=list(record["runs"]))
            continue
        merged = grouped[pid]
        merged["styles"].update(record["styles"])
        merged["runs"].extend(name for name in record["runs"] if name not in merged["runs"])
        for name in COUNTERS:
            merged[name] = max(merged[name], record[name])
    return [*grouped.values(), *unmeasured]


def load_static(path):
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ValueError(f"静态 JSON 读取失败：{path}：{error}") from error
    if not isinstance(data, dict):
        raise ValueError("静态 JSON 须为 T79 的单个对象")
    return data


def static_known(data):
    evidence = data.get("evidence")
    if data.get("ok") is not True or not isinstance(data.get("why"), str) or not isinstance(evidence, dict):
        return False
    return all(type(data.get(key)) is bool and isinstance(evidence.get(key), list)
               and all(isinstance(item, str) for item in evidence[key])
               for key in ("styles", "vibration", "sixaxis"))


def output_row(record, static):
    measured = record["status"] == "已解析"
    status = record["status"]
    styles = ",".join(name for name in STYLES if name in record["styles"]) or "-"
    if measured:
        rumble = "调用过且非零" if record["vib_nonzero"] > 0 else ("只发零幅" if record["vib_calls"] > 0 else "没调用")
        values = [record["pid"], "; ".join(record["runs"]), styles,
                  *[record[name] for name in COUNTERS],
                  "声明了：" + styles if record["styles"] else "未声明", rumble,
                  "启动过" if record["sixaxis_start"] > 0 else "没启动"]
        if static is not None:
            if not static_known(static):
                status += "；静态未知"
            else:
                conflicts = [label for key, called, label in [
                    ("styles", bool(record["styles"]), "手柄样式"),
                    ("vibration", record["vib_calls"] > 0, "震动"),
                    ("sixaxis", record["sixaxis_start"] > 0, "六轴"),
                ] if called and static[key] is False]
                if conflicts:
                    status = "证据冲突：" + "、".join(conflicts)
    else:
        values = [record["pid"], "; ".join(record["runs"]), "未测",
                  "-", "-", "-", "未测", "未测", "未测"]
    values.append(status)
    if static is not None:
        values.append(json.dumps(static, ensure_ascii=False, separators=(",", ":")))
    return values


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("runs", type=Path, nargs="+", metavar="局目录")
    parser.add_argument("--merge-static", type=Path, help="只关联唯一程序号的 T79 单 exefs JSON")
    args = parser.parse_args()
    records = [read_run(directory) for directory in args.runs]
    static = None
    if args.merge_static:
        try:
            programs = {record["pid"] for record in records}
            if "-" in programs or len(programs) != 1:
                raise ValueError("T79 JSON 不含身份：--merge-static 要求所有局有同一个唯一程序号")
            static = load_static(args.merge_static)
        except ValueError as error:
            print(f"错误：{error}", file=sys.stderr)
            return 2
    writer = csv.writer(sys.stdout, delimiter="\t", lineterminator="\n")
    writer.writerow(HEADER + (["声明引用"] if static is not None else []))
    for record in merge_runs(records):
        writer.writerow(output_row(record, static))
    for record in records:
        if record["error"]:
            print(f"错误：{json.dumps(record['runs'], ensure_ascii=False)}：{record['status']}", file=sys.stderr)
    return 1 if any(record["error"] for record in records) else 0


if __name__ == "__main__":
    sys.exit(main())
