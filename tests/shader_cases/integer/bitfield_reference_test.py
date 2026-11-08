#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Independent expectations for the T221 bitfield cases (integer/bitfield_*.json).

A small interpreter over the cases' readable instruction text, from the PTX semantics the SASS instructions map onto:
BFE (PTX bfe): control B = position | length << 8 (low byte each); .BREV bit-reverses A first; bits [pos, pos+len) of A,
  zero-extended (.U32) or sign-extended from bit min(pos+len-1, 31) (.S32); length 0 gives 0, a field past bit 31 is
  filled with that extension bit.
BFI (PTX bfi): insert the low len bits of A into the base C at pos (bits past 31 dropped); length 0 or pos > 31 gives C.
  BFI Rd Ra Rb c[][] is the Rc form: control from the register, base from the constant buffer.
POPC: population count of B, after '~' inverts it.
FLO (PTX bfind): position of the most significant 1 (.U32) or of the most significant non-sign bit (.S32) of B after
  '~'; .SH returns 31 - position; none found gives 0xffffffff either way.
MOV32I sets a register; c[0][offset] reads the framework's zero-filled C0. It imports no encoder, translator, SPIR-V or produced result.
Usage: python3 tests/shader_cases/integer/bitfield_reference_test.py
"""
import copy
import json
from pathlib import Path
import re

M = 0xffffffff


def brev(a):
    return int(format(a, "032b")[::-1], 2)


def bfe(a, b, signed, reverse):
    a = brev(a) if reverse else a
    pos, length = b & 0xff, (b >> 8) & 0xff
    if length == 0:
        return 0
    sbit = (a >> min(pos + length - 1, 31)) & 1 if signed else 0
    return sum(((a >> (pos + i)) & 1 if i < length and pos + i <= 31 else sbit) << i for i in range(32))


def bfi(a, b, c):
    pos, length = b & 0xff, (b >> 8) & 0xff
    for i in range(length):
        if pos + i <= 31:
            c = (c & ~(1 << (pos + i)) & M) | (((a >> i) & 1) << (pos + i))
    return c


def flo(b, signed, shift):
    if signed and b >> 31:
        b ^= M
    if b == 0:
        return M
    pos = b.bit_length() - 1
    return 31 - pos if shift else pos


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

    def source(token):
        invert = token.startswith("~")
        token = token[1:] if invert else token
        if token.startswith("R"):
            v = read(token)
        elif re.fullmatch(r"c\[0\]\[\w+\]", token):
            v = 0  # framework C0: 64 KiB of zeros
        else:
            v = int(token, 0)
            if not -(1 << 19) <= v < 1 << 19:
                raise ValueError("20-bit immediate out of range: " + token)
            v &= M
        return v ^ M if invert else v

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
        elif m[0] == "BFE" and len(m) > 1 and m[1] in ("U32", "S32") and set(m[2:]) <= {"BREV"} and len(a) == 3 and not a[2].startswith("~"):
            write(a[0], bfe(read(a[1]), source(a[2]), m[1] == "S32", "BREV" in m))
        elif op == "BFI" and len(a) == 4 and not (a[2].startswith("c[") and a[3].startswith("c[")):
            write(a[0], bfi(read(a[1]), source(a[2]), source(a[3])))
        elif op == "POPC" and len(a) == 2:
            write(a[0], bin(source(a[1])).count("1"))
        elif m[0] == "FLO" and len(m) > 1 and m[1] in ("U32", "S32") and set(m[2:]) <= {"SH"} and len(a) == 2:
            write(a[0], flo(source(a[1]), m[1] == "S32", "SH" in m))
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
    assert bfe(0x12345678, 0x0804, False, False) == 0x67 and bfe(0xdeadbeef, 0x0804, True, False) == 0xffffffee
    assert bfe(0xdeadbeef, 0x081c, True, False) == 0xfffffffd and bfe(0xdeadbeef, 0x081c, False, False) == 0xd
    assert bfe(0xdeadbeef, 0x0820, True, False) == M and bfe(0xdeadbeef, 0x0820, False, False) == 0 and bfe(0xdeadbeef, 0x0000, True, False) == 0
    assert bfe(0x12345678, 0x0804, False, True) == 0xc4      # brev(0x12345678) = 0x1e6a2c48
    assert bfi(0x12345678, 0x0804, 0xdeadbeef) == 0xdeadb78f and bfi(0x12345678, 0x081c, 0xdeadbeef) == 0x8eadbeef
    assert bfi(0, 0x1008, M) == 0xff0000ff and bfi(0x12345678, 0x0820, 0xdeadbeef) == 0xdeadbeef
    assert flo(0x12345678, False, False) == 28 and flo(0x12345678, False, True) == 3 and flo(0xdeadbeef, True, False) == 29
    assert flo(M, True, False) == M and flo(0, False, True) == M and flo(0x80000001, True, True) == 1
    paths = sorted(Path(__file__).parent.glob("bitfield_*.json"))
    if not paths:
        raise ValueError("no original integer bitfield cases")
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
    for bad_line in ("BFE R3 R2 4", "BFE.U32 R3 R2 ~R2", "BFI R3 R2 c[0][0x10] c[0][0x10]", "FLO R3 R2", "POPC R3 0x80000"):
        try:
            execute(["LDC64 R0 0 0", "LDG32 R2 R0 0", bad_line, "EXIT"], [0] * 64)
        except ValueError:
            pass
        else:
            raise AssertionError("instruction outside the modelled domain accepted: " + bad_line)
    print("reference: %d bitfield cases; out-of-domain forms rejected" % len(paths))


if __name__ == "__main__":
    main()
