#!/usr/bin/env python3
"""Synthetic real pack -> NPDM-adjacent requirements -> production layout."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('make_pack', REPO / 'android/tools/make_pack.py')
pack = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pack)
PROGRAM = '0100000000abcdef'


class PackLayoutTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.root = Path(pack.synthetic_root(str(self.base)))
        self.build = (self.root / 'exefs/main').read_bytes()[0x40:0x50].hex()

    def table(self, alias, heap, program=PROGRAM):
        return f'版本\t2\n程序号\t{program}\n构建号\t{self.build}\n别名区GB\t{alias}\n普通堆MB\t{heap}\n'

    def make(self, suffix=''):
        out = self.base / ('package' + suffix)
        pack.write_pack(str(out), pack.entries_from_root(str(self.root), str(self.base / ('stage' + suffix) / 'modules'), sysdata=''))
        artifact = json.loads((out / 'game-build-artifact.json').read_text())
        npdm = out / artifact['npdm']  # the launch contract, also used by APK source mode
        table = npdm.with_name('addr_need.tsv')
        self.assertTrue(table.is_file(), 'runtime NPDM lost its requirements neighbour')
        self.assertEqual(table.read_bytes(), (out / 'modules/addr_need.tsv').read_bytes())
        index = (out / 'index.tsv').read_bytes()
        self.assertEqual(artifact['contentRoot'], 'sha256-' + hashlib.sha256(index).hexdigest())
        for rel in ['exefs/addr_need.tsv', 'modules/addr_need.tsv']:
            self.assertIn(f'{rel}\t{table.stat().st_size}\t{hashlib.sha256(table.read_bytes()).hexdigest()}\n', index.decode())
        return out, table, artifact

    def layout(self, table, alias, heap, fits, unbounded=False, android=True):
        probe = self.base / 'layout'
        flags = ['-D__ANDROID__'] if android else []
        subprocess.run([os.environ.get('CC', 'cc'), *flags, '-I' + str(REPO / 'runtime/src'), '-I' + str(REPO / 'runtime/include'),
                        str(REPO / 'android/tests/pack_layout_probe.c'), str(REPO / 'runtime/src/layout.c'),
                        '-o', str(probe)], check=True)
        subprocess.run([str(probe), str(table), str(alias), str(heap), str(fits), str(int(unbounded))], check=True)

    def test_input_tables_are_not_used_by_static_collector(self):
        a = self.root / 'addr_need.tsv'
        a.write_text(self.table(63, 32, '0100000000000000'))
        stage = self.base / 'first'; stage.mkdir()
        before = Path(pack.stage_address_requirements(self.root, stage)).read_bytes()
        a.write_text(self.table(4, 6144))
        stage2 = self.base / 'second'; stage2.mkdir()
        after = Path(pack.stage_address_requirements(self.root, stage2)).read_bytes()
        self.assertEqual(before, after)

    def test_default(self):
        _, table, _ = self.make()
        self.layout(table, 60, 3284, 0)

    def test_unbounded_preserves_heap_and_full_alias(self):
        table = self.base / 'unbounded.tsv'
        table.write_text(self.table(38, 3284) + '别名区上限\t不定\n上限不定原因\t合成条件提交\n')
        self.layout(table, 63, 3284, 1, unbounded=True)
        self.layout(table, 63, 3284, 1, unbounded=True, android=False)  # CTest 宿主也编译同一布局

    def claim_62_gib(self):
        # Add a real nn::os::AllocateAddressRegion PLT/import and constant call to
        # the rewrite selftest NSO; retain its original EH frame and entry code.
        p = self.root / 'exefs/main'; raw = bytearray(p.read_bytes())
        name = b'_ZN2nn2os21AllocateAddressRegionEPmm'
        struct.pack_into('<i', raw, 0x1104, 0x300)  # MOD0 -> dynamic at 0x1300
        raw[0x1500:0x1500 + len(name) + 2] = b'\0' + name + b'\0'
        struct.pack_into('<IBBHQQ', raw, 0x1618, 1, 0x12, 0, 0, 0, 0)
        struct.pack_into('<QQq', raw, 0x1700, 0x2100, (1 << 32) | 1026, 0)
        for i, (tag, value) in enumerate(((5, 0x1400), (6, 0x1500), (23, 0x1600), (2, 24), (0, 0))):
            struct.pack_into('<qQ', raw, 0x1400 + i * 16, tag, value)
        struct.pack_into('<III', raw, 0x400, 0xD0000010, 0xF9408211, 0xD61F0220)  # plt@0x300 -> got@0x2100
        # AllocateAddressRegion 的尺寸在 x1；只写 x8 不能证明该调用的尺寸有界。
        mov62 = 0xB2400000 | (33 << 16) | (4 << 10) | 0x3E0 | 1
        struct.pack_into('<IIII', raw, 0x300, 0xD65F03C0, mov62, 0x9400003E, 0xD65F03C0)
        p.write_bytes(raw)

    def system_resource(self, size):
        # SystemResourceSize（NPDM META +0x14）：> 0 才有 nn::os 虚拟地址内存（VAMM），AllocateAddressRegion 才会跑；
        # b273f2ef6 起地址需求按它判（tools/addr_need.py npdm_system_resource），合成 NPDM 缺省 0 = VAMM 关
        n = self.root / 'exefs/main.npdm'; raw = bytearray(n.read_bytes())
        self.assertEqual(raw[:4], b'META')
        struct.pack_into('<I', raw, 0x14, size); n.write_bytes(raw)

    def test_static_62_gib_claim(self):
        self.claim_62_gib(); self.system_resource(0x1000000)
        _, table, _ = self.make()
        self.assertNotIn('别名区上限\t不定', table.read_text())
        self.layout(table, 63, 798, 1)

    def test_static_62_gib_claim_vamm_off(self):
        # 同一 62 GiB 常量调用，但 SystemResourceSize = 0（VAMM 关，这条调用在真机上是死代码）→ 不算开局占位，落回缺省 60 GiB
        self.claim_62_gib(); self.system_resource(0)
        _, table, _ = self.make()
        self.layout(table, 60, 3284, 0)


if __name__ == '__main__':
    unittest.main()
