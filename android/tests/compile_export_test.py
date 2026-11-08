#!/usr/bin/env python3
"""Synthetic host-only checks of the payload gate and atomic request-set writer."""
import os
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
NATIVE = ROOT / 'android/native'
SOURCE = (NATIVE / 'direct/compile_export.c').read_text()
TEST = Path(__file__).with_suffix('.c')


def main():
    anchor = 'if (n > sn && !strcmp(entry->d_name + n - sn, suffix))'
    gate = 'return debug_open != 0 || explicit_export != 0;'
    assert SOURCE.count(anchor) == SOURCE.count(gate) == 1
    variants = {
        'positive': SOURCE,
        'ignore-identity': SOURCE.replace(anchor, 'if (n > sn && !strcmp(entry->d_name + n - sn, suffix) && 0)'),
        'always-open': SOURCE.replace(gate, 'return 1; (void)debug_open; (void)explicit_export;'),
        'release-external': SOURCE.replace('const char *root = debug_open ? debug_dir : state_dir;', 'const char *root = debug_dir; (void)state_dir;'),
        'keep-stale-session': SOURCE.replace('if (unsetenv("S2A_DIRECT_DIAG_DIR")) return -1;', 'if (0) return -1;'),
        'ignore-cohort': SOURCE.replace('export_hash_field(&hash, closure);', 'export_hash_field(&hash, "fixed");').replace('export_hash_field(&hash, profile_hash);', 'export_hash_field(&hash, "fixed");'),
    }
    with tempfile.TemporaryDirectory(prefix='compile-export-') as tmp:
        root = Path(tmp)
        include = root / 'include' / 'sys'
        include.mkdir(parents=True)
        (include / 'system_properties.h').write_text('#pragma once\n#define PROP_VALUE_MAX 92\nint __system_property_get(const char *, char *);\n')
        for debug in (False, True):
            exe = root / ('gate-debug' if debug else 'gate-release')
            cmd = [os.environ.get('CC', 'cc'), '-std=c11', '-Wall', '-Wextra', '-Werror', '-D__ANDROID__',
                   '-I', str(root / 'include'), '-I', str(NATIVE), str(Path(__file__).with_name('compile_export_gate_test.c')),
                   str(NATIVE / 'direct/compile_export.c'), str(NATIVE / 'direct/sha256.c'), '-o', str(exe)]
            if debug:
                cmd.insert(1, '-DS2A_ANDROID_DEBUG_ENV=1')
            subprocess.run(cmd, check=True, timeout=30)
            subprocess.run([str(exe)], check=True, timeout=30)
        anchor_write = 'ssize_t n = write(tempfd, p, left);'
        assert SOURCE.count(anchor_write) == 1
        fault_source = root / 'fault.c'
        fault_source.write_text(SOURCE.replace(anchor_write, '(void)write(tempfd, p, 3); _exit(91); ssize_t n = 0;'))
        fault_exe = root / 'fault'
        fault_cmd = [os.environ.get('CC', 'cc'), '-std=c11', '-Wall', '-Wextra', '-Werror',
                     '-I', str(NATIVE), '-I', str(NATIVE / 'direct'),
                     str(Path(__file__).with_name('compile_export_fault_test.c')),
                     str(fault_source), str(NATIVE / 'direct/sha256.c'), '-o', str(fault_exe)]
        subprocess.run(fault_cmd, check=True, timeout=30)
        fault_dir = root / 'fault-fixture'
        fault_dir.mkdir()
        assert subprocess.run([str(fault_exe), str(fault_dir)], timeout=30).returncode == 91
        sets = list(fault_dir.glob('requests-*'))
        assert len(sets) == 1 and not list(sets[0].glob('*.compile-request.json'))
        clean_exe = root / 'after-fault'
        clean_cmd = fault_cmd[:]
        clean_cmd[clean_cmd.index(str(fault_source))] = str(NATIVE / 'direct/compile_export.c')
        clean_cmd[clean_cmd.index(str(fault_exe))] = str(clean_exe)
        subprocess.run(clean_cmd, check=True, timeout=30)
        subprocess.run([str(clean_exe), str(fault_dir)], check=True, timeout=30)
        assert len(list(sets[0].glob('*.compile-request.json'))) == 1
        print('interrupted partial write: no final file, later retry succeeds')
        for name, old, new in (
            ('write-fail', 'ssize_t n = write(tempfd, p, left);', 'ssize_t n = write(tempfd, p, 0); n = -1; errno = EIO;'),
            ('close-fail', 'if (close(tempfd))', 'if ((close(tempfd), errno = EIO, -1))'),
            ('link-fail', 'if (linkat(dirfd, temp, dirfd, final, 0))', 'if ((errno = EIO, -1))'),
        ):
            assert SOURCE.count(old) == 1
            error_source = root / (name + '.c')
            error_source.write_text(SOURCE.replace(old, new))
            error_exe = root / name
            error_cmd = fault_cmd[:]
            error_cmd[error_cmd.index(str(fault_source))] = str(error_source)
            error_cmd[error_cmd.index(str(fault_exe))] = str(error_exe)
            subprocess.run(error_cmd, check=True, timeout=30)
            error_dir = root / (name + '-fixture')
            error_dir.mkdir()
            assert subprocess.run([str(error_exe), str(error_dir)], timeout=30).returncode == 1
            error_sets = list(error_dir.glob('requests-*'))
            assert len(error_sets) == 1 and not list(error_sets[0].glob('*.compile-request.json'))
            subprocess.run([str(clean_exe), str(error_dir)], check=True, timeout=30)
            assert len(list(error_sets[0].glob('*.compile-request.json'))) == 1
            print(name, 'no partial publication, later retry succeeds')
        for name, source in variants.items():
            source_path = root / (name + '.c')
            source_path.write_text(source)
            exe = root / name
            build = subprocess.run([os.environ.get('CC', 'cc'), '-std=c11', '-Wall', '-Wextra', '-Werror',
                '-I', str(NATIVE), '-I', str(NATIVE / 'direct'), str(TEST), str(source_path),
                str(NATIVE / 'direct/sha256.c'), '-o', str(exe)], capture_output=True, text=True, timeout=30)
            if build.returncode:
                raise RuntimeError(f'{name}: compile failed, not a valid negative control\n{build.stderr}')
            fixture = root / (name + '-fixture')
            fixture.mkdir()
            run = subprocess.run([str(exe), str(fixture)], capture_output=True, text=True, timeout=30)
            if name == 'positive':
                assert run.returncode == 0, run.stderr
            else:
                assert run.returncode != 0 and ('Assertion failed' in run.stderr or 'Assertion' in run.stderr), (name, run.returncode, run.stderr)
            print(name, 'pass' if name == 'positive' else 'expected assertion failure')


if __name__ == '__main__':
    main()
