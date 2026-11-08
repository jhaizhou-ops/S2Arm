"""改写产物金样：C 改写器产物对仓库里固定的 SHA-256（10-31 删 Python 改写器后，替代原来的 Python / C 对拍）。

金样表 tests/fixtures/rewrite_golden/<表名>.tsv，每行：标签 \t 退出码 \t 输入 SHA-256 \t 文件名=SHA-256 …（空格分隔、按文件名排序）。
来源：10-31 由 Python 改写器与 C 改写器同产物时生成——生成前先用当时的对拍单测核过两边逐字节相同，再按 C 产物写表。
有意改变改写产物时：S2A_GOLDEN_WRITE=1 跑对应单测，按当前 C 产物重写金样表；在提交里写明哪些标签变了、为什么。
"""
import hashlib
import os
from pathlib import Path

DIR = Path(__file__).resolve().parent / 'fixtures/rewrite_golden'


def sha(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1 << 20), b''):
            h.update(block)
    return h.hexdigest()


def files(out, names=None):
    """输出目录里的文件（names 给定时只取这几个；缺的记「无」）→ {文件名: SHA-256}。"""
    out = Path(out)
    if names is None:
        return {p.name: sha(p) for p in sorted(out.iterdir()) if p.is_file()} if out.is_dir() else {}
    return {n: (sha(out / n) if (out / n).is_file() else '无') for n in sorted(names)}


class Golden:
    def __init__(self, name):
        self.path = DIR / (name + '.tsv')
        self.write = os.environ.get('S2A_GOLDEN_WRITE') == '1'
        self.rows, self.seen = {}, set()
        if not self.write:
            if not self.path.is_file():
                raise SystemExit(f'🔴 金样表缺 {self.path}')
            for line in self.path.read_text().splitlines():
                if line and not line.startswith('#'):
                    label, rc, src, digest = line.split('\t')
                    self.rows[label] = (int(rc), src, digest)

    def check(self, label, rc, source, out, names=None):
        """对金样：一致返回 None，不一致返回一句写明差在哪的话（输入变了 / 退出码 / 哪几个文件）。"""
        got = files(out, names)
        row = (rc, sha(source), ' '.join(f'{k}={v}' for k, v in got.items()))
        assert label not in self.seen, ('金样标签重复', label)
        self.seen.add(label)
        if self.write:
            self.rows[label] = row
            return None
        want = self.rows.get(label)
        if want is None:
            return f'{label}：金样表没有这个标签'
        if want[1] != row[1]:
            return f'{label}：合成输入变了（金样 {want[1][:12]}… 实 {row[1][:12]}…），先核输入生成再谈产物'
        if want[0] != rc:
            return f'{label}：退出码 金样 {want[0]} 实 {rc}'
        if want[2] != row[2]:
            w = dict(x.split('=') for x in want[2].split())
            diff = sorted(n for n in set(w) | set(got) if w.get(n) != got.get(n))
            return f'{label}：产物与金样不同（{", ".join(diff)}）'
        return None

    def finish(self, complete=True):
        """写表模式落盘；校验模式下 complete=True 时报金样表里没跑到的标签（防止射程悄悄变小）。"""
        if self.write:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            head = ('# 改写产物金样（tests/rewrite_golden.py）：标签\t退出码\t输入 SHA-256\t文件名=SHA-256 …\n'
                    '# 10-31 由 Python 改写器与 C 改写器同产物时生成；有意改变改写产物时在提交里写明并更新金样（S2A_GOLDEN_WRITE=1 重写）\n')
            self.path.write_text(head + ''.join(f'{k}\t{v[0]}\t{v[1]}\t{v[2]}\n' for k, v in sorted(self.rows.items())))
            print(f'已写金样 {self.path}（{len(self.rows)} 行）')
            return []
        return [f'{k}：金样表有、本次没跑到' for k in sorted(set(self.rows) - self.seen)] if complete else []
