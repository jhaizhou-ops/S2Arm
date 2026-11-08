#!/usr/bin/env python3
# 门禁手动：要私有游戏数据 + 编好的 Mac 宿主：双人成行 / 猎天使魔女3 产物根，用游戏自带 OodleLZ_Decompress 真解一段比 sha256（SERVE 与 DM_OODLE_JOB 两路），手动回归；协议层已由 tests/oodle_proto_test.sh 进门禁
# Oodle 工具模式·真解码回归（要私有游戏数据，手动跑；文件头写「门禁手动」）：
#   用法：tests/t_oodle_real.py <产物根…>     产物根 = 改写模块目录（main.fixups.tsv / main.patched.bin / main.npdm）+ romfs/，即 ~/.s2arm/run/s2arm/roots/<款>@现行
#   宿主 = DM_OODLE_HOST 或本仓库 build/s2arm-host（先 make host）。
# 期望值是 10-28 第一次用游戏自带 OodleLZ_Decompress 解出后记下的 sha256（SERVE 与 DM_OODLE_JOB 两路解出一致才记）；之后任何一路解出的字节变了就红。
# 每款两路都跑：① DM_OODLE_SERVE（OodleHost 协议，经 pack/ue_pak.py / graphics/tools/shbake/pkz.py 的正式读法）② DM_OODLE_JOB（DMOJ 作业文件 → DMOR）。按 main 构建号认款，没登记的根跳过并说明。
import hashlib, importlib.util, os, struct, subprocess, sys, tempfile
H = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(H, 'graphics/tools/shbake'))
import pkz, unreal_pak as UP
def _load(name, rel):   # 按路径装（graphics/tools/shbake 下另有同名 ue_pak.py，不能靠 sys.path 碰运气）
    spec = importlib.util.spec_from_file_location(name, os.path.join(H, rel)); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m
ue_pak, U = _load('ue_pak_pack', 'pack/ue_pak.py'), _load('uepak', 'translator/uepak.py')

# main 构建号（exefs/main 0x40 起 16 字节）→ [(说明, 取块函数, 原长, sha256)]；取块函数(根) → [(压缩块, 块原长)]，拼接后原长 / sha 按登记值核
def itt_blocks(root):   # 双人成行 1.0.2：Nuts-Switch.pak（v11，方法 1 = Oodle）里一个 5 块的 .uexp（块经 unreal_pak 取，解码器换成记块的桩）
    pk = UP.Pak(os.path.join(root, 'romfs/Nuts/Content/Paks/Nuts-Switch.pak')); h = pk.by_name['Engine/Content/EditorMaterials/AssetViewer/EpicQuadPanorama_CC+EV1.uexp']
    e = pk.entry(h); assert e['method'] == 'Oodle' and not e['encrypted']
    out = []; pk.read(h, decode=lambda b, k: (out.append((bytes(b), k)), bytes(k))[1]); pk.close()
    return out
def bayo3_blocks(root):   # 猎天使魔女3：romfs/root_000.pkz 的 OodleKraken 成员（整包 8 个成员全是）
    d = open(os.path.join(root, 'romfs/root_000.pkz'), 'rb').read(); ents = pkz.entries(d, oodle=True)
    return [(bytes(pkz.span(d, m.offset, m.stored, m.name)), m.size) for m in ents if pkz.is_oodle(m.compression)]
CASES = {
    'c4067e8cb3258656d8e9b448ee31aa38': [('双人成行 Nuts-Switch.pak EpicQuadPanorama_CC+EV1.uexp（5 块 Oodle，公开入口 OodleLZ_Decompress）', itt_blocks, 1049043, '6546866e492ed02f23261d6d2a86b2265ce59534395026675cfdb47ec6697f6c')],
    'b47cc79b88b7091ea514b2b725c50ae0': [('猎天使魔女3 root_000.pkz 全部 8 个 OodleKraken 成员（Decoder 三件套）', bayo3_blocks, None, None)],   # 原长 / sha 由 BAYO3_EXPECT 给（下面）
}
BAYO3_EXPECT = (58787601, 'ab4204d3b7d9c3d4fb5e445f121b2ed3929c1d798365a43506cf11fa8278e361')   # 10-28 首次真解（SERVE 与 JOB 一致）；索引原长合计 = 实测

def main():
    roots = sys.argv[1:]
    if not roots: print(__doc__ or open(__file__).read().split('\n')[1]); return 2
    host = os.environ.get('DM_OODLE_HOST') or os.path.join(H, 'build/s2arm-host')
    if not os.path.isfile(host): print(f'【红】没有宿主 {host}（make host）'); return 1
    bad = n = 0
    for root in roots:
        main_p = os.path.join(root, 'exefs/main')
        if not os.path.isfile(main_p) or not os.path.isfile(os.path.join(root, 'main.fixups.tsv')): print(f'跳过 {root}：不是产物根（要 exefs/main 与 main.fixups.tsv）'); continue
        bid = open(main_p, 'rb').read(0x50)[0x40:0x50].hex()
        if bid not in CASES: print(f'跳过 {root}：main 构建号 {bid} 没登记期望值'); continue
        for name, fn, want_n, want_sha in CASES[bid]:
            if want_n is None: want_n, want_sha = BAYO3_EXPECT
            record_only = want_n is None   # 期望值还没登记：跑一遍把实测值打出来（供登记），SERVE / JOB 两路仍要一致
            blocks = fn(root); n += 1
            # ① SERVE
            h = U.OodleHost(host, root)
            try: got = b''.join(h(c, m) for c, m in blocks)
            except ValueError as e: print(f'✗ {name} SERVE：{e}'); bad += 1; h.close(); continue
            h.close(); sha = hashlib.sha256(got).hexdigest()
            if record_only:
                want_n, want_sha = sum(mm for _, mm in blocks), sha   # 原长由索引给，sha 取实测（只用于本次打印，不算通过）
                print(f'（登记用）{name}：{len(blocks)} 块，索引原长合计 {want_n}，实测 {len(got)} 字节，sha256 {sha}')
            ok1 = (len(got), sha) == (want_n, want_sha) and not record_only
            print(f'{"✓" if ok1 else "✗"} {name} SERVE：{len(blocks)} 块 → {len(got)} 字节 sha256 {sha[:16]}…（期望 {want_n} 字节 {want_sha[:16]}…{"，期望值未登记" if record_only else ""}）')
            # ② JOB
            job = tempfile.mktemp(suffix='.dmoj')
            with open(job, 'wb') as w:
                w.write(struct.pack('<II', U.JOB_MAGIC, len(blocks)))
                for c, m in blocks: w.write(struct.pack('<II', len(c), m) + c)
            r = subprocess.run([host, root], env=dict(os.environ, DM_OODLE_JOB=job), capture_output=True, text=True)
            o = open(job + '.out', 'rb').read() if os.path.exists(job + '.out') else b''; os.remove(job)
            if os.path.exists(job + '.out'): os.remove(job + '.out')
            parts = []; q = 8
            if len(o) >= 8 and struct.unpack_from('<II', o) == (U.OUT_MAGIC, len(blocks)):
                for _ in blocks: L, = struct.unpack_from('<I', o, q); q += 4; parts.append(o[q:q + L]); q += L
            got2 = b''.join(parts); ok2 = r.returncode == 0 and got2 == got
            print(f'{"✓" if ok2 else "✗"} {name} JOB：rc={r.returncode}，{len(parts)} 条 → {len(got2)} 字节，{"与 SERVE 一致" if got2 == got else "与 SERVE 不一致"}')
            bad += (not ok1) + (not ok2)
    print(f'{"✓" if not bad else "✗"} t_oodle_real：{bad} 处不符（{n} 款 × 2 路）'); return 1 if bad or not n else 0
if __name__ == '__main__': sys.exit(main())
