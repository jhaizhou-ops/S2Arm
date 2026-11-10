#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Execute original and rewritten synthetic AArch64 leaves on Apple silicon."""

import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import tempfile

from rewrite_corpus import run as corpus

CASES = (
    ('register-only-overlap', -16, 'mov x18, x2'),
    ('no-writeback-overlap', -16, 'add x18, sp, #0'),
    ('no-writeback-control', -64, 'add x18, sp, #0'),
    ('post-index-overlap', -112, 'ldr x18, [sp], #16\nsub sp, sp, #16'),
    ('post-index-control', -64, 'ldr x18, [sp], #16\nsub sp, sp, #16'),
    ('pre-index-overlap', -112, 'ldr x18, [sp, #-96]!\nadd sp, sp, #96'),
    # Exercise an instruction that reads the original SP-relative data itself.
    ('pair-load-overlap', -8, 'ldp x18, x3, [sp, #-16]'),
)


def main():
    rewriter = Path(os.environ['REW']).resolve()
    env = {name: value for name, value in os.environ.items() if not name.startswith('S2A_')}
    env.update(S2A_TARGET='apple', S2A_REWRITE_SPIN='0')
    failures = 0
    with tempfile.TemporaryDirectory(prefix='rewrite-redzone-') as tmp:
        root = Path(tmp)
        runner = root / 'run-leaf'
        runner_source = Path(__file__).with_name('rewrite_redzone_exec.c')
        subprocess.run(['xcrun', 'clang', '-arch', 'arm64', '-O2', runner_source, '-o', runner], check=True)

        for label, offset, instruction in CASES:
            work = root / label
            work.mkdir()
            readback = 'mov x0, x3' if label == 'pair-load-overlap' else f'ldur x0, [sp, #{offset}]'
            source = f'mov x2, #0xbeef\nstur x2, [sp, #{offset}]\n{instruction}\n{readback}\nret\n'
            words = corpus.assemble(label, source)
            original = work / 'original.bin'
            original.write_bytes(struct.pack(f'<{len(words)}I', *words))
            raw = work / 'input.nso'
            corpus.nso(words, {}, len(words) * 4, raw, tsz=0x4000)
            log = subprocess.check_output([rewriter, raw, work, 'main'], env=env, text=True, timeout=30)
            assert "'plain': 1" in log, log
            fixups = (work / 'main.fixups.tsv').read_text()
            assert '# LOAD_BIAS' not in fixups, fixups
            key = re.search(r'^# KEY_PAGE_OFF\s+(0x[0-9a-f]+)', fixups, re.M)[1]
            before = subprocess.check_output([runner, original, '0', '0'], text=True, timeout=10).strip()
            after = subprocess.check_output(
                [runner, work / 'main.patched.bin', '0x100', key], text=True, timeout=10,
            ).strip()
            passed = before == after == '0xbeef'
            failures += not passed
            print(f'{label}: {before} -> {after} (expected 0xbeef) {"OK" if passed else "FAIL"}')
    print(f'rewrite_redzone: {len(CASES) - failures}/{len(CASES)} passed')
    return bool(failures)


if __name__ == '__main__':
    try:
        sys.exit(main())
    finally:
        shutil.rmtree(corpus.T)
