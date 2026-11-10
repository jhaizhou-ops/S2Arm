#!/usr/bin/env python3
"""改写器读 .eh_frame 的绝对指针编码（#286，程序号 01E6A672A8800000，Windows 出包「改写失败：不支持 EH 编码 0」）：REW=<C 改写器> python3 tests/rewrite_eh_absptr_test.py
CIE 没写 R 增强时 FDE 指针按缺省编码 0（DW_EH_PE_absptr，AArch64 上 8 字节绝对地址）存；位置无关映像里这个槽由装载器按
R_AARCH64_RELATIVE 填——lld 缺省原位留 0、加数只在 RELA 表里，GNU ld 原位也写加数。改写器按 .eh_frame 定函数范围（内嵌数据判定、
函数起点），读错就把函数范围算歪。
合成模块：两个不相邻的函数 A=[0x100,0x140)、B=[0x200,0x240)，A 里一条 hvc #0（异常类指令 → 改写器打「函数范围 N 段」）。
期望按输入手写、不跑被测实现：函数范围 2 段（两段不相邻、不合并），退出码与 pcrel sdata4（0x1B，常见写法）对照相同。
  ① 对照：CIE「zR」R=0x1B → 2 段
  ② absptr、原位写地址（GNU ld 写法）→ 2 段
  ③ absptr、原位 0、地址只在 RELA 的 R_AARCH64_RELATIVE 加数里（lld 写法）→ 2 段（只读原位会把两个函数都当成从 0 开始，塌成 1 段）
旧代码反证：同一测试对 origin/main 的改写器 → ②③ 退出 1、报「不支持 EH 编码 0」"""
import os, re, struct, subprocess, sys, tempfile

REW = os.environ['REW']
RET, HVC, NOP = 0xd65f03c0, 0xd4000002, 0xd503201f
FUNCS = [(0x100, 0x40), (0x200, 0x40)]
bad = 0


def chk(name, want, got):
    global bad
    ok = want == got; bad += not ok; print(f'{"通" if ok else "不通"} {name}：期望 {want!r} → 真结果 {got!r}')


def nso(path, enc, inplace):
    """enc = CIE 的 R 编码（0x1B / 0x00）；inplace = absptr 时原位写地址（True）还是写 0 并在 RELA 里给加数（False）"""
    tsz = 0x1000
    text = bytearray(tsz); struct.pack_into('<II', text, 0, 0x14000040, tsz)
    for fa, fl in FUNCS:
        struct.pack_into('<%dI' % (fl // 4), text, fa, *([NOP] * (fl // 4 - 1) + [RET]))
    struct.pack_into('<I', text, FUNCS[0][0] + 8, HVC)
    psz = 8 if enc == 0 else 4
    fde_len = 4 + 2 * psz + 1          # CIE 指针 + pc_begin + pc_range + 增强长度（0）
    fde_sz = (4 + fde_len + 3) & ~3
    nf = len(FUNCS); EH = 0x100; TB = EH + 12; EF = (TB + 8 * nf + 15) & ~15
    cie = struct.pack('<II', 0x14, 0) + bytes([1]) + b'zR\0' + bytes([4, 0x78, 30, 1, enc]) + bytes(7)
    rosz = 0x1000
    ro = bytearray(rosz)
    dyn = 0x800                         # 动态段放在 ro 段里（映像地址 tsz + dyn）
    struct.pack_into('<4sIIIii', ro, 0, b'MOD0', dyn, 0, 0, EH, EH + 0x20)
    struct.pack_into('<BBBBiI', ro, EH, 1, 0x1B, 0x03, 0x3B, (tsz + EF) - (tsz + EH + 4), nf)
    ro[EF:EF + len(cie)] = cie
    rela = []
    for k, (fa, fl) in enumerate(FUNCS):
        off = EF + len(cie) + fde_sz * k; f = tsz + off
        struct.pack_into('<II', ro, off, fde_len, (f + 4) - (tsz + EF))
        if enc == 0:
            struct.pack_into('<QQ', ro, off + 8, fa if inplace else 0, fl)
            if not inplace:
                rela.append((f + 8, fa))
        else:
            struct.pack_into('<ii', ro, off + 8, fa - (f + 8), fl)
        struct.pack_into('<ii', ro, TB + 8 * k, fa - (tsz + EH), f - (tsz + EH))
    RT = 0x900                          # RELA 表（映像地址 tsz + RT）
    for k, (o, a) in enumerate(rela):
        struct.pack_into('<QQq', ro, RT + 24 * k, o, 1027, a)
    struct.pack_into('<QQQQQQ', ro, dyn, 7, tsz + RT, 8, 24 * len(rela), 0, 0)
    segs = ((0, bytes(text)), (tsz, bytes(ro)), (tsz + rosz, bytes(0x1000)))
    h = bytearray(0x100); h[:4] = b'NSO0'
    for k, (mo, seg) in enumerate(segs):
        struct.pack_into('<III', h, 0x10 + 0x10 * k, 0x100 + sum(len(s[1]) for s in segs[:k]), mo, len(seg)); struct.pack_into('<I', h, 0x60 + 4 * k, len(seg))
    h[0x40:0x50] = bytes(range(16))
    open(path, 'wb').write(bytes(h) + b''.join(s[1] for s in segs))


def run(enc, inplace=True):
    with tempfile.TemporaryDirectory() as t:
        src = os.path.join(t, 'main'); nso(src, enc, inplace)
        r = subprocess.run([REW, src, os.path.join(t, 'o'), 'main'], capture_output=True, text=True, timeout=120, env=dict(os.environ, S2A_TARGET='ios'))
        out = r.stdout + r.stderr
        m = re.search(r'函数范围 (\d+) 段', out)
        if r.returncode not in (0, 3):
            print('    | ' + '\n    | '.join(out.strip().splitlines()[-3:]))
        return r.returncode, int(m[1]) if m else None


base = run(0x1B)
chk('① 对照 pcrel sdata4（0x1B）：函数范围 2 段', 2, base[1])
chk('② absptr、原位写地址（GNU ld）：退出码同对照、函数范围 2 段', (base[0], 2), run(0x00, inplace=True))
chk('③ absptr、原位 0 + RELA 加数（lld）：退出码同对照、函数范围 2 段', (base[0], 2), run(0x00, inplace=False))
print(f'rewrite_eh_absptr：{3 - bad}/3 通过'); sys.exit(1 if bad else 0)
