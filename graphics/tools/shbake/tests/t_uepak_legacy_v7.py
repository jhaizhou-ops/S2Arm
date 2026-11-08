#!/usr/bin/env python3
# 旧版 pak 5–7 版 + zlib 块单测（10-26 普查：侍魂晓 UE 4.2x 的 pak 是版本 7、zlib，translator/uepak.py 只认版本 4、压缩块一律交游戏自带解码器，
#   shader_split 的旧版 pak 路一支着色器都不收）：合成 pak，约 1 秒，退出 0 = 全过。**完全不含游戏数据**。
# 构造（按 UE FPakInfo / FPakEntry 旧版布局手写，不跑被测实现推期望）：数据区每个文件 = 重复一份 FPakEntry + 各块；索引 = 挂载点 FString、条目数、
#   每文件名 FString + FPakEntry（偏移 / 存储长 / 原长 i64、压缩标志 i32、SHA-1、压缩时块数 + 每块起止 i64、加密 u8、块大小 u32）；
#   尾部 = （版本 7 起）加密密钥 GUID 16 + 加密 u8 + 魔数 + 版本 + 索引偏移 / 长 + SHA-1。版本 < 5 块起止相对文件起点，≥ 5 相对条目起点。
# 覆盖：
#   ① 版本 4 / 5 / 6 / 7 各一个 pak：pak_version 认成旧版、Pak 打开、两块 zlib 文件与未压缩文件逐字节等于原文（不给 decode 也能读）
#   ② 反证：改前口径（LEGACY 只有 4）版本 7 不进旧版 pak 路（11-01 读取器收成一份后 Pak 本身不看 LEGACY）
#   ③ 非 zlib 的旧版压缩（标志 3，LZ5）不给 decode 仍报错，给了才走 decode
#   ④ 无主之地3 的紧凑条目（版本 6：偏移 u64、存储长 / 原长 u32、压缩标志 u8、块表、标志 u8，无 SHA-1 与块大小；数据前重复头同布局）、索引 AES 加密、
#      补齐按 UE 拿索引开头循环填：Pak 认出紧凑布局，标志 4 两块按 64 KiB 交 decode、加密的未压缩文件解回原文；shader_split.legacy_key 从「main」里找出密钥
#      （32 字节常量，过索引 SHA-1）；读完条目多剩 40 字节 → 两种布局都不认、报错
import hashlib, os, struct, sys, tempfile, zlib

H = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', '..', '..'))
sys.path.insert(0, os.path.join(H, 'translator'))
import uepak

T = tempfile.mkdtemp()
fail = n = 0
def ck(ok, what):
    global fail, n
    n += 1; print(('✓ ' if ok else '✗ ') + what); fail += 0 if ok else 1

MAGIC = 0x5A6F12E1
def fstr(s): b = s.encode() + b'\0'; return struct.pack('<i', len(b)) + b
def entry(off, size, raw, flag, blocks, bsz):
    e = struct.pack('<qqqi', off, size, raw, flag) + b'\0' * 20
    if flag: e += struct.pack('<i', len(blocks)) + b''.join(struct.pack('<qq', s, t) for s, t in blocks)
    return e + struct.pack('<BI', 0, bsz)

def make_pak(path, ver, files):
    """files: [(名, 原文, 压缩标志, 块大小, 块编码函数)] → 写 pak"""
    data = bytearray(); idx = []
    for name, raw, flag, bsz, enc in files:
        off = len(data)
        if not flag:
            head = entry(0, len(raw), len(raw), 0, [], 0); data += head + raw; idx.append((name, entry(off, len(raw), len(raw), 0, [], 0))); continue
        chunks = [enc(raw[i:i + bsz]) for i in range(0, len(raw), bsz)]
        hl = len(entry(0, 0, 0, flag, [(0, 0)] * len(chunks), bsz)); blocks, at = [], hl
        for c in chunks: blocks.append((at, at + len(c))); at += len(c)
        size = sum(map(len, chunks))
        if ver < 5: blocks = [(off + s, off + t) for s, t in blocks]
        e = entry(off, size, len(raw), flag, blocks, bsz)
        data += e + b''.join(chunks); idx.append((name, e))
    index = fstr('../../../') + struct.pack('<i', len(idx)) + b''.join(fstr(nm) + e for nm, e in idx)
    ioff = len(data)
    foot = (b'\x11' * 16 if ver >= 7 else b'') + struct.pack('<BIIQQ', 0, MAGIC, ver, ioff, len(index)) + hashlib.sha1(index).digest()
    open(path, 'wb').write(bytes(data) + index + foot)

body = bytes((i * 7 + i // 300) & 0xff for i in range(70000))   # 两块（块大小 65536）
plain = b'not compressed ' * 100
for ver in (4, 5, 6, 7):
    p = os.path.join(T, f'v{ver}.pak')
    make_pak(p, ver, [('Engine/GlobalShaderCache-GLSL_SWITCH.bin', body, 1, 65536, zlib.compress), ('Onion/a.txt', plain, 0, 0, None)])
    with open(p, 'rb') as f: v = uepak.pak_version(f)
    ck(v == ver and v in uepak.LEGACY, f'① 版本 {ver}：认成旧版 pak（读到版本 {v}）')
    try:
        pk = uepak.Pak(p); a = pk.read('Engine/GlobalShaderCache-GLSL_SWITCH.bin'); b = pk.read('Onion/a.txt')
        ck(a == body and b == plain, f'① 版本 {ver}：两块 zlib 文件与未压缩文件逐字节等于原文，不给 decode')
    except Exception as e: ck(False, f'① 版本 {ver}：读失败 {e}')

# ② 反证：改前口径
#   11-01 读取器收成一份（graphics/tools/shbake/unreal_pak.py）后，Pak 按格式认版本、不再看 LEGACY；LEGACY 只决定 shader_split 走不走旧版 pak 路（ue_legacy_jobs：pak_version in LEGACY）。
#   改前口径即「只认版本 4」：版本 7 不进旧版 pak 路
old = uepak.LEGACY; uepak.LEGACY = (4,)
with open(os.path.join(T, 'v7.pak'), 'rb') as f: v = uepak.pak_version(f)
ck(v == 7 and v not in uepak.LEGACY, f'② 改前口径（只认版本 4）：版本 {v} 不进旧版 pak 路')
uepak.LEGACY = old

# ③ 标志 3（LZ5）：只有游戏自带解码器能解
p = os.path.join(T, 'lz5.pak'); fake = lambda b: b'LZ5!' + b
make_pak(p, 4, [('x.uexp', body, 3, 65536, fake)])
pk = uepak.Pak(p)
try: pk.read('x.uexp'); ck(False, '③ LZ5 文件不给 decode 居然读出来了')
except ValueError as e: ck('LZ5' in str(e), f'③ LZ5 文件不给 decode 报错：{e}')
seen = []
got = pk.read('x.uexp', decode=lambda b, k: (seen.append(k), b[4:])[1])
ck(got == body and seen == [65536, len(body) - 65536], f'③ 给了 decode 才走它（每块原长 {seen}）')

# ④ 无主之地3：紧凑条目 + 加密索引（AES-256-ECB，CommonCrypto 加密；期望值 = 拼进去的原文）
import ctypes
def aes_enc(key, data):
    cc = ctypes.CDLL('/usr/lib/libSystem.B.dylib').CCCrypt; out = ctypes.create_string_buffer(len(data)); n = ctypes.c_size_t()
    assert cc(0, 0, 2, key, 32, None, data, len(data), out, len(data), ctypes.byref(n)) == 0; return out.raw[:n.value]
def pad16(b, cyc): k = -len(b) % 16; return b + ((b * 2)[:k] if cyc else bytes(k))
KEY = bytes(range(7, 39))
def compact_pak(path, files, extra=b''):
    """files: [(名, 原文, 压缩?)]；压缩的按 64 KiB 分块、块 = b'CUS!' + 原文（标志 4）；未压缩的加密存（标志 1）"""
    data = bytearray(); idx = b''
    for name, raw, comp in files:
        off = len(data)
        if comp:
            chunks = [b'CUS!' + raw[i:i + 65536] for i in range(0, len(raw), 65536)]
            hl = 8 + 4 + 4 + 1 + 4 + 16 * len(chunks) + 1; blocks, at = b'', hl
            for c in chunks: blocks += struct.pack('<QQ', at, at + len(c)); at += len(c)
            e = struct.pack('<QIIB', off, sum(map(len, chunks)), len(raw), 4) + struct.pack('<I', len(chunks)) + blocks + b'\0'; body = b''.join(chunks)
        else:
            body = aes_enc(KEY, pad16(raw, False)); e = struct.pack('<QIIB', off, len(raw), len(raw), 0) + b'\x01'
        data += e + body; idx += fstr(name) + e
    index = pad16(fstr('../../../') + struct.pack('<i', len(files)) + idx + extra, True)
    foot = struct.pack('<BIIQQ', 1, MAGIC, 6, len(data), len(index)) + hashlib.sha1(index).digest()
    open(path, 'wb').write(bytes(data) + aes_enc(KEY, index) + foot)
p = os.path.join(T, 'bl3.pak'); compact_pak(p, [('Engine/GlobalShaderCache-GLSL_SWITCH.bin', body, True), ('Oak/a.uasset', plain, False)])
main = os.path.join(T, 'main'); open(main, 'wb').write(b'\0' * 4096 + KEY + b'\0' * 4096)   # 「main」：密钥是一段 32 字节常量（pak_crypto 认 NSO 以外的原样镜像）
os.environ.setdefault('DM_GAME', '01006F8002326000')   # shader_split 导入时按 DM_GAME 选配置档；这里只测 legacy_key，选哪款无关
import shader_split
key = shader_split.legacy_key(p, [main], [])
ck(key == KEY, '④ legacy_key 从 main 找出索引加密密钥（过索引 SHA-1）')
seen = []
try:
    pk = uepak.Pak(p, key); got = pk.read('Engine/GlobalShaderCache-GLSL_SWITCH.bin', decode=lambda b, k: (seen.append(k), b[4:])[1]); pl = pk.read('Oak/a.uasset')
    ck(got == body and seen == [65536, len(body) - 65536] and pl == plain, f'④ 紧凑条目：标志 4 两块按 64 KiB 交 decode（{seen}）、加密未压缩文件解回原文')
except Exception as e: ck(False, f'④ 紧凑条目读失败：{e}')
p2 = os.path.join(T, 'bl3x.pak'); compact_pak(p2, [('Oak/a.uasset', plain, False)], extra=b'\7' * 40)
try: uepak.Pak(p2, KEY); ck(False, '④ 读完条目多剩 40 字节居然打开了')
except ValueError as e: ck('条目布局认不出' in str(e), f'④ 读完条目多剩 40 字节：两种布局都不认（{str(e)[-80:]}）')   # 11-01 读取器收成一份后报错为中文「条目布局认不出」

# ⑤ 版本 8（真・女神转生Ⅴ：索引加密，文件尾 0xcc = 4.23+ 带 5 个压缩方式名）：legacy_key 要按解析出的文件尾取索引 SHA-1，原先写死旧式 0x2d 取错位置、密钥永远验不过
idx8 = fstr('../../../') + struct.pack('<i', 1) + fstr('Game/a.uasset') + struct.pack('<qqqI', 0, len(plain), len(plain), 0) + bytes(20) + b'\0' + struct.pack('<I', 0x10000)
ent8 = struct.pack('<qqqI', 0, len(plain), len(plain), 0) + bytes(20) + b'\0' + struct.pack('<I', 0x10000)
data8 = ent8 + plain; index8 = pad16(idx8, True)
foot8 = bytes(16) + b'\1' + struct.pack('<IIQQ', MAGIC, 8, len(data8), len(index8)) + hashlib.sha1(index8).digest() + b''.join(n_.ljust(32, b'\0') for n_ in (b'Zlib', b'', b'', b'', b''))
p8 = os.path.join(T, 'smt5.pak'); open(p8, 'wb').write(data8 + aes_enc(KEY, index8) + foot8)
k8 = shader_split.legacy_key(p8, [main], [])
try: got8 = uepak.Pak(p8, k8).read('Game/a.uasset')
except Exception as e: got8 = repr(e)
ck(k8 == KEY and got8 == plain, f'⑤ 版本 8 加密索引：legacy_key 按文件尾解析取 SHA-1 找出密钥、条目解回原文（密钥对 {k8 == KEY}）')

print(f'旧版 pak 5–8 版 + zlib：{n - fail}/{n} 过')
sys.exit(1 if fail else 0)
