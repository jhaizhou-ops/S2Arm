#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁覆盖：pack/stage_rewrite.sh
# 整份生产阶段的官方只算键路径；原创合成 NSO / NPDM，无游戏或编译器执行。
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
exec "${S2A_PY:-$HOME/.s2arm/venv/bin/python3}" - "$H" <<'PY'
import hashlib
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(sys.argv[1])


def synthetic_main(path):
    header = bytearray(0x100)
    header[:4] = b'NSO0'
    header[0x40:0x50] = bytes(range(16))
    segments = [bytearray(0x1000) for _ in range(3)]
    struct.pack_into('<I', segments[0], 0, 0xD65F03C0)  # RET, synthetic input only
    for index, segment in enumerate(segments):
        struct.pack_into('<III', header, 0x10 + index * 0x10,
                         0x100 + index * 0x1000, index * 0x1000, len(segment))
        struct.pack_into('<I', header, 0x60 + index * 4, len(segment))
    path.write_bytes(header + b''.join(segments))


class RewriteInputKey(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='rewrite-input-key-')
        self.addCleanup(self.temp.cleanup)
        self.tmp = Path(self.temp.name)
        self.data = self.tmp / 'input root'
        for name in ['exefs', 'romfs/deep', 'romfs/.hidden']:
            (self.data / name).mkdir(parents=True, exist_ok=True)
        synthetic_main(self.data / 'exefs/main')
        npdm = bytearray(0x1000)
        npdm[:4] = b'META'
        struct.pack_into('<I', npdm, 0x70, 0x80)
        npdm[0x80:0x84] = b'ACI0'
        struct.pack_into('<Q', npdm, 0x90, 0x0100AAAA00000000)
        (self.data / 'exefs/main.npdm').write_bytes(npdm)
        (self.data / 'exefs/subsdk0').write_bytes(b'module-A')
        (self.data / 'romfs/deep/plugin.nro').write_bytes(b'nro-bytes-A')
        (self.data / 'romfs/.hidden/UPPER.NRO').write_bytes(b'hidden-NRO-A')
        (self.data / 'romfs/data.pak').write_bytes(b'resource-A')
        self.main_hash = hashlib.sha256((self.data / 'exefs/main').read_bytes()).hexdigest()
        self.command = self.tmp / 'unused-c-rewriter'
        self.command.write_text('#!/bin/sh\necho unexpected-execution >&2\nexit 97\n')
        self.command.chmod(0o755)
        self.env = dict(os.environ, S2A_PY=sys.executable, S2A_PYTHON=sys.executable,
                        S2A_REWRITER='c', S2A_REWRITER_C=str(self.command), S2A_JOBS='1',
                        S2A_ROOTS=str(self.tmp / 'roots'), S2A_ROOTS_SHARED=str(self.tmp / 'shared'),
                        S2A_ROOTS_NO_BOOT='1', S2A_STAGE_KEYS=str(self.tmp / 'keys.tsv'),
                        S2A_WIDEN_AUTO=str(self.tmp / 'no-auto'), S2A_WIDEN_DIR=str(self.tmp / 'no-tables'),
                        S2A_COMMUNITY_DIR=str(self.tmp / 'no-community'),
                        S2A_CPATCH_DIRS=str(self.tmp / 'no-index'), S2A_CPATCH='none',
                        S2A_COMMUNITY_PATCHES='0', S2A_REWRITE_SPIN='1', S2A_TARGET='apple')
        self.env.pop('S2A_COMMUNITY_SELECT', None)
        self.env['PATH'] = str(Path(sys.executable).parent) + os.pathsep + self.env['PATH']

    def key(self, data=None):
        output = Path(self.env['S2A_STAGE_KEYS'])
        output.unlink(missing_ok=True)
        result = subprocess.run(['bash', str(ROOT / 'pack/stage_rewrite.sh'), 'fixture'],
                                env=dict(self.env, S2A_ROOT_CUR=str(data or self.data)),
                                capture_output=True, text=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(output.exists(), 'real root_stage_done did not publish the requested key')
        rows = output.read_text().splitlines()
        self.assertEqual(len(rows), 1)
        stage, value = rows[0].split('\t')
        self.assertEqual(stage, 'rewrite')
        self.assertTrue(value)
        self.assertNotIn('unexpected-execution', result.stdout + result.stderr)
        return value

    def changed(self, operation):
        before = self.key()
        operation()
        self.assertEqual(hashlib.sha256((self.data / 'exefs/main').read_bytes()).hexdigest(),
                         self.main_hash, 'main changed: this does not test the missing member input')
        self.assertNotEqual(before, self.key(), 'input changed but rewrite key was reused')

    def test_identical_input_is_stable(self):
        self.assertEqual(self.key(), self.key())

    def test_same_length_subsdk_content(self):
        self.changed(lambda: (self.data / 'exefs/subsdk0').write_bytes(b'module-B'))

    def test_subsdk_add(self):
        self.changed(lambda: (self.data / 'exefs/subsdk1').write_bytes(b'module-A'))

    def test_subsdk_remove(self):
        self.changed(lambda: (self.data / 'exefs/subsdk0').unlink())

    def test_subsdk_rename(self):
        self.changed(lambda: (self.data / 'exefs/subsdk0').rename(self.data / 'exefs/subsdk9'))

    def test_same_length_nro_content(self):
        self.changed(lambda: (self.data / 'romfs/deep/plugin.nro').write_bytes(b'nro-bytes-B'))

    def test_uppercase_nro_in_hidden_directory(self):
        self.changed(lambda: (self.data / 'romfs/.hidden/UPPER.NRO').write_bytes(b'hidden-NRO-B'))

    def test_nro_add(self):
        self.changed(lambda: (self.data / 'romfs/deep/second.nro').write_bytes(b'nro-bytes-A'))

    def test_nro_remove(self):
        self.changed(lambda: (self.data / 'romfs/deep/plugin.nro').unlink())

    def test_nro_rename(self):
        self.changed(lambda: (self.data / 'romfs/deep/plugin.nro').rename(self.data / 'romfs/deep/renamed.nro'))

    def test_nro_length_change(self):
        self.changed(lambda: (self.data / 'romfs/deep/plugin.nro').write_bytes(b'nro-bytes-AA'))

    def test_nro_middle_change_beyond_first_and_last_megabyte(self):
        path = self.data / 'romfs/deep/plugin.nro'
        path.write_bytes(b'A' * (3 * 1024 * 1024))
        def mutate():
            with path.open('r+b') as handle:
                handle.seek(1536 * 1024)
                handle.write(b'B')
        self.changed(mutate)

    def test_unrelated_romfs_resource_does_not_change_rewrite_key(self):
        before = self.key()
        (self.data / 'romfs/data.pak').write_bytes(b'resource-B')
        self.assertEqual(before, self.key())

    def test_input_root_location_does_not_change_key(self):
        before = self.key()
        relocated = self.tmp / 'different location'
        shutil.copytree(self.data, relocated)
        self.assertEqual(before, self.key(relocated))

    def test_mtime_only_does_not_change_key(self):
        before = self.key()
        for relative in ['exefs/subsdk0', 'romfs/deep/plugin.nro']:
            os.utime(self.data / relative, (1700000000, 1700000000))
        self.assertEqual(before, self.key())


result = unittest.TextTestRunner(verbosity=1).run(unittest.defaultTestLoader.loadTestsFromTestCase(RewriteInputKey))
print(f'rewrite_input_key: {result.testsRun} cases, {len(result.failures)} failed, {len(result.errors)} errors')
raise SystemExit(not result.wasSuccessful())
PY
