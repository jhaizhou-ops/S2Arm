#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Original rational FSET oracle; imports no encoder, translator or actual output.

Finite binary32 normal numbers and signed zeros only. Abs precedes negation;
AND PT leaves the comparison unchanged. True is mask all-ones or BF 1.0,
false is +0 bits. See README for pinned independent encoding/semantic sources.
"""
from fractions import Fraction
import json
from pathlib import Path
import re
import struct


def rational(bits):
    if type(bits) is not int or not 0 <= bits < 2**32:
        raise ValueError('not a uint32')
    exponent, fraction = (bits >> 23) & 255, bits & 0x7fffff
    if exponent == 255 or (exponent == 0 and fraction):
        raise ValueError('NaN/Inf/subnormal outside FSET slice')
    if exponent == 0:
        return Fraction(0)
    return (-1 if bits >> 31 else 1) * Fraction((1 << 23) + fraction) * Fraction(2) ** (exponent - 150)


def predicate(op, a, b):
    if op == 'LT': return a < b
    if op == 'EQ': return a == b
    if op == 'LE': return a <= b
    if op == 'GT': return a > b
    if op == 'NE': return a != b
    if op == 'GE': return a >= b
    raise ValueError('unsupported comparison')


def execute(instructions, initial):
    if len(initial) != 64 or any(type(x) is not int or not 0 <= x < 2**32 for x in initial):
        raise ValueError('expected 64 uint32 inputs')
    memory, registers = list(initial), {'RZ': 0}

    def reg(token):
        if token != 'RZ' and not re.fullmatch(r'R(?:[0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-4])', token):
            raise ValueError('invalid register')
        return token

    def operand(token):
        negate = token.startswith('-') and token[1:2] in ('R', '|')
        if negate: token = token[1:]
        absolute = token.startswith('|') and token.endswith('|')
        if absolute: token = token[1:-1]
        if token.startswith('R'):
            value = rational(registers[reg(token)])
        else:
            # Parse decimal independently, require exact binary32/20-bit representation.
            decimal = Fraction(token)
            bits = struct.unpack('<I', struct.pack('<f', float(token)))[0]
            value = rational(bits)
            if bits & 4095 or value != decimal:
                raise ValueError('immediate is not exactly representable in 20 bits')
        if absolute: value = abs(value)
        return -value if negate else value

    def address(base, offset):
        if registers[reg(base)] != 0 or registers.get('R1') != 0:
            raise ValueError('only fixed zero address base supported')
        n = int(offset, 0)
        if n % 4 or not 0 <= n < 256:
            raise ValueError('out-of-bounds word')
        return n // 4

    exited = False
    for line in instructions:
        if exited: raise ValueError('instruction after EXIT')
        op, *args = line.replace(',', ' ').split()
        if op == 'LDC64' and args == ['R0', '0', '0']:
            registers.update(R0=0, R1=0)
        elif op == 'LDG32' and len(args) == 3:
            registers[reg(args[0])] = memory[address(*args[1:])]
        elif op == 'STG32' and len(args) == 3:
            memory[address(*args[1:])] = registers[reg(args[0])]
        elif op == 'MOV32I' and len(args) == 2:
            bits = int(args[1], 0)
            rational(bits)  # all explicit FSET operands stay within this slice
            registers[reg(args[0])] = bits
        elif re.fullmatch(r'FSET\.(LT|EQ|LE|GT|NE|GE)(\.BF)?', op) and len(args) == 3:
            parts = op.split('.')
            passed = predicate(parts[1], operand(args[1]), operand(args[2]))
            registers[reg(args[0])] = (0x3f800000 if 'BF' in parts else 0xffffffff) if passed else 0
        elif op == 'EXIT' and not args:
            exited = True
        else:
            raise ValueError('outside FSET reference domain: ' + line)
    if not exited: raise ValueError('missing EXIT')
    return memory


def main():
    # Hand-computed anchors, including adjacent normal bit patterns and signed zero.
    assert rational(0x00800000) == Fraction(1, 2**126)
    assert rational(0x7f7fffff) == (2**24 - 1) * 2**104
    assert rational(0x3f800001) - rational(0x3f800000) == Fraction(1, 2**23)
    assert rational(0) == rational(0x80000000) == 0
    for op, truth in zip(('LT','EQ','LE','GT','NE','GE'), (False,True,True,False,False,True)):
        assert predicate(op, rational(0), rational(0x80000000)) == truth
    rejected = 0
    for bits in (1, 0x80000001, 0x007fffff, 0x7f800000, 0xff800000, 0x7fc00000):
        try: rational(bits)
        except ValueError: rejected += 1
        else: raise AssertionError('out-of-domain accepted')
    cases = sorted(Path(__file__).parent.glob('fset_*.json'))
    assert len(cases) == 6, 'missing FSET fixture'
    mutations = 0
    for path in cases:
        case = json.loads(path.read_text())
        actual = execute(case['instructions'], case['inputs']['storage0'])
        assert actual == case['expected'], path.name
        # Every output and guard word participates in exact comparison.
        for index in range(64):
            bad = case['expected'].copy(); bad[index] ^= 1
            assert bad != actual, (path.name, index)
            mutations += 1
    print(f'FSET rational oracle: {len(cases)} cases/384 words, {mutations} wrong-word negatives, {rejected} domain rejections; hand anchors passed')


if __name__ == '__main__':
    main()
