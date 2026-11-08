# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁覆盖：pack/orch/roots.py
# 门禁手动：W1限定七新增文件且不改列车入口；Windows与Mac显式原生运行本测试，命令与分母随PR交付
"""Original files only: transaction/CAS, independent bytes and outside sentinels."""
import contextlib
import errno
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from pack.orch import roots


class RootsTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='s2a-orch-')
        self.home = Path(self.temp.name)
        self.store = roots.Roots(self.home / 'roots', shared=False)

    def tearDown(self):
        roots.remove_owned(self.home)
        self.temp.cleanup()

    def seed(self):
        tx = self.store.begin('原创', 'seed')
        (tx.path / 'exefs').mkdir()
        (tx.path / 'exefs/main').write_bytes(b'original main\x00')
        (tx.path / 'romfs').mkdir()
        (tx.path / 'romfs/data').write_bytes(b'original resource\x00')
        (tx.path / '.stage_rewrite').write_bytes(b'rw0\n')
        return tx.commit()

    def test_seed_twice_same_roots(self):   # 11-06 天眼死机后原样重起：同一工作目录二次播种，icon.jpg / ctl/control.nacp 已在现行版本里，原先 copy_file 撞「目标已在」整单红
        from pack.orch import refresh
        src = self.home / 'ex'; (src / 'exefs').mkdir(parents=True); (src / 'exefs/main').write_bytes(b'm')
        (src / 'romfs').mkdir(); (src / 'romfs/a').write_bytes(b'r'); (src / 'ctl').mkdir(); (src / 'ctl/control.nacp').write_bytes(b'n1')
        (src / 'icon.jpg').write_bytes(b'i1'); (src / 'unpack.tsv').write_text('title_id\t0100aaaa00000000\n')
        with patch.dict(os.environ, {'S2A_DUAL': '0'}):
            refresh.seed(self.store, '原创', src)
            (src / 'icon.jpg').write_bytes(b'i2'); (src / 'ctl/control.nacp').write_bytes(b'n2')
            cur = refresh.seed(self.store, '原创', src)
        self.assertEqual(((cur / 'icon.jpg').read_bytes(), (cur / 'ctl/control.nacp').read_bytes()), (b'i2', b'n2'))

    def test_commit_abort_keeps_previous_and_reuses_store(self):
        first = self.seed()
        resource = (first / 'romfs').resolve()
        tx = self.store.begin('原创', 'abort')
        (tx.path / 'exefs/main').write_bytes(b'not published')
        tx.abort()
        self.assertEqual(self.store.cur('原创'), first)
        self.assertEqual((first / 'exefs/main').read_bytes(), b'original main\x00')
        tx = self.store.begin('原创', 'next')
        (tx.path / 'exefs/main').write_bytes(b'new main')
        second = tx.commit()
        self.assertEqual((second / 'romfs').resolve(), resource)
        self.assertEqual((second / 'romfs/data').read_bytes(), b'original resource\x00')
        self.assertEqual((first / 'exefs/main').read_bytes(), b'original main\x00')
        self.assertEqual(self.store.cur('原创'), second)

    def test_failed_activation_leaves_current(self):
        first = self.seed()
        tx = self.store.begin('原创', 'fail')
        with patch.object(roots, 'replace_link', side_effect=OSError('activation denied')):
            with self.assertRaises(OSError):
                tx.commit()
        self.assertEqual(self.store.cur('原创'), first)
        self.assertEqual((first / 'exefs/main').read_bytes(), b'original main\x00')

    def test_concurrent_unclaimed_write_is_rejected(self):
        self.seed()
        a = self.store.begin('原创', 'a')
        b = self.store.begin('原创', 'b')
        (a.path / 'a').write_bytes(b'A')
        (b.path / 'b').write_bytes(b'B')
        current = a.commit()
        with self.assertRaises(roots.Conflict):
            b.commit()
        self.assertEqual(self.store.cur('原创'), current)
        self.assertFalse((current / 'b').exists())
        self.assertFalse(b.path.exists())

    def test_replay_preserves_other_stage_and_deletions(self):
        self.seed()
        a = self.store.begin('原创', 'a')
        b = self.store.begin('原创', 'b')
        (a.path / 'a').write_bytes(b'A')
        (b.path / 'b').write_bytes(b'B')
        (b.path / 'exefs/main').unlink()
        a.commit()
        current = b.commit(replay=('b', 'exefs/main'))
        self.assertEqual((current / 'a').read_bytes(), b'A')
        self.assertEqual((current / 'b').read_bytes(), b'B')
        self.assertFalse((current / 'exefs/main').exists())

    def test_external_link_rejected_and_original_untouched(self):
        first = self.seed()
        outside = self.home / 'outside'
        outside.mkdir()
        (outside / 'sentinel').write_bytes(b'KEEP')
        roots.directory_link(outside, first / 'evil')
        with self.assertRaises(roots.UnsafeRoot):
            self.store.begin('原创', 'bad')
        self.assertEqual((outside / 'sentinel').read_bytes(), b'KEEP')
        self.assertEqual(self.store.cur('原创'), first)

    def test_wrong_game_store_link_is_rejected(self):
        first = self.seed()
        roots.remove_owned(first / 'romfs')
        outside = self.store.path / '.romfs_store/别款/id'
        outside.mkdir(parents=True)
        roots.directory_link(outside, first / 'romfs')
        with self.assertRaises(roots.UnsafeRoot):
            self.store.begin('原创', 'bad')

    def test_store_parent_link_rejected_before_creating_external_directory(self):
        outside = self.home / 'outside-store'
        outside.mkdir()
        roots.directory_link(outside, self.store.path / '.romfs_store')
        tx = self.store.begin('原创', 'bad-store')
        (tx.path / 'romfs').mkdir()
        (tx.path / 'romfs/data').write_bytes(b'original')
        with self.assertRaises(roots.UnsafeRoot):
            tx.commit()
        self.assertEqual(list(outside.iterdir()), [])
        self.assertIsNone(self.store.cur('原创'))

    def test_romfs_is_physically_readonly(self):
        first = self.seed()
        probe = 'from pathlib import Path; import sys; Path(sys.argv[1]).write_bytes(b"BAD")'
        result = subprocess.run([sys.executable, '-c', probe, str(first / 'romfs/data')], capture_output=True)
        if os.name != 'nt' and hasattr(os, 'geteuid') and os.geteuid() == 0:
            self.skipTest('root bypasses POSIX permission bits; normal-user check required')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual((first / 'romfs/data').read_bytes(), b'original resource\x00')

    def test_realcopy_warns_and_bytes_match(self):
        src = self.home / 'source'
        dst = self.home / 'dest'
        src.write_bytes(bytes(range(256)) * 33)
        err = io.StringIO()
        with contextlib.ExitStack() as stack:
            stack.enter_context(patch.object(roots, 'refs_same_volume', return_value=False))
            if sys.platform == 'darwin':
                # Same-volume clonefile can succeed on APFS. Exercise the
                # real-copy fallback deliberately, not by assuming the host.
                libc = type('LibC', (), {'clonefile': Mock(return_value=-1)})()
                stack.enter_context(patch.object(roots.C, 'CDLL', return_value=libc))
                stack.enter_context(patch.object(roots.C, 'get_errno', return_value=errno.EXDEV))
            elif sys.platform.startswith('linux'):
                import fcntl
                stack.enter_context(patch.object(fcntl, 'ioctl', side_effect=OSError(errno.EXDEV, 'original fallback')))
            stack.enter_context(contextlib.redirect_stderr(err))
            roots.copy_file(src, dst)
        self.assertEqual(src.read_bytes(), dst.read_bytes())
        self.assertIn('实拷', err.getvalue())

    @unittest.skipUnless(os.name == 'nt', 'native Windows junction fallback')
    def test_junction_fallback_and_atomic_switch(self):
        a, b = self.home / 'a', self.home / 'b'
        a.mkdir(); b.mkdir()
        (a / 'file').write_bytes(b'A')
        (b / 'file').write_bytes(b'B')
        with patch.object(roots.os, 'symlink', side_effect=OSError(1314, 'no privilege')):
            roots.directory_link(a, self.home / 'current')
            roots.directory_link(b, self.home / 'next')
        self.assertTrue((self.home / 'current').is_junction())
        roots.replace_link(self.home / 'next', self.home / 'current')
        self.assertEqual((self.home / 'current/file').read_bytes(), b'B')
        self.assertEqual((a / 'file').read_bytes(), b'A')

    def test_prune_keeps_current_previous(self):
        self.seed()
        for tag in ('v2', 'v3', 'v4'):
            self.store.begin('原创', tag).commit()
        names = sorted(p.name for p in self.store.path.glob('原创@*') if not roots.is_link(p))
        self.assertEqual(names, ['原创@v3', '原创@v4'])

    def test_replay_exclusion_preserves_new_nested_data(self):
        self.seed()
        a = self.store.begin('原创', 'a')
        b = self.store.begin('原创', 'b')
        (a.path / 'shaders/direct').mkdir(parents=True)
        (a.path / 'shaders/direct/key').write_bytes(b'new-direct')
        (b.path / 'shaders').mkdir()
        (b.path / 'shaders/other').write_bytes(b'new-other')
        a.commit()
        current = b.commit(replay=('shaders', '!shaders/direct'))
        self.assertEqual((current / 'shaders/direct/key').read_bytes(), b'new-direct')
        self.assertEqual((current / 'shaders/other').read_bytes(), b'new-other')

    def test_kernel_lock_excludes_another_process(self):
        script = ('from pathlib import Path; from pack.orch.roots import Roots; '
                  'import sys; r=Roots(sys.argv[1],shared=False); '
                  'exec("try:\\n with r.locked(\'原创\',timeout=.2): pass\\nexcept TimeoutError:\\n sys.exit(7)")')
        with self.store.locked('原创'):
            p = subprocess.run([sys.executable, '-X', 'utf8', '-c', script, str(self.store.path)],
                               cwd=roots.REPO, capture_output=True)
        self.assertEqual(p.returncode, 7, p.stderr.decode('utf-8'))
        with self.store.locked('原创', timeout=.2):
            pass

    def test_live_reader_pin_prevents_prune(self):
        first = self.seed()
        script = ('from pack.orch.roots import Roots; import sys,time; '
                  'r=Roots(sys.argv[1],shared=False); r.cur("原创"); '
                  'print("pinned",flush=True); time.sleep(30)')
        p = subprocess.Popen([sys.executable, '-X', 'utf8', '-c', script, str(self.store.path)],
                             cwd=roots.REPO, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            self.assertEqual(p.stdout.readline().strip(), b'pinned')
            for tag in ('v2', 'v3'):
                self.store.begin('原创', tag).commit()
            self.assertTrue(first.is_dir())
        finally:
            p.terminate(); p.communicate(timeout=10)
        self.store.prune('原创')
        self.assertFalse(first.exists())

    def test_shared_newer_same_stage_cannot_be_replayed_back(self):
        repo = self.home / 'git'
        repo.mkdir()
        def git(*args):
            return subprocess.run(['git', '-C', str(repo), *args], check=True,
                                  capture_output=True).stdout.decode().strip()
        git('init', '-q')
        git('config', 'user.name', 'Original fixture')
        git('config', 'user.email', 'fixture@example.invalid')
        (repo / 'version').write_bytes(b'old')
        git('add', 'version'); git('commit', '-qm', 'original old')
        old = git('rev-parse', 'HEAD')
        (repo / 'version').write_bytes(b'new')
        git('commit', '-qam', 'original new')
        newer = git('rev-parse', 'HEAD')
        git('update-ref', 'refs/remotes/origin/main', newer)
        git('checkout', '--detach', '-q', old)
        store = roots.Roots(self.home / 'shared', shared=True, repo=repo)
        initial = store.begin('原创', 'initial')
        (initial.path / '.stage_rewrite').write_bytes(b'old\n')
        initial.commit()
        slow = store.begin('原创', 'slow')
        (slow.path / '.stage_rewrite').write_bytes(b'old-rebuilt\n')
        git('checkout', '--detach', '-q', newer)
        fast = store.begin('原创', 'fast')
        (fast.path / '.stage_rewrite').write_bytes(b'new\n')
        current = fast.commit()
        with self.assertRaises(roots.Conflict):
            slow.commit(replay=('.stage_rewrite',))
        self.assertEqual(store.cur('原创'), current)
        self.assertEqual((current / '.stage_rewrite').read_bytes(), b'new\n')
        git('checkout', '--detach', '-q', old)
        with self.assertRaises(roots.Conflict):
            store.begin('原创', 'backward')

    @unittest.skipUnless(os.name == 'nt', 'Windows exited process object lifetime')
    def test_exited_process_object_is_not_a_live_reader(self):
        from pack.jobs import winproc
        p = subprocess.Popen([sys.executable, '-c', 'import time;time.sleep(30)'])
        try:
            with winproc._process(p.pid) as held:
                stamp = winproc._creation_time(held)
                self.assertEqual(roots.process_start(p.pid), stamp)
                p.terminate(); p.communicate(timeout=10)
                # Deliberately retain a query handle: a creation timestamp
                # remains obtainable even though this original child exited.
                self.assertEqual(winproc._creation_time(held), stamp)
                self.assertEqual(roots.process_start(p.pid), '')
        finally:
            if p.poll() is None:
                p.terminate(); p.communicate(timeout=10)


if __name__ == '__main__':
    unittest.main()
