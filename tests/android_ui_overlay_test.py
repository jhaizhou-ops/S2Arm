#!/usr/bin/env python3
"""安卓资源包叠界面布局覆盖层（Windows 编排 uilayout 写 <产物根>/ui_overlay/romfs/，romfs.s2aidx 按覆盖层大小建）。
11-07 回归批：读方没叠覆盖层 → 索引与实际长度不符 → 游戏读 RomFS 回 2002-4703 中止。
期望值不跑被测实现：原件 / 覆盖层内容是本测写下的固定字节。"""
import importlib.util
import struct
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('android_make_pack', ROOT / 'android/tools/make_pack.py')
pack = importlib.util.module_from_spec(spec); spec.loader.exec_module(pack)


class AndroidUiOverlay(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / 'root'
        (self.root / 'romfs/Layout').mkdir(parents=True); (self.root / 'ui_overlay/romfs/Layout').mkdir(parents=True)
        (self.root / 'romfs/Layout/a.zs').write_bytes(b'\x11' * 1000)
        (self.root / 'romfs/b.bin').write_bytes(b'\x33' * 64)
        (self.root / 'ui_overlay/romfs/Layout/a.zs').write_bytes(b'\x22' * 1200)
        (self.root / 'exefs').mkdir(); (self.root / 'exefs/main.npdm').write_bytes(b'npdm')
        (self.root / 'ctl').mkdir()
        nacp = bytearray(0x4000); struct.pack_into('<Q', nacp, 0x3038, 0x0100000000001000)
        (self.root / 'ctl/control.nacp').write_bytes(nacp)
        (self.root / 's2a_caps.tsv').write_text('plat\tandroid\n')

    def test_entries_carry_overlay_after_romfs(self):
        staging = Path(self.tmp.name) / 'staging'; staging.mkdir()
        done = mock.Mock(returncode=0, stdout='', stderr='')
        with mock.patch.object(pack, 'stage_system_data', return_value=None), mock.patch.object(pack, 'rewrite'), \
                mock.patch.object(pack, 'stage_address_requirements', return_value=str(staging / 'addr_need.tsv')), \
                mock.patch.object(pack.subprocess, 'run', return_value=done):
            entries = pack.entries_from_root(str(self.root), str(staging))
        romfs = [src for name, src in entries if name == 'romfs']
        self.assertEqual(romfs, [str(self.root / 'romfs'), str(self.root / 'ui_overlay/romfs')])

    def test_pack_overlay_wins_once(self):
        out = Path(self.tmp.name) / 'packed'
        pack.write_pack(str(out), [('romfs', str(self.root / 'romfs')), ('romfs', str(self.root / 'ui_overlay/romfs')),
                                   ('ctl/control.nacp', str(self.root / 'ctl/control.nacp'))])
        self.assertEqual((out / 'romfs/Layout/a.zs').read_bytes(), b'\x22' * 1200)
        self.assertEqual((out / 'romfs/b.bin').read_bytes(), b'\x33' * 64)
        rows = [l.split('\t') for l in (out / 'index.tsv').read_text().splitlines()]
        self.assertEqual([r[:2] for r in rows if r[0] == 'romfs/Layout/a.zs'], [['romfs/Layout/a.zs', '1200']])


if __name__ == '__main__':
    unittest.main()
