#!/usr/bin/env python3
"""Synthetic NACP names: old strings, bounded raw-DEFLATE, and malformed input."""
import importlib.util
from pathlib import Path
import struct
import sys
import tempfile
import unittest
import zlib

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('game_apk', ROOT / 'android/tools/game_apk.py')
producer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(producer)


def nacp(name='Fixture Game', compressed=False, raw_size=0x6000, slot=0):
    result = bytearray(0x4000)
    table = bytearray(raw_size if compressed else 0x3000)
    name = name.encode('utf-8')
    offset = slot * 0x300
    table[offset:offset + len(name)] = name
    if compressed:
        comp = zlib.compressobj(level=9, wbits=-15)
        payload = comp.compress(table) + comp.flush()
        result[:2] = len(payload).to_bytes(2, 'little')
        result[2:2 + len(payload)] = payload
    else:
        result[:len(table)] = table
    struct.pack_into('<Q', result, 0x3038, 0x0100000000ABCDEF)
    result[0x3060:0x3063] = b'1.2'
    return result


class NacpTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.path = Path(self.temp.name) / 'control.nacp'

    def read(self, data):
        self.path.write_bytes(data)
        return producer.nacp_info(self.path)

    def test_legacy_and_compressed_name_are_identical(self):
        for name in ('Fixture Game', '游戏 sample', 'A'):
            with self.subTest(name=name):
                expected = ('0100000000ABCDEF', name, '1.2')
                self.assertEqual(self.read(nacp(name)), expected)
                self.assertEqual(self.read(nacp(name, compressed=True)), expected)
                self.assertEqual(self.read(nacp(name, compressed=True, slot=14)), expected)

    def test_reject_invalid_compressed_and_unbounded_output(self):
        for size in (0x5fff, 0x6001, 0x12000):
            with self.subTest(size=size), self.assertRaises((SystemExit, ValueError)):
                self.read(nacp(compressed=True, raw_size=size))
        corrupt = nacp(compressed=True); corrupt[2:6] = b'\xff\xff\xff\xff'
        with self.assertRaises((SystemExit, ValueError)):
            self.read(corrupt)
        controls = nacp(); controls[:3] = b'\x01A\x00'
        with self.assertRaises((SystemExit, ValueError)):
            self.read(controls)
        truncated = nacp(compressed=True); n = int.from_bytes(truncated[:2], 'little')
        truncated[:2] = (n - 1).to_bytes(2, 'little')
        with self.assertRaises((SystemExit, ValueError)):
            self.read(truncated)
        trailing = nacp(compressed=True); n = int.from_bytes(trailing[:2], 'little')
        trailing[:2] = (n + 1).to_bytes(2, 'little')
        trailing[2 + n] = 0xff
        with self.assertRaises((SystemExit, ValueError)):
            self.read(trailing)
        oversized = nacp(); oversized[:4] = b'\xff\x2f\xff\x00'
        with self.assertRaises((SystemExit, ValueError)):
            self.read(oversized)
        with self.assertRaises((SystemExit, ValueError)):
            self.read(nacp()[:0x306f])
        bad = nacp(); bad[:4] = b'\xff\x00\x01\x00'
        with self.assertRaises((SystemExit, ValueError)):
            self.read(bad)


if __name__ == '__main__':
    unittest.main()
