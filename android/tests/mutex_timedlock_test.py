#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""mutex_timedlock.h：macOS 可移植实现（Linux 用 -DS2A_PORTABLE_TIMEDLOCK 编同一实现）与 Linux 原生分支都跑同一组用例。"""
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent


class MutexTimedlockTest(unittest.TestCase):
    def test_timeout_and_acquire(self):
        cc = shutil.which(os.environ.get('CC', 'cc'))
        self.assertIsNotNone(cc, 'C compiler required')
        modes = [['-DS2A_PORTABLE_TIMEDLOCK']] if sys.platform == 'darwin' else [[], ['-DS2A_PORTABLE_TIMEDLOCK']]
        with tempfile.TemporaryDirectory(prefix='timedlock-') as td:
            for extra in modes:
                with self.subTest(portable=bool(extra)):
                    exe = Path(td) / ('t' + ('-portable' if extra else '-native'))
                    subprocess.run([cc, '-std=gnu11', '-Wall', '-Wextra', '-Werror', '-pthread', *extra,
                                    '-I' + str(HERE.parent / 'native/nvn'), str(HERE / 'mutex_timedlock_test.c'),
                                    '-o', str(exe)], check=True)
                    r = subprocess.run([str(exe)], capture_output=True, text=True, timeout=30)
                    print(('portable' if extra else 'native') + '\n' + r.stdout + r.stderr)
                    self.assertEqual(r.returncode, 0, r.stdout + r.stderr)


if __name__ == '__main__':
    unittest.main()
