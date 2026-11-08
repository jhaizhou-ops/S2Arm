# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""#1100: native cross-process library locking, with original Failure text."""
import ast
import errno
import importlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

JOBS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(JOBS))


class NativeImport(unittest.TestCase):
    def test_core_import_succeeds_without_posix_runtime(self):
        code = "import sys;sys.path.insert(0,sys.argv[1]);import core;print('imported')"
        p = subprocess.run([sys.executable, '-B', '-c', code, str(JOBS)],
                           capture_output=True, text=True, timeout=5)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(p.stdout.strip(), 'imported')


class FileLocks(unittest.TestCase):
    def setUp(self):
        self.module = importlib.import_module('filelock')
        self.tmp = tempfile.TemporaryDirectory(prefix='s2arm lock 中文 ')
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / 'shared lock'
        self.path.touch()

    def holder(self):
        code = ("import sys;sys.path.insert(0,sys.argv[1]);import filelock;"
                "f=open(sys.argv[2],'a');filelock.try_lock(f);print('locked',flush=True);"
                "sys.stdin.readline();filelock.unlock(f);f.close()")
        p = subprocess.Popen([sys.executable, '-B', '-u', '-c', code, str(JOBS), str(self.path)],
                             stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        def stop():
            if p.poll() is None:
                p.kill()
            p.communicate(timeout=5)
        self.addCleanup(stop)
        self.assertEqual(p.stdout.readline().strip(), 'locked')
        return p

    def probe(self):
        code = '''import sys
sys.path.insert(0,sys.argv[1])
import filelock
with open(sys.argv[2],'a') as f:
    try: filelock.try_lock(f)
    except BlockingIOError: print('busy')
    else:
        filelock.unlock(f)
        print('acquired')
'''
        p = subprocess.run([sys.executable, '-B', '-c', code, str(JOBS), str(self.path)],
                           capture_output=True, text=True, timeout=5)
        self.assertEqual(p.returncode, 0, p.stderr)
        return p.stdout.strip()

    def test_other_process_cannot_acquire_held_lock(self):
        with self.path.open('a') as f:
            self.module.try_lock(f)
            try: self.assertEqual(self.probe(), 'busy')
            finally: self.module.unlock(f)

    def test_explicit_unlock_allows_other_process(self):
        with self.path.open('a') as f:
            self.module.try_lock(f)
            self.module.unlock(f)
            self.assertEqual(self.probe(), 'acquired')

    def test_owner_process_exit_releases_lock(self):
        p = self.holder()
        self.assertEqual(self.probe(), 'busy')
        p.kill(); p.wait(timeout=5)
        self.assertEqual(self.probe(), 'acquired')

    def test_context_reports_original_failure_on_busy(self):
        import core
        directory = Path(self.tmp.name)
        self.path = directory / '.catalog.lock'
        self.path.touch()
        p = self.holder()
        context = object.__new__(core.Context)
        context.library = directory
        with patch.object(context, 'check'), patch.object(context, 'require_library'):
            caught = None
            try:
                with context.lock():
                    pass
            except Exception as error:
                caught = error
            self.assertIsInstance(caught, core.Failure)
        self.assertEqual(str(caught), '另一个任务正在使用游戏库，请稍后重试。')
        p.stdin.write('release\n'); p.stdin.flush(); p.wait(timeout=5)
        with patch.object(context, 'check'), patch.object(context, 'require_library'):
            with context.lock(): pass
        self.assertEqual(self.probe(), 'acquired')

    def test_lock_uses_byte_zero_even_when_position_moves(self):
        self.path.write_bytes(b'abcdef')
        with self.path.open('a') as f:
            f.seek(5)
            self.module.try_lock(f)
            try: self.assertEqual(self.probe(), 'busy')
            finally:
                f.seek(4)
                self.module.unlock(f)
            self.assertEqual(self.probe(), 'acquired')
        self.assertEqual(self.path.read_bytes(), b'abcdef')

    def test_empty_file_is_not_modified(self):
        with self.path.open('a') as f:
            self.module.try_lock(f); self.module.unlock(f)
        self.assertEqual(self.path.read_bytes(), b'')

    def test_no_platform_specific_top_level_import(self):
        tree = ast.parse(Path(self.module.__file__).read_text(encoding='utf-8'))
        top = {name.name for node in tree.body if isinstance(node, ast.Import) for name in node.names}
        self.assertFalse(top & {'fcntl', 'msvcrt'})

    @unittest.skipUnless(os.name == 'nt', 'Windows errno adapter only')
    def test_windows_busy_errno_is_normalized(self):
        import msvcrt
        for number in (errno.EACCES, errno.EDEADLK):
            with self.subTest(errno=number), self.path.open('a') as f:
                with patch.object(msvcrt, 'locking', side_effect=OSError(number, 'synthetic busy')):
                    with self.assertRaises(BlockingIOError): self.module.try_lock(f)
        with self.path.open('a') as f:
            with patch.object(msvcrt, 'locking', side_effect=OSError(errno.EBADF, 'synthetic invalid fd')):
                with self.assertRaises(OSError) as caught: self.module.try_lock(f)
                self.assertNotIsInstance(caught.exception, BlockingIOError)


if __name__ == '__main__': unittest.main()
