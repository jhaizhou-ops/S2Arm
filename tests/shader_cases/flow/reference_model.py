#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Independent byte-array semantics for the first T223 single-thread cases.

This is deliberately a small reference domain, not a Maxwell encoder/emulator.
It imports no translator, decoder, SPIR-V, runner, or produced result.
Usage: python3 tests/shader_cases/flow/reference_model.py
"""
import copy
import json
from pathlib import Path
import struct


def execute(instructions, initial):
    if len(initial) != 64 or any(type(v) is not int or not 0 <= v < 2**32 for v in initial):
        raise ValueError("reference domain is exactly 64 uint32 words")
    memory = bytearray(struct.pack("<64I", *initial))
    constants = bytes(65536)  # Explicit framework C0 uniform input, not expected output.
    registers = {255: 0}

    def number(token):
        n = 255 if token == "RZ" else int(token.removeprefix("R"))
        if not token.startswith("R") or not 0 <= n <= 255:
            raise ValueError("bad register")
        return n

    def read(token):
        n = number(token)
        if n not in registers:
            raise ValueError("undefined reference register " + token)
        return registers[n]

    def write(token, value):
        n = number(token)
        if n != 255:
            registers[n] = value & 0xffffffff

    def address(base, offset):
        n = number(base)
        if n >= 254 or n not in registers or n + 1 not in registers:
            raise ValueError("reference needs an initialized 64-bit address pair")
        pos = registers[n] + (registers[n + 1] << 32) + int(offset, 0)
        if pos % 4 or not 0 <= pos <= len(memory) - 4:
            raise ValueError("reference uses only aligned, in-range uint32 access")
        return pos

    stopped = False
    for index, line in enumerate(instructions):
        op, *a = line.replace(",", " ").split()
        if op == "MOV32I" and len(a) == 2:
            write(a[0], int(a[1], 0))
        elif op == "IADD32I" and len(a) == 3:
            write(a[0], read(a[1]) + int(a[2], 0))
        elif op == "LDC64" and len(a) == 3:
            n, slot, offset = number(a[0]), int(a[1], 0), int(a[2], 0)
            if n >= 254 or slot != 0 or offset % 8 or not 0 <= offset <= 32760:
                raise ValueError("reference LDC64 uses a nonnegative signed16 displacement from RZ")
            lo, hi = struct.unpack_from("<II", constants, offset)
            write(a[0], lo)
            write("R" + str(n + 1), hi)
        elif op == "LDG32" and len(a) == 3:
            write(a[0], struct.unpack_from("<I", memory, address(a[1], a[2]))[0])
        elif op == "STG32" and len(a) == 3:
            struct.pack_into("<I", memory, address(a[1], a[2]), read(a[0]))
        elif op == "EXIT" and not a and index == len(instructions) - 1:
            stopped = True
        else:
            raise ValueError("outside reference instruction domain: " + line)
    if not stopped:
        raise ValueError("explicit final EXIT required")
    return list(struct.unpack("<64I", memory))


def verify(case):
    if case["stage"] != "compute" or set(case["inputs"]) != {"storage0"}:
        raise ValueError("reference is single-invocation storage0 only")
    actual = execute(case["instructions"], case["inputs"]["storage0"])
    if actual != case["expected"]:
        raise AssertionError("independent expectation mismatch: " + case["id"])
    return actual


def main():
    paths = sorted(Path(__file__).parent.glob("*.json"))
    if not paths:
        raise ValueError("no original flow cases")
    rejected = 0
    for path in paths:
        case = json.loads(path.read_text())
        actual = verify(case)
        changed = next(i for i, (a, b) in enumerate(zip(actual, case["inputs"]["storage0"])) if a != b)
        bad = copy.deepcopy(case)
        bad["expected"][changed] ^= 1
        try:
            verify(bad)
        except AssertionError:
            rejected += 1
        else:
            raise AssertionError("wrong expectation survived")
        print("reference " + case["id"] + ": 64 words match; one-bit wrong expectation rejected")
    try:
        execute(["LDC64 R0 0 0", "LDC64 R2 0 65528", "EXIT"], [0] * 64)
    except ValueError:
        print("reference invalid zero-base raw0xfff8 displacement rejected (signed value -8)")
    else:
        raise AssertionError("negative displacement treated as unsigned in-range address")
    print(f"reference: {len(paths)}/{len(paths)} cases; wrong expectations {rejected}/{len(paths)} rejected")


if __name__ == "__main__":
    main()
