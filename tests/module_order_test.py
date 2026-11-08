#!/usr/bin/env python3
"""Horizon 装载序（tools/module_order.py）与出包端点回归。

覆盖：
  ① load_order / is_load_order：main → subsdk0..N（数字序）→ sdk，名单外的名排中间；
  ② 负对照：乱序输入经纯 sorted() 得到的是字母序（main → sdk → subsdk*），必须不是合法装载序
     —— 谁把出包端点改回 sorted()，这条会红；
  ③ stage_a0.module_list：乱序的 modules/*.patched.bin 产出 Horizon 序 artifact 模块表；
  ④ make_pack.write_artifact：同上，写到真 artifact JSON 里核。"""
import importlib.util
import json
import os
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, 'tools'))
from module_order import is_load_order, load_order   # noqa: E402

fails = 0


def check(what, ok):
    global fails
    print(f"{'通' if ok else '不通'} {what}")
    fails += not ok


def load_script(path, name):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


FIXUPS = "# TARGET\tandroid\n# REWRITE_ABI\tandroid-sp-safe-v1\n"


def fake_modules(root, names):
    d = os.path.join(root, 'modules')
    os.makedirs(d, exist_ok=True)
    for n in names:
        for suf, body in (('.patched.bin', b'\x7fELF'), ('.fixups.tsv', FIXUPS), ('.gates.tsv', '0x100\tsvc\t1\t0x128\n')):
            mode = 'wb' if isinstance(body, bytes) else 'w'
            with open(os.path.join(d, n + suf), mode) as f:
                f.write(body)
    return d


SHUFFLED = ['subsdk10', 'sdk', 'subsdk2', 'main', 'subsdk0']
WANT = ['main', 'subsdk0', 'subsdk2', 'subsdk10', 'sdk']

check('① load_order：subsdk 按数字序、sdk 最后', load_order(SHUFFLED) == WANT)
check('① load_order：名单外的名（rtld）排 subsdk* 与 sdk 之间',
      load_order(['sdk', 'rtld', 'subsdk0', 'main']) == ['main', 'subsdk0', 'rtld', 'sdk'])
check('① is_load_order 收 Horizon 序', is_load_order(WANT))
check('① is_load_order 拒 main 不在首位', not is_load_order(['sdk', 'main', 'subsdk0']))
check('① is_load_order 拒 subsdk 非数字序', not is_load_order(['main', 'subsdk10', 'subsdk2', 'sdk']))
check('② 负对照：sorted() 的字母序不是合法装载序（改回 sorted 会红）',
      sorted(SHUFFLED) != WANT and not is_load_order(sorted(SHUFFLED)))

stage_a0 = load_script(os.path.join(REPO, 'android/tools/stage_a0.py'), 'stage_a0')
make_pack = load_script(os.path.join(REPO, 'android/tools/make_pack.py'), 'make_pack')

with tempfile.TemporaryDirectory(prefix='module-order-') as tmp:
    root = os.path.join(tmp, 'game')
    fake_modules(root, SHUFFLED)
    got = [m['name'] for m in stage_a0.module_list(root)]
    check('③ stage_a0.module_list：乱序模块文件产出 Horizon 序', got == WANT)

with tempfile.TemporaryDirectory(prefix='module-order-') as tmp:
    fake_modules(tmp, SHUFFLED)
    nacp = bytearray(0x4000)
    nacp[0x3038:0x3040] = (0x0100000000ABCDEF).to_bytes(8, 'little')
    os.makedirs(os.path.join(tmp, 'ctl'), exist_ok=True)
    with open(os.path.join(tmp, 'ctl', 'control.nacp'), 'wb') as f:
        f.write(nacp)
    make_pack.write_artifact(tmp, 'ab' * 32, 1, 4)
    with open(os.path.join(tmp, 'game-build-artifact.json'), encoding='utf-8') as f:
        got = [m['name'] for m in json.load(f)['modules']]
    check('④ make_pack.write_artifact：乱序模块文件产出 Horizon 序', got == WANT)

print(f"{'不通' if fails else '通'} module_order：{fails} 处不符")
sys.exit(1 if fails else 0)
