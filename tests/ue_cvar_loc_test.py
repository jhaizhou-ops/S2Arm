# tools/ue_cvar_loc.py 合成镜像单测（期望值按镜像布局手算，不跑被测实现推导）
import hashlib, os, struct, subprocess, sys, tempfile
H = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
def adrp(pc, t, rd): imm = ((t & ~0xfff) - (pc & ~0xfff)) >> 12; return 0x90000000 | (imm & 3) << 29 | ((imm >> 2) & 0x7FFFF) << 5 | rd
def add(rd, rn, imm): return 0x91000000 | imm << 10 | rn << 5 | rd
BL = 0x94000000; BLR8 = 0xD63F0100; RET = 0xD65F03C0
def mov(rd, rm): return 0xAA0003E0 | rm << 16 | rd   # mov xd, xm（orr xd, xzr, xm）
img = bytearray(0x10000)
struct.pack_into('<I', img, 4, 0x100)
struct.pack_into('<4sIII', img, 0x100, b'MOD0', 0, 0x9000 - 0x100, 0xC000 - 0x100)   # .bss 0x9000–0xC000
def put(off, s): img[off:off + 2 * len(s) + 2] = s.encode('utf-16-le') + b'\0\0'
put(0x4000, 't.MaxFPS'); put(0x4100, 'Caps the frame rate'); put(0x4200, 'r.VSync'); put(0x4300, 'Use vsync')
def code(pc, ins):
    for n, i in enumerate(ins): struct.pack_into('<I', img, pc + 4 * n, i(pc + 4 * n) if callable(i) else i)
DSO = 0x8000   # __dso_handle（数据段）
# 例 1：TAutoConsoleVariable 静态初始化，对象在 .bss 0x9058（__cxa_atexit(析构, 对象, __dso_handle) 的 x1）→ 期望 0x9068
code(0x1000, [lambda p: adrp(p, 0x4000, 1), add(1, 1, 0x000), lambda p: adrp(p, 0x4100, 2), add(2, 2, 0x100),
              lambda p: adrp(p, 0x9058, 19), add(19, 19, 0x058), mov(1, 19), lambda p: adrp(p, DSO, 2), add(2, 2, 0), BL])
# 例 1 的干扰：同名字串的按名查找（x1 = 名字后直接是 .bss 结构、x2 也装数据地址，但没有帮助文本）→ 不算
code(0x1100, [lambda p: adrp(p, 0x4000, 1), add(1, 1, 0x000), lambda p: adrp(p, 0x9400, 8), add(8, 8, 0x400), lambda p: adrp(p, DSO, 2), add(2, 2, 0), BL])
# 例 2：对象在已初始化数据段 0x8800（≥ __dso_handle、.bss 之前），帮助文本在 x3 → 期望 0x8810
code(0x1200, [lambda p: adrp(p, 0x4200, 1), add(1, 1, 0x200), lambda p: adrp(p, 0x4300, 3), add(3, 3, 0x300),
              lambda p: adrp(p, 0x8800, 20), add(20, 20, 0x800), mov(1, 20), lambda p: adrp(p, DSO, 2), add(2, 2, 0), BL])
# 例 3（10-30 担架拍档形态）：函数开头 x23 = .bss 基址 0x9800，中间隔一次别的调用（bl 不清 x19–x28）；注册经 blr x8，之后把虚表地址
#   0x8C00+0x10（数据段，落在 __dso_handle 与 .bss 末之间）装进 x8 存进对象——旧规则会把虚表当对象写出 0x8c10；
#   对象 = x23 + 0x768 = 0x9F68，atexit 时 x1 = 它 → 期望 0x9F78
put(0x4400, 'r.DynamicRes.FrameTimeBudget'); put(0x4500, 'Frame time budget in ms')
code(0x1300, [RET, lambda p: adrp(p, 0x9800, 23), add(23, 23, 0x800), BL,
              lambda p: adrp(p, 0x4400, 1), add(1, 1, 0x400), lambda p: adrp(p, 0x4500, 2), add(2, 2, 0x500), BLR8,
              lambda p: adrp(p, 0x8C00, 8), add(8, 8, 0xC00), add(8, 8, 0x10), add(19, 23, 0x768),
              lambda p: adrp(p, 0x0100, 0), add(0, 0, 0x100), lambda p: adrp(p, DSO, 2), add(2, 2, 0), mov(1, 19), BL])
f = tempfile.NamedTemporaryFile(delete=False, suffix='.bin'); f.write(img); f.close()
def run(*a): r = subprocess.run([sys.executable, H + '/tools/ue_cvar_loc.py', f.name, *a], capture_output=True, text=True); return r.returncode, r.stdout
bad = 0
def chk(name, got, want):
    global bad; ok = got == want; bad |= not ok; print(('过 ' if ok else '没过 ') + f'{name}：期望 {want!r} → 真结果 {got!r}')
rc, out = run('t.MaxFPS:f32:60', 'r.VSync:i32:0', 'r.DynamicRes.FrameTimeBudget:f32:16.6667')
rows = [l.split('#')[0].strip() for l in out.splitlines()]
chk('.bss 对象 +0x10、干扰引用不算', rows[0] if rows else '', 'w main 0x9068 f32 60 *0')
chk('.data 对象 +0x10（x3 帮助文本）', rows[1] if len(rows) > 1 else '', 'w main 0x8810 i32 0 *0')
chk('基址寄存器 + 偏移的对象（担架拍档形态，注册走 blr、之后装虚表）→ 对象 +0x10、不取虚表', rows[2] if len(rows) > 2 else '', 'w main 0x9f78 f32 16.6667 *0')
chk('都找到退出 0', rc, 0)
rc, out = run('t.Missing:f32:60')
chk('找不到不写、退出 1', (rc, out), (1, ''))
# NSO 的文件段顺序不同于内存位置，并在 text 与 ro 之间留空洞。
def literal_lz4(data):
    length = len(data) - 15
    return b'\xf0' + b'\xff' * (length // 255) + bytes([length % 255]) + data
def make_nso(compressed):
    head = bytearray(0x100); head[:4] = b'NSO0'
    struct.pack_into('<I', head, 0xc, 7 if compressed else 0)
    payload = bytearray()
    for i, (mem, size) in enumerate(((0, 0x2000), (0x4000, 0x4000), (0x8000, 0x1000))):
        raw = bytes(img[mem:mem + size]); data = literal_lz4(raw) if compressed else raw
        struct.pack_into('<III', head, 0x10 + i * 0x10, 0x100 + len(payload), mem, size)
        struct.pack_into('<I', head, 0x60 + i * 4, len(data))
        payload.extend(data)
    return head + payload
def run_input(data):
    with tempfile.NamedTemporaryFile() as x:
        x.write(data); x.flush()
        return subprocess.run([sys.executable, H + '/tools/ue_cvar_loc.py', x.name, 't.MaxFPS:f32:60'], capture_output=True, text=True)
plain = make_nso(False)
result = run_input(plain)
chk('未压缩 NSO 按内存偏移映射', (result.returncode, result.stdout.split('#')[0].strip()), (0, 'w main 0x9068 f32 60 *0'))
try:
    import lz4.block
except ImportError:
    result = run_input(make_nso(True))
    chk('缺 lz4 明确报错', (result.returncode, '需要 Python lz4' in result.stderr), (1, True))
else:
    result = run_input(make_nso(True))
    chk('压缩 NSO 按内存偏移映射', (result.returncode, result.stdout.split('#')[0].strip()), (0, 'w main 0x9068 f32 60 *0'))
hashed = plain[:]
struct.pack_into('<I', hashed, 0xc, 8)
hashed[0xa0:0xc0] = hashlib.sha256(hashed[0x100:0x2100]).digest()
result = run_input(hashed)
chk('有效 NSO 段哈希', result.returncode, 0)
bad_hash = hashed[:]; bad_hash[0x100] ^= 1
file_overlap = plain[:]; struct.pack_into('<I', file_overlap, 0x20, 0x100)
bad_version = plain[:]; struct.pack_into('<I', bad_version, 4, 1)
# Switch 2 头标志 0x40 与段解码无关（Splatoon Raiders main 为 0x7f）→ 照常读；0x80 = 段压缩方式是 ZBIC（事实取自 Eden-NS2）：经 tools/nso_plain.py 交 nx_unpack 解（tests/nso_plain_test.sh 测）；这里拒绝不认识的 0x100
s2_flag = plain[:]; struct.pack_into('<I', s2_flag, 0xc, 0x40)
result = run_input(s2_flag)
chk('Switch 2 标志 0x40 照常读', (result.returncode, result.stdout.split('#')[0].strip()), (0, 'w main 0x9068 f32 60 *0'))
bad_flags = plain[:]; struct.pack_into('<I', bad_flags, 0xc, 0x100)
for name, malformed in [('截断', plain[:300]), ('短头', b'NSO0'), ('重叠', plain[:]),
                        ('文件段重叠', file_overlap), ('哈希错误', bad_hash),
                        ('未知版本', bad_version), ('未知标志', bad_flags)]:
    if name == '重叠': struct.pack_into('<I', malformed, 0x24, 0x1000)
    result = run_input(malformed)
    chk('拒绝坏 NSO ' + name, (result.returncode != 0, 'Traceback' not in result.stderr), (True, True))
# 例 4（11-02 八方旅人 1 代形态）：TCHAR 4 字节（名字 / 帮助文本都是 UTF-32）；adrp x1 与 add x1 中间插着装 x2 的 adrp；
#   __dso_handle 经 GOT 取（adrp x2 / ldr x2, [x2, #槽]，值读不到）→ 下界取 MOD0 的 .dynamic（本镜像 MOD0 动态段偏移 0x7F00 → 0x8000）。
#   对象 = x22 + 0x5d8，x22 = 0x9000 → 0x95D8，期望写 0x95E8；同形态但对象落在 .dynamic 之下（0x7000）→ 不写
img4 = bytearray(0x10000); struct.pack_into('<I', img4, 4, 0x100)
struct.pack_into('<4siII', img4, 0x100, b'MOD0', 0x8000 - 0x100, 0x9000 - 0x100, 0xC000 - 0x100)
def put32(off, s): img4[off:off + 4 * len(s) + 4] = s.encode('utf-32-le') + b'\0' * 4
put32(0x4000, 't.MaxFPS'); put32(0x4100, 'Caps the frame rate'); put32(0x4300, 'r.VSync'); put32(0x4400, 'Use vsync')
def ldr(rt, rn, off): return 0xF9400000 | (off // 8) << 10 | rn << 5 | rt
def code4(pc, ins):
    for n, i in enumerate(ins): struct.pack_into('<I', img4, pc + 4 * n, i(pc + 4 * n) if callable(i) else i)
code4(0x1000, [RET, lambda p: adrp(p, 0x9000, 22), add(22, 22, 0),
               lambda p: adrp(p, 0x4000, 1), lambda p: adrp(p, 0x4100, 2), add(1, 1, 0x000), add(2, 2, 0x100), BLR8,
               add(19, 22, 0x5d8), lambda p: adrp(p, 0x8000, 2), ldr(2, 2, 0x10), mov(1, 19), BL])
code4(0x1100, [RET, lambda p: adrp(p, 0x7000, 22), add(22, 22, 0),
               lambda p: adrp(p, 0x4300, 1), lambda p: adrp(p, 0x4400, 2), add(1, 1, 0x300), add(2, 2, 0x400), BLR8,
               add(19, 22, 0), lambda p: adrp(p, 0x8000, 2), ldr(2, 2, 0x10), mov(1, 19), BL])
g = tempfile.NamedTemporaryFile(delete=False, suffix='.bin'); g.write(img4); g.close()
r4 = subprocess.run([sys.executable, H + '/tools/ue_cvar_loc.py', g.name, 't.MaxFPS:f32:60', 'r.VSync:i32:0'], capture_output=True, text=True)
rows4 = [l.split('#')[0].strip() for l in r4.stdout.splitlines() if l.split('#')[0].strip()]
chk('UTF-32 名字、adrp/add 中间插指令、__dso_handle 经 GOT → 对象 +0x10；对象在 .dynamic 之下的不写', rows4, ['w main 0x95e8 f32 60 *0'])
os.unlink(g.name)
os.unlink(f.name); sys.exit(1 if bad else 0)
