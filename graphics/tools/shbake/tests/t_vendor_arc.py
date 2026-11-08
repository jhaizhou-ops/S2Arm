#!/usr/bin/env python3
# 厂商着色器容器单测（11-02 着色器容器族 A 组：telltale.py / volition_vpp.py / nso_zstd.py + nxsh_extract 接入）。不读游戏数据，夹具全在本文件里按公开格式手造。
# 期望值按构造定：着色器对 = 本文件造的控制段 + 机器码字节，键 = sha256(控制段 ‖ 机器码) 前 16 位（hashlib 现算，不调被测实现）。
#   ① Telltale：着色器对按 t3fxpack 排法 [u32 机器码长][机器码][u32 控制段长][控制段] 放进成员 → 成员套 ZCTT（多块裸 deflate）→ 进 4ATT → 套 NCTT，visit 抽出恰好这些键；
#      ECTT（加密）只计数、0 支；块边界被改坏 → 记「读不了」、0 支、不抛
#   ② VPP v10：机器码紧贴控制段前，逐条 zlib（sync flush 收尾、无末块）/ condensed（各条压缩段接成一条流、目录偏移 16 字节对齐而流里不带填充）/ 不压缩三种，visit 都抽出恰好这些键；文件长字段不符 → 读不了
#   ③ 主程序内嵌字典的 zstd 帧：镜像 = 杂字节 + {1, 字典长} + 字典 + 若干帧（[控制段][m × 12 字节][机器码]，含无头计算着色器），scan_nso_zstd 按帧结构取出恰好这些键（含 m = 0 / 5）；
#      计算着色器线程组为 0 的帧 → 丢弃计数；镜像里没有字典 → 什么都不做
#   ④ zstd_frame 窗口：压缩后 > 1 MB 的帧照样解出原文；big_split 不把厂商归档分段（按头认）
# 用法：t_vendor_arc.py [shbake 目录]；退出 0 = 全过
import sys, os, struct, zlib, hashlib, random, collections, tempfile
sys.dont_write_bytecode = True
D = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')
sys.path.insert(0, os.path.abspath(D)); import nxsh_extract as X
from compression import zstd
fail = 0
def check(ok, what):
    global fail
    print(('✓ ' if ok else '✗ ') + what); fail += 0 if ok else 1
rnd = random.Random(1102)
NOP, EXIT = 0x50b0000000070f00, 0xe30000000007000f
def shader(stage):
    """→ (控制段, 机器码)：图形着色器机器码带 78563412 头、+0x30 记阶段号；计算着色器无头、控制段 +0x748 线程组 (8,8,1)。指令区 = 随机字 + EXIT + NOP，+0x700 记指令区终点"""
    body = [rnd.getrandbits(64) for _ in range(rnd.randint(4, 12))] + [EXIT, NOP]
    if stage == 'cs': code = struct.pack(f'<{len(body)}Q', *body)
    else:
        hdr = bytearray(0x80); hdr[:4] = bytes.fromhex('78563412'); struct.pack_into('<I', hdr, 0x30, {'vs': 1, 'ps': 5}[stage] << 10)
        code = bytes(hdr) + struct.pack(f'<{len(body)}Q', *body)
    ctl = bytearray(rnd.randbytes(0x880)); ctl[:8] = bytes.fromhex('3412769801000000')
    struct.pack_into('<I', ctl, 0x20, 0x880); struct.pack_into('<II', ctl, 0x700, len(code), len(code))
    struct.pack_into('<3I', ctl, 0x748, *((8, 8, 1) if stage == 'cs' else (0, 0, 0)))
    return bytes(ctl), code
def key(ctl, code): return hashlib.sha256(ctl + code).hexdigest()[:16]
def run(name, data):
    rows, blobs, stat = [], {}, collections.Counter(); X.visit(name, data, rows, blobs, stat)
    return {r[0]: r[1] for r in rows}, blobs, stat
# ---- ① Telltale ----
S1 = [shader(st) for st in ('vs', 'ps', 'ps', 'vs')]
fx = b''.join(struct.pack('<I', len(c)) + c + struct.pack('<I', len(t)) + t for t, c in S1) + b'\0' * 16
def zctt(b, bs=0x400):
    blocks = []
    for i in range(0, len(b), bs):
        z = zlib.compressobj(6, zlib.DEFLATED, -15); blocks.append(z.compress(b[i:i + bs]) + z.flush())
    n = len(blocks); edge = [12 + 8 * (n + 1)]
    for x in blocks: edge.append(edge[-1] + len(x))
    return b'ZCTT' + struct.pack('<II', bs, n) + struct.pack(f'<{n + 1}Q', *edge) + b''.join(blocks)
def tta4(files):
    names = b''; ents = b''; data = b''
    for nm, b in files:
        ents += struct.pack('<QQIIHH', zlib.crc32(nm), len(data), len(b), 0, 0, len(names)); names += nm + b'\0'; data += b
    return b'4ATT' + struct.pack('<II', len(names), len(files)) + ents + names + data
fxz = zctt(fx)
arc = tta4([(b'readme.txt', b'not a shader' * 10), (b'Game_Shaders_mem.t3fxpack', fxz)])
nctt = b'NCTT' + struct.pack('<Q', len(arc)) + arc
got, blobs, stat = run('Game_Shaders_mem.ttarch2', nctt)
want = {key(t, c): st for (t, c), st in zip(S1, ('vs', 'ps', 'ps', 'vs'))}
check(got == want and all(blobs[k] == (c, t) for t, c in S1 for k in [key(t, c)]), f'① NCTT → 4ATT → ZCTT（{len(fxz) - 12} 字节、{struct.unpack_from("<I", fxz, 8)[0]} 块）→ t3fxpack：抽出 {len(got)} 支 = 造的 {len(want)} 支、字节一致')
got, _, stat = run('enc.ttarch2', b'ECTT' + bytes(64))
check(not got and stat['telltale 加密 / 不支持的变体（未解）'] == 1, f'① ECTT 只计数不解：{dict(stat)}')
bad = bytearray(fxz); struct.pack_into('<Q', bad, 12 + 8, 1 << 40)
got, _, stat = run('bad.ttarch2', bytes(bad))
check(not got and stat['telltale 读不了'] == 1, f'① ZCTT 块边界越界 → 读不了、0 支：{dict(stat)}')
# ---- ② VPP v10 ----
def vpp(files, mode):
    """mode：'z' 逐条 zlib（sync flush 收尾）/ 'c' condensed（同一个压缩器逐条 sync flush 接成一条流，目录偏移按 16 对齐、流里不带填充，同 SR4 *.str2_nx64）/ 'raw' 不压缩"""
    names = b''; dirs = b''; data = b''; raw = b''; zc = zlib.compressobj(); upos = 0
    for nm, b in files:
        no = len(names); names += nm + b'\0'
        if mode == 'z':
            z = zlib.compressobj(); s = z.compress(b) + z.flush(zlib.Z_SYNC_FLUSH)
            dirs += struct.pack('<5IHH', no, 0, len(data), len(b), len(s), 0, 0); data += s
        elif mode == 'c':
            s = zc.compress(b) + zc.flush(zlib.Z_SYNC_FLUSH)
            dirs += struct.pack('<5IHH', no, 0, upos, len(b), len(s), 1, 16); data += s; upos += len(b) + (-len(b) % 16)
        else: dirs += struct.pack('<5IHH', no, 0, len(raw), len(b), 0xffffffff, 0, 0); raw += b
    fl = {'z': 1, 'c': 3, 'raw': 0}[mode]; data = raw if mode == 'raw' else data
    names += b'\0' * (-len(names) % 16)
    total = 0x28 + len(dirs) + len(names) + len(data)
    usz = {'z': sum(len(b) for _, b in files), 'c': upos, 'raw': len(raw)}[mode]
    return struct.pack('<10I', 0x51890ACE, 10, 0, total, fl, len(files), len(dirs), len(names), usz, len(data)) + dirs + names + data
S2 = [shader(st) for st in ('vs', 'ps', 'cs')]
fxo = b'\xee\xa1\x42\x4b' + bytes(28) + b''.join(c + t + struct.pack('<4I', 0x17, 0, 7, 0) + bytes(0x30) for t, c in S2)   # 同 SR4 真 .fxo_nx64：机器码紧贴控制段前，控制段后跟一段小记录再到下一支
want = {key(t, c): st for (t, c), st in zip(S2, ('vs', 'ps', 'cs'))}
for mode in ('z', 'c', 'raw'):
    got, _, stat = run(f'shaders_{mode}.vpp_nx64', vpp([(b'a.txt', b'hello' * 99), (b'lighting.fxo_nx64', fxo)], mode))
    check(got == want and stat['volition_vpp'] == 1, f'② VPP v10（{mode}）：抽出 {len(got)} 支 = 造的 {len(want)} 支（含无头计算着色器）')
b = bytearray(vpp([(b'lighting.fxo_nx64', fxo)], 'z')); struct.pack_into('<I', b, 12, len(b) + 1)
got, _, stat = run('bad.vpp_nx64', bytes(b))
check(not got and stat['volition_vpp 读不了'] == 1, f'② 文件长字段不符 → 读不了、0 支：{dict(stat)}')
# ---- ③ 主程序内嵌字典的 zstd 帧 ----
zd = zstd.train_dict([rnd.randbytes(64) + bytes(200) + rnd.randbytes(64) for _ in range(300)], 4096)
S3 = [(shader(st), m) for st, m in (('vs', 0), ('ps', 5), ('cs', 2), ('vs', 1))]
frames = [zstd.compress(t + rnd.randbytes(12 * m) + c, zstd_dict=zd) for (t, c), m in S3]
t0, c0 = shader('cs'); t0 = bytearray(t0); struct.pack_into('<3I', t0, 0x748, 0, 0, 0)   # 计算着色器线程组为 0：排法对但不是真计算着色器
frames.append(zstd.compress(bytes(t0) + c0, zstd_dict=zd))
img = rnd.randbytes(999) + struct.pack('<II', 1, len(zd.dict_content)) + zd.dict_content + b''.join(rnd.randbytes(rnd.randint(1, 50)) + f for f in frames) + rnd.randbytes(77)
rows, blobs, stat = [], {}, collections.Counter(); X.scan_nso_zstd('nso:main', img, rows, blobs, stat)
want = {key(t, c): ('cs' if st == 'cs' else st) for ((t, c), m), st in zip(S3, ('vs', 'ps', 'cs', 'vs'))}
got = {r[0]: r[1] for r in rows}
check(got == want and stat['主程序内嵌 zstd 字典'] == 1 and stat['主程序 zstd 着色器帧对不上（丢弃）'] == 1,
      f'③ 内嵌字典 {zd.dict_id:#x} + {len(frames)} 帧：抽出 {len(got)} 支 = 造的 {len(want)} 支（小记录 0 / 5 / 2 / 1 条）、线程组 0 的丢 1 支：{dict(stat)}')
rows, blobs, stat = [], {}, collections.Counter(); X.scan_nso_zstd('nso:main', rnd.randbytes(5000) + frames[0], rows, blobs, stat)
check(not rows and not stat, '③ 镜像里没有字典 → 不扫帧、0 支')
# ---- ⑤ id Tech 7 IDCL v12：只交出 renderProgResource 条目；压缩方式 2 走调用方给的 Oodle 解码器（这里用假解码器：压缩段 = b'OO' + 原文倒序），0 = 原样 ----
def idcl(ents):
    """ents：[(类型, 名字, 原文, 压缩方式)] → IDCL v12 字节（按 11-02 对真文件核过的布局）"""
    strs = []; si = []
    for t, nm, _, _ in ents: si += [len(strs), len(strs) + 1]; strs += [t.encode(), nm.encode()]
    sdata = b''; offs = []
    for s in strs: offs.append(len(sdata)); sdata += s + b'\0'
    o_ent = 0x7C; o_str = o_ent + 0x90 * len(ents); stab = struct.pack('<Q', len(strs)) + struct.pack(f'<{len(offs)}Q', *offs) + sdata
    o_di = o_str + len(stab); di = b''; o_si = o_di; sitab = struct.pack(f'<{len(si)}Q', *si); o_data = o_si + len(sitab)
    blobs = [(b'OO' + raw[::-1]) if how == 2 else raw for _, _, raw, how in ents]
    hdr = b'IDCL' + struct.pack('<III', 12, 0, 1) + struct.pack('<QQ', (1 << 40) - 1, 0) + struct.pack('<6I', len(ents), 0, 0, len(si), 0, 0)
    hdr += struct.pack('<7Q', len(stab), o_str, o_di, o_ent, o_di, o_di, o_data); hdr += bytes(0x7C - len(hdr))
    et = b''; pos = o_data
    for i, ((t, nm, raw, how), b) in enumerate(zip(ents, blobs)):
        e = bytearray(0x90); struct.pack_into('<Q', e, 0x20, 2 * i); struct.pack_into('<3Q', e, 0x38, pos, len(b), len(raw)); e[0x70] = how; et += bytes(e); pos += len(b)
    return hdr + et + stab + di + sitab + b''.join(blobs)
S5 = [shader(st) for st in ('vs', 'ps')]
rp = lambda t, c: struct.pack('<I', len(c)) + c + struct.pack('<I', len(t)) + t
data = idcl([('image', 'a.tga', rp(*shader('vs')), 0), ('renderProgResource', 'p0', rp(*S5[0]), 2), ('renderProgResource', 'p1', rp(*S5[1]), 0)])
calls = []
def fake_oodle(b, n): calls.append(n); return b[2:][::-1] if b[:2] == b'OO' else None
real_oodle = X.pkz_oodle; X.pkz_oodle = fake_oodle
got, _, stat = run('gameresources.resources', data)
want = {key(t, c): st for (t, c), st in zip(S5, ('vs', 'ps'))}
check(got == want and len(calls) == 1 and stat['idtech_idcl 成员'] == 2, f'⑤ IDCL：只交出 2 条着色器条目（贴图条目里的那支不抽）、1 条经 Oodle 解码器：{len(got)} 支 = 造的 {len(want)} 支')
def no_host(b, n): raise RuntimeError('没有 Mac 宿主')
X.pkz_oodle = no_host
got, _, stat = run('gameresources.resources', data)
check(stat['idtech_idcl 读不了'] == 1, f'⑤ 没有 Oodle 宿主 → 记「读不了」、不抛：{dict(stat)}')
X.pkz_oodle = real_oodle
# ---- ④ zstd_frame 大帧窗口 / big_split ----
big = rnd.randbytes(3 << 20); f = zstd.compress(big)
r = X.zstd_frame(b'junk' + f + b'tail', 4)
check(r is not None and r[0] == big and r[1] == len(f), f'④ 压缩后 {len(f) >> 20} MB 的帧（> 1 MB 窗口）解出原文')
with tempfile.TemporaryDirectory() as td:
    X.BIG = 16; ok = True
    for nm, b, want_split in (('a.ttarch2', zctt(fx), False), ('b.vpp_nx64', vpp([(b'x', fxo)], 'z'), False), ('c.bin', rnd.randbytes(64), True)):
        p = os.path.join(td, nm); open(p, 'wb').write(b); ok &= X.big_split(p) == want_split
    check(ok, '④ big_split：厂商归档（ZCTT / VPP）不分段、未知大文件照旧分段')
print(f'{"全过" if not fail else f"{fail} 项不过"}')
sys.exit(1 if fail else 0)
