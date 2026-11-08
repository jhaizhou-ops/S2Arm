#!/usr/bin/env python3
"""W2 mount: explicit gate, unavailable producer, and delegation; host fixture only."""
import os
from pathlib import Path
import subprocess
import tempfile
ROOT = Path(__file__).resolve().parents[2]
NATIVE = ROOT / 'android/native'
SRC = (NATIVE / 'direct/compile_export_w2.c').read_text()

def main():
    gate = 'if (!s2a_compile_export_open()) return S2A_W2_QUERY_DISABLED;'
    missing = 'if (!registered_provider) result = S2A_COMPILE_EXPORT_W2_UNWIRED;'
    assert SRC.count(gate) == SRC.count(missing) == 1
    variants = {'positive': SRC, 'ungated': SRC.replace(gate, ''),
                'unwired-success': SRC.replace(missing, 'if (!registered_provider) result = S2A_W2_QUERY_OBSERVED;'),
                'skip-provider': SRC.replace('registered_provider(registered_context, key, &input, &resolver, &snapshot)', '1'),
                'ignore-identity': SRC.replace('memcmp(digest, key->input_sha, sizeof digest)', '0')}
    with tempfile.TemporaryDirectory(prefix='export-w2-') as tmp:
        td = Path(tmp)
        for name, text in variants.items():
            src = td / (name + '.c'); src.write_text(text); exe = td / name
            build = subprocess.run([os.environ.get('CC', 'cc'), '-std=c11', '-Wall', '-Wextra', '-Werror', '-pthread',
                '-I', str(NATIVE), '-I', str(NATIVE / 'direct'), str(Path(__file__).with_suffix('.c')),
                str(src), str(NATIVE / 'direct/sha256.c'), '-o', str(exe)], capture_output=True, text=True, timeout=30)
            assert build.returncode == 0, (name, 'compile failure is not a valid control', build.stderr)
            result = subprocess.run([str(exe)], capture_output=True, text=True, timeout=30)
            if name == 'positive': assert result.returncode == 0, result.stderr
            else: assert result.returncode != 0 and 'Assertion' in result.stderr, (name, result.returncode, result.stderr)
            print(name, 'pass' if name == 'positive' else 'expected assertion failure')
        binary = td / 'integration'
        direct = NATIVE / 'direct'
        subprocess.run([os.environ.get('CC', 'cc'), '-std=c11', '-Wall', '-Wextra', '-Werror', '-pthread',
            '-I', str(NATIVE), '-I', str(direct), '-I', str(ROOT / 'graphics/nvn/gfx/nvn/include'),
            str(Path(__file__).with_name('compile_export_w2_integration_test.c')),
            *[str(direct / (name + '.c')) for name in ('compile_export_w2', 'w2_single_query', 'input_identity', 'texture_facts', 'sha256')],
            '-o', str(binary)], check=True, timeout=30)
        subprocess.run([str(binary)], check=True, timeout=30)
if __name__ == '__main__': main()
