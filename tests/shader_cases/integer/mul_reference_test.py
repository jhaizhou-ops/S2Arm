#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Independent low-32 product model; no encoder, translator or output imports.

For either signedness, the low word is (A * B) modulo 2**32. Signed
interpretation subtracts a multiple of 2**32, so it cannot change that word.
I-form immediates are sign-extended from 20 bits; C0 is the harness's zero
buffer, not arbitrary constant data. See mul_README.md for evidence/boundaries.
"""
import copy
import json
from pathlib import Path
import re

MASK = 0xffffffff


def execute(instructions, initial):
    if len(initial) != 64 or any(type(v) is not int or not 0 <= v <= MASK for v in initial):
        raise ValueError("reference requires exactly 64 uint32 words")
    memory = list(initial)
    registers = {255: 0}

    def number(token):
        if token == "RZ":
            return 255
        if not re.fullmatch(r"R\d+", token) or not 0 <= int(token[1:]) < 255:
            raise ValueError("invalid register: " + token)
        return int(token[1:])

    def read(token):
        n = number(token)
        if n not in registers:
            raise ValueError("undefined register: " + token)
        return registers[n]

    def write(token, value):
        n = number(token)
        if n != 255:
            registers[n] = value & MASK

    def source(token):
        if token.startswith("R"):
            return read(token)
        if token.startswith("c["):
            match = re.fullmatch(r"c\[0\]\[(0x[0-9a-fA-F]+|[0-9]+)\]", token)
            if not match:
                raise ValueError("only the existing zero C0 is supported")
            offset = int(match[1], 0)
            if not 0 <= offset <= 65532 or offset % 4:
                raise ValueError("invalid C0 uint32 offset")
            return 0
        value = int(token, 0)
        if not -(1 << 19) <= value < (1 << 19):
            raise ValueError("immediate outside signed 20-bit range")
        return value & MASK

    def word(base, offset):
        n = number(base)
        if n >= 254 or read(base) or read("R" + str(n + 1)):
            raise ValueError("only the zero C0 address pair is supported")
        pos = int(offset, 0)
        if not 0 <= pos <= 252 or pos % 4:
            raise ValueError("invalid storage uint32 offset")
        return pos // 4

    for index, line in enumerate(instructions):
        op, *args = line.split()
        if op == "LDC64" and len(args) == 3 and args[1:] == ["0", "0"] and number(args[0]) < 254:
            write(args[0], 0)
            write("R" + str(number(args[0]) + 1), 0)
        elif op == "MOV32I" and len(args) == 2:
            value = int(args[1], 0)
            if not -(1 << 31) <= value <= MASK:
                raise ValueError("MOV32I outside 32-bit range")
            write(args[0], value)
        elif op == "LDG32" and len(args) == 3:
            write(args[0], memory[word(args[1], args[2])])
        elif op == "STG32" and len(args) == 3:
            memory[word(args[1], args[2])] = read(args[0])
        elif re.fullmatch(r"IMUL\.(U32|S32)\.(U32|S32)", op) and len(args) == 3:
            write(args[0], read(args[1]) * source(args[2]))
        elif op == "EXIT" and not args and index == len(instructions) - 1:
            return memory
        else:
            raise ValueError("outside IMUL low-word reference domain: " + line)
    raise ValueError("explicit final EXIT required")


def verify(case):
    if case["schema"] != 1 or case["stage"] != "compute" or set(case["inputs"]) != {"storage0"}:
        raise ValueError("reference requires v1 single-invocation storage0")
    actual = execute(case["instructions"], case["inputs"]["storage0"])
    if actual != case["expected"]:
        raise AssertionError("independent expectation mismatch: " + case["id"])
    return actual


def main():
    # Fixed hand-derived anchors validate the model, not translator-generated gold.
    anchors = [(0, MASK, 0), (1, MASK, MASK), (MASK, MASK, 1),
               (0x80000000, 2, 0), (0x7fffffff, 2, 0xfffffffe),
               (0x10001, 0x10001, 0x20001), (0x12345678, 3, 0x369d0368)]
    for a, b, expected in anchors:
        for sa in ("U32", "S32"):
            for sb in ("U32", "S32"):
                lines = ["LDC64 R0 0 0", f"MOV32I R2 {a}", f"MOV32I R3 {b}",
                         f"IMUL.{sa}.{sb} R2 R2 R3", "STG32 R2 R0 0", "EXIT"]
                assert execute(lines, [0] * 64)[0] == expected
    paths = sorted(Path(__file__).parent.glob("mul_*.json"))
    if not paths:
        raise ValueError("no original IMUL cases")
    for path in paths:
        case = json.loads(path.read_text())
        verify(case)
        # Include unchanged guards: a comparison that checks only products is insufficient.
        for word in range(64):
            bad = copy.deepcopy(case)
            bad["expected"][word] ^= 1
            try:
                verify(bad)
            except AssertionError:
                pass
            else:
                raise AssertionError(f"one-bit wrong expectation survived: {path.name} word {word}")
        print(f"reference {case['id']}: all 64 words match; all 64 one-bit errors rejected")
    for line in ("IMUL R4 R2 R2", "IMUL.U32.U32.HI R4 R2 R2",
                 "IMUL.S32.S32.CC R4 R2 R2", "IMUL.U32.U32 R4 -R2 R2",
                 "IMUL.U32.U32 R4 R2 524288", "IMUL.U32.U32 R4 R2 -524289",
                 "IMUL.U32.U32 R4 R2 c[1][0]", "IMUL.U32.U32 R4 R2 c[0][2]",
                 "IMUL.U32.U32 R4 R2 c[0][65536]", "IMUL.U32.U32 R4 R2 R5"):
        try:
            execute(["LDC64 R0 0 0", "MOV32I R2 3", line, "EXIT"], [0] * 64)
        except ValueError:
            pass
        else:
            raise AssertionError("out-of-domain instruction accepted: " + line)
    print(f"reference: {len(paths)} IMUL cases; 28 hand anchors and out-of-domain checks passed")


if __name__ == "__main__":
    main()
