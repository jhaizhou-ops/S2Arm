#!/usr/bin/env python3
"""pack/resource_input_key.py 同款跨根摘要缓存单测（11-05 根修：产物根重新克隆后 inode / ctime 全变，18.6 万文件全部重采约 8 分钟）。
期望按规则手写，不用被测函数推：
  ① 原根算一次键：3 个文件全采（exefs/main、romfs/a、romfs/b）
  ② 同款新根 = 原根的拷贝（保留字节数与 mtime，inode / ctime 变）：键与原根相同，只重采 exefs/main（1 次）
  ③ 负对照：新根里 romfs/a 改了内容（同长、mtime 变）→ 重采 romfs/a，键变
  ④ 负对照：别的款（根名 @ 前不同）同内容 → 不借用，全采
  ⑤ 负对照（审计 P1-54 口径，同 tests/pkg_key_inputs_test.sh）：克隆根算过键后，原根里 romfs/a 原地改一个字节、mtime 改回原值
     （字节数 + mtime 与同款缓存一致、inode 不变、ctime 变）→ 必须重采 romfs/a，键变
"""
import os, shutil, sys, tempfile, time, unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'pack'))
import resource_input_key as rik  # noqa: E402


class TitleMemo(unittest.TestCase):
    def setUp(self):
        self.t = tempfile.TemporaryDirectory(prefix='rik-'); self.base = Path(self.t.name)
        r = self.base / 't0100aaaa@pkg-1'
        (r / 'exefs').mkdir(parents=True); (r / 'romfs').mkdir()
        (r / 'exefs/main').write_bytes(b'MAIN' * 100)
        (r / 'romfs/a').write_bytes(b'a' * 1000)
        (r / 'romfs/b').write_bytes(os.urandom(300 * 1024))   # 大于 2 × 64 KiB，走首尾抽样
        self.src = r
        self.reads = []
        real = rik.read_digest
        def counted(path, expected, full):
            self.reads.append(Path(path).relative_to(Path(path).parents[1]).as_posix()); return real(path, expected, full)
        self._real = real; rik.read_digest = counted

    def tearDown(self):
        rik.read_digest = self._real; self.t.cleanup()

    def clone(self, name):
        dst = self.base / name; shutil.copytree(self.src, dst, copy_function=shutil.copy2)   # copy2 保留 mtime，同 clonefile / cp -c
        return dst

    def test_clone_reuses_digests(self):
        k1 = rik.resource_key(self.src)
        self.assertEqual(sorted(self.reads), ['exefs/main', 'romfs/a', 'romfs/b'])
        self.reads.clear(); time.sleep(0.01)
        k2 = rik.resource_key(self.clone('t0100aaaa@pkg-2'))
        self.assertEqual(k2, k1, '同款克隆根内容没变：键相同')
        self.assertEqual(self.reads, ['exefs/main'], '只重算 exefs/main，romfs 按字节数 + mtime 复用')

    def test_changed_content_resamples(self):
        k1 = rik.resource_key(self.src); self.reads.clear()
        dst = self.clone('t0100aaaa@pkg-3'); time.sleep(0.01)
        (dst / 'romfs/a').write_bytes(b'z' * 1000)   # 同长改内容，mtime 自然变
        k3 = rik.resource_key(dst)
        self.assertIn('romfs/a', self.reads); self.assertNotIn('romfs/b', self.reads)
        self.assertNotEqual(k3, k1, '内容变了：键变')

    def test_other_title_not_borrowed(self):
        rik.resource_key(self.src); self.reads.clear()
        rik.resource_key(self.clone('t0100bbbb@pkg-1'))
        self.assertEqual(sorted(self.reads), ['exefs/main', 'romfs/a', 'romfs/b'], '别的款不借用摘要')

    def test_inplace_edit_same_mtime_resamples(self):
        k1 = rik.resource_key(self.src)
        rik.resource_key(self.clone('t0100aaaa@pkg-4'))   # 同款缓存此时记着克隆根那份（内容同原根）
        self.reads.clear(); time.sleep(0.01)
        a = self.src / 'romfs/a'; st = a.stat()
        with a.open('r+b') as f: f.seek(500); f.write(b'z')
        os.utime(a, ns=(st.st_atime_ns, st.st_mtime_ns))
        k5 = rik.resource_key(self.src)
        self.assertIn('romfs/a', self.reads, '本根原地改过（ctime 变）：不许借同款缓存')
        self.assertNotEqual(k5, k1, '内容变了：键变')


if __name__ == '__main__':
    unittest.main()
