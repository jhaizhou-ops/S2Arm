#!/usr/bin/env python3
# 虚幻 4 控制台变量按名定位：tools/ue_cvar_loc.py <主程序 NSO 或平铺镜像> <名:类型:值>...
#   例：ue_cvar_loc.py main.patched.bin t.MaxFPS:f32:60 r.VSync:i32:0  → 打印帧率表（runtime/fps/<构建号>.tsv）的 w 行，每个名字一行
# 为什么：社区帧率补丁对 UE4 款给的是「某构建号的指针地址」，换版本就失效；变量名字串跨版本不变，按名找到就不依赖构建号。
# 规则（八方2 1.1.1 正对照：t.MaxFPS → main+0x76fef68、r.VSync → main+0x6f017e8，与社区同构建号条目指出的地址一致）：
#   静态变量 TAutoConsoleVariable<T> CVar(TEXT("名"), 缺省, TEXT("帮助"), 标志) 的初始化代码 = adrp/add 把宽字符名字串（UTF-16，老版 UE4 为 UTF-32）放进 x1，
#   紧跟着把帮助文本串（同在只读段）放进 x2 / x3，再把静态对象地址放进某个寄存器，随后 x2 = __dso_handle 挂 atexit；
#   对象 = 帮助文本之后第一个落在 (__dso_handle, .bss 末) 的 8 字节对齐地址（八方2 在 .bss、侍魂晓在已初始化数据段）；
#   对象 +0x10 是 Ref（指向变量值的指针）→ 帧率表写「w main <对象+0x10> <类型> <值> *0」。
#   同一名字串的其他引用（按名查找 / 读值处）中间没有帮助文本串，不算；老式写法（直接调 IConsoleManager::RegisterConsoleVariable、
#   结果存进别的结构，如侍魂晓 r.VSync）不是这条规则，找不到或不止一处 → 退出 1，不猜。
# 段边界从 MOD0 读（.bss 起止）；名字串要求以同宽空字符结尾。只读镜像、不执行游戏代码。
import hashlib, struct, sys
import os as _os, sys as _sys; _sys.path.insert(0, _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), '.')); from nso_plain import plain as _nso_plain   # ZBIC（NSO 标志 0x80）先经 nx_unpack 规整成不压缩段，不各写一份解码（tools/nso_plain.py）

# 防止畸形头导致按文件内地址分配过大内存。
MAX_IMAGE = 512 * 1024 * 1024

def load_image(raw):
    """将 NSO 的 text/ro/data 映射到模块偏移；平铺镜像保持原样。"""
    if raw[:4] != b'NSO0':
        return raw
    if len(raw) < 0x100:
        raise ValueError('NSO 头不完整')
    raw = _nso_plain(raw, 'NSO')
    version, flags = struct.unpack_from('<I', raw, 4)[0], struct.unpack_from('<I', raw, 0xc)[0]
    # 0x40：Switch 2 新出现的标志位，与段解码无关（事实取自 Eden-NS2 加载器，GPL，代码自写：只认 0-5 位与 0x80 ZBIC）；0x80 ZBIC 已在上面经 _nso_plain 解成不压缩段
    if version != 0 or flags & ~0x7f:
        raise ValueError('不支持的 NSO 版本或标志')
    segments = []
    for i in range(3):
        offset, memory, size = struct.unpack_from('<III', raw, 0x10 + i * 0x10)
        stored = struct.unpack_from('<I', raw, 0x60 + i * 4)[0]
        if not flags & (1 << i) and stored != size:
            raise ValueError('NSO 未压缩段长度不匹配')
        if memory + size > MAX_IMAGE or (size and (offset < 0x100 or not stored or offset + stored > len(raw))) or (not size and stored):
            raise ValueError('NSO 段超出输入或映像上限')
        segments.append((offset, stored, memory, size, bool(flags & (1 << i))))
    for i, (offset, stored, start, size, _) in enumerate(segments):
        for other_offset, other_stored, other, other_size, _ in segments[:i]:
            if size and other_size and max(start, other) < min(start + size, other + other_size):
                raise ValueError('NSO 映像段重叠')
            if stored and other_stored and max(offset, other_offset) < min(offset + stored, other_offset + other_stored):
                raise ValueError('NSO 文件段重叠')
    image = bytearray(max(memory + size for _, _, memory, size, _ in segments))
    for i, (offset, stored, memory, size, compressed) in enumerate(segments):
        data = raw[offset:offset + stored]
        if compressed and size:
            try:
                import lz4.block
            except ImportError:
                raise ValueError('压缩 NSO 需要 Python lz4（tools/rewriter-requirements.txt）') from None
            try:
                data = lz4.block.decompress(data, uncompressed_size=size)
            except (ValueError, RuntimeError):
                raise ValueError('NSO 段解压失败') from None
        if len(data) != size:
            raise ValueError('NSO 段长度不匹配')
        if flags & (8 << i) and hashlib.sha256(data).digest() != raw[0xa0 + 32 * i:0xc0 + 32 * i]:
            raise ValueError('NSO 段哈希不匹配')
        image[memory:memory + size] = data
    # 数据段与 BSS 之间可以有对齐空洞；定位器扫描到 BSS 起点为止。
    if len(image) < 8:
        raise ValueError('NSO 映像缺少 MOD0 指针')
    mod = struct.unpack_from('<I', image, 4)[0]
    if mod + 16 > len(image) or image[mod:mod + 4] != b'MOD0':
        raise ValueError('NSO 映像没有有效 MOD0')
    bs = mod + struct.unpack_from('<I', image, mod + 8)[0]
    if bs > MAX_IMAGE:
        raise ValueError('NSO BSS 超出映像上限')
    if bs > len(image):
        image.extend(bytes(bs - len(image)))
    return bytes(image)

def sx(v, n): return v - (1 << n) if (v >> (n - 1)) & 1 else v
def adrp(pc, i): return (pc & ~0xfff) + (sx(((i >> 29) & 3) | (((i >> 5) & 0x7FFFF) << 2), 21) << 12)

RET = 0xD65F03C0


def atexit_obj(b, W, k, be, is_u16str, lo=None):
    """名字串装进 x1 的那条 adrp（字下标 k）→ 静态对象地址或 None。
    对象 = 名字之后第一个 bl（__cxa_atexit(析构, 对象, __dso_handle)；注册本身走 blr）时 x1 的值，这个 bl 不满足就判没找到：要求 x2（__dso_handle）< x1 < .bss 末、8 字节对齐，
    且名字之后、这个 bl 之前出现过帮助文本（x2 / x3 装进只读段 UTF-16 串）——同名字串的按名查找没有帮助文本，不算。
    10-30 根修：旧规则取「帮助文本之后第一个落在 (__dso_handle, .bss 末) 的地址」，没在注册调用（blr）处停，担架拍档 1.0.0（14D7D1537BD5A986）
    把注册后装进对象的虚表地址 0x4dce7e0 当成对象，t.MaxFPS 写出 main+0x4dce7f0（虚表区）；该款对象是「函数开头设的基址寄存器 x23 + 0x768」，
    社区同构建号条目写 [MAIN, 0x5C880D8, 0] = 0x5c87960 + 0x768 + 0x10。所以从所在函数开头（前一个 ret 之后）跟踪寄存器：adrp / add 立即数 /
    mov 寄存器传值，bl / blr 清掉调用者保存的 x0–x18、x30，其余写寄存器的指令把目标记为未知。读不懂（没有 capstone）→ None，不猜。
    11-02 八方旅人 1 代：__dso_handle 经 GOT 取（adrp x2 / ldr x2, [x2, #槽]），x2 的值读不到；这时下界改用读写段起点 lo（MOD0 的 .dynamic），
    对象仍须在 [lo, .bss 末) 且 8 字节对齐"""
    try: import capstone
    except ImportError: return None
    pc = k * 4; st = pc
    for q in range(k - 1, max(k - 0x8000, 0), -1):   # 所在函数起点：往前最近的 ret 之后（最多 128 KB）
        if W[q] == RET: st = (q + 1) * 4; break
    else: st = max(pc - 0x2000, 0)
    md = capstone.Cs(capstone.CS_ARCH_ARM64, capstone.CS_MODE_ARM); md.detail = True; md.skipdata = True
    A = capstone.arm64
    def rn(r):   # capstone 寄存器号 → 0..30（x / w 同号），sp / xzr 等 → None
        n = md.reg_name(r)
        return int(n[1:]) if n and n[0] in 'xw' and n[1:].isdigit() else None
    regs = {}; got = set(); named = helped = False; end = min(pc + 0x400, len(b))   # got：值是从已知地址 ldr 来的寄存器（GOT 槽）
    for i in md.disasm(b[st:end], st):
        ops = i.operands if i.id != 0 else []
        if i.address == pc: named = True
        if i.id == A.ARM64_INS_BL:
            if named:   # 名字之后第一个 bl 定成败
                low = regs[2] if 2 in regs else lo if 2 in got and lo is not None else None
                return regs[1] if helped and 1 in regs and low is not None and low < regs[1] < be and regs[1] % 8 == 0 else None
            for r in list(regs):
                if r <= 18 or r == 30: del regs[r]
            got.difference_update({r for r in got if r <= 18 or r == 30})
            continue
        if i.id == A.ARM64_INS_BLR:
            for r in list(regs):
                if r <= 18 or r == 30: del regs[r]
            got.difference_update({r for r in got if r <= 18 or r == 30})
            continue
        if i.id == 0: continue
        d = rn(ops[0].reg) if ops and ops[0].type == A.ARM64_OP_REG else None
        val = None
        if i.id == A.ARM64_INS_ADRP and len(ops) == 2: val = ops[1].imm
        elif i.id == A.ARM64_INS_ADD and len(ops) == 3 and ops[2].type == A.ARM64_OP_IMM and rn(ops[1].reg) in regs and ops[1].reg not in (A.ARM64_REG_SP,):
            sh = ops[2].shift.value if ops[2].shift.type else 0
            val = regs[rn(ops[1].reg)] + (ops[2].imm << sh)
        elif i.id == A.ARM64_INS_MOV and len(ops) == 2 and ops[1].type == A.ARM64_OP_REG and rn(ops[1].reg) in regs: val = regs[rn(ops[1].reg)]
        gl = i.id == A.ARM64_INS_LDR and len(ops) == 2 and ops[1].type == A.ARM64_OP_MEM and rn(ops[1].mem.base) in regs
        if named and d in (2, 3) and val is not None and is_u16str(val): helped = True
        _, wr = i.regs_access()
        for r in wr:
            x = rn(r)
            if x is not None: regs.pop(x, None); got.discard(x)
        if d is not None and val is not None: regs[d] = val
        if d is not None and gl: got.add(d)
    return None


def locate(b, names):
    m = struct.unpack_from('<I', b, 4)[0]
    magic, _, bs, be = struct.unpack_from('<4sIII', b, m)
    if magic != b'MOD0': raise SystemExit('不是平铺主程序镜像（没有 MOD0）')
    bs += m; be += m; dyn = m + struct.unpack_from('<i', b, m + 4)[0]   # 读写段起点（.dynamic）：经 GOT 取 __dso_handle 时作对象下界
    # 不生成全段 Python 整数元组；big-endian 主机仍按 little-endian 解码。
    if sys.byteorder == 'little':
        W = memoryview(b)[:bs].cast('I')
    else:
        class Words:
            def __len__(self): return bs // 4
            def __getitem__(self, i): return struct.unpack_from('<I', b, i * 4)[0]
        W = Words()
    # TCHAR 宽度两种都认：多数 Switch 版 UE4 是 2 字节（UTF-16），老的是 4 字节（UTF-32，11-02 八方旅人 1 代：名字串只有 UTF-32、
    #   UTF-16 找不到，第二层整张表不写、局内引擎限 30）。名字串与帮助文本同一宽度
    def strs(s):
        out = set()
        for enc, w in (('utf-16-le', 2), ('utf-32-le', 4)):
            n = s.encode(enc) + b'\0' * w; j = b.find(n)
            while j != -1:
                if j % w == 0: out.add(j)
                j = b.find(n, j + 1)
        return out
    def is_u16str(t):   # 帮助文本：只读段里的宽字符可见串（至少 4 字、按字宽对齐；UTF-16 或 UTF-32）
        if t >= bs: return False
        for w in (2, 4):
            s = b[t:t + 4 * w]
            if t % w == 0 and len(s) == 4 * w and all(0x20 <= s[k] < 0x7f and not any(s[k + 1:k + w]) for k in range(0, 4 * w, w)): return True
        return False
    hits = {n: [] for n in names}
    tg = {}
    for n in names:
        for t in strs(n): tg[t] = n
    for k in range(len(W) - 1):
        i = W[k]
        if (i & 0x9F000000) != 0x90000000: continue
        pc = k * 4; rd = i & 31
        if rd != 1: continue
        # 配对的 add x1, x1, #lo 可以不紧跟 adrp：编译器会把装 x2（帮助文本）的 adrp 插在中间（11-02 八方旅人 1 代：adrp x1 / adrp x2 / add x1 / add x2）。
        #   往后看至多 4 条，中间不许有别的指令写 x1
        t = None
        for d in range(1, 5):
            if k + d >= len(W): break
            a = W[k + d]
            if (a & 0xFF800000) == 0x91000000 and ((a >> 5) & 31) == 1 and (a & 31) == 1:
                t = adrp(pc, i) + (((a >> 10) & 0xfff) << (12 * ((a >> 22) & 1))); break
            if (a & 31) == 1 and (a & 0x9F000000) != 0x90000000: break   # 粗判：目标寄存器位是 x1 的非 adrp 指令当作改写 x1，停
            if (a & 0x9F000000) == 0x90000000 and (a & 31) == 1: break
        if t is None: continue
        if t not in tg: continue
        obj = atexit_obj(b, W, k, be, is_u16str, dyn)
        if obj is not None: hits[tg[t]].append((pc, obj + 0x10))
    return hits

def main():
    if len(sys.argv) < 3: raise SystemExit(__doc__ or '用法见文件头')
    try:
        with open(sys.argv[1], 'rb') as f: raw = f.read()
        b = load_image(raw)
        m = struct.unpack_from('<I', b, 4)[0]
        if m + 16 > len(b): raise ValueError('MOD0 超出映像')
        magic, _, bs, be = struct.unpack_from('<4sIII', b, m)
        if (magic != b'MOD0' or m + bs > len(b) or m + bs > m + be
                or (raw[:4] == b'NSO0' and m + be > MAX_IMAGE) or (m + bs) % 4):
            raise ValueError('MOD0 或 BSS 范围无效')
    except (OSError, ValueError, struct.error) as e:
        raise SystemExit(str(e)) from None
    specs = [a.split(':') for a in sys.argv[2:]]
    hits = locate(b, [s[0] for s in specs]); rc = 0
    for n, ty, val in specs:
        h = sorted(set(o for _, o in hits[n]))
        if len(h) != 1:
            print(f'# {n}：{"没找到注册处" if not h else "多处注册 " + " ".join(map(hex, h))}，不写', file=sys.stderr); rc = 1; continue
        print(f'w main {h[0]:#x} {ty} {val} *0   # {n}（按名定位：注册处 main+{hits[n][0][0]:#x}）')
    sys.exit(rc)

if __name__ == '__main__': main()
