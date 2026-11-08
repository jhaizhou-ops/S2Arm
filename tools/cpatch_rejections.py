#!/usr/bin/env python3
"""只读汇总 cpatch_plan.log 的拒收事件；用法及口径见 docs/社区补丁拒收统计.md。

python3 tools/cpatch_rejections.py --log GAME PATH [--log GAME PATH ...]
输出 UTF-8 TSV：game / category / reason / count。游戏标签必须显式提供；
只数日志事件，不推断唯一补丁、最终出包状态或兼容性，不读邻居文件。
"""

import argparse
import csv
import io
import os
import re
import stat
import sys
from collections import Counter

# scan() copies sha256[:16] without validating its length/hex; an empty field
# falls back to a 16-hex path hash. This is an event label, not digest validation.
PATCH_ID = re.compile(r"(widescreen|fps|gfx):[^\t\r\n\x00]{1,16}\Z")
GAP_PREFIX = "改写器缺口："


class InputError(ValueError):
    """输入无法无歧义地用于本报表。"""


def rejection(line):
    """读取现行 plan/prune 的原始制表符文本（不是带引号的 CSV）。"""
    if not line.startswith("不收"):
        return None
    fields = line.split("\t")
    if fields[0] != "不收" or "\x00" in line or "\r" in line:
        raise InputError("损坏的拒收事件")
    if len(fields) < 3 or not (match := PATCH_ID.fullmatch(fields[1])):
        raise InputError("缺失或非法补丁编号（应为已知类别:1–16位非分隔字符）")
    if len(fields) == 3 or fields[2].startswith(GAP_PREFIX):
        if len(fields) != 3:
            raise InputError("改写器缺口事件含未转义 TAB，无法确定分界")
        # prune 不写模块/段名列；模块已经包含在其原因里。
        reason = fields[2]
        if not reason.startswith(GAP_PREFIX) or not reason[len(GAP_PREFIX) :].strip():
            raise InputError("三列拒收事件缺少改写器缺口原因")
    elif len(fields) == 5 and fields[2].strip():
        # writer 未转义字段；额外 tab 可能来自模块、段名或原因，不能猜分界。
        reason = fields[4]
    else:
        raise InputError("拒收事件需恰好五列或三列；字段可能含未转义 TAB，无法确定分界")
    if not reason.strip():
        raise InputError("拒收原因不能为空")
    return match[1], reason


def summarize(inputs):
    counts = Counter()
    seen = set()
    for game, path in inputs:
        if not game.strip():
            raise InputError("游戏标签不能为空；日志本身不含游戏身份")
        try:
            # 先以非阻塞只读方式打开再核普通文件，FIFO 不会等写端而挂住。
            fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
            with os.fdopen(fd, encoding="utf-8-sig", newline="\n") as source:
                info = os.fstat(source.fileno())
                if not stat.S_ISREG(info.st_mode):
                    raise InputError("输入必须是普通文件")
                identity = (info.st_dev, info.st_ino)
                if identity in seen:
                    raise InputError("重复输入同一文件（含软链/硬链别名）")
                seen.add(identity)
                for number, raw in enumerate(source, 1):
                    line = raw.removesuffix("\n").removesuffix("\r")
                    try:
                        record = rejection(line)
                    except InputError as exc:
                        raise InputError(f"{number}: {exc}") from exc
                    if record is not None:
                        category, reason = record
                        counts[game, category, reason] += 1
        except (OSError, UnicodeError, InputError) as exc:
            raise InputError(f"{path}:{exc}") from exc
    return counts


def render(counts):
    output = io.StringIO(newline="")
    writer = csv.writer(output, delimiter="\t", lineterminator="\n")
    writer.writerow(("game", "category", "reason", "count"))
    for key, count in sorted(counts.items()):
        writer.writerow((*key, count))
    return output.getvalue()


def main():
    # 不让宿主 locale / PYTHONIOENCODING 把中文报表变成替换字或编码错误。
    sys.stdout.reconfigure(encoding="utf-8", newline="\n")
    sys.stderr.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--log",
        nargs=2,
        action="append",
        required=True,
        metavar=("GAME", "PATH"),
        help="显式游戏标签与普通日志文件；可重复，不能重复同一输入文件",
    )
    args = parser.parse_args()
    try:
        report = render(summarize(args.log))  # 全部读完验证后才向 stdout 写，坏输入不产半表。
        sys.stdout.write(report)
        sys.stdout.flush()
    except (InputError, OSError) as exc:
        print(f"cpatch_rejections: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
