# Volition VPP 包 v10（Saints Row IV 的 *.vpp_nx64 / *.str2_nx64，11-02 着色器容器族 A 组）：nxsh_extract.visit 认出后逐条目再走 visit。
# 着色器在 shaders.vpp_nx64 的 *.fxo_nx64 条目里，机器码紧贴在控制段之前，由 scan_adj 的反向分支配对；本文件只管把包解开
#   （原先 0 支：条目是 zlib 流，但以 sync flush 收尾、没有末块和 adler32，zlib 流扫描要求完整结束、认不出）。
# 头 0x28 = 10 × u32 {魔数 CE 0A 89 51, 版本 10, 头校验, 文件长, 标志, 条目数 n, 目录长 (= 24n), 名字区长, 原数据总长, 存储数据总长}；
# 目录 0x28 起 n × 24 字节 {u32 名字偏移, u32 0, u32 存储偏移, u32 原长, u32 存储长 (0xffffffff = 未压缩), u16 标志, u16 对齐}；
# 名字区紧随目录（0 结尾）；数据区紧随名字区。
# 标志 bit0 = 压缩：bit1 也置（condensed，*.str2_nx64）时各条压缩段首尾相接成一条 zlib 流（每段 sync flush 收尾、后段可回指前段），解出的是各条原文按偏移顺序紧挨着拼接
#   （目录里的偏移按 16 字节对齐、原文之间不带对齐填充：11-02 brianne.str2_nx64 整流解出 847554 = 头里原长 847620 − 7 处对齐填充 66）；否则每条一条 zlib 流（按原长截，不要求流结束）。
# 依据：公开的 Volition VPP 格式说明（Saints Row 模组工具）+ 11-02 对 SR4 Switch 版逐条核过。任何字段越界 / 解出长度不符抛 ValueError。
import struct, zlib

MAGIC = 0x51890ACE


def recognize(data):
    return len(data) >= 0x28 and struct.unpack_from('<2I', data, 0) == (MAGIC, 10)


def _inflate(b, n):
    """一条 zlib 流解出恰好 n 字节（sync flush 收尾的流没有结束标记，不要求 eof）"""
    o = zlib.decompressobj().decompress(bytes(b), n)
    if len(o) != n: raise ValueError(f'zlib 解出 {len(o)} 字节，要 {n}')
    return o


def members(d, oodle=None):
    """→ [(名字, 内容)] 的生成器：目录（名字 / 偏移）先整个核完再逐条解（大包不一次解出全部）"""
    mg, ver, _, fs, fl, n, ds, fns, usz, csz = struct.unpack_from('<10I', d, 0)
    if (mg, ver) != (MAGIC, 10): raise ValueError(f'不是 VPP v10（{mg:#x} v{ver}）')
    if ds != 24 * n or fs != len(d): raise ValueError(f'VPP 目录长 {ds}（{n} 条）或文件长 {fs}（实际 {len(d)}）不符')
    names = 0x28 + ds; data = names + fns; whole = fl & 3 == 3; ents = []
    if data + (csz if fl & 1 else usz) > len(d): raise ValueError('VPP 数据区越界')
    for i in range(n):
        no, _, so, ul, cl, _, _ = struct.unpack_from('<5IHH', d, 0x28 + 24 * i)
        e = d.find(b'\0', names + no, data) if no < fns else -1
        if e < 0: raise ValueError(f'VPP 第 {i} 条名字越界')
        packed = fl & 1 and not whole and cl != 0xffffffff
        if (so + ul > usz) if whole else (data + so + (cl if packed else ul) > len(d)): raise ValueError(f'VPP 第 {i} 条越界')
        ents.append((bytes(d[names + no:e]).decode('latin-1'), so, ul, cl, packed))
    def gen():
        if whole:   # 按偏移顺序从整流里依次切
            blob = _inflate(d[data:data + csz], sum(e[2] for e in ents)); pos = 0
            for nm, so, ul, cl, packed in sorted(ents, key=lambda e: e[1]): yield nm, blob[pos:pos + ul]; pos += ul
            return
        for nm, so, ul, cl, packed in ents:
            if packed: yield nm, _inflate(d[data + so:data + so + cl], ul)
            else: yield nm, bytes(d[data + so:data + so + ul])
    return gen()
