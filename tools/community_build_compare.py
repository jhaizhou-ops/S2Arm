#!/usr/bin/env python3
"""只读对照 INDEX 与 unpack 元数据；事实表不表示补丁兼容或可应用。

只打开命令行列出的文件，不读取 INDEX 的 path、NSO 或相邻文件。
用法与状态边界见 docs/社区构建号对照.md。此独立人读表未接入面板或出包。
"""
from __future__ import annotations

import argparse
import csv
from dataclasses import dataclass
import io
from pathlib import Path
import re
import sys

COLUMNS = (
    'index_row', 'index_title_id', 'index_build_id', 'index_chars',
    'unpack_title_id', 'unpack_main_build_id', 'unpack_chars',
    'status', 'reason', 'index_path', 'unpack_path',
)
TITLE = re.compile(r'[0-9a-fA-F]{16}\Z')
BUILD = re.compile(r'[0-9a-fA-F]{16,64}\Z')


@dataclass(frozen=True)
class Record:
    path: str
    title: str
    build: str
    row: int = 0


class FormatError(ValueError):
    pass


def read_text(path: str) -> str:
    with Path(path).open(encoding='utf-8', newline='') as stream:
        text = stream.read()
    if '\x00' in text:
        raise FormatError(f'{path}: NUL in metadata')
    return text


def read_index(path: str) -> list[Record]:
    # Only leading comment lines are skipped: never filter inside quoted records.
    lines = read_text(path).splitlines(keepends=True)
    while lines and lines[0].startswith('#'):
        lines.pop(0)
    reader = csv.reader(io.StringIO(''.join(lines), newline=''), delimiter='\t', strict=True)
    try:
        header = next(reader, [])
        if (not header or any(not k for k in header) or len(set(header)) != len(header)
                or not {'title_id', 'build_id'} <= set(header)):
            raise FormatError(f'{path}: invalid or missing INDEX header (title_id, build_id required)')
        ti, bi = header.index('title_id'), header.index('build_id')
        records = []
        for number, row in enumerate(reader, 1):
            if len(row) != len(header):
                raise FormatError(f'{path}: INDEX row {number}: expected {len(header)} fields, got {len(row)}')
            records.append(Record(path, row[ti], row[bi], number))
        return records
    except csv.Error as exc:
        raise FormatError(f'{path}: INDEX CSV structure: {exc}') from exc


def read_unpack(path: str) -> Record:
    # Program.cs writes literal key TAB value LF, not quoted CSV. Do not guess
    # boundaries for embedded TAB/newline or silently overwrite duplicate keys.
    text = read_text(path)
    if not text:
        raise FormatError(f'{path}: empty unpack metadata')
    fields = {}
    lines = text.split('\n')
    for number, line in enumerate(lines, 1):
        if not line and number == len(lines):
            continue  # A single terminal LF is not an extra record.
        if line.endswith('\r') and number < len(lines):
            line = line[:-1]  # CRLF record terminator, not a value character.
        if '\r' in line:
            raise FormatError(f'{path}: unpack line {number}: unexpected CR')
        parts = line.split('\t')
        if len(parts) != 2 or not parts[0]:
            raise FormatError(f'{path}: unpack line {number}: expected key TAB value')
        key, value = parts
        if key in fields:
            raise FormatError(f'{path}: unpack line {number}: duplicate key {key!r}')
        fields[key] = value
    main = None
    for token in fields.get('builds', '').split(' '):
        if not token:
            continue
        module, sep, build = token.partition(':')
        if not module or not sep:
            raise FormatError(f'{path}: unpack builds: expected module:build token')
        if module == 'main':
            if main is not None:
                raise FormatError(f'{path}: unpack builds: duplicate main token')
            main = build
    return Record(path, fields.get('title_id', ''), main or '')


def title_status(record: Record, side: str) -> tuple[str, str] | None:
    if not record.title:
        return 'missing', f'{side}_title_missing'
    if TITLE.fullmatch(record.title) is None:
        return 'invalid', f'{side}_title_invalid'
    return None


def build_status(record: Record, side: str) -> tuple[str, str] | None:
    if not record.build:
        return 'missing', 'unpack_main_missing' if side == 'unpack' else 'index_build_missing'
    if BUILD.fullmatch(record.build) is None or len(record.build) % 2:
        return 'invalid', f'{side}_build_invalid'
    return None


def comparison(index: Record | None, unpack: Record | None) -> tuple[str, str]:
    # Bad identity/values are facts too. Validate present sides before reporting
    # a missing counterpart, so an invalid input cannot look like a valid miss.
    for side, record in (('index', index), ('unpack', unpack)):
        if record is not None:
            issue = title_status(record, side) or build_status(record, side)
            if issue:
                return issue
    if index is None:
        return 'missing', 'index_title_not_found'
    if unpack is None:
        return 'missing', 'unpack_title_not_found'
    left, right = index.build.lower(), unpack.build.lower()
    if not (left.startswith(right) or right.startswith(left)):
        return 'different', 'recorded_hex_differ'
    if len(left) == len(right) == 32:
        return 'same_recorded_128', 'equal_32_hex_records'
    if left == right:
        return 'prefix_only', 'equal_records_non128'
    return 'prefix_only', 'equal_known_prefix_only'


def table(indexes: list[Record], unpacks: list[Record]) -> list[tuple]:
    by_title = {}
    for i, record in enumerate(unpacks):
        if title_status(record, 'unpack') is None:
            by_title.setdefault(record.title.lower(), []).append((i, record))
    rows, used = [], set()

    def add(index: Record | None, unpack: Record | None) -> None:
        status, reason = comparison(index, unpack)
        rows.append((index.row if index else '', index.title if index else '',
                     index.build if index else '', len(index.build) if index else '',
                     unpack.title if unpack else '', unpack.build if unpack else '',
                     len(unpack.build) if unpack else '', status, reason,
                     index.path if index else '', unpack.path if unpack else ''))

    for record in indexes:
        matches = by_title.get(record.title.lower(), []) if title_status(record, 'index') is None else []
        if not matches:
            add(record, None)
        for i, unpack in matches:
            used.add(i)
            add(record, unpack)
    for i, record in enumerate(unpacks):
        if i not in used:
            add(None, record)
    return rows


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('index', help='one explicit UTF-8 INDEX.tsv')
    parser.add_argument('unpack', nargs='+', help='explicit UTF-8 unpack.tsv files, in report order')
    args = parser.parse_args(argv)
    try:
        indexes = read_index(args.index)
        unpacks = [read_unpack(path) for path in args.unpack]
        output = io.StringIO(newline='')
        writer = csv.writer(output, delimiter='\t', lineterminator='\n')
        writer.writerow(COLUMNS)
        writer.writerows(table(indexes, unpacks))
    except (OSError, UnicodeError, ValueError, csv.Error) as exc:
        print(f'community_build_compare: error: {exc}', file=sys.stderr)
        return 2
    # Decode/structure errors never leave a plausible partial report on stdout.
    sys.stdout.buffer.write(output.getvalue().encode('utf-8'))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
