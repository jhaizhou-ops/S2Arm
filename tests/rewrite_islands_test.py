#!/usr/bin/env python3
"""双补丁岛合成金样（原生层 10-30）：不需要游戏文件、不需要 clang。C 改写器跑一遍，全部产物对金样（tests/fixtures/rewrite_golden/rewrite_islands.tsv，
见 tests/rewrite_golden.py；原为 C / Python 对拍），且与按布局公式手算的期望相符。

（a）近布局越线 → 前岛接住低地址单元：text 0x3900000、bss 0x36e0000（end + bss = 0x6fe2000 → 键页 0x6fe4000、PATCH_OFF = align64K(0x6fe8000) = 0x6ff0000，
     仍是近布局）。0x1000 起 480000 个 svc（每个门块 10 字 = 40 字节），另一个 svc 在 0x3880000。
     原布局：第 k 个 svc 的块在 0x6ff0000 + 40k，回跳 B 的距离 = 0x6ff0000 − 0x1000 + 36k + 32，k ≥ 467968 时超 2^27 → 整轮按双岛重做。
     双岛：SPLIT = 0x6ff0000 / 2 = 0x37f8000，低于它的 480000 个 svc 进前岛；前岛首轮 FRONT 0x100000 放不下 480000 × 40 = 0x124f800，
     重做为 align64K(0x124f800 + 0x4000) = 0x1260000；0x3880000 的 svc 进后岛（原 PATCH_OFF 处）。
     期望：rc 0；表头 PATCH_OFF 0x6ff0000、PATCH2_OFF −0x1260000、PATCH2_LEN 0x124f800、TRAP_SITES 0、SPIN_UNREACHED 0；
     patched.bin 长 0x6ff0000 + 40 + 0x124f800；+0x1000 是 B −0x1261000（到前岛首），+0x3880000 是 B 0x3770000（到后岛首）。
（b）text > 128 MiB 用双岛 + brk：text 0x8080000、bss 0x7fda000（end = 0x8082000，end + bss = 0x1005c000 = 键页，IMAGE_SIZE 0x10060000，
     后岛 PATCH2_OFF = align64K(0x10060000) = 0x10060000，SPLIT 0x8030000）；128 MiB − text − 1 MiB < 1 MiB → 直接双岛，FRONT 0x100000（PATCH_OFF −0x100000）。
     前段：0x1000 svc #1、0x2000 mrs x5,tpidr_el0、0x3000 自旋（ldr w8,[x0]; cbz w8,-4）。
     中段 0x8040000：mrs x7,tpidr_el0 / msr tpidr_el0,x6 / mrs x0,ctr_el0 / 0x8040010 自旋——前岛最远够到 0x7f00000 + 块内偏移，
       后岛最近要 ≥ 0x10060000 − 2^27 = 0x8060000，两边都够不着。
     后段 0x8078000：mrs x9,tpidr_el0、svc #1、0x8078010 自旋。
     期望：rc 0；TRAP_SITES 3、SPIN_UNREACHED 1；# TRAP 行依次 0x8040000 tpidr_r 7 / 0x8040004 tpidr_w 6 / 0x8040008 ctr 0；
     三处原字换成 brk #0x8000 / #0x8001 / #0x8002（0xd4300000 / 0xd4300020 / 0xd4300040）；中段自旋回边 0x8040014 原字不动；
     +0x1000 是 B −0x101000（前岛首）、+0x2000 是 B −0x101fd8（前岛 +40，svc 块 10 字）、+0x8078000 是 B 0x7fe8000（后岛首）、
     +0x8078004 是 B 0x7fe801c（后岛 +32，tpidr_r 块 8 字）；前段自旋回边 0x3004 跳进前岛、后段 0x8078014 跳进后岛；日志有【红】自旋够不着行列出 0x8040010。
（c）同（b）再在中段 0x804000c 放一条 x18 改写点（add x3, x18, #8：不能在信号里模拟）：两岛都够不着 → 远跳（10-31 出包线，Minecraft 6325 点）：
     单元照常生成进岛，原字换成 brk #0xA000（0xd4340000）；期望 rc 0、gaps.tsv 没有缺口行、出 patched.bin；# FAR_JUMPS 2，
     一条入口 0x804000c → 岛里（E），一条出口 岛里 → 0x8040010（X），产物对金样。
用法：python3 tests/rewrite_islands_test.py（C 命令行取 pack/rewriter.py c-path；可用 REW_C 换）。
"""
import importlib.util
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'tests'))
from rewrite_golden import Golden
PY = os.environ.get('S2A_PY') or sys.executable
SVC, RET = 0xD4000021, 0xD65F03C0
SPIN = (0xB9400008, 0x34FFFFE8)   # ldr w8,[x0]; cbz w8,-4（tests/rewrite_spin_test.sh 的 A）
bad = 0
GOLDEN = Golden('rewrite_islands')


def ck(ok, what):
    global bad
    print(f'{"✓" if ok else "✗"} {what}')
    bad += not ok


def corpus():
    spec = importlib.util.spec_from_file_location('corpus', ROOT / 'tests/rewrite_corpus/run.py')
    m = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(m)
    return m


def make(path, tsz, bss, words):
    """骨架同 tests/rewrite_corpus/run.py nso()（代码段 0x100 一条 ret、一个 FDE），再按偏移写入稀疏的字、改 bss（NSO 头 0x3c）"""
    corpus().nso([RET], {}, 4, path, tsz=tsz)
    d = bytearray(open(path, 'rb').read())
    struct.pack_into('<I', d, 0x3C, bss)
    for off, w in words.items():
        struct.pack_into('<I', d, 0x100 + off, w)   # 段未压缩、代码段文件偏移 0x100
    open(path, 'wb').write(d)


def b_off(w):   # B 指令的跳转距离
    assert w >> 26 == 0x05, hex(w)
    i = w & 0x3FFFFFF
    return (i - (1 << 26) if i >> 25 else i) * 4


def run(rew, nso, out):
    cmd = [rew, nso, out, 'main']
    r = subprocess.run(cmd, capture_output=True, text=True, env=dict(os.environ, S2A_REWRITE_SPIN='1', S2A_TARGET='apple'))
    return r.returncode, r.stdout + r.stderr


def header(out):
    h, traps = {}, []
    for l in open(os.path.join(out, 'main.fixups.tsv')):
        c = l.rstrip('\n').split('\t')
        if c[0] == '# TRAP': traps.append(c[1:])
        elif c[0].startswith('# '): h[c[0][2:]] = c[1]
    return h, traps


def one(name, nso, t, rew_c, want_rc=0):
    out = os.path.join(t, f'{name}_C')
    rc, log = run(rew_c, nso, out)
    ck(rc == want_rc, f'{name} 返回码 期望 {want_rc} → {rc}')
    if rc != want_rc: print(log[-1500:])
    err = GOLDEN.check(name, rc, nso, out)
    ck(err is None, f'{name} 退出码与全部产物对金样' + (f'：{err}' if err else ''))
    return rc, log, out


def word(img, off):
    return struct.unpack_from('<I', img, off)[0]


def case_a(t, rew_c):
    nso = os.path.join(t, 'a.nso')
    words = {0x1000 + 4 * k: SVC for k in range(480000)}
    words[0x3880000] = SVC
    make(nso, 0x3900000, 0x36E0000, words)
    rc, log, out = one('（a）近布局越线', nso, t, rew_c)
    if rc: return
    h, traps = header(out)
    ck(log.count('整轮按双补丁岛重做') == 1, f'（a）原布局越射程 → 整轮双岛重做一次 → {log.count("整轮按双补丁岛重做")} 次')
    ck('补丁容量不足，重新生成：FRONT 0x100000 → 0x1260000' in log, '（a）前岛 FRONT 0x100000 → 0x1260000 重做一次')
    want = {'PATCH_OFF': '0x6ff0000', 'PATCH2_OFF': '-0x1260000', 'PATCH2_LEN': '0x124f800', 'TRAP_SITES': '0', 'SPIN_UNREACHED': '0'}
    for k, v in want.items(): ck(h.get(k) == v, f'（a）表头 {k} 期望 {v} → {h.get(k)}')
    img = open(os.path.join(out, 'main.patched.bin'), 'rb').read()
    ck(len(img) == 0x6FF0000 + 40 + 0x124F800, f'（a）patched.bin 长 期望 {0x6FF0000 + 40 + 0x124F800:#x} → {len(img):#x}')
    ck(b_off(word(img, 0x1000)) == -0x1261000, f'（a）+0x1000 B 期望 −0x1261000 → {b_off(word(img, 0x1000)):#x}')
    ck(b_off(word(img, 0x3880000)) == 0x3770000, f'（a）+0x3880000 B 期望 0x3770000 → {b_off(word(img, 0x3880000)):#x}')
    last = 0x1000 + 4 * 479999   # 原布局下越线的末一个 svc：双岛后落在前岛 −0x1260000 + 40 × 479999
    ck(last + b_off(word(img, last)) == -0x1260000 + 40 * 479999, f'（a）末个低地址 svc 进前岛 +{40 * 479999:#x}')


def case_c(t, rew_c):
    nso = os.path.join(t, 'c.nso')
    make(nso, 0x8080000, 0x7FDA000, {**B_WORDS, 0x804000C: 0x91002243})
    rc, log, out = one('（c）中段 x18 两岛都够不着 → 远跳', nso, t, rew_c)
    rows = [l.rstrip('\n').split('\t') for l in open(os.path.join(out, 'main.gaps.tsv')) if l.startswith('0x')]
    ck(rows == [], f'（c）远跳后没有缺口 → {rows}')
    ck(os.path.exists(os.path.join(out, 'main.patched.bin')), '（c）出 patched.bin')
    if rc or not os.path.exists(os.path.join(out, 'main.patched.bin')): return
    img = open(os.path.join(out, 'main.patched.bin'), 'rb').read()
    ck(word(img, 0x804000C) == 0xD4340000, f'（c）0x804000c 原字 期望 brk #0xA000（0xd4340000）→ {word(img, 0x804000C):#x}')
    fx = open(os.path.join(out, 'main.fixups.tsv')).read().splitlines()
    n = [l.split('\t')[1] for l in fx if l.startswith('# FAR_JUMPS\t')]
    far = [l.split('\t')[1:] for l in fx if l.startswith('# FAR\t')]
    ent = [f for f in far if f[2] == 'E']; ex = [f for f in far if f[2] == 'X']
    ck(n == ['2'] and len(ent) == 1 and len(ex) == 1, f'（c）# FAR_JUMPS 期望 2（入口 1 / 出口 1）→ {n} {far}')
    if len(ent) == 1 and len(ex) == 1:
        ck(ent[0][0] == '0x804000c' and not (0 <= int(ent[0][1], 16) < 0x8080000), f'（c）入口 期望 0x804000c → 岛里 → {ent[0]}')
        ck(ex[0][1] == '0x8040010' and not (0 <= int(ex[0][0], 16) < 0x8080000), f'（c）出口 期望 岛里 → 0x8040010 → {ex[0]}')


def case_d(t, rew_c):
    # #283 Core Keeper：尾调用 br x18（ldr x18,[x0,#8]; br x18，type 4）两岛都够不着 → 原先记 br_tail 缺口，现在同（c）走远跳。
    #   中段 0x8040020 / 0x8040024 放这两条，0x8040100 / 0x8040104 两条 bl 指到 0x8040020 / 0x8040028，围出只有这两条指令的函数边界
    #   （否则无 FDE 的中段按跳转目标界定函数，会把整段代码段当一个函数解码）。期望：rc 0、没有缺口、br 原位是 brk #0xA000、有一条从 0x8040024 出发的远跳入口
    nso = os.path.join(t, 'd.nso')
    make(nso, 0x8080000, 0x7FDA000, {**B_WORDS, 0x8040020: 0xF9400412, 0x8040024: 0xD61F0240, 0x8040100: 0x97FFFFC8, 0x8040104: 0x97FFFFC9})
    rc, log, out = one('（d）中段尾调用两岛都够不着 → 远跳', nso, t, rew_c)
    rows = [l.rstrip('\n').split('\t') for l in open(os.path.join(out, 'main.gaps.tsv')) if l.startswith('0x')]
    ck(rows == [], f'（d）远跳后没有缺口 → {rows}')
    if rc or not os.path.exists(os.path.join(out, 'main.patched.bin')): return
    img = open(os.path.join(out, 'main.patched.bin'), 'rb').read()
    ck(word(img, 0x8040024) == 0xD4340000, f'（d）0x8040024 原字 期望 brk #0xA000（0xd4340000）→ {word(img, 0x8040024):#x}')
    far = [l.split('\t')[1:] for l in open(os.path.join(out, 'main.fixups.tsv')).read().splitlines() if l.startswith('# FAR\t')]
    ck(any(f[0] == '0x8040024' and f[2] == 'E' and not (0 <= int(f[1], 16) < 0x8080000) for f in far), f'（d）有一条 0x8040024 → 岛里 的远跳入口 → {far}')


B_WORDS = {0x1000: SVC, 0x2000: 0xD53BD045, 0x3000: SPIN[0], 0x3004: SPIN[1],
           0x8040000: 0xD53BD047, 0x8040004: 0xD51BD046, 0x8040008: 0xD53B0020, 0x8040010: SPIN[0], 0x8040014: SPIN[1],
           0x8078000: 0xD53BD049, 0x8078004: SVC, 0x8078010: SPIN[0], 0x8078014: SPIN[1]}


def case_b(t, rew_c):
    nso = os.path.join(t, 'b.nso')
    make(nso, 0x8080000, 0x7FDA000, B_WORDS)
    rc, log, out = one('（b）text > 128 MiB', nso, t, rew_c)
    if rc: return
    h, traps = header(out)
    want = {'PATCH_OFF': '-0x100000', 'IMAGE_SIZE': '0x10060000', 'FILE_IMAGE_LEN': '0x8084000', 'PATCH2_OFF': '0x10060000',
            'TRAP_SITES': '3', 'SPIN_UNREACHED': '1'}
    for k, v in want.items(): ck(h.get(k) == v, f'（b）表头 {k} 期望 {v} → {h.get(k)}')
    tw = [['0x8040000', 'tpidr_r', '7', '0xd53bd047'], ['0x8040004', 'tpidr_w', '6', '0xd51bd046'], ['0x8040008', 'ctr', '0', '0xd53b0020']]
    ck(traps == tw, f'（b）# TRAP 行 期望 {tw} → {traps}')
    img = open(os.path.join(out, 'main.patched.bin'), 'rb').read()
    for off, w in ((0x8040000, 0xD4300000), (0x8040004, 0xD4300020), (0x8040008, 0xD4300040), (0x8040014, SPIN[1])):
        ck(word(img, off) == w, f'（b）+{off:#x} 期望 {w:#010x} → {word(img, off):#010x}')
    for off, d in ((0x1000, -0x101000), (0x2000, -0x101FD8), (0x8078000, 0x7FE8000), (0x8078004, 0x7FE801C)):
        got = b_off(word(img, off))
        ck(got == d, f'（b）+{off:#x} B 期望 {d:#x} → {got:#x}')
    t1 = 0x3004 + b_off(word(img, 0x3004)); t2 = 0x8078014 + b_off(word(img, 0x8078014)); l2 = int(h['PATCH2_LEN'], 16)
    ck(-0x100000 <= t1 < -0x4000, f'（b）前段自旋回边进前岛 → {t1:#x}')
    ck(0x10060000 <= t2 < 0x10060000 + l2, f'（b）后段自旋回边进后岛 → {t2:#x}')
    ck(any(l.startswith('【红】main 自旋区 1 处两个补丁岛都够不着') and '0x8040010' in l for l in log.splitlines()), '（b）日志【红】自旋够不着行列出 0x8040010')


def main():
    rew_c = os.environ.get('REW_C') or subprocess.run([PY, str(ROOT / 'pack/rewriter.py'), 'c-path'], capture_output=True, text=True,
                                                      env=dict(os.environ, S2A_REWRITER='c'), check=True).stdout.strip().splitlines()[-1]
    with tempfile.TemporaryDirectory() as t:
        case_a(t, rew_c)
        case_b(t, rew_c)
        case_c(t, rew_c)
        case_d(t, rew_c)
    for err in GOLDEN.finish():
        ck(False, err)
    print(f'{"✓" if not bad else "✗"} rewrite_islands：{bad} 处不符')
    return 1 if bad else 0


if __name__ == '__main__':
    sys.exit(main())
