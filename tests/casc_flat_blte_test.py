#!/usr/bin/env python3
"""BLTE 分块边界：纯合成容器调用实际 casc_flat.blte/read，不读取游戏数据。"""
import hashlib
import importlib.util
import struct
import tempfile
import unittest
import zlib
from pathlib import Path

TOOL = Path(__file__).resolve().parent.parent / 'graphics/tools/shbake/casc_flat.py'
spec = importlib.util.spec_from_file_location('casc_flat', TOOL)
casc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(casc)


def container(parts):
    """parts = [(包含模式字节的编码块, 解出长度)]；尺寸与 MD5 按编码字节生成。"""
    table = b''.join(struct.pack('>II', len(data), size) + hashlib.md5(data).digest()
                     for data, size in parts)
    return (b'BLTE' + struct.pack('>I', 12 + len(table)) + b'\x0f'
            + len(parts).to_bytes(3, 'big') + table + b''.join(data for data, _ in parts))


def encoded(mode, data):
    return mode + (zlib.compress(data) if mode == b'Z' else data), len(data)


def overstate(blob, index, extra=7):
    result = bytearray(blob)
    pos = 12 + index * 24
    size = struct.unpack_from('>I', blob, pos)[0]
    struct.pack_into('>I', result, pos, size + extra)
    return bytes(result)


def overlap_header():
    # 单块表到 36 字节结束；这个合法 N 块的 MD5 最后一个字节恰为 N。
    # 仅把头长改为 35 后，旧读取器把该字节当模式，错误解出 b'N\0'。
    result = bytearray(container([(b'N\0\x10', 2)]))
    struct.pack_into('>I', result, 4, 35)
    return bytes(result)


class BlteChunkBoundsTest(unittest.TestCase):
    def test_header_overlapping_table_rejected(self):
        with self.assertRaisesRegex(ValueError, 'BLTE 头长度与块表不符'):
            casc.blte(overlap_header())

    def test_header_past_end_with_no_chunks_rejected(self):
        blob = b'BLTE' + struct.pack('>I', 100) + b'\x0f\0\0\0'
        with self.assertRaisesRegex(ValueError, 'BLTE 头长度越界'):
            casc.blte(blob)

    def test_header_gap_before_payload_rejected(self):
        blob = container([encoded(b'N', b'payload')])
        blob = bytearray(blob[:36] + b'\0' + blob[36:])
        struct.pack_into('>I', blob, 4, 37)
        with self.assertRaisesRegex(ValueError, 'BLTE 头长度与块表不符'):
            casc.blte(bytes(blob))

    def test_zero_chunk_header_unchanged(self):
        self.assertEqual(casc.blte(b'BLTE' + struct.pack('>I', 12) + b'\x0f\0\0\0'), b'')

    def test_nested_f_rejects_inner_header_overlap(self):
        blob = container([(b'F' + overlap_header(), 2)])
        with self.assertRaisesRegex(ValueError, 'BLTE 头长度与块表不符'):
            casc.blte(blob)

    def test_read_rejects_overlapping_header(self):
        blob = overlap_header()
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, '00-00000000.data').write_bytes(b'pad' + blob)
            entry = ('synthetic-header', 0, 0, 3, len(blob), 2, 'b:test')
            with self.assertRaisesRegex(ValueError, 'BLTE 头长度与块表不符'):
                casc.read(directory, entry)

    def test_headerless_blocks_unchanged(self):
        for mode in (b'N', b'Z'):
            with self.subTest(mode=mode):
                data, _ = encoded(mode, b'headerless payload')
                self.assertEqual(casc.blte(b'BLTE' + bytes(4) + data), b'headerless payload')

    def test_single_chunk_exact_boundary(self):
        for mode in (b'N', b'Z'):
            with self.subTest(mode=mode):
                self.assertEqual(casc.blte(container([encoded(mode, b'chunk payload')])),
                                 b'chunk payload')

    def test_multiple_chunks_unchanged(self):
        for modes in ((b'N', b'Z'), (b'Z', b'N'), (b'N', b'N'), (b'Z', b'Z')):
            with self.subTest(modes=modes):
                blob = container([encoded(modes[0], b'first'), encoded(modes[1], b'last')])
                self.assertEqual(casc.blte(blob), b'firstlast')

    def test_empty_decoded_chunks_are_valid(self):
        for mode in (b'N', b'Z'):
            with self.subTest(mode=mode):
                self.assertEqual(casc.blte(container([encoded(mode, b'')])), b'')
                blob = container([encoded(mode, b''), encoded(b'N', b'tail')])
                self.assertEqual(casc.blte(blob), b'tail')

    def test_nested_f_block_unchanged(self):
        inner = container([encoded(b'Z', b'nested')])
        self.assertEqual(casc.blte(container([(b'F' + inner, 6)])), b'nested')

    def test_oversized_final_chunks(self):
        # Python 切片会截短；N 和完整 Z 流原本都可在声明多 7 字节时解出原文。
        for mode in (b'N', b'Z'):
            for count in (1, 2):
                with self.subTest(mode=mode, count=count):
                    parts = ([encoded(b'N', b'prefix')] if count == 2 else [])
                    blob = container(parts + [encoded(mode, b'chunk payload')])
                    with self.assertRaisesRegex(ValueError, 'BLTE 块编码长度越界'):
                        casc.blte(overstate(blob, count - 1))

    def test_maximum_declared_size_rejected(self):
        blob = bytearray(container([encoded(b'N', b'x')]))
        struct.pack_into('>I', blob, 12, 0xffffffff)
        with self.assertRaisesRegex(ValueError, 'BLTE 块编码长度越界'):
            casc.blte(bytes(blob))

    def test_bounds_checked_before_decode(self):
        blob = container([(b'Eunsupported', 0)])
        with self.assertRaisesRegex(ValueError, 'BLTE 块编码长度越界'):
            casc.blte(overstate(blob, 0))

    def test_data_offset_past_end_rejected(self):
        blob = bytearray(container([encoded(b'N', b'x')]))
        struct.pack_into('>I', blob, 4, len(blob) + 1)
        with self.assertRaises(ValueError):
            casc.blte(bytes(blob))

    def test_truncated_chunk_rejected(self):
        for mode in (b'N', b'Z'):
            with self.subTest(mode=mode):
                blob = container([encoded(mode, b'payload')])
                with self.assertRaises((ValueError, zlib.error)):
                    casc.blte(blob[:-1])

    def test_zero_encoded_size_rejected(self):
        with self.assertRaisesRegex(ValueError, 'BLTE 块模式'):
            casc.blte(container([(b'', 0)]))

    def test_truncated_header_rejected_before_table_decode(self):
        blob = container([encoded(b'N', b'x')])
        with self.assertRaisesRegex(ValueError, 'BLTE 头长度越界'):
            casc.blte(blob[:19])

    def test_decoded_size_mismatch_unchanged(self):
        with self.assertRaisesRegex(ValueError, 'BLTE 块解出长度不符'):
            casc.blte(container([(b'Npayload', 6)]))

    def test_unknown_mode_unchanged(self):
        with self.assertRaisesRegex(ValueError, 'BLTE 块模式'):
            casc.blte(container([(b'Qpayload', 7)]))

    def test_bad_zlib_keeps_zlib_error(self):
        with self.assertRaises(zlib.error):
            casc.blte(container([(b'Zinvalid', 7)]))

    def test_read_exact_entry_unchanged(self):
        blob = container([encoded(b'N', b'first'), encoded(b'Z', b'last')])
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, '00-00000000.data').write_bytes(b'pad' + blob)
            entry = ('synthetic', 0, 0, 3, len(blob), 9, 'b:test')
            self.assertEqual(casc.read(directory, entry), b'firstlast')

    def test_read_rejects_internal_overstatement(self):
        blob = overstate(container([encoded(b'Z', b'payload')]), 0)
        with tempfile.TemporaryDirectory() as directory:
            Path(directory, '00-00000000.data').write_bytes(blob)
            entry = ('synthetic', 0, 0, 0, len(blob), 7, 'b:test')
            with self.assertRaisesRegex(ValueError, 'BLTE 块编码长度越界'):
                casc.read(directory, entry)


if __name__ == '__main__':
    unittest.main()
