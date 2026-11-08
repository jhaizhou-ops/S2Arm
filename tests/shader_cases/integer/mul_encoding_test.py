#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Encoding checks separate from the independent arithmetic reference model.

Fixed words derived from envytools gm107.c, not the translator's decoder.
The low result cannot distinguish signedness bits, so check them explicitly.
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from run import encode


def main():
    fixed = {
        "IMUL.U32.U32 R4 R2 R3": 0x5c38000000370204,
        "IMUL.S32.U32 R4 R2 R3": 0x5c38010000370204,
        "IMUL.U32.S32 R4 R2 R3": 0x5c38020000370204,
        "IMUL.S32.S32 R4 R2 R3": 0x5c38030000370204,
        "IMUL.S32.U32 R4 R2 -1": 0x3938017ffff70204,
        "IMUL.U32.S32 R4 R2 -524288": 0x3938020000070204,
        "IMUL.U32.U32 R4 R2 524287": 0x3838007ffff70204,
        "IMUL.U32.U32 R4 R2 c[0][0]": 0x4c38000000070204,
        "IMUL.S32.S32 R4 R2 c[0][65532]": 0x4c380303fff70204,
        "IMUL.U32.U32 RZ RZ RZ": 0x5c3800000ff7ffff,
    }
    for line, expected in fixed.items():
        actual = encode(line)
        assert actual == expected, f"{line}: {actual:016x} != {expected:016x}"
        assert not actual & ((1 << 39) | (1 << 47)), "HI/CC must remain unset"
    for line in ("IMUL R4 R2 R3", "IMUL.U32.U32.HI R4 R2 R3",
                 "IMUL.U32.U32.CC R4 R2 R3", "IMUL32I R4 R2 3",
                 "IMUL.U32.U32 R4 -R2 R3", "IMUL.U32.U32 R4 R2 524288",
                 "IMUL.U32.U32 R4 R2 -524289", "IMUL.U32.U32 R4 R2 c[1][0]",
                 "IMUL.U32.U32 R4 R2 c[0][2]", "IMUL.U32.U32 R4 R2 c[0][65536]"):
        try:
            encode(line)
        except (ValueError, AssertionError):
            pass
        else:
            raise AssertionError("out-of-scope encoding accepted: " + line)
    print(f"IMUL encoding: {len(fixed)} fixed words and 10 domain rejections passed")


if __name__ == "__main__":
    main()
