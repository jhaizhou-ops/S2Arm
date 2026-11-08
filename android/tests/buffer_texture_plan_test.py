#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Pure copy-plan contract and four compiled functional mutation controls."""
import os
from pathlib import Path
import shlex
import subprocess
import sys
import buffer_texture_baseline
import tempfile

ROOT = Path(__file__).resolve().parents[2]
NATIVE = ROOT / 'android/native'
DIRECT = NATIVE / 'direct'
TEST = Path(__file__).with_suffix('.c')


def main():
    source = (DIRECT / 'buffer_texture_plan.c').read_text()
    mutations = (
        ('ignore-offset', 'p.x = (uint32_t)r->x; p.y = (uint32_t)r->y;', 'p.x = p.y = 0;', 'grid'),
        ('fixed-four-bytes', 'uint64_t bpp = fmt.bytes;', 'uint64_t bpp = 4;', 'formats'),
        ('overwrite-padding', 'out->bytes = p->row_bytes;', 'out->bytes = p->image_stride;', 'grid'),
        ('omit-image-before', 'p.image_before = dependency(in->direction, 0);',
         'p.image_before = dependency(in->direction, 0);\n    memset(&p.image_before, 0, sizeof p.image_before);', 'grid'),
        ('omit-image-after', 'p.image_after = dependency(in->direction, 1);',
         'p.image_after = dependency(in->direction, 1);\n    memset(&p.image_after, 0, sizeof p.image_after);', 'grid'),
    )
    with tempfile.TemporaryDirectory(prefix='s2a-bt-plan-') as temp:
        build = Path(temp)
        includes = (NATIVE, DIRECT, NATIVE / 'nvn', TEST.parent / 'vkhost',
                    ROOT / 'graphics/nvn/gfx/nvn', ROOT / 'graphics/nvn/third_party/vulkan-headers/include')

        def run(name, text, group=None):
            implementation = build / 'buffer_texture_plan.c'
            implementation.write_text(text)
            exe = build / name
            cmd = shlex.split(os.environ.get('CC', 'cc')) + ['-std=c11', '-O1', '-Wall', '-Wextra', '-Werror']
            cmd += shlex.split(os.environ.get('CFLAGS', '')) + ['-I' + str(p) for p in includes]
            subprocess.run(cmd + [str(TEST), str(implementation), str(NATIVE / 'nvn/nvn_vk_format.c'),
                                 '-o', str(exe)], check=True, timeout=60)
            result = subprocess.run([str(exe)] + ([group] if group else []), capture_output=True, text=True, timeout=10)
            print(name + ':\n' + result.stdout + result.stderr, end='', flush=True)
            return result

        result = run('production', source)
        if result.returncode or result.stdout.count('PASS ') != 5:
            raise RuntimeError('production contract failed')
        for name, old, new, group in mutations:
            if source.count(old) != 1:
                raise RuntimeError('mutation anchor changed: ' + name)
            result = run(name, source.replace(old, new), group)
            if result.returncode != 1 or 'FAIL ' + group + ':' not in result.stderr:
                raise RuntimeError(name + ': expected compiled functional assertion failure')
    print('PASS: 5 host groups and 5 compiled functional controls (4 fault classes); record/GPU/device not wired or tested')


if __name__ == '__main__':
    if len(sys.argv) == 2 and sys.argv[1] == "--baseline":
        raise SystemExit(buffer_texture_baseline.main())
    if len(sys.argv) != 1:
        raise SystemExit("usage: buffer_texture_plan_test.py [--baseline]")
    main()
