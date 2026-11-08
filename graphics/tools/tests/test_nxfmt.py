# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Synthetic Yaz0 / SARC checks. No game files. oead is optional."""
import os
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'graphics' / 'tools'))
sys.path.insert(0, str(ROOT / 'graphics' / 'widen' / 'scan'))
import nxfmt
import ui_lyt


def _hash(name, key=0x65):
    h = 0
    for b in name.encode('utf-8'):
        h = (h * key + b) & 0xFFFFFFFF
    return h


def _hand_sarc(files, endian='<'):
    """Build a SARC from the public layout, independent of SarcWriter."""
    items = sorted(((_hash(n), n, blob) for n, blob in files), key=lambda r: (r[0], r[1]))
    pool = bytearray()
    nodes = []
    for h, name, blob in items:
        off = len(pool)
        pool += name.encode('utf-8') + b'\0'
        while len(pool) % 4:
            pool.append(0)
        nodes.append((h, 0x01000000 | (off // 4), blob))
    out = bytearray(b'SARC')
    out += struct.pack(endian + 'HHIIHH', 0x14, 0xFEFF, 0, 0, 0x0100, 0)
    out += b'SFAT' + struct.pack(endian + 'HHI', 0x0C, len(nodes), 0x65)
    node_at = len(out)
    out += b'\0' * (16 * len(nodes))
    out += b'SFNT' + struct.pack(endian + 'HH', 8, 0) + pool
    data_off = (len(out) + 3) & ~3
    out += b'\0' * (data_off - len(out))
    for i, (h, attr, blob) in enumerate(nodes):
        start = len(out) - data_off
        out += blob
        struct.pack_into(endian + 'IIII', out, node_at + 16 * i, h, attr, start, start + len(blob))
    struct.pack_into(endian + 'I', out, 8, len(out))
    struct.pack_into(endian + 'I', out, 12, data_off)
    return bytes(out)


def _hand_yaz0_overlap():
    """abc then a dist-3 length-6 reference → abcabcabc. Flag bits are high-first."""
    raw = b'abcabcabc'
    body = bytes([0xE0, ord('a'), ord('b'), ord('c'), 0x40, 0x02])
    hdr = b'Yaz0' + len(raw).to_bytes(4, 'big') + b'\0' * 8
    return hdr + body, raw


class Yaz0Tests(unittest.TestCase):
    def test_literal_encoder_roundtrip_both_paths(self):
        raw = bytes(b % 251 for b in range(3000)) + b'\0abc' * 20
        packed = bytes(ui_lyt.yaz0_enc(raw, b'Yaz0' + b'\0' * 12))
        self.assertEqual(nxfmt.yaz0_decompress_py(packed), raw)
        lib = nxfmt._load_lib()
        if lib is None:
            self.skipTest('C Yaz0 library did not build')
        self.assertEqual(nxfmt.yaz0_decompress(packed), raw)

    def test_overlap_and_long_reference(self):
        packed, raw = _hand_yaz0_overlap()
        self.assertEqual(nxfmt.yaz0_decompress_py(packed), raw)
        # 3-byte form: high nibble 0, length = byte + 0x12, dist = 1, so 0x12 copies of 'Z'
        n = 1 + 0x12
        flag = 0x80  # one literal, then one reference
        body = bytes([flag, ord('Z'), 0x00, 0x00, 0x00])
        hdr = b'Yaz0' + n.to_bytes(4, 'big') + b'\0' * 8
        self.assertEqual(nxfmt.yaz0_decompress_py(hdr + body), b'Z' * n)

    def test_c_matches_python_and_existing_c_encoder(self):
        lib = nxfmt._load_lib()
        if lib is None:
            self.skipTest('C Yaz0 library did not build')
        packed, raw = _hand_yaz0_overlap()
        self.assertEqual(nxfmt.yaz0_decompress(packed), nxfmt.yaz0_decompress_py(packed))
        cc = os.environ.get('CC', 'cc')
        src = ROOT / 'graphics' / 'widen' / 'scan' / 'yaz0enc.c'
        sample = (b'abc' * 200) + bytes(range(256)) + (b'xyz' * 80)
        with tempfile.TemporaryDirectory() as td:
            enc = os.path.join(td, 'yaz0enc')
            built = subprocess.run([cc, '-O2', '-o', enc, str(src)], capture_output=True)
            if built.returncode != 0:
                self.skipTest('yaz0enc.c did not build')
            inp = os.path.join(td, 'in')
            outp = os.path.join(td, 'out')
            with open(inp, 'wb') as fh:
                fh.write(sample)
            hdr = (b'Yaz0' + len(sample).to_bytes(4, 'big') + b'\0' * 8).hex()
            subprocess.run([enc, inp, outp, hdr], check=True, capture_output=True)
            with open(outp, 'rb') as fh:
                got = fh.read()
            self.assertEqual(nxfmt.yaz0_decompress(got), sample)
            self.assertEqual(nxfmt.yaz0_decompress_py(got), sample)

    def test_lib_already_built_by_another_process(self):
        # 11-05 天眼：几个工作进程同时现编，改名覆盖撞上别的进程已加载的 DLL（WinError 5）；目标在就用它、不抛、不留临时文件
        lib = nxfmt._compile_lib()
        if lib is None:
            self.skipTest('本机没有 C 编译器')
        real, built = os.replace, Path(lib).read_bytes()
        def raced(src, dst):   # 改名那一刻：别的进程刚放好目标，覆盖被拒
            with open(dst, 'wb') as fh: fh.write(built)
            raise PermissionError(5, '拒绝访问', dst)
        os.remove(lib); nxfmt.os.replace = raced
        try: got = nxfmt._compile_lib()
        finally: nxfmt.os.replace = real
        self.assertEqual(got, lib)
        self.assertTrue(os.path.isfile(lib))
        self.assertFalse(os.path.exists(lib + '.%d.tmp' % os.getpid()))   # 本进程的临时文件删掉了

    def test_rejects_bad_input(self):
        self.assertEqual(nxfmt.yaz0_decompress_py(b'Yaz0' + b'\0' * 12), b'')
        with self.assertRaises(ValueError):
            nxfmt.yaz0_decompress_py(b'Yaz1' + b'\0' * 20)
        with self.assertRaises(ValueError):
            nxfmt.yaz0_decompress_py(b'Yaz0' + (5).to_bytes(4, 'big') + b'\0' * 8 + b'\x00')

    def test_oead_yaz0_if_installed(self):
        try:
            import oead
        except ImportError:
            self.skipTest('oead not installed')
        raw = b'S2Arm' + b'abc' * 50 + bytes(range(64))
        if not hasattr(oead, 'yaz0') or not hasattr(oead.yaz0, 'compress'):
            self.skipTest('oead.yaz0.compress missing')
        packed = bytes(oead.yaz0.compress(raw))
        self.assertEqual(nxfmt.yaz0_decompress_py(packed), bytes(oead.yaz0.decompress(packed)))
        self.assertEqual(nxfmt.yaz0_decompress(packed), bytes(oead.yaz0.decompress(packed)))


class SarcTests(unittest.TestCase):
    def test_roundtrip_both_endiannesses_and_alignment(self):
        files = {
            'ordinary.bin': b'hello',
            'dir/nested.txt': '名字'.encode() + b'\0inside',
            'z': b'',
        }
        for endian, mark in ((nxfmt.Endianness.Little, b'\xff\xfe'), (nxfmt.Endianness.Big, b'\xfe\xff')):
            writer = nxfmt.SarcWriter(endian, alignment=0x20)
            writer.files.update(files)
            alignment, blob = writer.write()
            self.assertEqual(alignment, 0x20)
            self.assertEqual(blob[6:8], mark)
            arc = nxfmt.Sarc(blob)
            self.assertEqual({f.name: f.data for f in arc.get_files()}, files)
            self.assertEqual(arc.get_file('ordinary.bin').data, b'hello')
            doff = int.from_bytes(blob[12:16], 'little' if endian == nxfmt.Endianness.Little else 'big')
            self.assertEqual(doff % 0x20, 0)
            for item in arc.get_files():
                # Re-read absolute starts from the nodes by parsing again.
                pass
            e = '<' if mark == b'\xff\xfe' else '>'
            count = struct.unpack_from(e + 'H', blob, 0x14 + 6)[0]
            self.assertEqual(count, 3)
            for i in range(count):
                _h, _a, start, end = struct.unpack_from(e + 'IIII', blob, 0x20 + 16 * i)
                self.assertEqual((doff + start) % 0x20, 0)
                self.assertEqual(blob[doff + start:doff + end], arc.get_files()[i].data)
                self.assertEqual(_h, _hash(arc.get_files()[i].name))

    def test_hand_built_archives_both_endiannesses(self):
        files = [('b.bin', b'BBB'), ('a.bin', b'AAA')]
        for endian in ('<', '>'):
            blob = _hand_sarc(files, endian)
            got = list(nxfmt.sarc_members(blob))
            self.assertEqual(dict(got), dict(files))
            self.assertEqual([name for name, _ in got], [name for name, _ in sorted(files, key=lambda r: (_hash(r[0]), r[0]))])

    def test_unnamed_node_and_missing_name(self):
        blob = bytearray(_hand_sarc([('only.bin', b'xyz')], '<'))
        # Clear the name bit on the only node. Hash stays; the reader must not invent the old string.
        attr = struct.unpack_from('<I', blob, 0x24)[0]
        struct.pack_into('<I', blob, 0x24, attr & 0x00FFFFFF)
        self.assertEqual(list(nxfmt.sarc_members(blob)), [('#0', b'xyz')])
        with self.assertRaises(KeyError):
            nxfmt.Sarc(_hand_sarc([('only.bin', b'xyz')])).get_file('missing')

    def test_hash_is_the_public_recurrence(self):
        self.assertEqual(nxfmt.name_hash('ordinary.bin'), _hash('ordinary.bin'))
        self.assertNotEqual(_hash('a'), _hash('b'))

    def test_oead_sarc_if_installed(self):
        try:
            import oead
        except ImportError:
            self.skipTest('oead not installed')
        payload = {'plain.bin': b'abc', 'sub/dir.bin': b'\x00\x01\x02'}
        for endian, ours in ((oead.Endianness.Little, nxfmt.Endianness.Little),
                             (oead.Endianness.Big, nxfmt.Endianness.Big)):
            theirs = oead.SarcWriter(endian)
            # oead 1.3.0 的 files 是 FileMap，没有 dict.update。
            for name, blob in payload.items():
                theirs.files[name] = oead.Bytes(blob)
            their_blob = bytes(theirs.write()[1])
            self.assertEqual({f.name: bytes(f.data) for f in nxfmt.Sarc(their_blob).get_files()}, payload)
            writer = nxfmt.SarcWriter(ours)
            writer.files.update(payload)
            our_blob = writer.write()[1]
            arc = oead.Sarc(our_blob)
            self.assertEqual({f.name: bytes(f.data) for f in arc.get_files()}, payload)


if __name__ == '__main__':
    unittest.main()
