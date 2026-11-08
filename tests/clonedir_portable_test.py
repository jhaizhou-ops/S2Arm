#!/usr/bin/env python3
"""Exercise directory snapshots on real hosts, including links and permissions."""
import os
from pathlib import Path
import resource
import signal
import shutil
import stat
import subprocess
import textwrap
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'tools' / 'clonedir.py'

class CloneDirContract(unittest.TestCase):
    @unittest.skipUnless(sys.platform.startswith('linux'), 'Linux Android refresh route')
    def test_android_refresh_does_not_require_xcode_on_linux(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            env = {'HOME': str(base), 'PATH': os.environ['PATH'], 'S2A_PACK_PLAT': 'android',
                   'S2A_RUN_ROOT': str(base / 'run'), 'S2A_ROOTS': str(base / 'roots'),
                   'S2A_MACHINE_NO_LOCAL': '1'}
            result = subprocess.run(['/bin/bash', str(SCRIPT.parents[1] / 'pack' / 'refresh.sh'), 'missing'],
                                    env=env, capture_output=True, text=True, timeout=30)
            output = result.stdout + result.stderr
            self.assertNotEqual(result.returncode, 0)
            self.assertNotIn('打 iPhone 包的 Xcode 不能用', output)
            self.assertIn('没有现行产物根', output)

    def test_android_oneclick_rejects_missing_xxd_before_work(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp); commands = base / 'bin'; commands.mkdir()
            for command in ('dirname', 'date'):
                os.symlink(shutil.which(command), commands / command)
            script = SCRIPT.parents[1] / 'pack' / 'oneclick' / 'oneclick.sh'
            env = {'PATH': str(commands), 'HOME': str(base)}
            result = subprocess.run(['/bin/bash', str(script), str(base), '--target', 'android'],
                                    env=env, capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('xxd', result.stdout + result.stderr)
            self.assertFalse((base / 'extract').exists())

    def test_root_copy_and_link_fail_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp); target = base / 'directory'; target.mkdir()
            (target / 'sentinel').write_text('safe')
            link = base / 'new-link'; os.symlink('source', link)
            roots = SCRIPT.parents[1] / 'pack' / 'roots.sh'
            copy = subprocess.run(['bash', '-c', 'source "$1"; _root_cp "$2" "$3"',
                                   '_', str(roots), str(base / 'missing'), str(target)], capture_output=True)
            self.assertNotEqual(copy.returncode, 0)
            move = subprocess.run(['bash', '-c', 'source "$1"; _root_mv_link "$2" "$3"',
                                   '_', str(roots), str(link), str(target)], capture_output=True)
            self.assertNotEqual(move.returncode, 0)
            self.assertTrue(link.is_symlink())
            self.assertEqual((target / 'sentinel').read_text(), 'safe')
            self.assertEqual(sorted(p.name for p in target.iterdir()), ['sentinel'])

    def test_snapshot_preserves_source_and_link_contract(self):
        with tempfile.TemporaryDirectory() as temp:
            base = Path(temp)
            source, dest = base / 'source', base / 'dest'
            source.mkdir()
            (source / 'file').write_bytes(b'payload')
            (source / 'skip').write_bytes(b'ignore')
            (source / 'folder').mkdir()
            (source / 'folder' / 'nested').write_bytes(b'nested')
            os.symlink('nested', source / 'folder' / 'link')
            os.symlink('folder', source / 'toplink')
            os.chmod(source / 'folder', 0o500)
            run = subprocess.run([sys.executable, str(SCRIPT), str(source), str(dest), 'skip'], capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertEqual((dest / 'file').read_bytes(), b'payload')
            self.assertFalse((dest / 'skip').exists())
            self.assertFalse((dest / 'toplink').is_symlink())
            self.assertEqual((dest / 'toplink' / 'nested').read_bytes(), b'nested')
            self.assertTrue((dest / 'folder' / 'link').is_symlink())
            self.assertEqual(os.readlink(dest / 'folder' / 'link'), 'nested')
            self.assertTrue((dest / 'folder').stat().st_mode & stat.S_IWUSR)
            self.assertFalse((source / 'folder').stat().st_mode & stat.S_IWUSR)
            duplicate = subprocess.run([sys.executable, str(SCRIPT), str(source), str(dest), 'skip'], capture_output=True, text=True)
            self.assertNotEqual(duplicate.returncode, 0, 'existing destination entries must not be silently overwritten')
            self.assertEqual((dest / 'file').read_bytes(), b'payload')

    def test_existing_destination_is_not_mutated(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp); src = base / 'src'; dst = base / 'dst'
            src.mkdir(); dst.mkdir(); (src / 'same').mkdir(); (dst / 'same').mkdir()
            (src / 'same' / 'x').write_text('new'); (dst / 'same' / 'x').write_text('old')
            os.chmod(dst / 'same', 0o500)
            result = subprocess.run([sys.executable, str(SCRIPT), str(src), str(dst)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual((dst / 'same' / 'x').read_text(), 'old')
            self.assertEqual(stat.S_IMODE((dst / 'same').stat().st_mode), 0o500)
            os.chmod(dst / 'same', 0o700)

    def test_overlapping_roots_are_rejected_without_changes(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp); src = base / 'src'; src.mkdir(); (src / 'file').write_text('safe')
            for destination in (src, src / 'inside', base):
                result = subprocess.run([sys.executable, str(SCRIPT), str(src), str(destination)], capture_output=True, text=True)
                self.assertNotEqual(result.returncode, 0, str(destination))
                self.assertEqual((src / 'file').read_text(), 'safe')
                self.assertFalse((src / 'inside').exists())

    @unittest.skipUnless(sys.platform.startswith('linux'), 'Linux copy-path contract')
    def test_destination_symlink_race_cannot_overwrite_victim(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp); src = base / 'src'; dst = base / 'dst'; src.mkdir()
            (src / 'item').write_text('new'); victim = base / 'victim'; victim.write_text('safe')
            code = textwrap.dedent("""
                import os, runpy, shutil, sys
                script, src, dst, victim = sys.argv[1:]
                original_open, original_copy = os.open, shutil.copy2
                fired = [False]
                def inject(path, flags, *args, **kwargs):
                    if not fired[0] and path == 'item' and flags & os.O_EXCL:
                        os.symlink(victim, path, dir_fd=kwargs.get('dir_fd')); fired[0] = True
                    return original_open(path, flags, *args, **kwargs)
                def old_copy(srcpath, dstpath, *args, **kwargs):
                    if not fired[0] and os.path.basename(dstpath) == 'item':
                        os.symlink(victim, dstpath); fired[0] = True
                    return original_copy(srcpath, dstpath, *args, **kwargs)
                os.open, shutil.copy2 = inject, old_copy
                sys.argv = [script, src, dst]
                runpy.run_path(script, run_name='__main__')
            """)
            result = subprocess.run([sys.executable, '-c', code, str(SCRIPT), str(src), str(dst), str(victim)], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0, result.stderr)
            self.assertEqual(victim.read_text(), 'safe')
            self.assertFalse(dst.exists())

    @unittest.skipUnless(sys.platform.startswith('linux'), 'Linux copy-path contract')
    def test_directory_symlink_race_cannot_modify_victim(self):
        with tempfile.TemporaryDirectory() as tmp:
            base=Path(tmp); src=base/'src'; dst=base/'dst'; victim=base/'victim'
            src.mkdir(); victim.mkdir(); (src/'item').mkdir()
            (src/'item'/'file').write_text('new'); (victim/'file').write_text('safe')
            code=textwrap.dedent("""
                import os,runpy,sys
                script,src,dst,victim=sys.argv[1:]; original=os.mkdir; fired=[False]
                def inject(path, mode=0o777, *, dir_fd=None):
                    if not fired[0] and path=='item' and dir_fd is not None:
                        os.symlink(victim,path,dir_fd=dir_fd); fired[0]=True
                    return original(path,mode,dir_fd=dir_fd)
                os.mkdir=inject;sys.argv=[script,src,dst]
                runpy.run_path(script,run_name='__main__')
            """)
            result=subprocess.run([sys.executable,'-c',code,str(SCRIPT),str(src),str(dst),str(victim)],capture_output=True,text=True)
            self.assertNotEqual(result.returncode,0,result.stderr)
            self.assertEqual((victim/'file').read_text(),'safe')
            self.assertFalse(dst.exists())

    @unittest.skipUnless(sys.platform.startswith('linux'), 'Linux copy-path contract')
    def test_failed_tree_removes_only_new_entries(self):
        with tempfile.TemporaryDirectory() as tmp:
            base=Path(tmp); src=base/'src';dst=base/'dst';src.mkdir()
            (src/'dir').mkdir();(src/'dir'/'a').write_text('new');os.mkfifo(src/'dir'/'z-fifo')
            (base/'existing').write_text('safe')
            result=subprocess.run([sys.executable,str(SCRIPT),str(src),str(dst)],capture_output=True,text=True,timeout=5)
            self.assertNotEqual(result.returncode,0)
            self.assertFalse((dst/'dir').exists())
            self.assertEqual((base/'existing').read_text(),'safe')
            self.assertFalse(dst.exists())
            self.assertEqual(list(base.glob('.s2a-clonedir-*')), [])

    @unittest.skipUnless(sys.platform.startswith('linux'), 'Linux copy-path contract')
    def test_many_files_do_not_exhaust_descriptors(self):
        with tempfile.TemporaryDirectory() as tmp:
            base=Path(tmp);src=base/'src';dst=base/'dst';(src/'dir').mkdir(parents=True)
            for i in range(300): (src/'dir'/str(i)).write_text('x')
            def limit(): resource.setrlimit(resource.RLIMIT_NOFILE,(64,64))
            result=subprocess.run([sys.executable,str(SCRIPT),str(src),str(dst)],capture_output=True,text=True,preexec_fn=limit)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(len(list((dst/'dir').iterdir())),300)

    @unittest.skipUnless(sys.platform.startswith('linux'), 'Linux copy-path contract')
    def test_deep_trees_with_descriptor_limit(self):
        for depth in (64, 128):
            with self.subTest(depth=depth), tempfile.TemporaryDirectory() as tmp:
                base = Path(tmp); src = base / 'src'; dst = base / 'dst'; src.mkdir()
                node = src
                for _ in range(depth): node = node / 'd'; node.mkdir()
                (node / 'item').write_text('safe')
                def limit(): resource.setrlimit(resource.RLIMIT_NOFILE, (64, 64))
                run = subprocess.run([sys.executable, str(SCRIPT), str(src), str(dst)],
                                     capture_output=True, text=True, preexec_fn=limit)
                self.assertEqual(run.returncode, 0, run.stderr)
                self.assertEqual((dst.joinpath(*(['d'] * depth)) / 'item').read_text(), 'safe')

    @unittest.skipUnless(sys.platform.startswith('linux'), 'Linux copy-path contract')
    def test_paths_beyond_path_max_fail_cleanly(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp); src = base / 'src'; dst = base / 'dst'; src.mkdir()
            fd = os.open(src, os.O_RDONLY | os.O_DIRECTORY)
            try:
                for _ in range(110):
                    name = 'a' * 40
                    os.mkdir(name, dir_fd=fd)
                    nxt = os.open(name, os.O_RDONLY | os.O_DIRECTORY, dir_fd=fd)
                    os.close(fd); fd = nxt
            finally: os.close(fd)
            def limit(): resource.setrlimit(resource.RLIMIT_NOFILE, (64, 64))
            run = subprocess.run([sys.executable, str(SCRIPT), str(src), str(dst)],
                                 capture_output=True, text=True, preexec_fn=limit)
            self.assertNotEqual(run.returncode, 0)
            self.assertIn('PATH_MAX', run.stderr)
            self.assertFalse(dst.exists())
            self.assertEqual(list(base.glob('.s2a-clonedir-*')), [])

    @unittest.skipUnless(sys.platform.startswith('linux'), 'Linux staging cleanup')
    def test_sigterm_staging_is_reclaimed_but_live_pid_is_preserved(self):
        code = textwrap.dedent('''
            import os, runpy, signal, sys
            script, src, dst = sys.argv[1:]
            original = os.open
            def intercept(path, flags, *args, **kwargs):
                if path == 'item' and flags & os.O_EXCL:
                    print('READY', flush=True)
                    signal.pause()
                return original(path, flags, *args, **kwargs)
            os.open = intercept
            sys.argv = [script, src, dst]
            runpy.run_path(script, run_name='__main__')
        ''')
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp); src = base / 'src'; dst = base / 'dst'; src.mkdir()
            (src / 'item').write_text('new')
            proc = subprocess.Popen([sys.executable, '-c', code, str(SCRIPT), str(src), str(dst)],
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            self.assertEqual(proc.stdout.readline().strip(), 'READY')
            proc.terminate(); proc.communicate(timeout=10)
            self.assertEqual(proc.returncode, -signal.SIGTERM)
            abandoned = list(base.glob(f'.s2a-clonedir-{proc.pid}-*'))
            self.assertEqual(len(abandoned), 1)
            active = base / f'.s2a-clonedir-{os.getpid()}-123-live'; active.mkdir()
            (active / 'sentinel').write_text('safe')
            run = subprocess.run([sys.executable, str(SCRIPT), str(src), str(dst)],
                                 capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertIn('清理失主暂存', run.stderr)
            self.assertFalse(abandoned[0].exists())
            self.assertEqual((active / 'sentinel').read_text(), 'safe')
            self.assertEqual((dst / 'item').read_text(), 'new')

    @unittest.skipUnless(sys.platform.startswith('linux'), 'Linux copy-path contract')
    def test_top_level_links_to_destination_or_ancestor_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp); src = base / 'src'; dst = base / 'dst'; src.mkdir()
            for target in (dst, base):
                os.symlink(target, src / 'link')
                run = subprocess.run([sys.executable, str(SCRIPT), str(src), str(dst)],
                                     capture_output=True, text=True, timeout=5)
                self.assertNotEqual(run.returncode, 0)
                self.assertFalse(dst.exists())
                self.assertEqual(list(base.glob('.s2a-clonedir-*')), [])
                (src / 'link').unlink()

    @unittest.skipUnless(sys.platform.startswith('linux'), 'Linux atomic publication')
    def test_destination_created_at_commit_is_never_replaced(self):
        code = textwrap.dedent('''
            import ctypes, os, runpy, sys
            script, src, dst, victim, kind = sys.argv[1:]
            real_cdll = ctypes.CDLL
            class Proxy:
                def __init__(self, *args, **kwargs): self.lib = real_cdll(*args, **kwargs)
                def __getattr__(self, name):
                    fn = getattr(self.lib, name)
                    if name != 'renameat2': return fn
                    def publish(*args):
                        if kind == 'dir': os.mkdir(dst)
                        else: os.symlink(victim, dst)
                        return fn(*args)
                    return publish
            ctypes.CDLL = Proxy
            sys.argv = [script, src, dst]
            runpy.run_path(script, run_name='__main__')
        ''')
        for kind in ('dir', 'symlink'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as tmp:
                base = Path(tmp); src = base / 'src'; dst = base / 'dst'; victim = base / 'victim'
                src.mkdir(); (src / 'item').write_text('new'); victim.write_text('safe')
                run = subprocess.run([sys.executable, '-c', code, str(SCRIPT), str(src), str(dst), str(victim), kind],
                                     capture_output=True, text=True)
                self.assertNotEqual(run.returncode, 0)
                self.assertEqual(victim.read_text(), 'safe')
                self.assertTrue(dst.is_dir() if kind == 'dir' else dst.is_symlink())
                if kind == 'dir': self.assertEqual(list(dst.iterdir()), [])
                self.assertEqual(list(base.glob('.s2a-clonedir-*')), [])

    @unittest.skipUnless(sys.platform.startswith('linux'), 'Linux atomic publication')
    def test_missing_atomic_rename_fails_closed(self):
        code = textwrap.dedent('''
            import ctypes, runpy, sys
            script, src, dst = sys.argv[1:]
            real_cdll = ctypes.CDLL
            class Proxy:
                def __init__(self, *args, **kwargs): self.lib = real_cdll(*args, **kwargs)
                def __getattr__(self, name):
                    if name == 'renameat2': raise AttributeError(name)
                    return getattr(self.lib, name)
            ctypes.CDLL = Proxy
            sys.argv = [script, src, dst]
            runpy.run_path(script, run_name='__main__')
        ''')
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp); src = base / 'src'; dst = base / 'dst'; src.mkdir()
            (src / 'item').write_text('new')
            run = subprocess.run([sys.executable, '-c', code, str(SCRIPT), str(src), str(dst)],
                                 capture_output=True, text=True)
            self.assertNotEqual(run.returncode, 0)
            self.assertFalse(dst.exists())
            self.assertEqual(list(base.glob('.s2a-clonedir-*')), [])

    @unittest.skipUnless(sys.platform.startswith('linux'), 'Linux metadata copy')
    def test_supported_xattr_and_symlink_timestamp_preserved(self):
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp); src = base / 'src'; dst = base / 'dst'; src.mkdir()
            file = src / 'item'; file.write_text('payload'); os.symlink('item', src / 'link')
            # Nested links are preserved; top-level links intentionally follow their targets.
            (src / 'nested').mkdir(); os.symlink('../item', src / 'nested' / 'link')
            stamp = 1_600_000_000_123_456_789
            os.utime(src / 'nested' / 'link', ns=(stamp, stamp), follow_symlinks=False)
            try: os.setxattr(file, 'user.s2a_test', b'value')
            except OSError as exc: self.skipTest(f'user xattrs unavailable: {exc}')
            run = subprocess.run([sys.executable, str(SCRIPT), str(src), str(dst)], capture_output=True, text=True)
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertEqual(os.getxattr(dst / 'item', 'user.s2a_test'), b'value')
            self.assertEqual((dst / 'nested' / 'link').lstat().st_mtime_ns, stamp)

    @unittest.skipUnless(sys.platform == 'darwin', 'macOS cross-volume fallback')
    def test_mac_cross_volume_deep_tree_with_descriptor_limit(self):
        code = textwrap.dedent('''
            import ctypes, errno, runpy, sys
            script, src, dst = sys.argv[1:]
            real_cdll = ctypes.CDLL
            class Proxy:
                def __init__(self, *args, **kwargs): self.lib = real_cdll(*args, **kwargs)
                def __getattr__(self, name):
                    if name == 'clonefile':
                        def clone(*args): ctypes.set_errno(errno.EXDEV); return -1
                        return clone
                    return getattr(self.lib, name)
            ctypes.CDLL = Proxy
            sys.argv = [script, src, dst]
            runpy.run_path(script, run_name='__main__')
        ''')
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp); src = base / 'src'; dst = base / 'dst'; src.mkdir()
            node = src
            for _ in range(128): node = node / 'd'; node.mkdir()
            (node / 'item').write_text('safe')
            def limit(): resource.setrlimit(resource.RLIMIT_NOFILE, (64, 64))
            run = subprocess.run([sys.executable, '-c', code, str(SCRIPT), str(src), str(dst)],
                                 capture_output=True, text=True, preexec_fn=limit)
            self.assertEqual(run.returncode, 0, run.stderr)
            self.assertEqual((dst.joinpath(*(['d'] * 128)) / 'item').read_text(), 'safe')

    @unittest.skipUnless(sys.platform == 'darwin', 'macOS cross-volume fallback')
    def test_mac_fallback_commit_race_never_replaces_link(self):
        code = textwrap.dedent('''
            import ctypes, errno, os, runpy, sys
            script, src, dst, victim = sys.argv[1:]
            real_cdll = ctypes.CDLL
            class Proxy:
                def __init__(self, *args, **kwargs): self.lib = real_cdll(*args, **kwargs)
                def __getattr__(self, name):
                    if name == 'clonefile':
                        def clone(*args): ctypes.set_errno(errno.EXDEV); return -1
                        return clone
                    fn = getattr(self.lib, name)
                    if name != 'renamex_np': return fn
                    def publish(*args):
                        os.symlink(victim, os.path.join(dst, 'item'))
                        return fn(*args)
                    return publish
            ctypes.CDLL = Proxy
            sys.argv = [script, src, dst]
            runpy.run_path(script, run_name='__main__')
        ''')
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp); src = base / 'src'; dst = base / 'dst'; victim = base / 'victim'
            src.mkdir(); dst.mkdir(); (src / 'item').write_text('new'); victim.write_text('safe')
            run = subprocess.run([sys.executable, '-c', code, str(SCRIPT), str(src), str(dst), str(victim)],
                                 capture_output=True, text=True)
            self.assertNotEqual(run.returncode, 0)
            self.assertTrue((dst / 'item').is_symlink())
            self.assertEqual(victim.read_text(), 'safe')
            self.assertEqual(list(dst.glob('.s2a-clonedir-*')), [])

if __name__ == '__main__':
    unittest.main()
