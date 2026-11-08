#!/usr/bin/env python3
# zstd 解压入口单测（graphics/tools/shbake/zstd_lib.py，11-02 出包线：玩家 App 的 Python 3.12 没有 compression.zstd，改调 zstd 命令旁边的 libzstd）：约 1 秒，退出 0 = 全过
# 夹具都用 zstd 命令行压（不跑被测实现、不依赖 Python 的 zstd 模块），期望 = 原文：
#   ① 记原长的帧；② 管道压出的不记原长的帧 + ① 首尾相接 → 两份原文；③ 只要前 7 字节；④ zstd --train 训出的字典压、按字典解；
#   ⑤ 反证：截断 10 字节 → ZstdError；不是 zstd → ZstdError；⑥ 字典帧不给字典 → ZstdError（不静默出错字节）；⑦ 解出恰好一个输出缓冲（131072）及其倍数不误判截断
import os, sys, random, subprocess, tempfile
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__)))); import zstd_lib
fail = cases = 0
def ck(ok, msg):
    global fail, cases
    print(('✓ ' if ok else '✗ ') + msg); fail += 0 if ok else 1; cases += 1
def z(data, *a): return subprocess.run(['zstd', '-q', '-c', *a, '-'], input=data, capture_output=True, check=True).stdout
def err(f):
    try: f(); return '没报'
    except zstd_lib.ZstdError as e: return f'ZstdError：{e}'
T = tempfile.mkdtemp(); random.seed(1)
A = bytes(random.getrandbits(8) for _ in range(300000)) + b'abc' * 100000
fa = os.path.join(T, 'a'); open(fa, 'wb').write(A)
c = subprocess.run(['zstd', '-q', '-c', fa], capture_output=True, check=True).stdout   # 从文件压：帧头记原长
s = z(A)                                                                              # 从管道压：不记原长
ck(zstd_lib.decompress(c) == A, '① 记原长的帧逐字节解出')
ck(zstd_lib.decompress(s + c) == A + A, '② 不记原长的帧 + 记原长的帧首尾相接 → 两份原文')
ck(zstd_lib.decompress(c, max_length=7) == A[:7], '③ 只要前 7 字节')
os.makedirs(os.path.join(T, 's'))
for i in range(400): open(os.path.join(T, 's', str(i)), 'wb').write(f'sample {i} shader key {i * 7} '.encode() * 20)
dic = os.path.join(T, 'dict'); subprocess.run(['zstd', '-q', '--train', '-r', os.path.join(T, 's'), '-o', dic, '--maxdict=4096'], check=True)
D = open(dic, 'rb').read(); M = b'sample 7 shader key 49 ' * 50
dc = z(M, '-D', dic)
ck(zstd_lib.decompress(dc, dict_bytes=D) == M, '④ 字典帧按字典解出')
# ⑦ 解出恰好一个输出缓冲（ZSTD_DStreamOutSize，131072）与它的整数倍：帧解完时输出正好填满，不能再调一次被当成新帧开头误判截断（11-02 王国之泪 bphsc.zs）
for n in (131072, 262144):
    E = bytes(random.getrandbits(8) for _ in range(n // 2)) + b'x' * (n - n // 2); fe = os.path.join(T, f'e{n}'); open(fe, 'wb').write(E)
    ce = subprocess.run(['zstd', '-q', '-c', '--check', fe], capture_output=True, check=True).stdout
    got = err(lambda: zstd_lib.decompress(ce))
    ck(got == '没报' and zstd_lib.decompress(ce) == E, f'⑦ 解出恰好 {n} 字节（带校验和）：不报截断、逐字节同原文（实得 {got}）')
r1, r2, r3 = err(lambda: zstd_lib.decompress(c[:-10])), err(lambda: zstd_lib.decompress(b'not zstd at all')), err(lambda: zstd_lib.decompress(dc))
ck(r1.startswith('ZstdError') and r2.startswith('ZstdError'), f'⑤ 截断 → {r1}；不是 zstd → {r2}')
ck(r3.startswith('ZstdError'), f'⑥ 字典帧不给字典 → {r3}')
print(f't_zstd_lib：{cases} 项，失败 {fail}'); sys.exit(1 if fail else 0)
