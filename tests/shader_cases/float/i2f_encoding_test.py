#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Independent fixed envytools machine-word anchors, not translator goldens."""
from pathlib import Path
import sys
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from run import encode


def main():
    fixed = {
        'I2F.F32.S32 R8 R2': 0x5cb8000000272a08,
        'I2F.F32.U32 R8 R2': 0x5cb8000000270a08,
        'I2F.F32.S32 R8 0': 0x38b8000000072a08,
        'I2F.F32.S32 R8 -1': 0x39b8007ffff72a08,
        'I2F.F32.U32 R8 -524288': 0x39b8000000070a08,
        'I2F.F32.U32 R8 524287': 0x38b8007ffff70a08,
    }
    for line, word in fixed.items():
        assert encode(line) == word, (line, hex(encode(line)), hex(word))
    bad = ['I2F R8 R2', 'I2F.F32.S16 R8 R2', 'I2F.F64.S32 R8 R2',
           'I2F.F32.S32.RZ R8 R2', 'I2F.F32.S32.CC R8 R2',
           'I2F.F32.S32 R8 |R2|', 'I2F.F32.U32 R8 c[0][0]',
           'I2F.F32.S32 R8 524288', 'I2F.F32.S32 R8 -524289',
           'I2F.F32.S32 R8 R2 P0']
    for line in bad:
        try: encode(line)
        except (ValueError, AssertionError): pass
        else: raise AssertionError('outside scope accepted: ' + line)
    print(f'I2F encoding: {len(fixed)} fixed words; {len(bad)} rejected forms')


if __name__ == '__main__': main()
