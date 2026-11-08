#!/usr/bin/env python3
"""pack/gamedec（游戏自带解码器的跨平台工具模式，ARMeilleure 执行游戏 main 里的解码函数）单测，不用游戏文件：python3 tests/gamedec_test.py
夹具：手写一个最小 NSO（段不压缩；MOD0 → 动态段 → 符号表 / JUMP_SLOT 重定位），按名导出三个函数，指令按 ARM64 编码手写：
  LZ5_decompress_safe(src, dst, csz, max)：先 malloc(0x80000)，回空就返回 -1；再 free、经导入 memcpy(dst, src, csz) 拷过去、返回 csz（= 恒等「解码器」）
  malloc：mov x0, #0; ret——同游戏静态链进 main 的 malloc 在 SDK 初始化前回空（11-05 勇者斗恶龙 XI S：LZ5 头一件事 malloc 512 KB，回空即 -1）
  free：ret；memcpy：未定义的导入（GOT 一项，JUMP_SLOT）
期望（手算，不跑被测实现推）：恒等解码 → 每块解出 = 输入原样
  ① --verify：3 块（1 / 4096 / 100000 字节）逐字节相同、退 0（证明 main 自带的 malloc 被接管、导入 memcpy 接到工具实现）
  ② DM_OODLE_SERVE=1 服务模式：2 个请求各回 u64 原长 + 原样字节；stdin 关掉后进程 10 秒内自己退出、退 0（11-05 天眼：解完进程不退）
  ③ RELR 夹具（11-05 普查 c1105_r4 轩辕剑柒 main 用 DT_RELR，gamedec 原先抛「还没实现」）：malloc / free 不再直接 bl，改经数据段两个函数指针槽 ldr + blr，
     槽里原值 = 函数在模块里的偏移，只由 DT_RELR 重定位（一个地址项改 FREE 槽、一个位图项第 1 位改紧跟的 MALLOC 槽）：装载基址 0x0800_0000 加上去才跳得对，
     没展开或没加基址就跳到未映射的低地址 → 执行失败；期望同 ①（3 块逐字节相同、退 0）"""
import os, struct, subprocess, sys, tempfile
from pathlib import Path

R = Path(__file__).resolve().parents[1]
bad = 0
def chk(name, want, got):
    global bad
    ok = want == got; bad += not ok
    print(f'{"通" if ok else "不通"} {name}：期望 {want!r} → 真结果 {got!r}')

LZ5, MALLOC, FREE, GOT = 0x100, 0x200, 0x210, 0x1800
FREE_P, MALLOC_P, RELR = 0x1808, 0x1810, 0x1320   # RELR 夹具：两个函数指针槽（数据段）、RELR 表（只读段，JMPREL 之后）
def bl(pc, to): return 0x94000000 | ((to - pc) // 4 & 0x3ffffff)
def code(relr=False):
    w = {}; pc = LZ5
    def emit(x):
        nonlocal pc; w[pc] = x; pc += 4
    def call(fn, slot):   # 直接 bl，或（RELR 夹具）ldr x16, <槽>；blr x16
        if not relr: emit(bl(pc, fn)); return
        emit(0x58000000 | ((slot - pc) // 4 & 0x7ffff) << 5 | 16); emit(0xD63F0200)
    emit(0xF81F0FFE)                  # str x30, [sp, #-16]!
    emit(0xAA0003E9); emit(0xAA0103EA); emit(0x2A0203EB)   # mov x9, x0；mov x10, x1；mov w11, w2
    emit(0xD2A00100)                  # movz x0, #0x8, lsl #16（0x80000）
    call(MALLOC, MALLOC_P)
    fail_at = pc; emit(0)             # cbz x0, fail（下面回填）
    call(FREE, FREE_P)
    emit(0xAA0A03E0); emit(0xAA0903E1); emit(0x2A0B03E2)   # mov x0, x10；mov x1, x9；mov w2, w11
    emit(0x58000000 | ((GOT - pc) // 4 & 0x7ffff) << 5 | 16)   # ldr x16, GOT（memcpy）
    emit(0xD63F0200)                  # blr x16
    emit(0x2A0B03E0)                  # mov w0, w11
    emit(0xF84107FE); emit(0xD65F03C0)                     # ldr x30, [sp], #16；ret
    w[fail_at] = 0xB4000000 | ((pc - fail_at) // 4 & 0x7ffff) << 5   # cbz x0 → fail
    emit(0x12800000)                  # fail: movn w0, #0（-1）
    emit(0xF84107FE); emit(0xD65F03C0)
    w[MALLOC], w[MALLOC + 4] = 0xD2800000, 0xD65F03C0      # malloc：mov x0, #0；ret
    w[FREE] = 0xD65F03C0                                   # free：ret
    return w

def nso(relr=False):
    img = bytearray(0x1820)
    for a, x in code(relr).items(): struct.pack_into('<I', img, a, x)
    struct.pack_into('<I', img, 4, 0x1000)                 # 映像 +4：MOD0 偏移
    img[0x1000:0x1004] = b'MOD0'; struct.pack_into('<6i', img, 0x1004, 0x40, 0x810, 0x810, 0, 0, 0)   # 动态段在 MOD0+0x40；bss / eh_frame_hdr 不用
    names = [b'', b'LZ5_decompress_safe', b'malloc', b'free', b'memcpy']
    strtab, offs = b'\0', []
    for n in names[1:]: offs.append(len(strtab)); strtab += n + b'\0'
    SYM = 0x1100; STR = SYM + 24 * len(names)
    syms = [(0, 0, 0, 0)] + [(offs[0], 1, LZ5, 0x60), (offs[1], 1, MALLOC, 8), (offs[2], 1, FREE, 4), (offs[3], 0, 0, 0)]
    for i, (no, shndx, val, size) in enumerate(syms): struct.pack_into('<IBBHQQ', img, SYM + 24 * i, no, 0x12 if shndx else 0, 0, shndx, val, size)
    img[STR:STR + len(strtab)] = strtab
    struct.pack_into('<QQQ', img, 0x1300, GOT, 4 << 32 | 1026, 0)   # R_AARCH64_JUMP_SLOT memcpy
    dyn = [(6, SYM), (5, STR), (10, len(strtab)), (11, 24), (23, 0x1300), (2, 24)]   # SYMTAB STRTAB STRSZ SYMENT JMPREL PLTRELSZ
    if relr:   # 槽里放模块内偏移（RELR 的加数就是槽里原值）；表：地址项 FREE_P（游标随后到 FREE_P + 8 = MALLOC_P）、位图项第 1 位 → 游标后第 0 字 = MALLOC_P
        struct.pack_into('<QQ', img, FREE_P, FREE, MALLOC); struct.pack_into('<QQ', img, RELR, FREE_P, 1 | 1 << 1)
        dyn += [(36, RELR), (35, 16), (37, 8)]   # DT_RELR DT_RELRSZ DT_RELRENT
    dyn.append((0, 0))
    for i, (t, v) in enumerate(dyn): struct.pack_into('<qQ', img, 0x1040 + 16 * i, t, v)
    segs = [(0x100, 0, 0x1000), (0x1100, 0x1000, 0x800), (0x1900, 0x1800, 0x20)]
    h = bytearray(0x100); h[:4] = b'NSO0'
    for i, (fo, mo, sz) in enumerate(segs): struct.pack_into('<III', h, 0x10 + 0x10 * i, fo, mo, sz); struct.pack_into('<I', h, 0x60 + 4 * i, sz)
    out = bytearray(h) + bytearray(0x1920 - 0x100)
    for fo, mo, sz in segs: out[fo:fo + sz] = img[mo:mo + sz]
    return bytes(out)

with tempfile.TemporaryDirectory() as t:
    t = Path(t); (t / 'root/exefs').mkdir(parents=True); (t / 'root/exefs/main').write_bytes(nso())
    b = subprocess.run(['bash', str(R / 'tools/mem_admit.sh'), 'dotnet', 'gamedec_test', '--', 'dotnet', 'build', str(R / 'pack/gamedec/gamedec.csproj'), '-c', 'Release',
                        '-nologo', '-v', 'q', '-o', str(t / 'bin')] if os.name != 'nt' else
                       ['dotnet', 'build', str(R / 'pack/gamedec/gamedec.csproj'), '-c', 'Release', '-nologo', '-v', 'q', '-o', str(t / 'bin')], capture_output=True, text=True,
                       env=dict(os.environ, S2A_MEM_DIR=str(t / 'mem'), S2A_MEM_LOCK=str(t / 'mem.flock')))   # 内存准入记私有账本：门禁步里不许写共享账本（mem_admit ⑯）
    chk('编出 gamedec', 0, b.returncode)
    if b.returncode: print((b.stdout + b.stderr)[-1500:]); sys.exit(1)
    tool = ['dotnet', str(t / 'bin/gamedec.dll')]
    ref = t / 'ref'; ref.mkdir(); rows = []
    for i, n in enumerate((1, 4096, 100000)):
        c = bytes((k * 7 + i) & 255 for k in range(n)); (ref / f'{i}.c').write_bytes(c); (ref / f'{i}.r').write_bytes(c); rows.append(f'{i}\t{n}\t{n}\t夹具')
    (ref / 'index.tsv').write_text('\n'.join(rows) + '\n', encoding='utf-8')
    v = subprocess.run([*tool, '--verify', str(t / 'root'), str(ref)], capture_output=True, text=True, timeout=120)
    chk('① --verify：3 块逐字节相同、退 0', (0, True), (v.returncode, '3 块逐字节相同、0 块不同' in v.stdout))
    if v.returncode: print((v.stdout + v.stderr)[-1500:])
    reqs = [b'hello gamedec', bytes(range(256)) * 300]
    p = subprocess.Popen([*tool, str(t / 'root')], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=dict(os.environ, DM_OODLE_SERVE='1'))
    got = []
    for c in reqs:
        p.stdin.write(struct.pack('<QQ', len(c), len(c)) + c); p.stdin.flush()
        n, = struct.unpack('<Q', p.stdout.read(8)); got.append(p.stdout.read(n))
    p.stdin.close()
    try: rc = p.wait(timeout=10)
    except subprocess.TimeoutExpired: p.kill(); p.wait(); rc = '10 秒没退出'
    chk('② 服务模式：两个请求原样解回（长度）', [len(c) for c in reqs], [len(g) for g in got]); chk('② 服务模式：字节与请求相同', True, got == reqs)
    chk('② stdin 关掉后自己退出、退 0', 0, rc)
    (t / 'relr/exefs').mkdir(parents=True); (t / 'relr/exefs/main').write_bytes(nso(relr=True))
    try: v = subprocess.run([*tool, '--verify', str(t / 'relr'), str(ref)], capture_output=True, text=True, timeout=60); got = (v.returncode, '3 块逐字节相同、0 块不同' in v.stdout)
    except subprocess.TimeoutExpired: v, got = None, ('60 秒没退出（槽没按基址改，跳进了别处）', False)
    chk('③ RELR 夹具 --verify：3 块逐字节相同、退 0', (0, True), got)
    if v is not None and v.returncode: print((v.stdout + v.stderr)[-1500:])

print(f'{"✓" if not bad else "✗"} gamedec：{bad} 不通')
sys.exit(1 if bad else 0)
