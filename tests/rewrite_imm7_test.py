#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""P2-20: real C CLI must not round/wrap plain()'s scratch restore address.

Inputs are original synthetic NSOs. AArch64 signed imm7 * 8 is decoded
independently; the saved address must equal SP_delta + restore displacement.
Android's existing indexed spframe route remains allowed where encodable.
"""
import importlib.util
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('imm7_corpus', ROOT / 'tests/rewrite_corpus/run.py')
corpus = importlib.util.module_from_spec(spec)
spec.loader.exec_module(corpus)


def signed(value, bits):
    return value - (1 << bits) if value & (1 << (bits - 1)) else value


def pair_offset(word):
    return signed((word >> 15) & 127, 7) * 8


def source_word(kind, delta):
    # These are ISA encodings, not rewriter helpers: imm7 for 64/32-bit pairs,
    # imm9 for an indexed 64-bit load. x18 is the guest register to rewrite.
    if kind == 'ldr_post':
        assert -256 <= delta <= 255
        return 0xf8400400 | ((delta & 511) << 12) | (31 << 5) | 18
    scale = 4 if kind == 'ldpw_post' else 8
    assert delta % scale == 0 and -64 <= delta // scale <= 63
    op = {'ldp_post': 0xa8c00000, 'stp_pre': 0xa9800000,
          'ldpw_post': 0x28c00000}[kind]
    return op | (((delta // scale) & 127) << 15) | (2 << 10) | (31 << 5) | 18


def check_output(directory, delta, framed):
    data = (directory / 'main.patched.bin').read_bytes()
    word, = struct.unpack_from('<I', data, 0x100)
    assert word >> 26 == 5, 'original instruction was not rewritten to B'
    at = 0x100 + 4 * signed(word & 0x3ffffff, 26)
    words = []
    for offset in range(at, at + 64, 4):
        w, = struct.unpack_from('<I', data, offset)
        words.append(w)
        if w >> 26 == 5:
            break
    # The production trampoline saves/restores two scratch registers through SP.
    stores = [w for w in words if (w & 0xffc003e0) ==
              (0xa98003e0 if framed else 0xa90003e0)]
    loads = [w for w in words if (w & 0xffc003e0) ==
             (0xa8c003e0 if framed else 0xa94003e0)]
    assert len(stores) == len(loads) == 1, 'missing scratch save/restore'
    save, restore = pair_offset(stores[0]), pair_offset(loads[0])
    if framed:
        assert save <= -16 and restore == delta - save, (save, restore, delta)
    else:
        assert save == delta + restore, f'store {save}, restore effective {delta + restore} (d={delta}, encoded={restore})'
    return save, restore


def main():
    rew = Path(os.environ['REW']).resolve()
    cases = [(kind, d) for kind in ('ldp_post', 'stp_pre')
             for d in (-104, -96, -88, -8, 0, 8, 392, 400, 408, 488, 496, 504)]
    cases += [('ldr_post', d) for d in (-95, -9, -1, 1, 4, 7, 9, 15, 127, 255)]
    cases += [('ldpw_post', d) for d in (4, 12, 248, 252)]
    failed = 0
    accepted = rejected = total = 0
    with tempfile.TemporaryDirectory(prefix='rewrite-imm7-') as tmp:
        root = Path(tmp)
        for index, (kind, delta) in enumerate(cases):
            raw = root / 'input.nso'
            corpus.nso([source_word(kind, delta), 0xd65f03c0], {}, 8, str(raw))
            original = raw.read_bytes()
            for compressed in (False, True):
                if compressed:
                    import lz4.block
                    header, payload = bytearray(original[:0x100]), bytearray()
                    struct.pack_into('<I', header, 12, 7)
                    for k in range(3):
                        offset, _, size = struct.unpack_from('<III', original, 0x10 + 16*k)
                        block = lz4.block.compress(original[offset:offset+size], store_size=False)
                        struct.pack_into('<I', header, 0x10 + 16*k, 0x100+len(payload))
                        struct.pack_into('<I', header, 0x60+4*k, len(block))
                        payload += block
                    raw.write_bytes(header + payload)
                else:
                    raw.write_bytes(original)
                for target in ('apple', 'android'):
                    total += 1
                    # 64/32-bit indexed pair spframe can allocate a frame on Android;
                    # pre-index may require a larger frame to cover negative delta.
                    frame = 16
                    if kind == 'stp_pre':
                        while delta < 16 - frame:
                            frame += 16
                    framed = (target == 'android' and kind != 'ldr_post' and
                              (frame + delta) % 8 == 0 and -512 <= frame + delta <= 504)
                    plain_ok = -96 <= delta <= 400 and delta % 8 == 0
                    want_ok = framed or plain_ok
                    directory = root / f'out-{total}'
                    directory.mkdir()
                    env = {k: v for k, v in os.environ.items() if not k.startswith('S2A_')}
                    env.update(S2A_TARGET=target, S2A_REWRITE_SPIN='0')
                    result = subprocess.run([str(rew), str(raw), str(directory), 'main'],
                                            env=env, capture_output=True, text=True, timeout=30)
                    label = f'{target} {kind} d={delta} lz4={int(compressed)}'
                    try:
                        if want_ok:
                            assert result.returncode == 0, result.stdout + result.stderr
                            save, restore = check_output(directory, delta, framed)
                            accepted += 1
                        else:
                            detail = ''
                            if result.returncode == 0:
                                try:
                                    check_output(directory, delta, False)
                                except AssertionError as error:
                                    detail = str(error)
                            assert result.returncode != 0, 'unsafe sequence accepted: ' + detail
                            assert 'PFRW' in result.stdout and ('GAP' in result.stdout or 'fatal=1' in result.stdout), result.stdout + result.stderr
                            rejected += 1
                        print('通 ' + label)
                    except (AssertionError, struct.error) as error:
                        failed += 1
                        print('不通 ' + label + ': ' + str(error).splitlines()[0])
        print(f'rewrite_imm7: {total} combinations, accepted {accepted}, rejected {rejected}, failed {failed}')
    return bool(failed)


if __name__ == '__main__':
    try:
        sys.exit(main())
    finally:
        # run.py created this unique temporary directory during this import.
        shutil.rmtree(corpus.T)
