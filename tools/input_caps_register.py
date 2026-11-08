#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""登记 input_caps_scan.py 的 TSV，不改变扫描判定、不做设备体感结论。

每次输入只含一款程序号，--build 必须显式给出经核实的构建号；不从局名猜身份。
--repo 指定时写 docs/名单_输入能力/<程序号>.tsv，否则仅输出登记 TSV。
保留静态「未见」与局内「调用」冲突，不将未见/未调用写成 unsupported。
所有记录仍属设备体感未验；本工具不修改兼容性卡 support/verification。
局目录名是不可逆的人读文本，分号原样保留；制表/换行不能写入逐行登记表，拒绝。
无记录时不创建、不改写任何文件。已有相同程序号/构建号/项/依据局显示文本/日期但证据不同则拒绝，
不静默覆盖历史证据；补充实测应使用其真实日期/依据局。
"""
import argparse
import csv
import datetime
import io
import json
from pathlib import Path
import re
import sys

import input_caps_scan as scan
import reglist

TABLE = '名单_输入能力'
HEADER = ['程序号', '构建号', '项', '静态', '局内', '依据局', '日期']
FEATURES = ('controller', 'rumble', 'gyro')
STATIC = ('引用', '未见', '未知')
DYNAMIC = ('调用', '未调用', '未测')


def fail(source, line, message):
    raise ValueError(f'{source}:{line}: {message}')


def field(value):
    return isinstance(value, str) and bool(value.strip()) and not any(ord(c) < 32 or ord(c) == 127 or c in '\x85\u2028\u2029' for c in value)


def valid_date(value):
    try:
        return datetime.date.fromisoformat(value).isoformat() == value
    except (ValueError, TypeError):
        return False


def validate_record(row, source, line):
    if len(row) != len(HEADER) or not all(field(v) for v in row):
        fail(source, line, '登记列数、空字段或控制字符错误')
    if not re.fullmatch(r'[0-9A-F]{16}', row[0]):
        fail(source, line, '程序号须为 16 位十六进制大写')
    if row[2] not in FEATURES or row[3] not in STATIC or row[4] not in DYNAMIC:
        fail(source, line, '项/静态/局内枚举错误')
    if not valid_date(row[6]):
        fail(source, line, '日期须为有效 YYYY-MM-DD')


def parse_scan(text, source, build, date):
    """完整校验后返回七列证据行；不写文件。期望身份由调用者明确提供。"""
    if not field(build):
        fail(source, 1, '必须显式提供构建号，且不能含控制字符')
    if not valid_date(date):
        fail(source, 1, '日期须为有效 YYYY-MM-DD')
    reader = csv.reader(io.StringIO(text, newline=''), delimiter='\t', strict=True)
    result, programs = [], set()
    try:
        header = next(reader, None)
        if header is None:
            return []
        if header not in (scan.HEADER, scan.HEADER + ['声明引用']):
            fail(source, 1, '须为 input_caps_scan TSV 表头')
        for values in reader:
            line = reader.line_num
            if not values:
                continue
            if len(values) != len(header):
                fail(source, line, '扫描列数错误')
            if not re.fullmatch(r'[0-9a-fA-F]{16}', values[0]) or not field(values[1]):
                fail(source, line, '程序号或局目录名错误')
            pid = values[0].upper()
            static = None
            if len(values) == len(scan.HEADER) + 1:
                try:
                    static = json.loads(values[-1])
                except json.JSONDecodeError:
                    fail(source, line, '声明引用不是合法 JSON')
                if not isinstance(static, dict):
                    fail(source, line, '声明引用须为 T79 对象')
            missing = values[9] == '缺摘要行'
            record = dict(pid=pid, runs=[values[1]], styles=set(), status='缺摘要行' if missing else '已解析')
            if not missing:
                styles = set() if values[2] == '-' else set(values[2].split(','))
                if not styles.issubset(scan.STYLES) or not all(re.fullmatch(r'[0-9]+', v) for v in values[3:6]):
                    fail(source, line, '样式或非负调用计数错误')
                record.update(styles=styles, **dict(zip(scan.COUNTERS, map(int, values[3:6]))))
                if record['vib_nonzero'] > record['vib_calls']:
                    fail(source, line, '非零幅计数大于全部震动调用')
            # 重用扫描器的显示/冲突口径，拒绝手改 TSV 中自相矛盾的显示和数值。
            expected = list(map(str, scan.output_row(record, static)))[:len(scan.HEADER)]
            actual = [pid, *values[1:len(scan.HEADER)]]
            if actual != expected:
                fail(source, line, '扫描状态或显示字段与原始计数/静态证据不一致')
            known = static is not None and scan.static_known(static)
            called = (bool(record['styles']), record.get('vib_calls', 0) > 0,
                      record.get('sixaxis_start', 0) > 0)
            for item, static_key, positive in zip(FEATURES, ('styles', 'vibration', 'sixaxis'), called):
                row = [pid, build, item, ('引用' if static[static_key] else '未见') if known else '未知',
                       '未测' if missing else ('调用' if positive else '未调用'), values[1], date]
                validate_record(row, source, line)
                result.append(row)
            programs.add(pid)
        if len(programs) > 1:
            fail(source, 1, '一个显式构建号只关联一款程序号；请分款登记')
    except csv.Error as error:
        fail(source, reader.line_num, f'TSV 格式错误：{error}')
    return result


def key(row):
    return tuple(row[:3] + row[5:])


def register(repo, rows):
    """追加证据，完全相同行幂等；校验全量后才交既有 reglist 写者。"""
    if not rows:
        return
    for number, row in enumerate(rows, 1):
        validate_record(row, '<新记录>', number)
    text, locations = reglist.read(repo, TABLE)
    existing, seen = [], {}
    lines = text.splitlines()
    prefix = '\t'.join(HEADER) + '\n'
    if lines:
        header_index = next((i for i, line in enumerate(lines) if line.strip() and not line.startswith('#')), None)
        if header_index is None or lines[header_index].split('\t') != HEADER:
            path, number = locations[0]
            fail(path or f'{reglist.dir_of(TABLE)}/{reglist.HEAD}', number, '登记表头错误')
        prefix = '\n'.join(lines[:header_index + 1]) + '\n'
        for index, value in enumerate(lines[header_index + 1:], header_index + 1):
            if not value.strip() or value.startswith('#'):
                continue
            row = value.split('\t')
            path, number = locations[index]
            source = path or f'{reglist.dir_of(TABLE)}/{reglist.HEAD}'
            validate_record(row, source, number)
            identity = key(row)
            if identity in seen and seen[identity] != row:
                fail(source, number, '同一记录身份的证据冲突')
            seen[identity] = row
            existing.append(row)
    for number, row in enumerate(rows, 1):
        identity = key(row)
        if identity in seen:
            if seen[identity] != row:
                fail('<新记录>', number, '同一记录身份的证据冲突；未覆盖历史证据')
            continue
        seen[identity] = row
        existing.append(row)
    merged = prefix + ''.join('\t'.join(row) + '\n' for row in existing)
    reglist.write(repo, TABLE, merged)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('scan', type=Path, help='现有 input_caps_scan.py TSV')
    parser.add_argument('--build', required=True, help='调用方核实的构建号，不从目录名推断')
    parser.add_argument('--date', required=True, help='证据日期 YYYY-MM-DD')
    parser.add_argument('--repo', type=Path, help='写入该仓库按款目录；省略时只输出')
    args = parser.parse_args()
    try:
        rows = parse_scan(args.scan.read_text(encoding='utf-8'), str(args.scan), args.build, args.date)
        if args.repo is not None:
            register(args.repo, rows)
        elif rows:
            writer = csv.writer(sys.stdout, delimiter='\t', lineterminator='\n')
            writer.writerow(HEADER)
            writer.writerows(rows)
    except (OSError, UnicodeError, ValueError) as error:
        print(f'错误：{error}', file=sys.stderr)
        return 2
    return 0


if __name__ == '__main__':
    sys.exit(main())
