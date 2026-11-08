#!/usr/bin/env python3
"""直连着色器覆盖检查（H02 / #147），只读输入，不判整款游戏是否就绪。

用法：python3 tools/direct_ready.py --seen <seen_shaders.tsv> --keys <keys.tsv>
按 §12.3 及 PR #157 直连线评审的新契约：有效键仅为 16 位小写十六进制。
keys 中的不合法行是输入错误；seen 中的 code:<哈希16>、大写或其他坏行均保留为缺口。
忽略空行和行尾 ASCII 空白（空格、TAB、CR、LF），不静默转换大小写或删除坏记录。
覆盖率按唯一整行字节串；缺口按输入行出现次数降序、同次数按整行字节序升序。
次数只表示输入行数，去重的生产者文件每键都是 1，不能用来推算游戏调用频次。
seen 缺失或为空都缺少游玩证据，ready=0、覆盖率显示无样本；keys 缺失仍是输入错。
退出：0 已覆盖 / 1 未就绪 / 2 输入错。
同口径的可编译 C 参考函数见 tests/fixtures/direct_ready/reference.c。
"""

import argparse
import re
import sys
from collections import Counter
from collections.abc import Iterator, Mapping, Set
from dataclasses import dataclass
from pathlib import Path

KEY = re.compile(rb"[0-9a-f]{16}\Z")


@dataclass(frozen=True)
class Coverage:
    """数量均为唯一键数；missing_rows 的次数是 seen 文件的输入行数。"""

    seen: int
    covered: int
    missing_rows: tuple[tuple[bytes, int], ...]

    @property
    def ready(self) -> bool:
        return self.seen > 0 and not self.missing_rows


def read_rows(path: Path, *, is_seen: bool) -> Iterator[bytes]:
    # 二进制逐 LF 行读，保持大小写，不把 Unicode 空白或多列静默归一化。
    try:
        stream = path.open("rb")
    except FileNotFoundError:
        if is_seen:
            return  # 尚未有通用模式记录；只接受文件不存在，其他读取错误照常报错。
        raise
    with stream:
        for number, raw in enumerate(stream, 1):
            row = raw.rstrip(b" \t\r\n")
            if not row:
                continue
            if not is_seen and not KEY.fullmatch(row):
                raise ValueError(f"{path}:{number}：keys 应为单列 16 位小写十六进制键")
            yield row


def compare(seen: Mapping[bytes, int], keys: Set[bytes]) -> Coverage:
    """坏 seen 行始终挡住就绪；即使调用者给出同名的坏 keys，也不能计为覆盖。"""
    missing = tuple(
        sorted(
            ((key, count) for key, count in seen.items() if not KEY.fullmatch(key) or key not in keys),
            key=lambda entry: (-entry[1], entry[0]),
        )
    )
    return Coverage(len(seen), len(seen) - len(missing), missing)


def display_key(key: bytes) -> str:
    # 坏行可能含 TAB、NUL 或非 UTF-8 字节；转义仅用于展示，去重和排序仍使用原始字节。
    return "".join(chr(byte) if 32 <= byte < 127 and byte != 92 else f"\\x{byte:02x}" for byte in key)


def render(result: Coverage) -> str:
    lines = [
        f"ready={int(result.ready)} seen={result.seen} covered={result.covered} "
        f"missing={len(result.missing_rows)}"
    ]
    if result.seen:
        lines.append(f"coverage={result.covered}/{result.seen} ({100 * result.covered / result.seen:.6f}%)")
    else:
        lines.append("coverage=0/0 (no samples; not ready)")
    lines.append("# input_rows = occurrences in seen input; not gameplay call frequency")
    lines.append("missing_key\tinput_rows")
    lines.extend(f"{display_key(key)}\t{count}" for key, count in result.missing_rows)
    return "\n".join(lines) + "\n"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--seen", required=True, type=Path, help="明确指定 seen_shaders.tsv")
    parser.add_argument("--keys", required=True, type=Path, help="明确指定本次目标直连库的 keys.tsv")
    args = parser.parse_args(argv)
    try:
        seen = Counter(read_rows(args.seen, is_seen=True))
        keys = set(read_rows(args.keys, is_seen=False))
        result = compare(seen, keys)
    except (OSError, ValueError) as error:
        print(f"direct_ready：输入错误：{error}", file=sys.stderr)
        return 2
    sys.stdout.write(render(result))
    return 0 if result.ready else 1


if __name__ == "__main__":
    sys.exit(main())
