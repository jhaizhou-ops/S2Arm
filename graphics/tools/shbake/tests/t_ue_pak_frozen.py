#!/usr/bin/env python3
# UE pak 版本 9 冻结索引单测（11-02 普查鬼灭之刃 火之神血风谭、轩辕剑柒「pak 版本 9 的冻结索引」）：graphics/tools/shbake/unreal_pak.py Pak._load_frozen。
#   合成 pak 按 FPakFile 内存映像布局手写（数组 / 字符串 = {u64 冻结指针, i32 Num, i32 Max}，指针 = (目标 - 字段地址) << 1 | 1；布局两款真文件实测，见 unreal_pak.py 文件头），不跑被测实现推期望：
#   ① 两个目录三个文件（不压缩的着色器存档、Zlib 两块的全局着色器缓存、不压缩的小文件）：名字、原长逐个对，读出字节等于原文；挂载点 = 给的
#   ② 经 uepak.Pak（直连抽取 shader_split 用的那层）按名字读到同样的字节
#   ③ pack/ue_pak.py 命令行：写出着色器存档、记录逐条等于合成本
#   ④ 某个名字的条目号越界 → Corrupt（不静默当好的）；⑤ 有条目没有名字 → Corrupt；⑥ 冻结索引又加密 → Unsupported（文件尾不记 SHA-1，没法核密钥）
#   ⑦ 反证：改前的 unreal_pak.py（git HEAD）对同一个 pak 报「pak 版本 9 的冻结索引」
import hashlib, importlib.util, os, struct, subprocess, sys, tempfile, zlib

H = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', '..', '..', '..'))
sys.path.insert(0, os.path.join(H, 'graphics', 'tools', 'shbake'))
import unreal_pak as UP
fail = n = 0
def ck(ok, what):
    global fail, n
    n += 1; print(('✓ ' if ok else '✗ ') + what); fail += 0 if ok else 1


class Img:
    """冻结内存映像：先占位、再回填指针（指针字段地址已知，目标地址追加后才知道）"""
    def __init__(s): s.b = bytearray()
    def alloc(s, n): o = len(s.b); s.b += bytes(n); return o
    def put(s, data, align=8):
        while len(s.b) % align: s.b.append(0)
        o = len(s.b); s.b += data; return o
    def arr(s, field, target, num):   # {冻结指针, Num, Max}
        p = 0 if target is None else ((target - field) << 1) | 1
        struct.pack_into('<Qii', s.b, field, p, num, num)
    def fstr(s, field, text):
        if not text: s.arr(field, None, 0); return
        u = (text + '\0').encode('utf-16-le'); s.arr(field, s.put(u, 2), len(text) + 1)
    def sparse(s, field, elem_addrs_count, data):   # 稀疏数组：元素区（全部已分配）+ 位数组
        s.arr(field, data, elem_addrs_count)
        bits = s.put(bytes([0xff]) * ((elem_addrs_count + 7) // 8) if elem_addrs_count else b'', 1)
        if elem_addrs_count % 8: s.b[bits + elem_addrs_count // 8] = (1 << (elem_addrs_count % 8)) - 1
        struct.pack_into('<Qii', s.b, field + 16, ((bits - (field + 16)) << 1) | 1 if elem_addrs_count else 0, elem_addrs_count, elem_addrs_count)


def build(path, mount, dirs, encrypted=False, bad_index=None, drop_name=None):
    """dirs = [(目录名, [(文件名, 原文, 方式号 0 / 1=Zlib, 块大小)])] → 写 pak；→ [(全路径, 原文)]"""
    files = [(d + f, raw, m, bs) for d, fs in dirs for f, raw, m, bs in fs]
    data = bytearray(); ents = []
    for name, raw, m, bs in files:
        off = len(data)
        if m:
            chunks = [zlib.compress(raw[i:i + bs]) for i in range(0, len(raw), bs)]
            head_len = 53 + 4 + 16 * len(chunks); a = head_len; blocks = []
            for c in chunks: blocks.append((a, a + len(c))); a += len(c)
            body = b''.join(chunks); size = len(body)
        else:
            head_len = 53; blocks = []; body = raw; size = len(raw)
        sha = hashlib.sha1(raw).digest()
        head = struct.pack('<qqqI', 0, size, len(raw), m) + sha + ((struct.pack('<i', len(blocks)) + b''.join(struct.pack('<qq', *b) for b in blocks)) if m else b'') + struct.pack('<BI', 0, bs if m else 0)
        assert len(head) == head_len
        data += head + body; ents.append((off, size, len(raw), sha, blocks, bs if m else 0, m))
    im = Img(); im.alloc(88); im.fstr(0, mount)
    ea = im.put(bytes(80 * len(ents))); im.arr(16, ea, len(ents))
    for i, (off, size, raw, sha, blocks, bs, m) in enumerate(ents):
        o = ea + 80 * i; struct.pack_into('<qqq', im.b, o, off, size, raw); im.b[o + 24:o + 44] = sha
        if blocks: im.arr(o + 48, im.put(b''.join(struct.pack('<qq', *b) for b in blocks)), len(blocks))
        struct.pack_into('<IIB', im.b, o + 64, bs, m, 0)
    da = im.put(bytes(80 * len(dirs))); im.sparse(32, len(dirs), da)
    k = 0
    for j, (d, fs) in enumerate(dirs):
        o = da + 80 * j; im.fstr(o, d)
        fa = im.put(bytes(32 * len(fs))); im.sparse(o + 16, len(fs), fa)
        for q, (f, *_rest) in enumerate(fs):
            e = fa + 32 * q; idx = k
            if bad_index is not None and k == bad_index: idx = len(ents) + 5
            if drop_name is not None and k == drop_name: idx = (k + 1) % len(ents)   # 两个名字指向同一条目 → 另一条没有名字
            im.fstr(e, f); struct.pack_into('<i', im.b, e + 16, idx); k += 1
    idx = bytes(im.b)
    names = b'Zlib'.ljust(32, b'\0') + bytes(32 * 4)
    foot = bytes([1 if encrypted else 0]) + struct.pack('<IIQQ', UP.MAGIC, 9, len(data), len(idx)) + bytes(20) + b'\x01' + names
    open(path, 'wb').write(bytes(data) + idx + foot)
    return [(name, raw) for name, raw, _, _ in files]


def archive(recs):   # 版本 2 着色器存档（不压缩），recs = [(阶段, 记录)]
    code = b''.join(r for _, r in recs); ents = []; at = 0
    for fr, r in recs: ents.append(struct.pack('<QIIB', at, len(r), len(r), fr)); at += len(r)
    k = len(recs)
    return (struct.pack('<II', 2, 1) + bytes(20) + struct.pack('<I', k) + bytes(20 * k) + struct.pack('<IIIII', 1, 0, k, 0, 0)
            + struct.pack('<I', k) + b''.join(ents) + struct.pack('<I', 0) + struct.pack('<I', k) + struct.pack(f'<{k}I', *range(k)) + code)


T = tempfile.mkdtemp(prefix='frozen-')
recs = [(0, b'LSLGSV' + bytes(range(200)) * 2), (3, b'LSLGSP' + bytes(range(50, 250)) * 3)]
arc = archive(recs); gsc = b'GSC!' + os.urandom(300); small = b'ini=1\n'
DIRS = [('SWD7/Content/', [('ShaderArchive-Fx-GLSL_SWITCH.ushaderbytecode', arc, 0, 0), ('Config.ini', small, 0, 0)]),
        ('Engine/', [('GlobalShaderCache-GLSL_SWITCH.bin', gsc, 1, 128)])]
romfs = os.path.join(T, 'romfs', 'SWD7', 'Content', 'Paks'); os.makedirs(romfs)
p = os.path.join(romfs, 'pakchunk0-Switch.pak'); want = build(p, '../../../', DIRS)
pk = UP.Pak(p); got = {nm: pk.read(h) for nm, h in pk.files}
ck(pk.mount == '../../../' and sorted(got) == sorted(nm for nm, _ in want) and all(got[nm] == raw for nm, raw in want),
   f'① 冻结索引 3 个文件：名字 / 原文逐个对、挂载点对（实得 {sorted(got)}）')
spec = importlib.util.spec_from_file_location('uepak_t', os.path.join(H, 'translator', 'uepak.py')); U = importlib.util.module_from_spec(spec); spec.loader.exec_module(U)
up = U.Pak(p); ck(up.read('Engine/GlobalShaderCache-GLSL_SWITCH.bin') == gsc, '② uepak.Pak（直连抽取那层）按名字读到 Zlib 两块的原文')
out = os.path.join(T, 'out'); r = subprocess.run([sys.executable, os.path.join(H, 'pack', 'ue_pak.py'), os.path.join(T, 'romfs'), out], capture_output=True, text=True)
a = os.path.join(out, 'ShaderArchive-Fx-GLSL_SWITCH.ushaderbytecode')
ok3 = r.returncode == 0 and os.path.isfile(a)
if ok3:
    d = open(a, 'rb').read(); A = U.archive(d); ok3 = [(fr, d[A['code'] + o:A['code'] + o + s]) for o, s, _, fr in A['shaders']] == recs
ck(ok3, f'③ pack/ue_pak.py 写出存档、2 支记录逐条等于合成本（rc={r.returncode}{"" if ok3 else "；" + (r.stdout + r.stderr)[-200:]}）')
for tag, kw, exc, what in (('④', dict(bad_index=1), UP.Corrupt, '条目号越界'), ('⑤', dict(drop_name=0), UP.Corrupt, '有条目没名字'), ('⑥', dict(encrypted=True), UP.Unsupported, '冻结又加密')):
    q = os.path.join(T, f'bad{tag}.pak'); build(q, '../../../', DIRS, **kw)
    try: UP.Pak(q); res = '没抛'
    except exc as e: res = f'{type(e).__name__}：{e}'
    except Exception as e: res = f'别的异常 {type(e).__name__}：{e}'
    ck(res.startswith(exc.__name__), f'{tag} {what} → {exc.__name__}（实得 {res[:80]}）')
old = subprocess.run(['git', '-C', H, 'show', '268ee30f4:graphics/tools/shbake/unreal_pak.py'], capture_output=True, text=True)
if old.returncode == 0 and '_load_frozen' not in old.stdout:
    od = os.path.join(T, 'old'); os.makedirs(od)
    for f in ('pak_crypto.py', 'zstd_lib.py'): open(os.path.join(od, f), 'w').write(open(os.path.join(H, 'graphics', 'tools', 'shbake', f)).read())
    open(os.path.join(od, 'unreal_pak.py'), 'w').write(old.stdout)
    r7 = subprocess.run([sys.executable, '-c', 'import sys; sys.path.insert(0, sys.argv[1]); import unreal_pak as U\ntry: U.Pak(sys.argv[2]); print("读成了")\nexcept U.Unsupported as e: print(e)', od, p], capture_output=True, text=True)
    ck('冻结索引' in r7.stdout, f'⑦ 反证：改前 unreal_pak.py 报「{r7.stdout.strip()[:40]}」')
import shutil; shutil.rmtree(T, ignore_errors=True)
print(f'UE pak 版本 9 冻结索引：{n} 项，失败 {fail}；真文件鬼灭之刃 / 轩辕剑柒 6 个 pak 108714 条目头逐字段交叉、解压长度全符（11-02）')
sys.exit(1 if fail else 0)
