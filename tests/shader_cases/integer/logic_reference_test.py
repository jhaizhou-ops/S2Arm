#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Independent expectations for the T221 integer logic cases (integer/logic_*.json).

A small interpreter over the cases' readable instruction text, from ISA semantics:
LOP / LOP32I invert a source when it is prefixed with '~', then AND / OR / XOR / PASS_B;
a LOP / LOP3 immediate is a signed 20-bit value (sign-extended to 32 bits);
LOP3.LUT result bit = (lut >> (a*4 + b*2 + c)) & 1, the PTX lop3 convention (A=0xF0, B=0xCC, C=0xAA);
c[slot][offset] reads the framework's zero-filled C0. It imports no encoder, translator, SPIR-V or produced result.
Usage: python3 tests/shader_cases/integer/logic_reference_test.py
"""
import copy
import json
from pathlib import Path
import re
import struct

M = 0xffffffff
LOGIC = {"AND": lambda a, b: a & b, "OR": lambda a, b: a | b, "XOR": lambda a, b: a ^ b, "PASS_B": lambda a, b: b}


def lop3(lut, a, b, c):
    return sum(((lut >> ((a >> i & 1) * 4 + (b >> i & 1) * 2 + (c >> i & 1))) & 1) << i for i in range(32))


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

    def source(token, imm_bits):
        if token.startswith("R"):
            return read(token)
        if re.fullmatch(r"c\[0\]\[\w+\]", token):
            return 0  # framework C0: 64 KiB of zeros
        v = int(token, 0)
        lo, hi = (-(1 << (imm_bits - 1)), (1 << (imm_bits - 1)) - 1) if imm_bits == 20 else (-(1 << 31), M)
        if not lo <= v <= hi:
            raise ValueError("immediate out of range: " + token)
        return v & M

    def invertible(token, imm_bits):
        return (source(token[1:], imm_bits) ^ M) if token.startswith("~") else source(token, imm_bits)

    def word(base, offset):
        if read(base) or read("R" + str(number(base) + 1)):
            raise ValueError("reference uses the zero C0 base address only")
        pos = int(offset, 0)
        if pos % 4 or not 0 <= pos <= 252:
            raise ValueError("reference uses only aligned, in-range uint32 access")
        return pos // 4

    for index, line in enumerate(instructions):
        op, *a = line.replace(",", " ").split()
        if op == "LDC64" and a[1:] == ["0", "0"] and number(a[0]) < 254:
            write(a[0], 0)
            write("R" + str(number(a[0]) + 1), 0)
        elif op == "LDG32" and len(a) == 3:
            write(a[0], memory[word(a[1], a[2])])
        elif op == "STG32" and len(a) == 3:
            memory[word(a[1], a[2])] = read(a[0])
        elif op.startswith("LOP.") and op[4:] in LOGIC and len(a) == 3:
            write(a[0], LOGIC[op[4:]](invertible(a[1], 20), invertible(a[2], 20)))
        elif op.startswith("LOP32I.") and op[7:] in LOGIC and len(a) == 3:
            write(a[0], LOGIC[op[7:]](invertible(a[1], 32), invertible(a[2], 32)))
        elif op == "LOP3.LUT" and len(a) == 5 and 0 <= int(a[4], 0) < 256:
            write(a[0], lop3(int(a[4], 0), read(a[1]), source(a[2], 20), read(a[3])))
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
    assert lop3(0xF0, 0xF0F0F0F0, 0xCCCCCCCC, 0xAAAAAAAA) == 0xF0F0F0F0
    assert lop3(0xCA, M, 0x12345678, 0) == 0x12345678 and lop3(0xCA, 0, 0x12345678, 0x9abcdef0) == 0x9abcdef0
    assert lop3(0x96, 0x55555555, 0x33333333, 0x0f0f0f0f) == 0x55555555 ^ 0x33333333 ^ 0x0f0f0f0f == 0x69696969
    assert execute(["LDC64 R0 0 0", "LDG32 R2 R0 0", "LOP.AND R3 R2 -1", "LOP.OR R4 ~R2 0x7ffff", "STG32 R3 R0 4", "STG32 R4 R0 8", "EXIT"],
                   [0x12345678] + [0] * 63)[1:3] == [0x12345678, 0xedcfffff]  # ~0x12345678 = 0xedcba987
    paths = sorted(Path(__file__).parent.glob("logic_*.json"))
    if not paths:
        raise ValueError("no original integer logic cases")
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
    for bad_line in ("LOP.AND R3 R2 0x80000", "LOP3.LUT R3 R2 -0x80001 R2 0xf0", "LOP3.LUT R3 R2 R2 R2 0x100"):
        try:
            execute(["LDC64 R0 0 0", "LDG32 R2 R0 0", bad_line, "EXIT"], [0] * 64)
        except ValueError:
            pass
        else:
            raise AssertionError("out-of-range operand accepted: " + bad_line)
    print("reference: %d logic cases; out-of-range 20-bit immediates and LUT rejected" % len(paths))


if __name__ == "__main__":
    main()
