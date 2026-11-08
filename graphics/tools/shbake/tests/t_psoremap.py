#!/usr/bin/env python3
# 首用表按客体指纹重定位单测（graphics/tools/shbake/psoremap.py，约 0.2 秒）：退出 0 = 全过。期望按规则手写，程序哈希用 hashlib 按运行时公式直接算（不调被测实现）：
#   运行时公式（graphics/metal/gal_prog.m prog_finish_hash）：SHA-256(<6Q 小端：cs vs tcs tes gs fs 各阶段键>) 前 8 字节 = 管线键编码前 8 字节。
#   ⓪ 公式对得上运行时：动森正式局真行 3 条（2026-10-23 shcollect/acnh/pso_use.tsv 前 3 行原样），按名字算出的哈希 = 编码前 8 字节
#   ① 本包有的组合原样保留；② 旧键经对照换成本包同指纹程序：名字换新键、编码前 8 字节换新哈希、其余字节不动；
#   ③ 同一组指纹本包有两个程序（特化不同）→ 出两行；④ 对照里没有的旧键 → 丢、计「对照里没有」；
#   ⑤ 编码前 8 字节与按名字算的不符（布局变了）→ 不改写、计「程序哈希核不上」；⑥ keymap 重复并入不增行
import hashlib, os, struct, subprocess, sys, tempfile
H = os.path.dirname(os.path.dirname(os.path.abspath(__file__))); P = os.path.join(H, 'psoremap.py')
fail = 0; n = 0
def ck(ok, msg):
    global fail, n
    n += 1; print(('✓ ' if ok else '✗ ') + msg); fail += 0 if ok else 1
def ph(vs=0, fs=0, cs=0): return hashlib.sha256(struct.pack('<6Q', cs, vs, 0, 0, 0, fs)).digest()[:8].hex()
REAL = ['0\tb\ts3795896a525f7048,s318a1a0f1b9163e4\t315fb46f5e7c6d10-2001-ff-ff-79',
        '0\tf\ts3795896a525f7048,s318a1a0f1b9163e4\t315fb46f5e7c6d1047-1f01-e30f-0703-ff-8c',
        '0\tb\tsfc5291c3153d5208,s318a1a0f1b9163e4\t66a33530c31a3f60-2001-ff-ff-79']
for r in REAL:
    c = r.split('\t'); v, f = (int(x[1:], 16) for x in c[2].split(','))
    ck(c[3][:16] == ph(v, f), f'⓪ 运行时真行：按名字算的程序哈希 {ph(v, f)} = 编码前 8 字节 {c[3][:16]}')
T = tempfile.mkdtemp()
def w(name, txt): p = os.path.join(T, name); open(p, 'w').write(txt); return p
HDR = 'idx\torigin\tstatus\tkind\tsource\tstages\tspv\tms\terr\n'
def prow(i, vk, vfp, fk, ffp): return f'{i}\tbake\tok\tgraphics\tx\tvs:?:16:{vfp} fs:?:16:{ffp}\t{vk},{fk}\t1\t\n'
A, B, C, D = 'aaaaaaaaaaaaaaaa', 'bbbbbbbbbbbbbbbb', 'cccccccccccccccc', 'dddddddddddddddd'
A2, B2, B3 = 'a2a2a2a2a2a2a2a2', 'b2b2b2b2b2b2b2b2', 'b3b3b3b3b3b3b3b3'
old = w('old.tsv', HDR + prow(0, A, '1111111111111111', B, '2222222222222222') + prow(1, C, '3333333333333333', D, '4444444444444444'))
# 新包：A/B 的两段客体代码翻出新键 A2/B2，另有同指纹不同特化的 A2/B3；C/D 那段客体代码新包里还在、键没变（本包有）
new = w('new.tsv', HDR + prow(0, A2, '1111111111111111', B2, '2222222222222222') + prow(1, A2, '1111111111111111', B3, '2222222222222222')
        + prow(2, C, '3333333333333333', D, '4444444444444444'))
km = os.path.join(T, 'km.tsv')
run = lambda *a: subprocess.run([sys.executable, P, *a], capture_output=True, text=True)
run('keymap', old, km); run('keymap', new, km); r6 = run('keymap', old, km)
rows = [l for l in open(km) if not l.startswith('#')]
ck(len(rows) == 7 and '本次 0 条新增' in r6.stdout, f'⑥ 重复并入不增行（对照 {len(rows)} 行，期望 7 = 旧 A B C D + 新 A2 B2 B3；输出「{r6.stdout.strip()}」）')
tail = '-2001-ff-ff-79'
use = w('use.tsv', '# 表\n'
        f'5\tb\ts{A},s{B}\t{ph(int(A, 16), int(B, 16))}{tail}\n'
        f'3\tf\ts{C},s{D}\t{ph(int(C, 16), int(D, 16))}{tail}\n'
        f'7\tb\tseeeeeeeeeeeeeeee,s{B}\t{ph(0xeeeeeeeeeeeeeeee, int(B, 16))}{tail}\n'
        f'9\tf\ts{A},s{B}\t0000000000000000{tail}\n')
out = os.path.join(T, 'out.tsv'); r = run('resolve', use, km, new, out)
got = [l.rstrip('\n').split('\t') for l in open(out) if not l.startswith('#')]
ck(['3', 'f', f's{C},s{D}', f'{ph(int(C, 16), int(D, 16))}{tail}'] in got, '① 本包有的组合原样保留')
want2 = ['5', 'b', f's{A2},s{B2}', f'{ph(int(A2, 16), int(B2, 16))}{tail}']
ck(want2 in got, f'② 旧键换本包同指纹程序：名字 s{A2},s{B2}、编码前 8 字节 {ph(int(A2, 16), int(B2, 16))}、其余不动')
ck(['5', 'b', f's{A2},s{B3}', f'{ph(int(A2, 16), int(B3, 16))}{tail}'] in got, '③ 同指纹两个程序（特化不同）各出一行')
ck('对照里没有 1' in r.stdout, f'④ 对照里没有的旧键丢弃并计数（「{r.stdout.strip()}」）')
ck('程序哈希核不上 1' in r.stdout and not any(c[0] == '9' for c in got), '⑤ 编码前 8 字节与名字算的不符 → 不改写、计数')
ck(len(got) == 3 and [c[0] for c in got] == ['3', '5', '5'], f'行数 3、按首用帧升序（实得 {[c[0] for c in got]}）')
km2 = os.path.join(T, 'fresh', 'acnh', 'keymap.tsv'); r7 = run('keymap', new, km2)
ck(r7.returncode == 0 and os.path.exists(km2), f'⑦ 新机器收集目录还不存在：自己建目录、写出对照（退出 {r7.returncode}{"，" + r7.stderr.strip()[-80:] if r7.returncode else ""}）')
print(f't_psoremap：{n} 项，失败 {fail}')
sys.exit(1 if fail else 0)
