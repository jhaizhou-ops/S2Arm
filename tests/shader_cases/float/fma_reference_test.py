#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Independent expectations for the T222 FFMA / FMNMX cases (float/fma_*.json).

A small interpreter over the cases' readable instruction text, from IEEE 754 binary32 semantics, round to nearest even:
FFMA is fused: a*b + c is formed exactly as a rational number and rounded ONCE to binary32 (no binary64 intermediate,
which could round twice). Vulkan only promises GLSL.std.450 Fma the precision of OpFMul followed by OpFAdd (Mesa lavapipe
does round twice), so inputs whose fused and twice-rounded results differ are outside the modelled domain and rejected;
'-' negates B (the product) or C; .SAT clamps the rounded result to [0, 1]; a result beyond
the binary32 range is infinity, and an infinite operand follows IEEE infinity arithmetic. FFMA32I's C is Rd itself.
FMNMX.MIN / .MAX are IEEE minNum / maxNum of the sources after '|x|' then '-'. A 20-bit float immediate is the float's
top 20 bits; FFMA32I takes any binary32. c[0][offset] reads the framework's zero-filled C0 (+0.0).
The modelled domain excludes NaN, denormal results, a .SAT whose input is exactly +-0, and FMNMX of two zeros, where
FTZ / signed-zero conventions could decide. Tolerance: bit-exact (0 ULP). It imports no encoder, translator, SPIR-V or produced result.
Usage: python3 tests/shader_cases/float/fma_reference_test.py
"""
import copy
from fractions import Fraction
import json
import math
from pathlib import Path
import re
import struct

M = 0xffffffff


def value(bits):
    return struct.unpack("<f", struct.pack("<I", bits))[0]


def round_f32(q):
    """Exact rational -> binary32 bits, round to nearest even, in one step."""
    if q == 0:
        return 0  # an exact zero sum of nonzero terms is +0 under round to nearest
    sign, q = (1 << 31 if q < 0 else 0), abs(q)
    e = q.numerator.bit_length() - q.denominator.bit_length()
    if Fraction(2) ** e > q:
        e -= 1
    if e < -126:
        raise ValueError("denormal result is outside the modelled domain")
    if e > 127:
        return sign | 0x7f800000
    m = q / Fraction(2) ** (e - 23)                # in [2^23, 2^24)
    n, r = m.numerator // m.denominator, m - m.numerator // m.denominator
    if r > Fraction(1, 2) or (r == Fraction(1, 2) and n & 1):
        n += 1
    if n == 1 << 24:
        n, e = 1 << 23, e + 1
    if e > 127:
        return sign | 0x7f800000
    return sign | (e + 127) << 23 | (n - (1 << 23))


def fma_bits(a, b, c):
    if any(math.isinf(x) for x in (a, b, c)):
        r = a * b + c                              # IEEE infinity arithmetic, exact in binary64
        if math.isnan(r):
            raise ValueError("NaN is outside the modelled domain")
        return struct.unpack("<I", struct.pack("<f", r))[0]
    return round_f32(Fraction(a) * Fraction(b) + Fraction(c))


def ffma(a, b, c):
    """Fused result, provided the twice-rounded (FMul then FAdd) result is the same bits; else outside the domain."""
    fused = fma_bits(a, b, c)
    p = round_f32(Fraction(a) * Fraction(b)) if not any(math.isinf(x) for x in (a, b)) else None
    twice = fused if p is None or p & 0x7f800000 == 0x7f800000 else fma_bits(value(p), 1.0, c)
    if twice != fused:
        raise ValueError("inputs tell fused FFMA from FMul + FAdd (%#010x vs %#010x); Vulkan allows either" % (fused, twice))
    return fused


def saturate(bits):
    x = value(bits)
    if x == 0:
        raise ValueError("a .SAT input of exactly +-0 is outside the modelled domain")
    return 0 if x < 0 else 0x3f800000 if x > 1 else bits


def execute(instructions, initial):
    if len(initial) != 64 or any(type(v) is not int or not 0 <= v <= M for v in initial):
        raise ValueError("reference domain is exactly 64 uint32 words")
    memory = list(initial)
    registers = {255: 0}

    def number(token):
        if token == "RZ":
            return 255
        if not re.fullmatch(r"R\d+", token) or not 0 <= int(token[1:]) < 255:
            raise ValueError("bad register " + token)
        return int(token[1:])

    def read(token):
        n = number(token)
        if n not in registers:
            raise ValueError("undefined reference register " + token)
        return registers[n]

    def write(token, bits):
        if number(token) != 255:
            registers[number(token)] = bits & M

    def operand(token, imm20):
        negate = token[:1] == "-" and token[1:2] in ("R", "|", "c")
        token = token[1:] if negate else token
        absolute = len(token) > 2 and token[0] == "|" and token[-1] == "|"
        token = token[1:-1] if absolute else token
        if token.startswith("R"):
            x = value(read(token))
        elif re.fullmatch(r"c\[0\]\[\w+\]", token):
            x = 0.0  # framework C0: 64 KiB of zeros
        else:
            b = struct.unpack("<I", struct.pack("<f", float(token)))[0]
            if value(b) != float(token) or (imm20 and b & 0xfff):
                raise ValueError("immediate not representable in this form: " + token)
            x = value(b)
        if math.isnan(x):
            raise ValueError("NaN operand is outside the modelled domain")
        x = abs(x) if absolute else x
        return -x if negate else x, absolute

    def word(base, offset):
        if read(base) or read("R" + str(number(base) + 1)):
            raise ValueError("reference uses the zero C0 base address only")
        pos = int(offset, 0)
        if pos % 4 or not 0 <= pos <= 252:
            raise ValueError("reference uses only aligned, in-range uint32 access")
        return pos // 4

    for index, line in enumerate(instructions):
        op, *a = line.split()
        f = op.split(".")
        if op == "LDC64" and a[1:] == ["0", "0"] and number(a[0]) < 254:
            write(a[0], 0)
            write("R" + str(number(a[0]) + 1), 0)
        elif op == "LDG32" and len(a) == 3:
            write(a[0], memory[word(a[1], a[2])])
        elif op == "STG32" and len(a) == 3:
            memory[word(a[1], a[2])] = read(a[0])
        elif op == "MOV32I" and len(a) == 2:
            write(a[0], int(a[1], 0))
        elif f[0] == "FFMA" and set(f[1:]) <= {"SAT"} and len(a) == 4 and a[1].startswith("R"):
            (b, ab), (c, ac) = operand(a[2], True), operand(a[3], True)
            if ab or ac or (a[2].lstrip("-").startswith("c[") and a[3].lstrip("-").startswith("c[")):
                raise ValueError("FFMA has no |x| and at most one c[][] source: " + line)
            r = ffma(value(read(a[1])), b, c)
            write(a[0], saturate(r) if "SAT" in f else r)
        elif f[0] == "FFMA32I" and set(f[1:]) <= {"SAT"} and len(a) == 4 and a[3].lstrip("-") == a[0] and a[1].startswith("R"):
            b = operand(a[2].lstrip("-"), False)[0] * (-1 if a[2].startswith("-") else 1)
            c = value(read(a[0])) * (-1 if a[3].startswith("-") else 1)
            r = ffma(value(read(a[1])), b, c)
            write(a[0], saturate(r) if "SAT" in f else r)
        elif f[0] == "FMNMX" and len(f) == 2 and f[1] in ("MIN", "MAX") and len(a) == 3:
            x, y = operand(a[1], False)[0], operand(a[2], True)[0]
            if x == 0 and y == 0:
                raise ValueError("FMNMX of two zeros is outside the modelled domain")
            r = min(x, y) if f[1] == "MIN" else max(x, y)
            write(a[0], struct.unpack("<I", struct.pack("<f", r))[0])
        elif op == "EXIT" and not a and index == len(instructions) - 1:
            return memory
        else:
            raise ValueError("outside reference instruction domain: " + line)
    raise ValueError("explicit final EXIT required")


def verify(case):
    if case["stage"] != "compute" or set(case["inputs"]) != {"storage0"}:
        raise ValueError("reference is single-invocation storage0 only")
    actual = execute(case["instructions"], case["inputs"]["storage0"])
    if actual != case["expected"]:
        raise AssertionError("independent expectation mismatch: " + case["id"])
    return actual


def main():
    # Hand-computed anchors, so a slip in the interpreter itself cannot pass silently.
    a = value(0x3f800800)                                    # 1 + 2^-12
    assert fma_bits(a, a, -value(0x3f801000)) == 0x33800000  # fused: (1+2^-12)^2 - (1+2^-11) = 2^-24 exactly
    assert struct.unpack("<I", struct.pack("<f", value(struct.unpack("<I", struct.pack("<f", a * a))[0]) - value(0x3f801000)))[0] == 0
    assert round_f32(Fraction(1) + Fraction(1, 2 ** 24)) == 0x3f800000 and round_f32(Fraction(1) + Fraction(3, 2 ** 24)) == 0x3f800002
    assert round_f32(Fraction(2) ** 128) == 0x7f800000 and round_f32(-Fraction(3, 2)) == 0xbfc00000
    assert fma_bits(1.0, -2.5, value(0x40490fdb)) == 0x3f243f6c   # binary32 pi (0x40490fdb) - 2.5 = 0.64159274..., exact
    paths = sorted(Path(__file__).parent.glob("fma_*.json"))
    if not paths:
        raise ValueError("no original FFMA / FMNMX cases")
    for path in paths:
        case = json.loads(path.read_text())
        actual = verify(case)
        changed = [i for i, (x, y) in enumerate(zip(actual, case["inputs"]["storage0"])) if x != y]
        for i in changed:
            bad = copy.deepcopy(case)
            bad["expected"][i] ^= 1
            try:
                verify(bad)
            except AssertionError:
                pass
            else:
                raise AssertionError("wrong expectation survived: %s word %d" % (case["id"], i))
        print("reference %s: 64 words match; %d result words, each one-bit wrong expectation rejected" % (case["id"], len(changed)))
    for bad_line in ("FFMA R3 R2 |R2| R2", "FFMA R3 R2 c[0][0x10] c[0][0x10]", "FFMA32I R3 R2 2.0 R2", "FMNMX R3 R2 R2", "FMNMX.MIN R3 c[0][0x10] c[0][0x20]",
                     "FFMA R5 R4 R4 R6"):   # (1+2^-12)^2 - (1+2^-11): fused 2^-24, twice-rounded 0
        try:
            execute(["LDC64 R0 0 0", "MOV32I R2 0x3f800000", "MOV32I R3 0x3f800000", "MOV32I R4 0x3f800800", "MOV32I R6 0xbf801000", bad_line, "EXIT"], [0] * 64)
        except ValueError:
            pass
        else:
            raise AssertionError("instruction outside the modelled domain accepted: " + bad_line)
    print("reference: %d FFMA / FMNMX cases; illegal forms, zero / NaN / denormal edge cases and fused-vs-twice-rounded inputs rejected" % len(paths))


if __name__ == "__main__":
    main()
