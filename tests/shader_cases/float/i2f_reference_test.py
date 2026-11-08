#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Original integer-only binary32 RN-even oracle; no translator/encoder imports."""
import json
from pathlib import Path
import re


def binary32(word, signed):
    if type(word) is not int or not 0 <= word < 2**32:
        raise ValueError('expected uint32 bits')
    value = word - 2**32 if signed and word >= 2**31 else word
    sign = int(value < 0) << 31
    magnitude = abs(value)
    if not magnitude: return 0
    exponent = magnitude.bit_length() - 1
    shift = exponent - 23
    if shift <= 0:
        significand = magnitude << -shift
    else:
        significand, remainder = divmod(magnitude, 1 << shift)
        halfway = 1 << (shift - 1)
        if remainder > halfway or (remainder == halfway and significand & 1):
            significand += 1
        if significand == 1 << 24:
            significand >>= 1
            exponent += 1
    return sign | ((exponent + 127) << 23) | (significand & 0x7fffff)


def execute(lines, initial):
    if len(initial) != 64 or any(type(x) is not int or not 0 <= x < 2**32 for x in initial):
        raise ValueError('expected 64 uint32 words')
    memory, regs = list(initial), {'RZ': 0}
    def reg(s):
        if s != 'RZ' and not re.fullmatch(r'R(?:[0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-4])', s):
            raise ValueError('invalid register')
        return s
    def address(base, offset):
        n = int(offset, 0)
        if regs[reg(base)] != 0 or regs.get('R1') != 0 or n % 4 or not 0 <= n < 256:
            raise ValueError('invalid fixed-buffer address')
        return n // 4
    exited = False
    for line in lines:
        if exited: raise ValueError('instruction after EXIT')
        op, *a = line.split()
        if op == 'LDC64' and a == ['R0', '0', '0']:
            regs.update(R0=0, R1=0)
        elif op == 'LDG32' and len(a) == 3:
            regs[reg(a[0])] = memory[address(*a[1:])]
        elif op == 'STG32' and len(a) == 3:
            memory[address(*a[1:])] = regs[reg(a[0])]
        elif op in ('I2F.F32.S32', 'I2F.F32.U32') and len(a) == 2:
            if a[1].startswith('R'):
                word = regs[reg(a[1])]
            else:
                immediate = int(a[1], 0)
                if not -2**19 <= immediate < 2**19: raise ValueError('signed20 range')
                word = immediate & 0xffffffff
            regs[reg(a[0])] = binary32(word, op.endswith('S32'))
        elif op == 'EXIT' and not a: exited = True
        else: raise ValueError('outside I2F reference domain: ' + line)
    if not exited: raise ValueError('missing EXIT')
    return memory


def main():
    # Independently hand-calculated anchors: tie-even both directions and carry.
    anchors = [(0, False, 0), (1, True, 0x3f800000), (0xffffffff, True, 0xbf800000),
               (0x80000000, True, 0xcf000000), (0x7fffffff, True, 0x4f000000),
               (0xffffffff, False, 0x4f800000), (0x1000001, False, 0x4b800000),
               (0x1000003, False, 0x4b800002), (0xffffff, False, 0x4b7fffff),
               (0xffffff80, False, 0x4f800000), (0xfffffe80, False, 0x4f7ffffe),
               (0xfeffffff, True, 0xcb800000), (0xfefffffd, True, 0xcb800002)]
    for word, signed, expected in anchors: assert binary32(word, signed) == expected
    cases = sorted(Path(__file__).parent.glob('i2f_*.json'))
    assert len(cases) == 4
    negatives = 0
    for path in cases:
        case = json.loads(path.read_text())
        actual = execute(case['instructions'], case['inputs']['storage0'])
        assert actual == case['expected'], path.name
        for i in range(64):
            bad = case['expected'].copy(); bad[i] ^= 1
            assert bad != actual
            negatives += 1
    print(f'I2F integer oracle: {len(anchors)} hand anchors; 4 cases/256 words; {negatives} wrong-word negatives')


if __name__ == '__main__': main()
