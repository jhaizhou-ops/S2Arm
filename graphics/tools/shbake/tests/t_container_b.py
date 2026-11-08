#!/usr/bin/env python3
# 着色器容器族 B 组（11-02 普查「直连抽取 0 支」：Unravel Two 的 kit! 档案、No Man's Sky 的 HGPAK）：graphics/tools/shbake/kitpak.py、hgpak.py 与 nxsh_extract.py 的接入（work_members → visit → scan_adj）。
# 期望按格式手写，不跑被测实现：
#   kit!  ① 索引 + 两个数据卷：原样条目、两块链式 LZ4（第二块只能拿前一块当字典解出，夹具自检）都逐字节解回原文；同内容条目只排一次，卷文件归档案接管
#         ② 条目与 SHA-1 对不上 / 索引尾不是 '!tik'：ValueError
#   HGPAK ③ 压缩档案：文件跨块边界、原样块与压缩块混排、末块按「到最后一个文件尾」的长度解；名字取第 0 号文件的路径清单
#         ④ 末块补满 0x20000 压的：解码器拒收（ValueError）后按整块长再解
#         ⑤ 不压缩（没有块表）：偏移就是文件内偏移；⑥ 表尾与数据起点对不上：ValueError
#         ⑥b .nvb 按头取：控制段在 +0x60、机器码离控制段尾 0x20 字节（同真件；相邻扫描配不上这种），偏移越界 ValueError，不是 .nvb 的返回 None
#   端到端 ⑦ kit! 条目是 PhyreEngine 集群（RYHP，三支「机器码紧贴在控制段之前」背靠背：两支带头片元、一支无头计算；第一支控制段后面紧跟的是第二支带头的机器码，
#         scan_adj 旧规则按正向带头把它切成第一支的机器码、配出幽灵键并丢了真片元；现按这段字节里「只有一头像」的控制段多数定方向）、HGPAK 里一个 .nvb（0x20 头 + 填充 + 控制段 + 间隔 + 带头机器码 + 尾巴）：
#         nxsh_extract.work_members 出的键 = 按「控制段 + 机器码」sha256 手算的 4 个键，阶段 ps / ps / cs / vs，来源 <档案>//<条目名>，不多出幽灵
# Oodle 是游戏自带解码器（宿主工具模式），这里换成 zlib 替身（长度不对抛 ValueError，同 pkz_oodle），只测档案布局
import collections, hashlib, os, struct, sys, tempfile, unittest, zlib
import lz4.block
H = os.path.dirname(os.path.dirname(os.path.abspath(__file__))); sys.path.insert(0, H)
import hgpak, kitpak, nxsh_extract as X

CHUNK, NOP, EXIT = 0x20000, 0x50b0000000070f00, 0xe30000000007000f


def ctl(dn, tg=(0, 0, 0)):
    c = bytearray(0x800); c[:8] = bytes.fromhex('3412769801000000')
    struct.pack_into('<I', c, 0x20, 0x800); struct.pack_into('<I', c, 0x700, dn); struct.pack_into('<I', c, 0x704, dn); struct.pack_into('<3I', c, 0x748, *tg)
    return bytes(c)


def code(stage=None, n=0x60, tag=1):   # stage = SPH 着色器类型（1 顶点 5 片元），None = 无头计算；末字 NOP、区内有 EXIT（scan_adj code_ok）
    w = [tag] * (n // 8); w[-2] = EXIT; w[-1] = NOP
    b = bytearray(struct.pack(f'<{len(w)}Q', *w))
    if stage is not None: b[:16] = bytes.fromhex('78563412') + bytes(12); struct.pack_into('<I', b, 0x30, stage << 10)
    return bytes(b)


def key(c, k): return hashlib.sha256(c + k).hexdigest()[:16]


PS, CS, VS = code(5), code(None, tag=3), code(1, tag=5)
PS_C, CS_C, VS_C = ctl(len(PS)), ctl(len(CS), (64, 1, 1)), ctl(len(VS))
PS2 = code(5, n=0x80, tag=7); PS2_C = ctl(len(PS2))
CLUSTER = b'RYHP' + bytes(0x3c) + PS + PS_C + PS2 + PS2_C + CS + CS_C + b'\x22' * 8   # 背靠背：片元 1 机器码、控制段，片元 2（带头，紧跟片元 1 的控制段）、计算（无头）
NVB = struct.pack('<QQQQ', 0x40, 0x860, 0x38, 0x1234) + b'\x01' * 0x40 + VS_C + b'\x02' * 0x20 + VS + b'tail-not-code'   # 同真件：控制段在 +0x60，机器码离控制段尾 0x20 字节
NOISE = b''.join(hashlib.sha256(b'%d' % i).digest() for i in range(0x800))   # 64 KB 不自重复的字节
BIG = CLUSTER[:0x40] + NOISE[0x40:] + NOISE[0x8000:0x8400] + CLUSTER[0x40:]   # > 64 KB：第二块开头 1 KB = 第一块 0x8000 起的原文


def ext(n): return bytes([255] * (n // 255) + [n % 255])


def linked(data):
    """两块链式：第一块普通 LZ4；第二块手写（python lz4 的 compress 不用字典）：0 字面量、从 0x8000 字节前复制 0x400，余下全是字面量"""
    a, b = data[:0x10000], data[0x10000:]
    ca, rest = lz4.block.compress(a, store_size=False), b[0x400:]
    cb = bytes([0x0f]) + struct.pack('<H', 0x8000) + ext(0x400 - 4 - 15) + bytes([0xf0]) + ext(len(rest) - 15) + rest
    return struct.pack('<I', len(ca)) + ca + struct.pack('<I', len(cb)) + cb, cb


def kit(tmp, entries, vols=2, tail=b'!tik'):
    blobs = {v: bytearray(b'\xee' * 0x10) for v in range(vols)}; rows = []
    for h, v, stored, data in entries:
        off = len(blobs[v]); blobs[v] += stored
        rows.append(struct.pack('<QQQQ20sI', h, v | off << 16, len(stored), len(data), hashlib.sha1(data).digest(), 0))
    idx = b'kit!' + struct.pack('<7I', 1, 1, 1, 0x40, 0, len(entries), vols) + b'\x2f' + bytes(0x40) + b''.join(rows) + tail
    p = os.path.join(tmp, 'Data.kit'); open(p, 'wb').write(idx)
    for v, b in blobs.items(): open(f'{p}.{v}', 'wb').write(bytes(b))
    return p


def fake_oodle(calls):
    def dec(comp, n):
        calls.append(n); out = zlib.decompress(comp)
        if len(out) != n: raise ValueError(f'rejected {n}')
        return out
    return dec


def hgpak_bytes(files, comp=True, pad_last=False, stored=(1,)):
    allf = ['\n'.join(n for n, _ in files).encode() + b'\n'] + [d for _, d in files]
    body = b''.join(allf); n = len(allf)
    chunks = [body[i:i + CHUNK] for i in range(0, len(body), CHUNK)] if comp else []
    D = (0x30 + 32 * n + 8 * len(chunks) + 15) & ~15
    offs, o = [], D
    for d in allf: offs.append(o); o += len(d)
    if pad_last: chunks[-1] += bytes(CHUNK - len(chunks[-1]))
    st = [ch if k in stored else zlib.compress(ch) for k, ch in enumerate(chunks)]
    tables = b''.join(struct.pack('<16sQQ', hashlib.md5(d).digest(), off, len(d)) for d, off in zip(allf, offs)) + b''.join(struct.pack('<Q', len(s)) for s in st)
    data = b''.join(s + bytes(-len(s) & 15) for s in st) if comp else body
    return b'HGPAK\0\0\0' + struct.pack('<5Q', 2, n, len(st), int(comp), D) + tables + bytes(D - 0x30 - len(tables)) + data


BLOB = bytes(range(256)) * 0x500   # 0x50000：跨两个块边界
FILES = [('shaders/code/bin/switch/a.nvb', NVB), ('textures/big.dds', BLOB), ('x.txt', b'hello')]
LAST = sum(len(d) for d in ['\n'.join(n for n, _ in FILES).encode() + b'\n'] + [d for _, d in FILES]) - 2 * CHUNK


class ContainerB(unittest.TestCase):
    def test_1_kit_entries(self):
        st, cb = linked(BIG)
        self.assertEqual(lz4.block.decompress(cb, uncompressed_size=len(BIG) - 0x10000, dict=BIG[:0x10000]), BIG[0x10000:])   # 夹具自检：带字典解得出、
        with self.assertRaises(Exception): lz4.block.decompress(cb, uncompressed_size=len(BIG) - 0x10000)                      # 离了字典解不出
        with tempfile.TemporaryDirectory() as tmp:
            p = kit(tmp, [(0xa1, 0, b'plain', b'plain'), (0xb2, 1, st, BIG), (0xc3, 1, b'plain', b'plain')])
            jobs, taken = kitpak.jobs([p])
            self.assertEqual(taken, {p, p + '.0', p + '.1'})
            self.assertEqual(sorted(e[0] for _, es in jobs for e in es), [0xa1, 0xb2])   # 0xc3 与 0xa1 同内容
            self.assertEqual(dict(m for jp, es in jobs for m in kitpak.members(jp, es)), {'00000000000000a1': b'plain', '00000000000000b2': BIG})

    def test_2_kit_bad(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = kit(tmp, [(0xa1, 0, b'stored', b'stored')])
            e = kitpak.kit_entries(p)[0]
            with self.assertRaises(ValueError): list(kitpak.members(p, [e[:5] + (hashlib.sha1(b'other').digest(),)]))
            with self.assertRaises(ValueError): kitpak.kit_entries(kit(tmp, [(0xa1, 0, b'stored', b'stored')], tail=b'tik!'))

    def read_all(self, b, calls):
        r = hgpak.Hgpak(b, fake_oodle(calls)); return [(nm, r.read(o, s)) for nm, o, s in r.files()]

    def test_3_hgpak(self):
        calls = []; self.assertEqual(self.read_all(hgpak_bytes(FILES), calls), FILES); self.assertEqual(calls, [CHUNK, LAST])

    def test_4_hgpak_padded_last(self):
        calls = []; self.assertEqual(self.read_all(hgpak_bytes(FILES, pad_last=True), calls), FILES); self.assertEqual(calls, [CHUNK, LAST, CHUNK])

    def test_5_hgpak_plain(self):
        self.assertEqual(self.read_all(hgpak_bytes(FILES, comp=False), []), FILES)

    def test_6_hgpak_bad(self):
        b = bytearray(hgpak_bytes(FILES)); struct.pack_into('<Q', b, 0x28, struct.unpack_from('<Q', b, 0x28)[0] + 16)
        with self.assertRaises(ValueError): hgpak.hgpak_header(bytes(b))

    def test_6b_nvb(self):
        self.assertEqual(hgpak.shader(NVB), (VS_C, VS))
        self.assertIsNone(hgpak.shader(BLOB))
        bad = bytearray(NVB); struct.pack_into('<Q', bad, 8, len(NVB))   # 机器码偏移越过文件尾
        with self.assertRaises(ValueError): hgpak.shader(bytes(bad))

    def test_7_extract(self):
        with tempfile.TemporaryDirectory() as tmp, tempfile.TemporaryDirectory() as out:
            p = kit(tmp, [(0xb2, 1, linked(BIG)[0], BIG)])
            q = os.path.join(tmp, 'NMSARC.t.pak'); open(q, 'wb').write(hgpak_bytes(FILES))
            X.pkz_oodle = fake_oodle([])
            rows = []
            for m, src in ((kitpak, p), (hgpak, q)):
                E, _ = m.jobs([src], X.pkz_oodle)
                for e in E: rows += X.work_members((tmp, m.__name__, e, out))[0]
            got = {(r[0], r[1], r[2].split('@')[0]) for r in rows}
            self.assertEqual(got, {(key(PS_C, PS), 'ps', 'Data.kit//00000000000000b2'), (key(PS2_C, PS2), 'ps', 'Data.kit//00000000000000b2'), (key(CS_C, CS), 'cs', 'Data.kit//00000000000000b2'),
                                   (key(VS_C, VS), 'vs', 'NMSARC.t.pak//shaders/code/bin/switch/a.nvb')})


if __name__ == '__main__':
    r = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(ContainerB))
    bad = len(r.failures) + len(r.errors)
    print(f'{"✓" if not bad else "✗"} 着色器容器 B 组（kit! / HGPAK）：{r.testsRun} 项，{bad} 项不过')
    sys.exit(1 if bad else 0)
