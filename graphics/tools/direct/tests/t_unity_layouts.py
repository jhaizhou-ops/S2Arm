#!/usr/bin/env python3
"""Unity 无类型树的序列化文件：按版本生成 Shader 布局、计算着色器免树找 kernel、空 / 坏程序块跳过计数。只用合成字节，不读游戏。

  python3 graphics/tools/direct/tests/t_unity_layouts.py [--tools <放 unityfs.py / shader_split.py 的目录>]
--tools 指向旧版本（如 origin/main 的两个文件）跑同一批用例 = 修前读数。

期望怎么来的（不跑被测实现）：
  · 布局金样：unity_layouts_golden.py 里三份布局原文，各自对过真实类型树或 MIT 公开 reader（来源见其注释）；生成的布局要与之逐字节等价。
  · 合成 Shader：下面的 writer 按 AssetStudio d158e864 Shader.cs 的版本分支逐字段手写字节（2017.2 zClip、2017.3 多重采样 / 结构参数、
    2018 程序化实例 / 不可改纹理表、2019.1 全局 / 局部关键字、2019.3 光追程序 / 分段），不走被测布局；期望的程序块数、阶段、长度手算。
  · 计算着色器：kernel 的代码字节是向量（i32 长度 + 程序码），程序码自校验（控制段魔数、代码魔数、长度对得上）。
"""
import argparse, importlib.util, os, struct, sys, tempfile, unittest
from pathlib import Path

import lz4.block

HERE = Path(__file__).resolve().parent
TOOLS = HERE.parents[3] / 'translator'
sys.path.insert(0, str(HERE)); import unity_layouts_golden as G
U = SS = None
HASH = bytes.fromhex('266d5311000000000000000000000001')   # 不在任何已知表里的 type hash
CS_HASH = bytes.fromhex('1a955290000000000000000000000002')


def pack(fmt, *v): return struct.pack('<' + fmt, *v)
def aligned(b): return b + bytes(-len(b) % 4)
def string(t): r = t.encode(); return aligned(pack('i', len(r)) + r)
def vector(items): return pack('i', len(items)) + b''.join(items)
def u16s(vals): return aligned(pack('i', len(vals)) + b''.join(pack('H', x) for x in vals))
def flt(x): return pack('f', x) + string('')
def tags(): return pack('i', 1) + string('Queue') + string('Geometry')


def ctl_code(stage):
    """控制段 0x880（魔数、+0x20 自身长度、+0x704 代码区长度）+ 代码区 0x80（图形魔数 / 计算魔数）；没有真指令"""
    ctl = bytearray(0x880); ctl[:4] = bytes.fromhex('34127698')
    struct.pack_into('<I', ctl, 0x20, 0x880); struct.pack_into('<I', ctl, 0x704, 0x80)
    if stage == 'cs': struct.pack_into('<3I', ctl, 0x748, 8, 8, 1)
    code = bytearray(0x80); code[:4] = bytes.fromhex('79563412' if stage == 'cs' else '78563412')
    if stage != 'cs': struct.pack_into('<I', code, 0x30, (1 if stage == 'vs' else 5) << 10)
    return bytes(ctl), bytes(code)


def program_old(stage):   # 2019.3 前：0x10 头 {0, 0, 控制段长, 代码区长} + 控制段 + 代码区 = 0x910
    ctl, code = ctl_code(stage); return pack('4i', 0, 0, len(ctl), len(code)) + ctl + code


def program_new(stage):   # 2019.3 起：0x60 头（6 阶段 × {保留, 块偏移, 控制段长, 代码区长}）+ 一个阶段块 = 0x960
    ctl, code = ctl_code(stage); i = ['vs', 'ps', 'gs', 'hs', 'ds', 'cs'].index(stage)
    off = [-1] * 6; off[i] = 0; nc = [0] * 6; nc[i] = len(ctl); nk = [0] * 6; nk[i] = len(code)
    return pack('24i', *([0] * 6 + off + nc + nk)) + ctl + code


def ge(v, *w): return v >= w


def state(v):
    b = string('st') + b''.join(flt(i) for i in range(56)) + b'\0\0\0\0'
    b += flt(1) * ge(v, 2017, 2) + flt(2) * 3 + flt(3) * ge(v, 2020, 1) + flt(4) * 3   # zClip / zTest zWrite culling / conservative / offset ×2 alphaToMask
    b += flt(5) * 12 + flt(6) * 3 + flt(7) * 3 + flt(8) * 4 + string('fog')   # 3 个模板操作、模板掩码 ×2 与参考、雾 ×3、雾色
    return b + pack('ii', 0, 7) + tags() + pack('i', 100) + b'\1\0\0\0'


def params(v):
    """8 组参数（向量 / 矩阵 / 纹理 / 缓冲 / 常量缓冲 / 常量缓冲绑定 / UAV / sampler）；2020.3.2 起套进 SerializedProgramParameters，字节不变"""
    tex = aligned(pack('iii', 1, 2, 3) + b'\0' * ge(v, 2017, 3) + pack('b', 2))   # 2017.3 起多一个 m_MultiSampled
    cb = pack('i', 9) + vector([]) + vector([]) + vector([]) * ge(v, 2017, 3) + pack('i', 64)   # 2017.3 起多结构参数
    if ge(v, 2020, 3, 2) and not (2021,) <= v < (2021, 1, 4): cb += b'\1\0\0\0'   # m_IsPartialCB
    buf = pack('ii', 4, 5) + pack('i', 1) * ge(v, 2020)   # 2020 起 BufferBinding.m_ArraySize
    return vector([]) + vector([]) + vector([tex]) + vector([buf]) + vector([cb]) + vector([]) + vector([]) + vector([pack('Ii', 0, 1)]) * ge(v, 2017)


def subprogram(v, blob):
    b = pack('I', blob) + pack('i', 1) + pack('bb', 0, 1) + b'\0\0' + pack('i', 3)   # 1 个绑定通道（2 字节、补齐）+ m_SourceMap
    b += u16s([1, 2]) + u16s([3]) if (2019,) <= v < (2021, 2) else u16s([1, 2, 3])
    b += pack('bb', 0, 25) + b'\0\0' + params(v)
    if ge(v, 2017, 2): b += pack('q', 0x5a) if ge(v, 2021) else pack('i', 0x5a)   # m_ShaderRequirements：2021 起 64 位
    return b


def program(v, blobs, player, params_blob):
    """SerializedProgram：子程序；player = 带 2022 式玩家子程序表与参数条目表（blobs 在玩家表里，params_blob 是参数条目）"""
    b = vector([subprogram(v, x) for x in blobs])
    if player and blobs: b += vector([vector([pack('I', x) + u16s([1]) + pack('q', 0x5a) + b'\x19\0\0\0' for x in blobs])]) + vector([vector([pack('I', params_blob)])])
    elif player: b += vector([]) + vector([])
    if ge(v, 2020, 3, 2) and not (2021,) <= v < (2021, 1, 1): b += params(v)   # m_CommonParameters
    return b + u16s([7]) * ge(v, 2022, 1)   # 2022.1 起 m_SerializedKeywordStateMask 在这里


def shader_pass(v, player=False):
    b = b''
    if ge(v, 2020, 2): b += vector([]) + aligned(pack('i', 1) + b'\x13')   # m_EditorDataHash、m_Platforms
    if (2020, 2) <= v < (2021, 2): b += u16s([1]) + u16s([2])   # 局部 / 全局关键字掩码
    b += pack('i', 1) + string('n') + pack('i', 0) + pack('i', 0) + state(v) + pack('I', 3)
    b += program(v, [0], player, 2) + program(v, [1], player, 3) + program(v, [], player, 0) * (3 + ge(v, 2019, 3))   # 顶点、片元、几何 / 曲面 ×2，2019.3 起光追
    b += aligned(b'\1' + b'\0' * ge(v, 2018))   # m_HasInstancingVariant，2018 起 m_HasProceduralInstancingVariant
    b += string('') + string('FORWARD') + string('') + tags()
    return b + u16s([7]) * ((2021, 2) <= v < (2022, 1))   # 2021.2–2021.x 的 m_SerializedKeywordStateMask 在 pass 上


def shader_object(v, blob, player=False):
    prop = string('_Color') + string('Color') + vector([]) + pack('iI4f', 0, 0, 1, 1, 1, 1) + string('') + pack('i', 0)
    parsed = vector([prop]) + vector([vector([shader_pass(v, player)]) + tags() + pack('i', 100)])
    if ge(v, 2021, 2): parsed += vector([string('_KW')]) + aligned(pack('i', 1) + b'\0')   # m_KeywordNames、m_KeywordFlags
    parsed += string('Synth/Lit') + string('') + string('') + vector([]) + vector([]) * ge(v, 2021) + b'\0\0\0\0'   # 2021 起 m_CustomEditorForRenderPipelines
    comp = lz4.block.compress(blob, store_size=False)
    one = (lambda x: vector([vector([pack('I', x)])])) if ge(v, 2019, 3) else (lambda x: vector([pack('I', x)]))   # 2019.3 起每平台多段
    b = string('Synth/Lit') + parsed + vector([pack('I', 19)]) + one(0) + one(len(comp)) + one(len(blob)) + aligned(pack('i', len(comp)) + comp)
    if player: b += vector([pack('I', 1), pack('I', 1)])   # stageCounts
    b += vector([pack('iq', 0, 5)])
    if ge(v, 2018): b += pack('i', 1) + string('_Tex') + pack('iq', 0, 6)   # m_NonModifiableTextures
    return b + b'\1\0\0\0'


def blob(v, player=False):
    """子程序（顶点 / 片元，player 时再加两个参数条目）的平台块：子程序头 {版本, 类型, 12 字节统计, 4 字节, 关键字 0 个, [局部关键字 0 个], 代码长, 代码}"""
    sv = 202012090 if ge(v, 2021, 2) else 201806140 if ge(v, 2019) else 201708220
    ents = []
    for st in ('vs', 'ps'):
        code = program_new(st) if ge(v, 2019, 3) else program_old(st)
        ents.append(pack('ii', sv, 25) + bytes(16) + pack('i', 0) + pack('i', 0) * (201806140 <= sv < 202012090) + aligned(pack('i', len(code)) + code))
    if player: ents += [b'PARM' * 8, b'parm' * 8]   # 参数条目不是程序码，不能被当代码读
    w = 12 if ge(v, 2019, 3) else 8; o = 4 + w * len(ents); head = pack('I', len(ents))
    for e in ents: head += pack('III', o, len(e), 0) if w == 12 else pack('II', o, len(e)); o += len(e)
    return head + b''.join(ents)


def serialized(obj, version, cid=48, h=HASH, fmt=17):
    """无类型树的序列化文件（格式 17–21 在无树时元数据一样）：版本串、平台、无树、1 个类型、1 个对象"""
    meta = version.encode() + b'\0' + pack('i?i', 38, False, 1) + pack('iBh', cid, 0, -1) + h + pack('i', 1)
    meta += bytes(-(20 + len(meta)) % 4) + pack('qIIi', 7, 0, len(obj), 0) + pack('ii', 0, 0) + b'\0'
    off = (20 + len(meta) + 15) & ~15
    return struct.pack('>4I', len(meta), off + len(obj), fmt, off) + bytes(4) + meta + bytes(off - 20 - len(meta)) + obj


# 自拟的玩具 ComputeShader 布局（不是任何 Unity 版本的真布局）：只为让「有树」路径走到 kernel_variants 的「kernel 自带 code」分支
TOY_CS = """ToyKernel: string name; vector<data:UInt8> code; int extra
ToyVariant: int targetRenderer; vector<data:ToyKernel> kernels
ComputeShader: string m_Name; vector<data:ToyVariant> variants
"""


def toy_compute(codes):
    """玩具布局的 ComputeShader 对象：1 个平台变体，每段代码一个 kernel（K0、K1…）"""
    ks = [string(f'K{i}') + aligned(pack('i', len(c)) + c) + pack('i', 7) for i, c in enumerate(codes)]
    return string('Synth/CS') + vector([pack('i', 19) + vector(ks)])


def canon(n):
    """类型树 → 只看字节的形：(读宽 / 结构, 名字, 读完后是否对齐, 子节点)；有符号与否、对齐记在容器还是它的 Array 上不影响字节"""
    if n.type in U.PRIM and not n.kids: return (U.PRIM[n.type].lower(), n.name, bool(n.flags & 0x4000))
    al = bool(n.flags & 0x4000) or any(k.type == 'Array' and k.flags & 0x4000 for k in n.kids)
    kids = n.kids[0].kids[1:] if n.kids and n.kids[0].type == 'Array' else n.kids
    kind = 'str' if n.type == 'string' else 'seq' if n.kids and n.kids[0].type == 'Array' else 'rec'
    return (kind, n.name, al, tuple(canon(k) for k in kids))


class Layouts(unittest.TestCase):
    def test_generated_equals_golden(self):
        for ver, gold in (((5, 5, 0), G.SHADER_5_5), ((2020, 3, 18), G.SHADER_2020_3), ((2020, 3, 30), G.SHADER_2020_3),
                          ((2022, 3, 5), G.SHADER_2022_3), ((2022, 3, 17), G.SHADER_2022_3)):
            with self.subTest(ver=ver):
                self.assertEqual(canon(U.tree_from_layout('Shader', U.shader_layout(ver))), canon(U.tree_from_layout('Shader', gold)))

    def test_no_tree_shaders_by_version(self):
        # 本次普查的四个 hash 落在 2017.4 / 2019.2 / 2019.4；2020.3–2022.3 各取一点；2021.3.20 在「玩家子程序表」有无不明的窗口里，两种都要能解（对象字节定）
        # 另在 AssetStudio 版本分支的边界上各取一点（2017.1 / 2020.3.2 / 2021.2.0 / 2022.1.0）
        for version, fmt, player in (('2017.1.5f1', 17, False), ('2017.4.15f1', 17, False), ('2018.2.17f1', 17, False), ('2018.3.10f1', 17, False), ('2019.2.17f1', 19, False), ('2019.4.31f1', 21, False), ('2020.3.2f1', 21, False),
                                     ('2020.3.30f1', 21, False), ('2021.2.0f1', 21, False), ('2021.3.20f1', 21, False), ('2021.3.20f1', 21, True), ('2021.3.34f1', 21, True),
                                     ('2022.1.0f1', 21, False), ('2022.1.0f1', 21, True), ('2022.3.17f1', 21, True)):
            v = tuple(int(x) for x in version.split('f')[0].split('.'))
            with self.subTest(version=version, player=player):
                data = serialized(shader_object(v, blob(v, player), player), version, fmt=fmt)
                with self.assertRaises(U.NoTree): SS.unity_shaders(data, 'syn', [], {})   # 第一遍：没有树，延后
                SS.SECOND = True
                try:
                    out = []; SS.unity_shaders(data, 'syn', out, {})
                finally: SS.SECOND = False
                self.assertEqual([(w, st, len(c), len(k)) for w, st, c, k in out], [('syn#Synth/Lit#var19.0', 'vs', 0x880, 0x80), ('syn#Synth/Lit#var19.1', 'ps', 0x880, 0x80)])
                # 对齐会吞掉的字段（1 字节的 bool 落在补齐里）只看字节数抓不到，逐个看读出的值
                (_, _, o), = U.serialized_objects(data, {}, {48}, {}, layouts=True)
                ps = o['m_ParsedForm']['m_SubShaders'][0]['m_Passes'][0]; st = ps['m_State']; sub = ps['progVertex']['m_SubPrograms'][0]
                pp = sub.get('m_Parameters', sub); tex = pp['m_TextureParams'][0]; cb = pp['m_ConstantBuffers'][0]
                self.assertEqual(('zClip' in st, 'conservative' in st, st['zTest']['val'], st['alphaToMask']['val'], st['stencilReadMask']['val'], st['fogStart']['val'], st['m_LOD'], st['lighting']),
                                 (ge(v, 2017, 2), ge(v, 2020), 2, 4, 6, 7, 100, True))
                self.assertEqual((tex['m_Dim'], 'm_MultiSampled' in tex, cb['m_Size'], cb.get('m_IsPartialCB'), pp['m_BufferParams'][0].get('m_ArraySize'), pp['m_Samplers'], sub.get('m_ShaderRequirements')),
                                 (2, ge(v, 2017, 3), 64, True if ge(v, 2020, 3, 2) else None, 1 if ge(v, 2020) else None, [{'sampler': 0, 'bindPoint': 1}], 0x5a if ge(v, 2017, 2) else None))
                split_kw = (2019,) <= v < (2021, 2)
                kw = (sub['m_GlobalKeywordIndices'], sub['m_LocalKeywordIndices']) if split_kw else sub['m_KeywordIndices']
                self.assertEqual(kw, ([1, 2], [3]) if split_kw else [1, 2, 3])
                self.assertEqual((ps['m_HasInstancingVariant'], ps.get('m_HasProceduralInstancingVariant')), (True, False if ge(v, 2018) else None))
                self.assertEqual((ps.get('m_Platforms'), ps.get('m_SerializedKeywordStateMask'), ps['progVertex'].get('m_SerializedKeywordStateMask')),
                                 (b'\x13' if ge(v, 2020, 2) else None, [7] if (2021, 2) <= v < (2022, 1) else None, [7] if ge(v, 2022, 1) else None))
                self.assertEqual((ps['progVertex'].get('m_ParameterBlobIndices'), o.get('stageCounts'), o['m_ParsedForm'].get('m_KeywordNames')),
                                 ([[2]] if player else None, [1, 1] if player else None, ['_KW'] if ge(v, 2021, 2) else None))
                self.assertEqual((o['m_Dependencies'][0]['m_PathID'], len(o.get('m_NonModifiableTextures', [])), o['m_ShaderIsBaked']), (5, 1 if ge(v, 2018) else 0, True))

    def test_window_candidates(self):
        # 窗口外只有一份布局；窗口里两份，挑能整读全部对象的那份
        self.assertEqual([len(U.shader_layouts(v)) for v in ((2021, 2, 7), (2021, 3, 0), (2021, 3, 33), (2021, 3, 34), (2022, 1, 0), (2022, 3, 4), (2022, 3, 5))], [1, 2, 2, 1, 2, 2, 1])

    def test_wrong_version_or_extra_bytes_stop_loud(self):
        v = (2017, 4, 15); obj = shader_object(v, blob(v))
        for version, o in (('2018.1.0f1', obj), ('2019.4.31f1', obj), ('2017.4.15f1', obj + bytes(4))):
            with self.subTest(version=version, size=len(o)):
                with self.assertRaises(U.LayoutMismatch): list(U.serialized_objects(serialized(o, version), {}, {48}, {}, layouts=True))

    def test_version_source_and_range(self):
        v = (2017, 4, 15); obj = shader_object(v, blob(v))
        rows = list(U.serialized_objects(serialized(obj, ''), {}, {48}, {}, layouts=True, engine='2017.4.15f1'))   # 文件没记版本：用资源包头的
        self.assertEqual(rows[0][2]['m_ParsedForm']['m_Name'], 'Synth/Lit')
        for version in ('', '0.0.0', '2023.1.0f1', '5.4.6f1'):
            with self.subTest(version=version), self.assertRaises(U.NoTree):
                list(U.serialized_objects(serialized(obj, version), {}, {48}, {}, layouts=True))
        with self.assertRaises(U.NoTree):   # 不开 layouts（第一遍）不按版本猜
            list(U.serialized_objects(serialized(obj, '2017.4.15f1'), {}, {48}, {}))

    def test_empty_and_bad_blocks_skipped_and_counted(self):
        # Servonauts 的形：有树的计算着色器，一个 kernel 0 字节、一个正常 → 正常的出、空的跳过计数（修前：struct.error 整份停）
        data = serialized(toy_compute([b'', program_new('cs')]), '2021.3.20f1', 72, CS_HASH, 21)
        out = SS.unity_compute(data, 'syn', {(72, CS_HASH): U.tree_from_layout('ComputeShader', TOY_CS)})
        self.assertEqual([(w, st) for w, st, _, _ in out], [('syn#Synth/CS#K1.0', 'cs')])
        self.assertEqual([w for w, _ in SS.SKIPPED[-1:]], ['syn#Synth/CS#K0.0'])
        n = len(SS.SKIPPED)
        self.assertEqual(SS.unity_program(b'', 'syn#k.0', 'cs'), [])
        self.assertEqual(SS.unity_program(program_new('cs')[:0x40], 'syn#k.1', 'cs'), [])
        self.assertEqual([w for w, _ in SS.SKIPPED[n:]], ['syn#k.0', 'syn#k.1'])
        self.assertRegex(SS.SKIPPED[n][1], 'empty')

    def test_compute_kernels_without_tree(self):
        data = serialized(toy_compute([program_new('cs'), program_old('cs')]), '2019.4.31f1', 72, CS_HASH, 21)   # hash 不认得
        with self.assertRaises(U.NoTree): SS.unity_compute(data, 'syn', {})   # 第一遍延后
        SS.SECOND = True
        try: out = SS.unity_compute(data, 'syn', {})
        finally: SS.SECOND = False
        self.assertEqual([(w, st, len(c), len(k)) for w, st, c, k in out], [('syn#Synth/CS#kernel0', 'cs', 0x880, 0x80), ('syn#Synth/CS#kernel1', 'cs', 0x880, 0x80)])
        self.assertEqual(SS.unity_scan_kernels(string('x') + bytes(256)), [])   # 没有程序码就什么都不找到

    def test_no_pinned_compute_layout(self):
        # 原先按 hash bfdf63ab… 钉的 2022.3 ComputeShader 布局取自没有许可证的 TypeTreeDumps，已删：同一 hash 的对象（这里用玩具布局写）第二遍照样走免树扫描、
        # 不被钉死的布局误读（修前：钉的布局读玩具对象出错）。第二遍传进来的树就是 shader_split 给的那份：已知表全量
        data = serialized(toy_compute([program_new('cs')]), '2022.3.54f1', 72, bytes.fromhex('bfdf63ab0ce84d5a2c765ee560d90fe7'), 21)
        SS.SECOND = True
        try: out = SS.unity_compute(data, 'syn', {k: U.known_tree(*k) for k in U.KNOWN_TREES})
        finally: SS.SECOND = False
        self.assertEqual([(w, st) for w, st, _, _ in out], [('syn#Synth/CS#kernel0', 'cs')])
        self.assertFalse([k for k in U.KNOWN_TREES if k[0] == 72])


def main():
    global U, SS
    ap = argparse.ArgumentParser(); ap.add_argument('--tools', type=Path, default=TOOLS); a = ap.parse_args()
    spec = importlib.util.spec_from_file_location('unityfs', a.tools / 'unityfs.py'); U = importlib.util.module_from_spec(spec); sys.modules['unityfs'] = U; spec.loader.exec_module(U)
    with tempfile.TemporaryDirectory(prefix='unity-layouts-') as tmp:
        (Path(tmp) / 'game.tsv').write_text('shader_groups\tsyn=syn\nshader_note\tsyn\n')
        os.environ['DM_GAME'] = tmp
        sys.path.insert(0, str(a.tools)); sys.path[1:1] = [str(TOOLS), str(HERE.parents[3] / 'tools')]   # shader_split 依赖的 uepak / progress 取本仓的
        spec = importlib.util.spec_from_file_location('shader_split', a.tools / 'shader_split.py'); SS = importlib.util.module_from_spec(spec); spec.loader.exec_module(SS)
        SS.COMMON = {}
        r = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(Layouts))
    bad = len(r.failures) + len(r.errors)
    print(f'期望 Unity 无树布局 {r.testsRun} 项全过 → 真结果 失败 {bad} / {r.testsRun}（合成字节，真实游戏另验）')
    return 0 if r.wasSuccessful() else 1


if __name__ == '__main__': sys.exit(main())
