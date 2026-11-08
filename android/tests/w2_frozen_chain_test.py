#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Real native request/worker/export chain; registry and managed compiler synthetic.
Draw's source-derived tess is extracted verbatim. No APK/GPU/device claim.
"""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent)); import host_link   # 链接清单按符号闭包推导、弱引用自动放行（见 host_link.py）

from w2_frozen_producer_test import extract

ROOT = Path(__file__).resolve().parents[2]
NATIVE = ROOT / 'android/native'
TEST = Path(__file__).with_suffix('.c')
CASES = ('sync', 'worker', 'sync_stripped', 'worker_stripped', 'sync_stale', 'worker_stale',
         'sync_stop', 'worker_stop', 'sync_wrong', 'worker_wrong', 'sync_tess', 'worker_tess',
         'sync_tess_zero', 'worker_tess_zero', 'sync_tess_bad_source', 'worker_tess_bad_source',
         'sync_tess_bad_offset', 'worker_tess_bad_offset', 'sync_tess_bad_value', 'worker_tess_bad_value',
         'sync_tess_bad_field', 'worker_tess_bad_field', 'sync_tess_bad_control', 'worker_tess_bad_control',
         'sync_existing', 'worker_existing', 'sync_existing_bad', 'worker_existing_bad',
         'sync_existing_bad_source', 'worker_existing_bad_source', 'sync_existing_bad_clear', 'worker_existing_bad_clear')


def main():
    source = (NATIVE / 'nvn/nvn_vk_compile_facts.c').read_text()
    controls = [
        ('wrong-source', 'sync_tess', '!expected_gfx.has_tess_mode && view.control_bytes >= 0x748',
         'i == 1 && !expected_gfx.has_tess_mode && view.control_bytes >= 0x748'),
        ('wrong-offset', 'sync_tess', 'memcpy(&expected_gfx.tess_mode, view.control + 0x744, 4);',
         'memcpy(&expected_gfx.tess_mode, view.control + 0x740, 4);'),
        ('trust-request-value', 'sync_tess_bad_value', 'memcpy(&expected_gfx.tess_mode, view.control + 0x744, 4);',
         'expected_gfx.tess_mode = in->gfx.tess_mode;'),
        ('skip-other-fields', 'sync_tess_bad_field', 'n != expected_n || memcmp(bytes, expected_bytes, n)',
         'n != expected_n'),
    ]
    with tempfile.TemporaryDirectory(prefix='s2a-w2-chain-') as folder:
        build = Path(folder)
        (build / 'whole_chain_adapter.inc').write_text(extract((NATIVE / 'nvn/mtl_vk_adapter.c').read_text(),
            'static int adapter_worker_compile('))
        (build / 'whole_chain_tess.inc').write_text(extract((NATIVE / 'nvn/nvn_vk_draw.c').read_text(),
            'if (!in.gfx.has_tess_mode && v.control_bytes >= 0x748)'))
        includes = (NATIVE, NATIVE / 'direct', NATIVE / 'nvn', TEST.parent / 'vkhost',
                    ROOT / 'graphics/nvn/gfx/nvn', ROOT / 'graphics/nvn/gfx/nvn/include',
                    ROOT / 'graphics/nvn/third_party/vulkan-headers/include', build)
        # nvn_vk_compile_facts.c → nvn_vk_bcrt_view_format（强符号，nvn_vk_mrt.c）：必须补链。
        sources = [NATIVE / 'nvn/nvn_vk_format.c', NATIVE / 'nvn/nvn_vk_mrt.c'] + [NATIVE / ('direct/' + name + '.c') for name in
            ('source_store', 'sha256', 'input_identity', 'texture_facts', 'compile_request', 'compile_worker',
             'compiler_bind', 'json', 'compile_export', 'compile_export_w2', 'w2_single_query')]

        def run(label, text, cases, negative=False):
            implementation = build / 'nvn_vk_compile_facts.c'
            implementation.write_text(text)
            exe = build / label
            cmd = shlex.split(os.environ.get('CC', 'cc')) + ['-std=c11', '-Wall', '-Wextra', '-Werror',
                '-Wno-missing-field-initializers', '-pthread', '-DS2A_COMPILE_EXPORT_HOST_TEST']
            cmd += shlex.split(os.environ.get('CFLAGS', '')) + ['-I' + str(path) for path in includes]
            host_link.run(cmd + [str(TEST), str(implementation), *map(str, sources)] + ['-o', str(exe)], check=True, timeout=60)
            for case in cases:
                result = subprocess.run([str(exe), case], capture_output=True, text=True, timeout=10)
                if negative:
                    if result.returncode != 1 or 'ASSERT whole-chain:' not in result.stderr:
                        raise RuntimeError(label + ': expected functional failure\n' + result.stdout + result.stderr)
                elif result.returncode:
                    raise RuntimeError(case + ': ' + result.stdout + result.stderr)
                print(label + ' ' + case + ': ' + ('functional red' if negative else 'PASS'), flush=True)

        run('production', source, CASES)
        for label, case, old, new in controls:
            if source.count(old) != 1:
                raise RuntimeError('mutation anchor changed: ' + label)
            run(label, source.replace(old, new), (case,), True)
    print('whole-chain: 32 cases and 4 compiled functional mutation controls passed')


if __name__ == '__main__':
    main()
