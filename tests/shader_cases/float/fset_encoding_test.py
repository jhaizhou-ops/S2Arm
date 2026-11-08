#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Separate encoding assertions from the rational oracle (fixed envytools table)."""
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from run import encode


def main():
    # gm107.c pinned in README: R=0x58, I=0x30, comparison=48..51,
    # PT=39..41, negA=43, absB=44, BF=52, negB=53, absA=54.
    fixed = {
        'FSET.LT R4 R2 R3': 0x5801038000370204,
        'FSET.GE.BF R4 -|R2| -|R3|': 0x58761b8000370204,
        'FSET.EQ R4 R2 -1.5': 0x310203bfc0070204,
        'FSET.NE.BF R4 |R2| -|-1.5|': 0x317513bfc0070204,
        'FSET.LE R4 R2 0.0': 0x3003038000070204,
        'FSET.GT R4 R2 -0.0': 0x3104038000070204,
    }
    for line, expected in fixed.items():
        assert encode(line) == expected, line
        assert encode(line) & ((3 << 45) | (1 << 42) | (1 << 47) | (1 << 55)) == 0
    bad = [
        'FSET R4 R2 R3', 'FSET.LTU R4 R2 R3', 'FSETP.LT R4 R2 R3',
        'FSET.LT.FTZ R4 R2 R3', 'FSET.LT.CC R4 R2 R3', 'FSET.LT.OR R4 R2 R3',
        'FSET.LT.BF.BF R4 R2 R3', 'FSET.LT R4 R2 c[0][0]',
        'FSET.LT R4 R2 1.00000011920928955078125', 'FSET.LT R4 R2 R3 P0',
    ]
    for line in bad:
        try: encode(line)
        except (ValueError, AssertionError): pass
        else: raise AssertionError('out-of-scope encoding accepted: ' + line)
    print(f'FSET encoding: {len(fixed)} fixed words and {len(bad)} unsupported forms rejected')


if __name__ == '__main__':
    main()
