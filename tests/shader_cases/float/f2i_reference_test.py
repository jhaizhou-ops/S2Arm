#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Original exact binary32/rational oracle; no encoder or translator imports."""
from fractions import Fraction
import json
from pathlib import Path
import re


def rational(word):
    if type(word) is not int or not 0 <= word < 2**32:
        raise ValueError('expected uint32 bits')
    sign, exponent, fraction = word >> 31, (word >> 23) & 255, word & 0x7fffff
    if exponent == 255 or (exponent == 0 and fraction):
        raise ValueError('finite normal or zero only')
    if exponent == 0: return Fraction(0)
    significand = (1 << 23) | fraction
    power = exponent - 150
    magnitude = Fraction(significand << power) if power >= 0 else Fraction(significand, 1 << -power)
    return -magnitude if sign else magnitude


def integer(word, signed, mode):
    if type(signed) is not bool or mode not in ('RN', 'RZ'):
        raise ValueError('S32/U32 and RN/RZ only')
    value = rational(word)
    low, high = (-(1 << 31), (1 << 31) - 1) if signed else (0, (1 << 32) - 1)
    if not low <= value <= high: raise ValueError('input outside integer domain')
    magnitude = abs(value)
    quotient, remainder = divmod(magnitude.numerator, magnitude.denominator)
    if mode == 'RN' and (2 * remainder > magnitude.denominator or
                         (2 * remainder == magnitude.denominator and quotient & 1)):
        quotient += 1
    result = -quotient if value < 0 else quotient
    if not low <= result <= high: raise ValueError('rounded result outside integer domain')
    return result & 0xffffffff


def immediate(text):
    # Decimal text -> exact dyadic -> binary32, without host floating-point rounding.
    value = Fraction(text)
    sign = int(text.startswith('-')) << 31
    value = abs(value)
    if not value: return sign
    exponent = value.numerator.bit_length() - value.denominator.bit_length()
    if value < Fraction(2) ** exponent: exponent -= 1
    significand = value / (Fraction(2) ** (exponent - 23))
    if not -126 <= exponent <= 127 or significand.denominator != 1:
        raise ValueError('immediate not exactly normal binary32')
    word = sign | ((exponent + 127) << 23) | (int(significand) - (1 << 23))
    if word & 0xfff: raise ValueError('immediate needs low 12 bits zero')
    return word


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
        elif re.fullmatch(r'F2I\.(S32|U32)\.F32\.(RN|RZ)', op) and len(a) == 2:
            _, kind, _, mode = op.split('.')
            word = regs[reg(a[1])] if a[1].startswith('R') else immediate(a[1])
            regs[reg(a[0])] = integer(word, kind == 'S32', mode)
        elif op == 'EXIT' and not a: exited = True
        else: raise ValueError('outside F2I reference domain: ' + line)
    if not exited: raise ValueError('missing EXIT')
    return memory


def main():
    # Hand-derived RN/RZ pairs: ties both ways, signed symmetry, adjacent floats, limits.
    anchors = [(0, True, 0, 0), (0x80000000, True, 0, 0),
               (0x3f000000, True, 0, 0), (0x3fc00000, True, 2, 1),
               (0x40200000, True, 2, 2), (0x40600000, True, 4, 3),
               (0xbfc00000, True, 0xfffffffe, 0xffffffff),
               (0xc0200000, True, 0xfffffffe, 0xfffffffe),
               (0xc0600000, True, 0xfffffffc, 0xfffffffd),
               (0x3fbfffff, True, 1, 1), (0x3fc00001, True, 2, 1),
               (0xcf000000, True, 0x80000000, 0x80000000),
               (0x4effffff, True, 0x7fffff80, 0x7fffff80),
               (0x4f7fffff, False, 0xffffff00, 0xffffff00),
               (0x4f000000, False, 0x80000000, 0x80000000),
               (0x00800000, False, 0, 0)]
    for word, signed, rn, rz in anchors:
        assert integer(word, signed, 'RN') == rn
        assert integer(word, signed, 'RZ') == rz
    bad = [(0x7f800000, True), (0xff800000, True), (0x7fc00000, True),
           (1, True), (0x80000001, True), (0x4f000000, True),
           (0xcf000001, True), (0xbf000000, False), (0x4f800000, False)]
    for word, signed in bad:
        for mode in ('RN', 'RZ'):
            try: integer(word, signed, mode)
            except ValueError: pass
            else: raise AssertionError('outside domain accepted')
    for text, word in [('0', 0), ('-0.0', 0x80000000), ('1.5', 0x3fc00000),
                       ('-2.5', 0xc0200000), ('4293918720', 0x4f7ff000)]:
        assert immediate(text) == word
    for text in ('1.1', '1.00000011920928955078125', '1e-45'):
        try: immediate(text)
        except ValueError: pass
        else: raise AssertionError('unencodable immediate accepted')
    cases = sorted(Path(__file__).parent.glob('f2i_*.json'))
    assert len(cases) == 8
    negatives = 0
    for path in cases:
        case = json.loads(path.read_text())
        actual = execute(case['instructions'], case['inputs']['storage0'])
        assert actual == case['expected'], path.name
        swapped = [line.replace('.RN ', '.RZ ') if '.RN ' in line else
                   line.replace('.RZ ', '.RN ') for line in case['instructions']]
        assert execute(swapped, case['inputs']['storage0']) != actual, path.name
        for i in range(64):
            wrong = case['expected'].copy(); wrong[i] ^= 1
            assert wrong != actual
            negatives += 1
    print(f'F2I rational oracle: {len(anchors)} RN/RZ hand anchors; 8 cases/512 words; '
          f'{negatives} wrong-word negatives; 8 wrong-mode negatives; 18 domain rejections')


if __name__ == '__main__': main()
