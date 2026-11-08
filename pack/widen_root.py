#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Read-only identity check before reusing an iOS root; never enables widescreen."""
import argparse
from pathlib import Path
import re
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'tools'))
from addr_need import npdm_program


def regular(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError(f'{path.name} 缺失或不是普通文件')
    return path


def rows(path, identity=None, platform=None):
    records = []
    for line in regular(path).read_text(encoding='utf-8').splitlines():
        if not line.strip() or line.lstrip().startswith('#'):
            continue
        fields = line.split('\t')
        # Package validation concerns this root only; table-wide lint belongs
        # elsewhere. Marker parsing remains strict (no identity filter).
        if identity is not None and tuple(field.lower() for field in fields[:2]) != identity:
            continue
        # 平台列（F7 #1574）：表行第 4 列；同身份可以有 apple + android 两行，只取本平台的
        if platform is not None and (len(fields) < 4 or fields[3].lower() != platform):
            continue
        if len(fields) < 2 or not re.fullmatch(r'[0-9a-fA-F]{16}', fields[0]) or not re.fullmatch(r'[0-9a-fA-F]{32}', fields[1]):
            raise ValueError(f'{path.name} 的验证行格式无效')
        records.append(((fields[0].lower(), fields[1].lower()), fields))
    return records


def explicit_widen(caps):
    if caps is None or (not caps.exists() and not caps.is_symlink()):
        return None
    for line in regular(caps).read_text(encoding='utf-8').splitlines():
        fields = line.split('#', 1)[0].split()
        # Match caps.c: the first valid widen value takes effect.
        if len(fields) >= 2 and fields[0] == 'widen' and fields[1] in ('0', '1'):
            return fields[1]
    return None


def check(root, table, caps=None):
    value = explicit_widen(caps)
    if value is not None:
        return f'所选能力清单 widen={value}；运行时不消费验证标记'
    main = regular(root / 'exefs/main')
    with main.open('rb') as stream:
        header = stream.read(0x60)
    if len(header) != 0x60 or header[:4] != b'NSO0':
        raise ValueError('exefs/main 缺少有效 NSO0 头或 Build ID')
    identity = (npdm_program(regular(root / 'exefs/main.npdm')), header[0x40:0x50].hex())
    expected = [fields for who, fields in rows(table, identity, 'apple')]   # 本检查器只服务苹果根（pack/ipa.sh，列值 apple = iOS / Mac 同实现域）；安卓标记由安卓打包线管
    if len(expected) > 1:
        raise ValueError('当前身份有多条验证记录，不能确定验证标记')
    marker = root / 'widen_verified.tsv'
    # lexists semantics: a broken symlink is an invalid marker, not its absence.
    present = marker.exists() or marker.is_symlink()
    if not expected:
        if present:
            raise ValueError('宽屏验证标记遗留，但当前程序号 / Build ID 不在验证表')
        return '无已验证行且无标记；能力清单与用户开关仍按现行规则判定'
    if not present:
        raise ValueError('宽屏验证标记 widen_verified.tsv 缺失')
    actual = rows(marker)
    if len(actual) != 1 or actual[0][0] != identity:
        raise ValueError('宽屏验证标记的程序号 / Build ID 与根身份不符')
    # Compare provenance too; case in the two normalized identity columns does
    # not change identity, but changed/revoked evidence must refresh the root.
    if actual[0][1][2:] != expected[0][2:]:
        raise ValueError('宽屏验证标记与当前验证记录不一致')
    return '验证标记与当前程序号 / Build ID / 登记行一致'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    parser.add_argument('--table', type=Path, required=True)
    parser.add_argument('--caps', type=Path)
    args = parser.parse_args()
    try:
        result = check(args.root, args.table, args.caps)
    except (OSError, ValueError) as error:
        print(f'【红】宽屏验证标记检查失败：{error}；请刷新该根的改写阶段后重试，不自动补写标记', file=sys.stderr)
        return 1
    print(f'宽屏验证标记检查：{result}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
