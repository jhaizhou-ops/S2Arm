#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Fixed independent envytools machine words, not production-derived goldens."""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from run import encode


def main():
    # gm107.c f102b823: bases 5cb0/38b0, S32=1200, U32=200, F32=800,
    # trunc=18000000000, PT=70000, R2=200000, +/-1.5 immediate=3fc00/bfc00.
    fixed = {
        'F2I.S32.F32.RN R8 R2': 0x5cb0000000271a08,
        'F2I.U32.F32.RN R8 R2': 0x5cb0000000270a08,
        'F2I.S32.F32.RZ R8 R2': 0x5cb0018000271a08,
        'F2I.U32.F32.RZ R8 R2': 0x5cb0018000270a08,
        'F2I.S32.F32.RN R8 -1.5': 0x39b0003fc0071a08,
        'F2I.U32.F32.RN R8 1.5': 0x38b0003fc0070a08,
        'F2I.S32.F32.RZ R8 -1.5': 0x39b001bfc0071a08,
        'F2I.U32.F32.RZ R8 1.5': 0x38b001bfc0070a08,
        'F2I.S32.F32.RN R8 -0.0': 0x39b0000000071a08,
        'F2I.U32.F32.RZ R8 0': 0x38b0018000070a08,
    }
    for line, word in fixed.items():
        assert encode(line) == word, (line, hex(encode(line)), hex(word))
    bad = ['F2I R8 R2', 'F2I.S16.F32.RN R8 R2', 'F2I.S32.F64.RN R8 R2',
           'F2I.S32.F32.RM R8 R2', 'F2I.S32.F32.RP R8 R2',
           'F2I.S32.F32.RN.CC R8 R2', 'F2I.S32.F32.RN.FTZ R8 R2',
           'F2I.S32.F32.RN R8 |R2|', 'F2I.S32.F32.RN R8 -R2',
           'F2I.U32.F32.RN R8 c[0][0]', 'F2I.S32.F32.RN R8 1.1',
           'F2I.S32.F32.RN R8 1.0000000000000001',
           'F2I.S32.F32.RN R8 0.99999999999999999',
           'F2I.S32.F32.RN R8 1e-100', 'F2I.S32.F32.RN R8 nan',
           'F2I.S32.F32.RN R8 inf', 'F2I.S32.F32.RN R8 R2 P0']
    for line in bad:
        try: encode(line)
        except (ValueError, AssertionError): pass
        else: raise AssertionError('outside scope accepted: ' + line)
    print(f'F2I encoding: {len(fixed)} fixed words; {len(bad)} rejected forms')


if __name__ == '__main__': main()
