#!/usr/bin/env python3
# 客体着色器缓存读取器单测（graphics/tools/shbake/guest_cache.py，10-27 王国之泪社区缓存入库）：合成 yuzu 系缓存，约 1 秒，退出 0 = 全过。**合成部分不含游戏数据**。
# 构造（按 guest_cache.py 头注释的布局逐字节手写，不跑被测实现推期望）：
#   "yuzucach" + 版本 10 + 两条记录：① 图形（顶点 B + 片元，各带常量段 1 / 常量段 0 的取值；SPH 在代码区开头）+ 1032 字节图形管线键
#   ② 计算（一阶段，线程组 + 共享内存）+ 24 字节计算管线键
# 覆盖：
#   ① 正例：两个程序、槽号（顶点 1 / 片元 5 / 计算 0）、客体代码逐字节（图形从 SPH 起、计算从第一条指令起）、常量段 1 按偏移铺回（常量段 0 不进）
#   ② 写出的 .s2gb 按格式另行读回（不用被测代码）：头、程序数、每阶段长度与字节，末尾不多不少
#   ③ 反证：截掉末尾 8 字节 / 文件头不对 → 退出 1、打【红】行、不写输出
#   ④ 真文件正对照（本机有 ~/.s2arm/data/community_shcache/totk_yuzu_v10_1027/0100F2C0115B6000/vulkan.bin 才跑，没有就记「跳过」）：程序 46085、计算 130，
#      第一条是顶点 + 片元、顶点代码 472 字节且以 SPH 第一个字 0x02060461 开头（期望来自 xxd 看文件头手算：代码区起点 = 缓存下界）
#   ⑤ 反证：环境头的代码窗口盖不住入口（审计 #846 F-guest-env-empty）。计算阶段 size 0x48、起点 = 下界 + 0x58、上界 = 起点（起点 - 下界 超出代码区）；
#      图形（单个顶点阶段）size 0x48、起点 = 下界 + 0x48、上界 = 下界 + 0x40（代码区里入口之后 0 字节）。两份都恰好解到文件尾。
#      期望退出 1、打【红】行、不写输出；原先退出 0，写出的 .s2gb 里计算阶段代码长 0、图形阶段只有 0x50 字节 SPH
import os, struct, subprocess, sys, tempfile

H = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', '..', '..'))
GC = os.path.join(H, 'graphics', 'tools', 'shbake', 'guest_cache.py')
T = tempfile.mkdtemp()
fail = n = 0
def ck(ok, what):
    global fail, n
    n += 1; print(('✓ ' if ok else '✗ ') + what); fail += 0 if ok else 1

def env(stage, code, cbufs, sph=None, start=0x1000):
    """yuzu v10 环境：u64 × 5（代码字节、贴图类型数、像素格式数、常量数、常量替换数）+ u32 × 7 + 代码 + 常量 + 尾"""
    lo, hi = start, start + len(code) - 8
    e = struct.pack('<QQQQQ', len(code), 0, 0, len(cbufs), 0) + struct.pack('<IIIIIII', 0, 2, start, lo, hi, 1, stage) + code
    for (cb, off), v in cbufs.items(): e += struct.pack('<QI', (cb << 32) | off, v)
    e += struct.pack('<IIII', 32, 1, 1, 0) if stage == 5 else sph
    return e

sph_v = bytes([0x61, 0x04, 0x06, 0x02]) + bytes(range(4, 0x50)); sph_f = bytes([0x62, 0x04, 0x06, 0x02]) + bytes(0x4c)
code_v = sph_v + bytes(range(0x50, 0x50 + 0x40))   # 代码区开头就是 SPH（与真文件一致）
code_f = sph_f + b'\x11' * 0x38
code_c = b'\x22' * 0x48
gfx = struct.pack('<I', 2) + env(0, code_v, {(1, 0x10): 0xAABBCCDD, (0, 0x40): 0x1234}, sph_v) + env(4, code_f, {(1, 0): 7}, sph_f) + bytes(range(256)) * 4 + bytes(8)   # 1032 字节键
cmp = struct.pack('<I', 1) + env(5, code_c, {}) + b'\x33' * 24
blob = b'yuzucach' + struct.pack('<I', 10) + gfx + cmp
src = os.path.join(T, 'vulkan.bin'); open(src, 'wb').write(blob)

def run(*a):
    p = subprocess.run([sys.executable, '-I', GC, *a], capture_output=True, text=True); return p.returncode, p.stdout + p.stderr

def read_bundle(p):   # 按 .s2gb 格式另行读回
    b = open(p, 'rb').read(); assert b[:4] == b'S2GB'
    ver, tid, fmt, cnt = struct.unpack_from('<IQII', b, 4); q = 24; progs = []
    for _ in range(cnt):
        comp, ns = b[q], b[q + 1]; q += 2; st = []
        for _ in range(ns):
            slot, ln = struct.unpack_from('<BI', b, q); q += 5; code = b[q:q + ln]; q += ln
            cl, = struct.unpack_from('<I', b, q); q += 4; cb = b[q:q + cl]; q += cl; st.append((slot, code, cb))
        progs.append((comp, st))
    return ver, tid, fmt, progs, q == len(b)

out = os.path.join(T, 'a.s2gb'); rc, log = run('bundle', src, out, '--title', '0100F2C0115B6000')
ck(rc == 0 and os.path.exists(out), f'① 合成缓存 → 退出 {rc}、写出 .s2gb（{log.strip().splitlines()[0] if log.strip() else "无输出"}）')
if os.path.exists(out):
    ver, tid, fmt, progs, whole = read_bundle(out)
    ck(ver == 1 and tid == 0x0100F2C0115B6000 and fmt == 0xFFFF000A and whole, f'② 包头：版本 {ver}、程序号 {tid:016X}、来源格式 {fmt:#x}；读到末尾恰好 {whole}')
    ck(len(progs) == 2 and progs[0][0] == 0 and progs[1][0] == 1, f'① 两个程序：图形 + 计算（{[c for c, _ in progs]}）')
    g = progs[0][1]; c = progs[1][1] if len(progs) > 1 else []
    ck([s for s, _, _ in g] == [1, 5] and g[0][1] == code_v and g[1][1] == code_f, '① 图形：顶点槽 1 / 片元槽 5，客体代码从 SPH 起逐字节等于原料')
    ck(g[0][2] == bytes(0x10) + struct.pack('<I', 0xAABBCCDD) and g[1][2] == struct.pack('<I', 7), f'① 常量段 1 按偏移铺回、常量段 0 不进（顶点 {g[0][2].hex()}）')
    ck(len(c) == 1 and c[0][0] == 0 and c[0][1] == code_c and c[0][2] == b'', '① 计算：槽 0，代码从第一条指令起，无常量段 1')
# ③ 反证
open(os.path.join(T, 'cut.bin'), 'wb').write(blob[:-8]); o2 = os.path.join(T, 'cut.s2gb'); rc, log = run('bundle', os.path.join(T, 'cut.bin'), o2, '--title', '0100F2C0115B6000')
ck(rc == 1 and '【红】' in log and not os.path.exists(o2), f'③ 截掉末尾 8 字节 → 退出 {rc}、红行、不写输出（{log.strip()[-60:]}）')
open(os.path.join(T, 'bad.bin'), 'wb').write(b'notyuzu!' + blob[8:]); o3 = os.path.join(T, 'bad.s2gb'); rc, log = run('bundle', os.path.join(T, 'bad.bin'), o3, '--title', '0100F2C0115B6000')
ck(rc == 1 and 'yuzucach' in log and not os.path.exists(o3), f'③ 文件头不对 → 退出 {rc}、红行点名文件头')
# ⑤ 代码窗口盖不住入口
def env_raw(stage, code, start, lo, hi, tail):   # 起点 / 下界 / 上界直接给，不按代码长推
    return struct.pack('<QQQQQ', len(code), 0, 0, 0, 0) + struct.pack('<IIIIIII', 0, 2, start, lo, hi, 1, stage) + code + tail
for tag, rec in (('计算', struct.pack('<I', 1) + env_raw(5, code_c, 0x1000 + 0x58, 0x1000, 0x1000 + 0x58, struct.pack('<IIII', 32, 1, 1, 0)) + b'\x33' * 24),
                 ('图形', struct.pack('<I', 1) + env_raw(0, b'\x44' * 0x48, 0x1000 + 0x48, 0x1000, 0x1000 + 0x40, sph_v) + bytes(1032))):
    f5 = os.path.join(T, f'win_{tag}.bin'); open(f5, 'wb').write(b'yuzucach' + struct.pack('<I', 10) + rec); o5 = f5 + '.s2gb'
    rc, log = run('bundle', f5, o5, '--title', '0100F2C0115B6000')
    got = '没写输出' if not os.path.exists(o5) else '写出 ' + '、'.join(f'槽 {sl} 代码长 {len(c)}' for _, st in read_bundle(o5)[3] for sl, c, _ in st)
    ck(rc == 1 and '【红】' in log and not os.path.exists(o5), f'⑤ {tag}阶段代码窗口盖不住入口 → 退出 {rc}（期望 1）、{got}（{log.strip()[-60:]}）')
# ④ 真文件
real = os.path.expanduser('~/.s2arm/data/community_shcache/totk_yuzu_v10_1027/0100F2C0115B6000/vulkan.bin')
if os.path.exists(real):
    o4 = os.path.join(T, 'real.s2gb'); rc, log = run('bundle', real, o4, '--title', '0100F2C0115B6000')
    if rc == 0:
        _, _, _, progs, whole = read_bundle(o4); first = progs[0][1]
        ck(len(progs) == 46085 and sum(c for c, _ in progs) == 130 and whole, f'④ 真文件：程序 {len(progs)}（期望 46085）、计算 {sum(c for c, _ in progs)}（期望 130）、读到末尾 {whole}')
        ck([s for s, _, _ in first] == [1, 5] and len(first[0][1]) == 472 and first[0][1][:4] == bytes.fromhex('61040602'), f'④ 真文件第一条：槽 {[s for s, _, _ in first]}、顶点代码 {len(first[0][1])} 字节、开头 {first[0][1][:4].hex()}')
    else: ck(False, f'④ 真文件解不开：{log.strip()[-120:]}')
else: print('跳过 ④ 真文件正对照（本机没有 totk_yuzu_v10_1027/0100F2C0115B6000/vulkan.bin）')
print(f'客体缓存读取器：{n - fail}/{n} 过')
sys.exit(1 if fail else 0)
