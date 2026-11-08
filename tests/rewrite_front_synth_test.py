#!/usr/bin/env python3
"""FAR 补丁容量重选（#290）的合成金样：不需要游戏文件。

合成模块：text 0x7D00000（125 MiB，超 112 MiB 进 FAR）、62,500 个 `add x3, x18, #8`（每点补丁 40 字节）。
首轮 FRONT = alignDown64KiB(128 MiB - text - 1 MiB) = 0x200000，可用 0x1fc000，放不下补丁 0x2625a0；
期望自动重选一次：FRONT = align64KiB(0x2625a0 + 0x4000) = 0x270000（手算），rc 0。
五种产物的 SHA-256 是金样：10-25 由 Python 改写器生成（自旋关、苹果目标），当时 C 改写器同产物；有意改变改写产物时在提交里写明并更新金样。
用法：REW=<C 命令行> python3 tests/rewrite_front_synth_test.py（缺省 REW 取出包同一入口 python3 pack/rewriter.py c-path 的末行；约 40 秒）。
需要 xcrun clang / otool（同 tests/rewrite_corpus）。
"""
import hashlib
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
GOLDEN = {
    'patched.bin': '43b833f9204f4eaf2c1461c5b368161a99f0fbb593202edc3feeb97f183f208b',
    'fixups.tsv': '9a396b26c2d4283eeb84a372fe03adf31ddc6eea0ed7e0551ade4e1bb36cc7df',
    'gates.tsv': 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
    'sites.tsv': '8edcbde343bc1a11c2713b88613d9c095a81f7c2c1a1b908e93efd3916f3e5c5',
    'gaps.tsv': 'a9b455922f4a1c7a5d66ed12748c133b4ba3eeb23d60f059ad1a9d3cbfb55b79',
}
INPUT_SHA = '7c36f67de8419b960d156f1eb40068258f087c5b8e6b82370cdd1990f062f363'


def sha(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1 << 20), b''):
            h.update(block)
    return h.hexdigest()


def main():
    rew = os.environ.get('REW') or (subprocess.run([sys.executable, str(ROOT / 'pack/rewriter.py'), 'c-path'], capture_output=True, text=True).stdout.strip().splitlines() or [''])[-1]
    if not (rew and os.access(rew, os.X_OK)):
        print('🔴 取不到 C 改写器（python3 pack/rewriter.py c-path）')
        return 1
    spec = importlib.util.spec_from_file_location('corpus', ROOT / 'tests/rewrite_corpus/run.py')
    corpus = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(corpus)
    bad = 0
    with tempfile.TemporaryDirectory() as t:
        nso, out = os.path.join(t, 'far.nso'), os.path.join(t, 'out')
        code = corpus.assemble('blk', 'add x3, x18, #8\n') * 62500 + corpus.assemble('ret', 'ret\n')
        corpus.nso(code, {}, len(code) * 4, nso, tsz=0x7D00000)
        if sha(nso) != INPUT_SHA:
            print(f'🔴 合成输入哈希变了（{sha(nso)[:16]}…）：tests/rewrite_corpus 的 nso() / 汇编结果变了，先核输入再改本表')
            return 1
        cmd = [rew, nso, out, 'main']
        r = subprocess.run(cmd, capture_output=True, text=True, env=dict(os.environ, S2A_REWRITE_SPIN='0', S2A_TARGET='apple'))
        log = r.stdout + r.stderr
        retry = 'main 补丁容量不足，重新生成：FRONT 0x200000 → 0x270000，补丁 0x2625a0' in log
        print(f'{"✓" if r.returncode == 0 else "✗"} 返回码 期望 0 → {r.returncode}')
        print(f'{"✓" if retry else "✗"} 自动重选 期望 FRONT 0x200000 → 0x270000 一次 → {"有" if retry else "无"}（共 {log.count("重新生成")} 次）')
        bad += r.returncode != 0 or not retry or log.count('重新生成') != 1
        fx = os.path.join(out, 'main.fixups.tsv')
        po = next((l.split('\t')[1].strip() for l in open(fx) if l.startswith('# PATCH_OFF')), None) if os.path.exists(fx) else None
        print(f'{"✓" if po == "-0x270000" else "✗"} 表头 PATCH_OFF 期望 -0x270000 → {po}')
        bad += po != '-0x270000'
        for ext, want in GOLDEN.items():
            p = os.path.join(out, 'main.' + ext)
            got = sha(p) if os.path.exists(p) else '无'
            print(f'{"✓" if got == want else "✗"} {ext} 与金样 {"同" if got == want else "异（" + got[:16] + "…）"}')
            bad += got != want
        if bad:
            print(log[-2000:])
    print(f'{"✓" if not bad else "✗"} rewrite_front_synth：{bad} 处不符')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
