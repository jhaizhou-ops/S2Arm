#!/usr/bin/env python3
"""Unity 5.5 layout: synthetic bytes only, never game/translation evidence.

Run: python3 graphics/tools/direct/tests/t_unity55_layout.py [--reader unityfs.py]
The optional reader path runs the SAME fixtures against an old/mutated reader.
Fixture writers below are explicit field writes from the cited 5.5 format, not
walks of SHADER_5_5/Node. Expected offsets, values and counts are handwritten.
Requires the repository's existing lz4 dependency; no downloads or Apple tools.
"""
import argparse
import importlib.util
import os
from pathlib import Path
import struct
import sys
import tempfile
import unittest

import lz4.block

TOOLS = Path(__file__).resolve().parents[4] / 'translator'
HASH = bytes.fromhex('4496e93f2179252104401c8dda0a1751')
U = None
SS = None


def pack(fmt, *values):
    return struct.pack('<' + fmt, *values)


def aligned(data):
    return data + bytes(-len(data) % 4)


def string(text):
    raw = text.encode('utf-8')
    return aligned(pack('i', len(raw)) + raw)


def vector(entries):
    return pack('i', len(entries)) + b''.join(entries)


def tags():
    return pack('i', 1) + string('Queue') + string('Opaque')


def float_value(value):
    return pack('f', value) + string('')


def parameter():
    # Three i32 + two i8 + two padding bytes = 16, independent of layout DSL.
    return pack('iiibb', 11, 12, 13, -1, 4) + b'\0\0'


def texture():
    # No MultiSampled byte in 5.5: dimension lives at byte 12, not 13.
    return pack('iiib', 21, 22, 23, 3) + b'\0\0\0'


def constant_buffer(nonempty=True):
    if not nonempty:
        # Name, matrix count, vector count, size. No struct count/partial flag.
        return pack('iiii', 31, 0, 0, 64)
    return pack('i', 31) + vector([parameter()]) + vector([parameter()]) + pack('i', 64)


def subprogram(index=0, keywords=(0x2345,), nonempty=False):
    # One bind channel: bytes 8..9, padding 10..11, source map 12..15.
    head = pack('Iibb', index, 1, -2, 3) + b'\0\0' + pack('I', 0x11223344)
    head += vector([pack('H', k) for k in keywords])
    # Critically, no keyword-array alignment here. For one keyword, tier/type
    # are at 22/23 and the seven empty parameter counts end at byte 52.
    head = aligned(head + pack('bb', 2, 26 if index == 0 else 27))
    if not nonempty:
        return head + pack('7i', 0, 0, 0, 0, 0, 0, 0)
    return head + b''.join(vector([item]) for item in (
        parameter(), parameter(), texture(), pack('ii', 24, 25),
        constant_buffer(), pack('ii', 32, 33), pack('iii', 41, 42, 43)))


def state():
    data = string('state')
    data += b''.join(float_value(i) for i in range(1, 57))  # eight RTs, seven fields
    data += b'\1\0\0\0'
    data += b''.join(float_value(i) for i in range(101, 107))  # no zClip/conservative
    data += b''.join(float_value(i) for i in range(201, 213))  # three stencil ops
    data += b''.join(float_value(i) for i in range(301, 307))
    data += b''.join(float_value(i) for i in range(401, 405)) + string('fog')
    return data + pack('ii', 2, 19) + tags() + pack('i', 99) + b'\1\0\0\0'


def shader_pass():
    data = pack('i', 1) + string('main') + pack('ii', 0, 0) + state() + pack('I', 0x11)
    data += vector([subprogram(0, nonempty=True)])
    data += vector([subprogram(1, keywords=(5, 7))])
    data += pack('3i', 0, 0, 0)  # geometry, hull, domain
    # Only one boolean in 5.5; the later procedural-instancing flag is absent.
    return data + b'\1\0\0\0' + string('use') + string('pass') + string('tex') + tags()


def switch_program(stage):
    # Shape-only code: 0x10 wrapper + 0x880 control + 0x80 code = 0x910 bytes.
    # There are NO real GPU instructions, and nothing is compiled/executed.
    ctl = bytearray(0x880)
    ctl[:4] = bytes.fromhex('34127698')
    struct.pack_into('<I', ctl, 0x20, 0x880)
    struct.pack_into('<I', ctl, 0x704, 0x80)
    code = bytearray(0x80)
    code[:4] = bytes.fromhex('78563412')
    struct.pack_into('<I', code, 0x30, (1 if stage == 'vs' else 5) << 10)
    return pack('4i', 0, 0, 0x880, 0x80) + ctl + code


def blob_entry(stage):
    # 201608170: version/type, 12 stats bytes, extra 4 bytes, zero keywords,
    # code length = 32 header bytes; plus 0x910 program = 0x930 bytes.
    code = switch_program(stage)
    return pack('8i', 201608170, 26 if stage == 'vs' else 27, 0, 0, 0, 0, 0, 0x910) + code


def shader_object():
    prop = string('_Tint') + string('D') + vector([string('hdr')])
    prop += pack('iI4f', 0, 4, 1, 2, 3, 4) + string('white') + pack('i', 2)
    parsed = vector([prop]) + vector([vector([shader_pass()]) + tags() + pack('i', 101)])
    parsed += string('synthetic') + string('editor') + string('fallback')
    parsed += vector([string('from') + string('to')]) + b'\1\0\0\0'
    # Two old-format entries: 4 + 2*8 = 0x14; second starts at 0x14+0x930=0x944.
    blob = pack('5I', 2, 0x14, 0x930, 0x944, 0x930) + blob_entry('vs') + blob_entry('ps')
    compressed = lz4.block.compress(blob, store_size=False)
    data = string('outer') + parsed
    data += vector([pack('I', 19)]) + vector([pack('I', 0)])
    data += vector([pack('I', len(compressed))]) + vector([pack('I', 0x1274)])
    data += aligned(pack('i', len(compressed)) + compressed)
    # 12-byte PPtr (format >=14), then baked boolean. No texture map in 5.5.
    return data + vector([pack('iq', 2, 0x1122334455667788)]) + b'\1\0\0\0'


def serialized(obj, cid=48, type_hash=HASH, version='5.5.0p1'):
    meta = version.encode() + b'\0' + pack('i?i', 38, False, 1)
    meta += pack('iBh', cid, 0, -1) + type_hash + pack('i', 1)
    meta += bytes(-(20 + len(meta)) % 4)
    meta += pack('qIIi', 7, 0, len(obj), 0)
    meta += pack('ii', 0, 0) + b'\0'  # script refs, externals, user info
    offset = (20 + len(meta) + 15) & ~15
    header = struct.pack('>4I', len(meta), offset + len(obj), 17, offset) + bytes(4)
    return header + meta + bytes(offset - 20 - len(meta)) + obj


def known_trees():
    return {key: U.known_tree(*key) for key in U.KNOWN_TREES}


def decode(root, data, layout=None):
    tree = U.tree_from_layout(root, U.SHADER_5_5 if layout is None else layout)
    reader = U.Reader(data, True)
    value = U._read(reader, tree)
    return value, reader.p


class Unity55Layout(unittest.TestCase):
    def test_exact_registration(self):
        self.assertIn((48, HASH), U.KNOWN_TREES)
        self.assertNotIn((72, HASH), U.KNOWN_TREES)
        self.assertNotIn((48, bytes(16)), U.KNOWN_TREES)
        for cid, h in ((48, 'ea424a5fc1e48db62144df956f9e1005'),
                       (48, 'a30e3dcf6c6d25153d6f64e5e41caf4e'),
                       (48, '8db760073e1392061e4a36995f0735af')):
            self.assertIn((cid, bytes.fromhex(h)), U.KNOWN_TREES)
        # 10-29: the 2022.3 ComputeShader layout copied from TypeTreeDumps (no license) is gone; compute kernels are found without a tree
        self.assertNotIn((72, bytes.fromhex('bfdf63ab0ce84d5a2c765ee560d90fe7')), U.KNOWN_TREES)

    def test_odd_keyword_hand_offsets(self):
        raw = subprogram()
        self.assertEqual(len(raw), 52)
        self.assertEqual(raw[20:24], bytes.fromhex('4523021a'))
        obj, end = decode('SerializedSubProgram', raw)
        self.assertEqual(end, 52)
        self.assertEqual(obj['m_BlobIndex'], 0)
        self.assertEqual(obj['m_Channels']['m_Channels'], [{'source': -2, 'target': 3}])
        self.assertEqual(obj['m_Channels']['m_SourceMap'], 0x11223344)
        self.assertEqual(obj['m_KeywordIndices'], [0x2345])
        self.assertEqual((obj['m_ShaderHardwareTier'], obj['m_GpuProgramType']), (2, 26))
        self.assertNotIn('m_Samplers', obj)
        self.assertNotIn('m_ShaderRequirements', obj)

    def test_even_keyword_hand_offsets(self):
        raw = subprogram(1, (5, 7))
        self.assertEqual(len(raw), 56)
        self.assertEqual(raw[24:28], bytes.fromhex('021b0000'))
        obj, end = decode('SerializedSubProgram', raw)
        self.assertEqual(end, 56)
        self.assertEqual(obj['m_KeywordIndices'], [5, 7])
        self.assertEqual((obj['m_ShaderHardwareTier'], obj['m_GpuProgramType']), (2, 27))

    def test_texture_and_constant_buffer(self):
        obj, end = decode('TextureParameter', texture())
        self.assertEqual((end, obj), (16, {'m_NameIndex': 21, 'm_Index': 22,
                                         'm_SamplerIndex': 23, 'm_Dim': 3}))
        obj, end = decode('ConstantBuffer', constant_buffer(False))
        self.assertEqual((end, obj), (16, {'m_NameIndex': 31, 'm_MatrixParams': [],
                                         'm_VectorParams': [], 'm_Size': 64}))
        obj, end = decode('ConstantBuffer', constant_buffer())
        self.assertEqual(end, 48)
        self.assertEqual(obj['m_MatrixParams'][0]['m_RowCount'], 4)
        self.assertEqual(obj['m_VectorParams'][0]['m_Dim'], 4)
        self.assertEqual(obj['m_Size'], 64)

    def test_complete_object_nonempty_fields(self):
        raw = shader_object()
        obj, end = decode('Shader', raw)
        self.assertEqual(end, len(raw))
        parsed = obj['m_ParsedForm']
        self.assertEqual((obj['m_Name'], parsed['m_Name']), ('outer', 'synthetic'))
        prop = parsed['m_PropInfo']['m_Props'][0]
        self.assertEqual(prop['m_Attributes'], ['hdr'])
        self.assertEqual([prop[f'm_DefValue[{i}]'] for i in range(4)], [1, 2, 3, 4])
        self.assertEqual(prop['m_DefTexture'], {'m_DefaultName': 'white', 'm_TexDim': 2})
        p = parsed['m_SubShaders'][0]['m_Passes'][0]
        s = p['m_State']
        self.assertEqual(s['rtBlend7']['colMask']['val'], 56)
        self.assertEqual(s['zTest']['val'], 101)
        self.assertEqual(s['alphaToMask']['val'], 106)
        self.assertEqual(s['stencilOpBack']['comp']['val'], 212)
        self.assertEqual(s['fogDensity']['val'], 306)
        self.assertEqual(s['fogColor']['w']['val'], 404)
        self.assertEqual((s['m_LOD'], s['lighting']), (99, True))
        self.assertNotIn('zClip', s)
        self.assertNotIn('m_HasProceduralInstancingVariant', p)
        sp = p['progVertex']['m_SubPrograms'][0]
        self.assertEqual(sp['m_TextureParams'][0]['m_Dim'], 3)
        self.assertEqual(sp['m_BufferParams'], [{'m_NameIndex': 24, 'm_Index': 25}])
        self.assertEqual(sp['m_ConstantBuffers'][0]['m_Size'], 64)
        self.assertEqual(sp['m_ConstantBufferBindings'], [{'m_NameIndex': 32, 'm_Index': 33}])
        self.assertEqual(sp['m_UAVParams'], [{'m_NameIndex': 41, 'm_Index': 42, 'm_OriginalIndex': 43}])
        self.assertEqual(parsed['m_Dependencies'], [{'from': 'from', 'to': 'to'}])
        self.assertEqual(obj['m_Dependencies'], [{'m_FileID': 2, 'm_PathID': 0x1122334455667788}])
        self.assertTrue(obj['m_ShaderIsBaked'])
        self.assertNotIn('m_NonModifiableTextures', obj)
        self.assertEqual((obj['platforms'], obj['offsets'], obj['decompressedLengths']), ([19], [0], [0x1274]))

    def test_v17_first_pass_then_exact_fallback(self):
        data = serialized(shader_object())
        self.assertTrue(U.is_serialized(data))
        with self.assertRaises(U.NoTree):
            list(U.serialized_objects(data, {}, {48}, {}))
        rows = list(U.serialized_objects(data, {}, {48}, known_trees()))
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0][:2], (48, 7))
        self.assertEqual(rows[0][2]['m_ParsedForm']['m_Name'], 'synthetic')

    def test_wrong_hash_or_class_still_notree(self):
        for cid, h in ((48, bytes(16)), (72, HASH), (48, HASH[:-1] + b'\x50')):
            with self.subTest(cid=cid, h=h.hex()), self.assertRaises(U.NoTree):
                list(U.serialized_objects(serialized(shader_object(), cid, h), {}, None, known_trees()))
        # Same version string is not a fallback key, including nearby releases.
        for version in ('5.5.0p1', '5.5.0p2', '2018.3.10f1'):
            with self.subTest(version=version), self.assertRaises(U.NoTree):
                list(U.serialized_objects(serialized(shader_object(), type_hash=bytes(16), version=version), {}, None, known_trees()))

    def test_format_guard_unchanged(self):
        for version in (16, 23):
            data = bytearray(serialized(shader_object()))
            struct.pack_into('>I', data, 8, version)
            self.assertFalse(U.is_serialized(data))
            with self.assertRaisesRegex(ValueError, 'not supported'):
                list(U.serialized_objects(data, {}, {48}, known_trees()))

    def test_wrong_keyword_alignment_negative_control(self):
        original = 'vector<data:UInt16>~ m_KeywordIndices'
        self.assertEqual(U.SHADER_5_5.count(original), 1)
        bad = U.SHADER_5_5.replace(original, 'vector<data:UInt16> m_KeywordIndices')
        with self.assertRaises(struct.error):
            decode('SerializedSubProgram', subprogram(), bad)

    def test_required_field_truncations_reject(self):
        # Required bytes, not a claim that the generic reader validates padding.
        for raw in (subprogram()[:22], subprogram()[:-1]):
            with self.subTest(size=len(raw)), self.assertRaises(struct.error):
                decode('SerializedSubProgram', raw)
        with self.assertRaises(struct.error):
            decode('TextureParameter', texture()[:12])
        with self.assertRaises(struct.error):
            list(U.serialized_objects(serialized(shader_object()[:-4]), {}, {48}, known_trees()))

    def test_old_single_segment_and_split(self):
        obj, _ = decode('Shader', shader_object())
        entries = list(U.shader_programs(obj))
        self.assertEqual([(plat, k, len(b)) for plat, k, b in entries], [(19, 0, 0x930), (19, 1, 0x930)])
        self.assertEqual([U.subprogram(b)[4] for _, _, b in entries], [switch_program('vs'), switch_program('ps')])
        self.assertEqual(SS.unity_stages(obj), {0: 'vs', 1: 'ps'})
        self.assertIsNone(SS.unity_code_blobs(obj))
        out = []
        SS.unity_shaders(serialized(shader_object()), 'synthetic', out, known_trees())
        self.assertEqual([(w, st, len(ctl), len(code)) for w, st, ctl, code in out],
                         [('synthetic#synthetic#var19.0', 'vs', 0x880, 0x80),
                          ('synthetic#synthetic#var19.1', 'ps', 0x880, 0x80)])

    def test_switch_triple_check_negative_controls(self):
        good = switch_program('vs')
        with self.assertRaisesRegex(SystemExit, 'stage is not in m_ParsedForm'):
            SS.unity_program(good, 'synthetic')
        # A bad block is left out and counted (10-29: one bad block no longer stops the whole extraction)
        bad_len = bytearray(good)
        struct.pack_into('<I', bad_len, 0x10 + 0x704, 0x7f)
        bad_magic = bytearray(good)
        bad_magic[0x890:0x894] = bytes(4)
        for raw, why in ((bad_len, 'control.*length'), (bad_magic, 'header magic'), (good[:-1], 'out of bounds')):
            n = len(SS.SKIPPED)
            self.assertEqual(SS.unity_program(bytes(raw), 'synthetic', 'vs'), [])
            self.assertEqual(len(SS.SKIPPED), n + 1)
            self.assertRegex(SS.SKIPPED[-1][1], why)


def main():
    global U, SS
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--reader', type=Path, default=TOOLS / 'unityfs.py')
    args = parser.parse_args()
    spec = importlib.util.spec_from_file_location('unityfs', args.reader)
    U = importlib.util.module_from_spec(spec)
    sys.modules['unityfs'] = U
    spec.loader.exec_module(U)
    # The real shader_split import reads only this isolated synthetic profile.
    # Never select a user's game or import the script's CLI main().
    with tempfile.TemporaryDirectory(prefix='unity55-layout-') as tmp:
        (Path(tmp) / 'game.tsv').write_text('shader_groups\tsynthetic=synthetic\nshader_note\tsynthetic\n')
        previous = os.environ.get('DM_GAME')
        os.environ['DM_GAME'] = tmp
        try:
            sys.path.insert(0, str(TOOLS))
            import shader_split
            SS = shader_split
            SS.COMMON = {}
            suite = unittest.defaultTestLoader.loadTestsFromTestCase(Unity55Layout)
            result = unittest.TextTestRunner(verbosity=2).run(suite)
        finally:
            if previous is None:
                os.environ.pop('DM_GAME', None)
            else:
                os.environ['DM_GAME'] = previous
    print(f'Unity 5.5 合成布局：{result.testsRun} 项，失败 {len(result.failures)}，错误 {len(result.errors)}；真实游戏未验')
    return 0 if result.wasSuccessful() else 1


if __name__ == '__main__':
    sys.exit(main())
