#!/usr/bin/env python3
"""主机测试输出目录必须按运行隔离（#919 安卓门禁偶发红）。

根因：test.sh 的输出目录原先固定为 <仓库>/build/android-host-tests。
  · 同一棵树上两份门禁并行（列车本机步 + 各线自检 / 人工重跑）时两份都写 $out/java；
    javac 写 .class 不是原子的，另一个进程 java -cp 读到半截即
    java.lang.ClassFormatError: Truncated class file（本机 4 路并发 4 次实验里红 2 次）。
  · 目录还跨次复用：上一次被中断留下的半写文件，成为下一次首跑的输入。
本回归不改超时、不加锁：它断言「每次运行拿到的目录互不相同、且看不到上一次的残留」，
并按生产脚本（test.sh）的方式取目录 —— 修复前的提交上取到的是固定目录，因此必红。
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
ANDROID = ROOT / 'android'
TEST_SH = ANDROID / 'test.sh'
HELPER = ANDROID / 'tools/host_out.sh'
LEGACY_OUT = ROOT / 'build/android-host-tests'
CLASS = 'org.s2arm.android.GameTouchTest'


def production_out():
    """按 android/test.sh 的方式取本次运行的输出目录。

    test.sh 走 tools/host_out.sh 的 s2a_host_out；修复前它没有这个 helper，
    用的是固定目录，这里同样退回固定目录 —— 回归因此能在修复前的提交上红。
    """
    if HELPER.is_file():
        result = subprocess.run(
            ['bash', '-c', 'set -euo pipefail; source "$1"; s2a_host_out', 'fixture', str(HELPER)],
            text=True, capture_output=True)
        if result.returncode:
            raise AssertionError('s2a_host_out 取不到输出目录：' + result.stderr.strip())
        return Path(result.stdout.strip())
    return LEGACY_OUT


class HostOutputIsolationTest(unittest.TestCase):
    def test_output_directory_is_unique_per_run(self):
        seen = [production_out() for _ in range(3)]
        self.assertEqual(len(set(seen)), 3, '两次运行拿到同一个输出目录：%s' % seen)
        for path in seen:
            self.assertTrue(path.is_dir(), '输出目录必须本次新建：%s' % path)
            self.assertEqual(list(path.iterdir()), [],
                             '新输出目录里带着上一次的产物：%s' % list(path.iterdir()))
            path.rmdir()

    def test_parallel_runs_get_distinct_directories(self):
        script = 'set -euo pipefail; source "$1"; s2a_host_out'
        procs = [subprocess.Popen(['bash', '-c', script, 'fixture', str(HELPER)],
                                  text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                 for _ in range(4)]
        dirs = []
        for proc in procs:
            out, err = proc.communicate()
            self.assertEqual(proc.returncode, 0, err)
            dirs.append(out.strip())
        self.assertEqual(len(set(dirs)), 4, '并发运行拿到同一个输出目录：%s' % dirs)
        for path in dirs:
            Path(path).rmdir()

    def test_previous_run_leftovers_are_invisible(self):
        """上一次留下的半写 .class 只可能弄挂上一次的目录，不会成为本次的输入。"""
        javac, java = shutil.which('javac'), shutil.which('java')
        if not javac or not java:
            self.skipTest('需要 JDK 17 的 javac / java')
        previous, current = production_out(), production_out()
        self.assertNotEqual(previous, current, '两次运行共用一个输出目录：残留会直接成为输入')
        with tempfile.TemporaryDirectory(prefix='s2a-host-out-src-') as source:
            source = Path(source)
            java_file = source / 'GameTouchTest.java'
            java_file.parent.mkdir(parents=True, exist_ok=True)
            java_file.write_text(
                'package org.s2arm.android;\n'
                'public final class GameTouchTest { public static void main(String[] a) {} }\n',
                encoding='utf-8')
            classes = source / 'classes'
            classes.mkdir()
            compiled = subprocess.run([javac, '-d', str(classes), str(java_file)],
                                      text=True, capture_output=True)
            self.assertEqual(compiled.returncode, 0, compiled.stderr)
            whole = (classes / 'org/s2arm/android/GameTouchTest.class').read_bytes()
            # 半写文件 = 被中断 / 被另一个 javac 截断的 .class，正是 #919 的红行形态。
            truncated = previous / 'java/org/s2arm/android/GameTouchTest.class'
            truncated.parent.mkdir(parents=True, exist_ok=True)
            truncated.write_bytes(whole[:len(whole) * 6 // 10])
        try:
            stale = subprocess.run([java, '-cp', str(previous / 'java'), CLASS],
                                   text=True, capture_output=True)
            self.assertNotEqual(stale.returncode, 0, stale.stdout)
            self.assertIn('ClassFormatError', stale.stderr,
                          '上一次目录里的半写 .class 必须复现原红行：%s' % stale.stderr.strip())
            fresh = subprocess.run([java, '-cp', str(current / 'java'), CLASS],
                                   text=True, capture_output=True)
            self.assertNotEqual(fresh.returncode, 0, fresh.stdout)
            self.assertIn('ClassNotFoundException', fresh.stderr,
                          '本次目录不该看见上一次的残留：%s' % fresh.stderr.strip())
        finally:
            shutil.rmtree(previous, ignore_errors=True)
            shutil.rmtree(current, ignore_errors=True)

    def test_test_sh_uses_the_isolated_directory(self):
        text = TEST_SH.read_text(encoding='utf-8')
        assignments = [line for line in text.splitlines()
                       if line.startswith('out=') or line.startswith('out=')]
        self.assertTrue(assignments, 'test.sh 里找不到 out= 赋值')
        self.assertTrue(any('s2a_host_out' in line for line in assignments),
                        'test.sh 的 out 必须按运行取唯一目录，实为：%s' % assignments)
        self.assertIn('rm -rf "$out"', text, '输出目录必须在退出时清理，别把磁盘留给下一次')


if __name__ == '__main__':
    unittest.main(verbosity=2)
