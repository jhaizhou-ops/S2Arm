#!/usr/bin/env python3
# ue_programs 单测（10-21 pair）：手搓 UE4 冷冻着色器表（类型数组放在表头之前 = 负向冷冻指针），期望配对手算。
# 另核 CityHash64 / WithSeed 对 Google 参考实现的读数。旧代码反证：没有 ue_programs.py / cityhash.py（导入失败 = 全红）。用法：t_ue_programs.py [shbake 目录]
import sys, os, struct
D = os.path.abspath(sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
sys.path.insert(0, D)
fail = 0; n = 0
def check(ok, what):
    global fail, n
    n += 1; print(('✓ ' if ok else '✗ ') + what); fail += 0 if ok else 1
try:
    import cityhash, ue_programs as U
except Exception as e:
    print(f'✗ 导入 ue_programs / cityhash 失败：{e}'); print('期望 UE 冷冻表配对 全过 → 真结果 失败 1 / 1'); sys.exit(1)
# 1) CityHash：Google 参考实现（cityhash 0.4.7 的 city.cc）读数
check(cityhash.city64(b'') == 0x9ae16a3b2f90404f and cityhash.city64(b'hello') == 0xb48be5a931380ce8 and cityhash.city64_seed(b'FLOCALVERTEXFACTORY', 7) == 0x1e33db415a276274,
      'CityHash64("")、("hello")、WithSeed("FLOCALVERTEXFACTORY", 7) = 参考实现读数')
def build(types):
    """types：[(类型名, 频率)]；返回 (字节, 表头偏移, 名字表)；代码下标 = 序号（每支独占一条代码）"""
    n_ = len(types); TY = 0x10; O = 0x100; SH = 0x200
    d = bytearray(SH + n_ * 0xd0 + 0x10)
    for i, (tn, fq) in enumerate(types): struct.pack_into('<Q', d, TY + 8 * i, cityhash.city64_seed(tn.upper().encode(), 0))
    PP = O + 0x60
    def hdr(at, tgt): struct.pack_into('<qII', d, at, ((tgt - at) << 1) | 1, n_, n_)
    hdr(O, TY); hdr(O + 16, PP); hdr(O + 32, O + 0x80)
    for i, (tn, fq) in enumerate(types):
        so = SH + i * 0xd0; struct.pack_into('<q', d, O + 0x80 + 8 * i, ((so - (O + 0x80 + 8 * i)) << 1) | 1)
        struct.pack_into('<Ii', d, so + 0xc0, (0x4c << 3) | fq, i)
    struct.pack_into('<Q', d, O + 0x48, cityhash.city64_seed(b'FLOCALVERTEXFACTORY', 0))
    return bytes(d), O, {cityhash.city64_seed(tn.upper().encode(), 0): tn for tn, _ in types}
T = [('TBasePassVSFNoLightMapPolicy', 0), ('TBasePassPSFNoLightMapPolicy', 3), ('TBasePassPSFNoLightMapPolicySkylight', 3),
     ('TBasePassVSFCachedPointIndirectLightingPolicy', 0), ('TBasePassPSFCachedPointIndirectLightingPolicy', 3), ('TDepthOnlyVS<false>', 0), ('FDepthOnlyPS<false>', 3)]
d, O, H = build(T); keys = [f'k{i}' for i in range(len(T))]
entries = {len(d) + 0x100 * (i + 1): (keys[i], 'vs' if fq == 0 else 'ps') for i, (_, fq) in enumerate(T)}
tb = U.tables(d)
check(len(tb) == 1 and tb[0][0] == O and [r[3] for r in tb[0][2]] == list(range(7)), f'认出 1 张表、7 支、代码下标 0..6（类型数组在表头之前）：真结果 {[(hex(o), len(r)) for o, _, r in tb]}')
import collections
P, V, G = U.pair_file(d, entries, H, False, collections.Counter())
want = {('k0', 'k1'), ('k0', 'k2'), ('k3', 'k4'), ('k5', 'k6')}
check(P == want, f'材质表：NoLightMap VS × 两支 NoLightMap PS、CachedPoint VS × 其 PS、DepthOnly VS × PS，跨策略不配 → 真结果 {sorted(P)}')
check(V == {'k0', 'k3', 'k5'}, f'每支 VS 另出只顶点 → 真结果 {sorted(V)}')
G = [('FFilterVS', 'vs', 'f1'), ('FFilterPS', 'ps', 'f2'), ('FScreenVS', 'vs', 's1'), ('FScreenPS', 'ps', 's2'), ('FUpscaleVS', 'vs', 'u1'), ('FUpscalePS', 'ps', 'u2'), ('FCopyRectPS', 'ps', 'c2')]
gp, ng, nps = U.global_pairs(G)
gw = {('f1', 'f2'), ('s1', 's2'), ('u1', 'u2'), ('s1', 'f2'), ('s1', 'u2'), ('s1', 'c2')}
check(gp == gw, f'全局表：同族三对 + FScreenVS（名含 Screen）× 全部 4 支 PS；FUpscaleVS 有同族 PS 不当通用 → 真结果 {sorted(gp)}')
# 全局几何（10-21 gfxsh-extract）：WriteToSlice 无同族 PS → × 读 ⊆ GS 写（0x13）的全部全局 PS：p1 读 0x1、p2 读 0x13、cp 读 0x1 配，p3 读 0x100 不配；Cube 有同族 PS → 只配 cp
SP = {'wv': (0, 0x13), 'wg': (0x13, 0x13), 'p1': (0x1, 0), 'p2': (0x13, 0), 'p3': (0x100, 0), 'cv': (0, 0xf), 'cg': (0xf, 0xf), 'cp': (0x1, 0)}
GG = [('FWriteToSliceVS', 'vs', 'wv'), ('FWriteToSliceGS', 'gs', 'wg'), ('TOneColorPixelShaderMRT', 'ps', 'p1'), ('FLUTBlenderPS', 'ps', 'p2'), ('FBigPS', 'ps', 'p3'),
      ('FCubeVS', 'vs', 'cv'), ('FCubeGS', 'gs', 'cg'), ('FCubePS', 'ps', 'cp')]
try: gg, _ = U.global_gs(GG, SP.__getitem__)
except Exception as e: gg = f'异常 {e}'
check(gg == {('wv', 'wg', 'p1'), ('wv', 'wg', 'p2'), ('wv', 'wg', 'cp'), ('cv', 'cg', 'cp')}, f'全局几何：同族 VS + GS × 同族 PS / 接口相容的全局 PS → 真结果 {gg}')
print(f'期望 UE 冷冻表配对 {n} 项全过 → 真结果 失败 {fail} / {n}')
sys.exit(1 if fail else 0)
