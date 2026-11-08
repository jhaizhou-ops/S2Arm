#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Independent expectations for the T221 shift cases (integer/shift_*.json).

A small interpreter over the cases' readable instruction text, from ISA semantics:
SHL / SHR shift amount n is the 32-bit source; default clamps (n >= 32 gives 0, or the sign for SHR.S32), .W wraps (n & 31);
SHR.BREV bit-reverses A first; SHR.S32 is arithmetic.
SHF is the funnel shift of the 64-bit {C:A} (C high), as PTX shf documents it: SHF.L returns the high word of
({C:A} << n) mod 2^64, SHF.R the low word of {C:A} >> n (arithmetic for .S64). The limit is 32 by default and 64 for
.U64 / .S64; default clamps n to the limit, .W wraps (n & 31 or n & 63).
MOV32I sets a register; c[0][offset] reads the framework's zero-filled C0. It imports no encoder, translator, SPIR-V or produced result.
Usage: python3 tests/shader_cases/integer/shift_reference_test.py
"""
import copy
import json
from pathlib import Path
import re

M = 0xffffffff


def brev(a):
    return int(format(a, "032b")[::-1], 2)


def shl(a, n, wrap):
    n = n & 31 if wrap else n
    return (a << n) & M if n < 32 else 0


def shr(a, n, signed, wrap, reverse):
    a = brev(a) if reverse else a
    n = n & 31 if wrap else min(n, 32)
    s = a - (1 << 32) if signed and a >> 31 else a
    return (s >> n) & M if n < 32 else (M if s < 0 else 0)


def shf(left, a, n, c, limit, signed, wrap):
    n = n & (limit - 1) if wrap else min(n, limit)
    v = (c << 32) | a
    if left:
        return ((v << n) & (2**64 - 1)) >> 32
    if signed and c >> 31:
        v -= 1 << 64
    return (v >> n) & M


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

    def write(token, value):
        if number(token) != 255:
            registers[number(token)] = value & M

    def amount(token, imm_max):
        if token.startswith("R"):
            return read(token)
        if re.fullmatch(r"c\[0\]\[\w+\]", token):
            return 0  # framework C0: 64 KiB of zeros
        v = int(token, 0)
        if not 0 <= v <= imm_max:
            raise ValueError("shift immediate outside the modelled range: " + token)
        return v

    def word(base, offset):
        if read(base) or read("R" + str(number(base) + 1)):
            raise ValueError("reference uses the zero C0 base address only")
        pos = int(offset, 0)
        if pos % 4 or not 0 <= pos <= 252:
            raise ValueError("reference uses only aligned, in-range uint32 access")
        return pos // 4

    for index, line in enumerate(instructions):
        op, *a = line.split()
        m = op.split(".")
        if op == "LDC64" and a[1:] == ["0", "0"] and number(a[0]) < 254:
            write(a[0], 0)
            write("R" + str(number(a[0]) + 1), 0)
        elif op == "LDG32" and len(a) == 3:
            write(a[0], memory[word(a[1], a[2])])
        elif op == "STG32" and len(a) == 3:
            memory[word(a[1], a[2])] = read(a[0])
        elif op == "MOV32I" and len(a) == 2:
            write(a[0], int(a[1], 0))
        elif m[0] == "SHL" and set(m[1:]) <= {"W"} and len(a) == 3:
            write(a[0], shl(read(a[1]), amount(a[2], 0x7ffff), "W" in m))
        elif m[0] == "SHR" and len(m) > 1 and m[1] in ("U32", "S32") and set(m[2:]) <= {"W", "BREV"} and len(a) == 3:
            write(a[0], shr(read(a[1]), amount(a[2], 0x7ffff), m[1] == "S32", "W" in m, "BREV" in m))
        elif m[0] == "SHF" and len(m) > 1 and m[1] in ("L", "R") and set(m[2:]) <= {"W", "U64", "S64"} and len(a) == 4:
            if a[2].startswith("c["):
                raise ValueError("SHF has no constant-buffer form")
            wide = "U64" in m or "S64" in m
            write(a[0], shf(m[1] == "L", read(a[1]), amount(a[2], 63), read(a[3]), 64 if wide else 32, "S64" in m, "W" in m))
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
    assert brev(0x12345678) == 0x1e6a2c48 and brev(0x80000001) == 0x80000001
    assert shl(0x12345678, 4, False) == 0x23456780 and shl(0x12345678, 32, False) == 0 and shl(0x12345678, 33, True) == 0x2468acf0
    assert shr(0xdeadbeef, 4, True, False, False) == 0xfdeadbee and shr(0xdeadbeef, 40, True, False, False) == M
    assert shr(0xdeadbeef, 40, False, False, False) == 0 and shr(0x80000001, 1, True, False, True) == 0xc0000000
    assert shf(True, 0x12345678, 4, 0xdeadbeef, 32, False, False) == 0xeadbeef1
    assert shf(False, 0x12345678, 4, 0xdeadbeef, 32, False, False) == 0xf1234567
    assert shf(True, 0x12345678, 63, 0xdeadbeef, 32, False, False) == 0x12345678  # clamped to 32
    assert shf(False, 0x12345678, 40, 0xdeadbeef, 64, False, False) == 0x00deadbe
    assert shf(False, 0x12345678, 40, 0xdeadbeef, 64, True, False) == 0xffdeadbe
    assert shf(True, 0x12345678, 64, 0xdeadbeef, 64, False, True) == 0xdeadbeef  # .W: 64 & 63 = 0
    paths = sorted(Path(__file__).parent.glob("shift_*.json"))
    if not paths:
        raise ValueError("no original integer shift cases")
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
    for bad_line in ("SHF.L R3 R2 64 R2", "SHF.R R3 R2 c[0][0x10] R2", "SHR R3 R2 4", "SHL.BREV R3 R2 4"):
        try:
            execute(["LDC64 R0 0 0", "LDG32 R2 R0 0", bad_line, "EXIT"], [0] * 64)
        except ValueError:
            pass
        else:
            raise AssertionError("instruction outside the modelled domain accepted: " + bad_line)
    print("reference: %d shift cases; out-of-domain immediates / forms rejected" % len(paths))


if __name__ == "__main__":
    main()
