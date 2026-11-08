#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Independent expectations for the T222 FADD / FMUL cases (float/addmul_*.json).

A small interpreter over the cases' readable instruction text, from IEEE 754 binary32 semantics with round-to-nearest-even:
the exact sum / product is formed in binary64 (exact for a product of two binary32 values; for a sum the binary64 rounding
is innocuous because 53 >= 2*24+2) and rounded once to binary32; a result beyond the binary32 range rounds to infinity.
FADD: '|x|' takes the absolute value, then '-' negates, on either source. FMUL: '-' negates A; .D2/.D4/.D8 divide and
.M2/.M4/.M8 multiply the exact product by 2/4/8 before the single rounding. .SAT clamps to [0, 1]: a negative result becomes +0.0,
one above 1 becomes 1.0. A 20-bit float immediate
is the float's top 20 bits; FMUL32I takes any binary32. c[0][offset] reads the framework's zero-filled C0 (+0.0).
The modelled domain excludes NaN, denormal results and a .SAT whose input is exactly +-0, where FTZ / signed-zero
conventions could decide; a negative .SAT input is inside the domain and gives +0.0.
It imports no encoder, translator, SPIR-V or produced result.
Usage: python3 tests/shader_cases/float/addmul_reference_test.py
"""
import copy
import json
import math
from pathlib import Path
import re
import struct

M = 0xffffffff
SCALE = {"D2": 0.5, "D4": 0.25, "D8": 0.125, "M2": 2.0, "M4": 4.0, "M8": 8.0}


def value(bits):
    return struct.unpack("<f", struct.pack("<I", bits))[0]


def bits_of(x):
    """Round a binary64 value once to binary32 (round to nearest, ties to even) and return its bits."""
    if math.isnan(x):
        raise ValueError("NaN is outside the modelled domain")
    try:
        b = struct.unpack("<I", struct.pack("<f", x))[0]
    except OverflowError:  # rounds beyond the largest finite binary32
        b = 0xff800000 if x < 0 else 0x7f800000
    if b & 0x7f800000 == 0 and b & 0x7fffff:
        raise ValueError("denormal result is outside the modelled domain")
    return b


def saturate(x):
    if x <= 0 or x >= 1:
        if x == 0:
            raise ValueError("a .SAT input of exactly +-0 is outside the modelled domain")
        return 0.0 if x < 0 else 1.0
    return x


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
        x = abs(x) if absolute else x
        return (-x if negate else x), negate, absolute

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
        elif f[0] == "FADD" and set(f[1:]) <= {"SAT"} and len(a) == 3:
            x = operand(a[1], True)[0] + operand(a[2], True)[0]
            write(a[0], bits_of(saturate(x) if "SAT" in f else x))
        elif f[0] == "FMUL" and set(f[1:]) <= {"SAT"} | set(SCALE) and len(a) == 3:
            scale = [SCALE[s] for s in f[1:] if s in SCALE]
            x, _, abs_a = operand(a[1], True)
            y, neg_b, abs_b = operand(a[2], True)
            if abs_a or neg_b or abs_b or len(scale) > 1:
                raise ValueError("FMUL has only a negate on A and one scale: " + line)
            p = x * y * (scale[0] if scale else 1.0)
            write(a[0], bits_of(saturate(p) if "SAT" in f else p))
        elif f[0] == "FMUL32I" and set(f[1:]) <= {"SAT"} and len(a) == 3 and a[1].startswith("R"):
            p = value(read(a[1])) * operand(a[2], False)[0]
            write(a[0], bits_of(saturate(p) if "SAT" in f else p))
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
    assert bits_of(1.0 + 2.0**-24) == 0x3f800000            # tie -> even
    assert bits_of(1.0 + 2.0**-24 + 2.0**-47) == 0x3f800001  # just above the tie
    assert bits_of(value(0x3f800001) + 2.0**-24) == 0x3f800002  # tie from an odd mantissa -> even (up)
    assert bits_of(value(0x7f7fffff) * 2) == 0x7f800000 and bits_of(-value(0x7f7fffff) * 2) == 0xff800000
    assert bits_of(value(0x3f800001) ** 2) == 0x3f800002     # 1 + 2^-22 + 2^-46 -> 1 + 2^-22
    assert bits_of(-2.5 + 1.0) == 0xbfc00000 and bits_of(saturate(2.5)) == 0x3f800000
    paths = sorted(Path(__file__).parent.glob("addmul_*.json"))
    if not paths:
        raise ValueError("no original FADD / FMUL cases")
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
    for bad_line in ("FADD R3 R2 1.0000001", "FMUL R3 |R2| R2", "FADD.SAT R3 R2 -R2", "FMUL.D2.M2 R3 R2 R2"):
        try:
            execute(["LDC64 R0 0 0", "MOV32I R2 0x3f800000", bad_line, "EXIT"], [0] * 64)
        except ValueError:
            pass
        else:
            raise AssertionError("instruction outside the modelled domain accepted: " + bad_line)
    print("reference: %d FADD / FMUL cases; unrepresentable immediates, illegal modifiers, NaN / denormal results and +-0 .SAT inputs rejected" % len(paths))


if __name__ == "__main__":
    main()
