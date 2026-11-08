#!/usr/bin/env python3
# shader_split.kernel_variants 单测：Unity ComputeShader 各版本的 kernel 变体布局（期望按版本布局手写）。
#   2022.3 uniqueVariants、2020.3 variantMap（按关键字组）、2018.4 kernel 自带 code（10-25 Moving Out #379 在这里 KeyError 'variantMap'），其余布局报红退出
import os, subprocess, sys
HERE = os.path.dirname(os.path.abspath(__file__)); TOOLS = os.path.join(HERE, '..', '..', '..', '..', 'translator')
sys.path.insert(0, TOOLS)
os.environ.setdefault('DM_GAME', '01006F8002326000')   # shader_split 导入时按 DM_GAME 选配置档；这里只测纯函数，选哪款无关
import shader_split as ss
fails = []
def check(cond, msg):
    print(('  ✓ ' if cond else '  ✗ ') + msg)
    if not cond: fails.append(msg)
a, b = {'code': b'A'}, {'code': b'B'}
check(ss.kernel_variants({'name': 'k', 'uniqueVariants': [a, b]}, 'w') == [a, b], 'Unity 2022.3：uniqueVariants 原样')
check(ss.kernel_variants({'name': 'k', 'variantMap': [{'first': 'X', 'second': a}, {'first': 'Y', 'second': b}]}, 'w') == [a, b], 'Unity 2020.3：variantMap 取每组的 second')
k18 = {'name': 'CSMain', 'cbs': [], 'textures': [], 'code': b'C'}
check(ss.kernel_variants(k18, 'w') == [k18], 'Unity 2018.4：kernel 自带 code → 本身就是唯一变体')
p = subprocess.run([sys.executable, '-c', f'import sys; sys.path.insert(0, {TOOLS!r}); import shader_split as ss; ss.kernel_variants({{"name": "k", "cbs": []}}, "w")'], capture_output=True, text=True)
check(p.returncode != 0 and 'unknown layout' in (p.stdout + p.stderr) and "'cbs'" in (p.stdout + p.stderr), f'未知布局：报红退出并列出字段（实得 rc={p.returncode}）')
print(f't_unity_kernels：{"全符" if not fails else f"{len(fails)} 例不符"}')
sys.exit(1 if fails else 0)
