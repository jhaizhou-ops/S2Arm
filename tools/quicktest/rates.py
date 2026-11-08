#!/usr/bin/env python3
"""汇总快测表：rates.py <结果.tsv> [更多结果.tsv…] [--by 失败点]。

口径以 one_game.sh / verdict.py 的输出为准，不把合成表当实测：
- 按命令行文件顺序、文件内行顺序取最后一行（无时间列，不看 mtime）。
  16 位程序号不区分大小写；程序号为 '-' 则按原样「源」去重。
- 三率计数只复用 tools/census/census.py count_rates，口径见该文件头。
  32 位只排除解包分母，仍留在进局分母；进局使用「进局」而非首帧列。
  源文件坏 / 未判不进任何分母；未判另列条数，不作为游戏失败点。
  0 崩按实际起了 Mac 局计算（包括到点「收局」），不是首帧款数。
- one_game.sh 参数错误在写表前退出；仅外部明确标记参数问题时排除。
- 必须使用含进局 / Mac局秒的新版表；空分母显示 N/A。
  --by 不含不支持、参数问题、源文件坏和未判，同数按字面顺序输出。
"""

import argparse
from collections import Counter
import csv
from pathlib import Path
import re
import sys


sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "census"))
from census import count_rates


REQUIRED = {"源", "款", "程序号", "结论", "第一个失败点", "首帧", "崩溃", "进局", "Mac局秒"}
PROGRAM = re.compile(r"[0-9a-fA-F]{16}")


def read_latest(paths):
    """完整读入并校验后才输出，避免坏表产生部分成功统计。"""
    latest = {}
    for path in paths:
        try:
            with path.open(encoding="utf-8-sig", newline="") as stream:
                reader = csv.reader(stream, delimiter="\t")
                header = next(reader, [])
                if "进局" not in header:
                    raise ValueError(f"{path}: 旧表没有进局列，算不了进局率；请用新版 one_game.sh 重新测试并写入新表，不要向旧表追加。")
                missing = REQUIRED - set(header)
                if missing or len(header) != len(set(header)):
                    detail = "缺列 " + "、".join(sorted(missing)) if missing else "重复列名"
                    raise ValueError(f"{path}: 表头{detail}")
                for cells in reader:
                    if not cells:
                        continue
                    where = f"{path}:{reader.line_num}"
                    if len(cells) != len(header):
                        raise ValueError(f"{where}: 列数 {len(cells)}，应为 {len(header)}")
                    row = dict(zip(header, cells))
                    if any(not row[name] for name in REQUIRED):
                        raise ValueError(f"{where}: 必需字段为空（未测值应保留 '-'）")
                    pid = row["程序号"]
                    if pid != "-" and not PROGRAM.fullmatch(pid):
                        raise ValueError(f"{where}: 程序号须为 16 位十六进制或 '-'")
                    if row["首帧"] not in ("是", "否", "-"):
                        raise ValueError(f"{where}: 首帧须为 是/否/-")
                    key = ("源", row["源"]) if pid == "-" else ("程序号", pid.lower())
                    row["程序号"] = pid.lower()
                    # 删除再插入，使明细顺序也对应最终各行的出现顺序。
                    latest.pop(key, None)
                    latest[key] = row
        except (OSError, UnicodeError, csv.Error) as error:
            raise ValueError(f"{path}: 读取失败：{error}") from error
    return list(latest.values())


def exclusion(row):
    if row["结论"] in ("源文件坏", "未判"):
        return row["结论"]
    if row["结论"] == "参数问题" or row["第一个失败点"] == "参数问题":
        return "参数问题"
    return None


def report(rows, by_failure=False):
    excluded = [(row, exclusion(row)) for row in rows if exclusion(row)]
    included = [row for row in rows if not exclusion(row)]
    rates = count_rates(included)
    lines = []
    for label, (numerator, denominator) in zip(("解包成功率", "进局率", "0 崩率"), rates):
        percent = f"{numerator / denominator * 100:.2f}%" if denominator else "N/A（无样本）"
        lines.append(f"{label}\t{numerator}/{denominator}\t{percent}")
    lines.append(f"未判条数\t{sum(row['结论'] == '未判' for row in rows)}")
    lines.append("不计入分母\t程序号\t源\t原因")
    for row, why in excluded:
        lines.append("\t".join([row["款"], row["程序号"], row["源"], why]))
    if not excluded:
        lines.append("（无）")
    unsupported = [row for row in included if row["第一个失败点"].startswith("不支持")]
    if unsupported:
        lines.append("仅不计入解包分母（仍计入进局分母）\t程序号\t源\t原因")
        lines.extend("\t".join([row["款"], row["程序号"], row["源"], row["第一个失败点"]]) for row in unsupported)
    if by_failure:
        counts = Counter(row["第一个失败点"] for row in included if row["第一个失败点"] != "-" and not row["第一个失败点"].startswith("不支持"))
        lines.append("失败点\t款数")
        lines.extend(f"{point}\t{count}" for point, count in sorted(counts.items(), key=lambda item: (-item[1], item[0])))
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("tables", metavar="结果.tsv", type=Path, nargs="+")
    parser.add_argument("--by", choices=["失败点"], help="另外输出按款数降序的失败点统计")
    args = parser.parse_args()
    try:
        rows = read_latest(args.tables)
    except ValueError as error:
        print(f"错误：{error}", file=sys.stderr)
        return 2
    print(report(rows, args.by == "失败点"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
