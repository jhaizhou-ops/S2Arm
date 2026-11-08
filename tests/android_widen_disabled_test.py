#!/usr/bin/env python3
"""Android real pack rewrite: disabled widening never instruments candidate instructions."""
import ast
import contextlib
import importlib.util
import io
import json
import re
import struct
import tempfile
import unittest
import zipfile
from unittest import mock
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('android_make_pack', ROOT/'android/tools/make_pack.py')
pack=importlib.util.module_from_spec(spec);spec.loader.exec_module(pack)
apk_spec=importlib.util.spec_from_file_location('android_game_apk', ROOT/'android/tools/game_apk.py')
game_apk=importlib.util.module_from_spec(apk_spec);apk_spec.loader.exec_module(game_apk)


def synthetic_nso(path):
    # Same valid AArch64 instruction shapes and FDE framing as widen_aspcap_test.
    code=[0x52838e48,0x72a800e8,0x1e270101,0x52838e49,0x72a800e9,0xb9000909,
          0x528aaaaa,0x72a802aa,0x1e270142,0xd65f03c0]
    text=bytearray(0x1000);struct.pack_into('<II',text,0,0x14000040,0x1000);struct.pack_into('<%dI'%len(code),text,0x100,*code)
    ro=bytearray(0x1000);eh,ef=0x100,0x200
    struct.pack_into('<4sIIIii',ro,0,b'MOD0',0,0,0,eh,eh+0x20)
    struct.pack_into('<BBBBiIii',ro,eh,1,0x1b,0x03,0x3b,(0x1000+ef)-(0x1000+eh+4),1,0x100-(0x1000+eh),(0x1000+ef+0x18)-(0x1000+eh))
    cie=struct.pack('<II',0x14,0)+bytes([1])+b'zR\0'+bytes([4,0x78,30,1,0x1b])+bytes(7)
    ro[ef:ef+0x18]=cie;f=0x1000+ef+0x18
    struct.pack_into('<IIii',ro,ef+0x18,0x10,(f+4)-(0x1000+ef),0x100-(f+8),4*len(code))
    data=bytes(0x1000);header=bytearray(0x100);header[:4]=b'NSO0'
    for k,(off,seg) in enumerate(((0,text),(0x1000,ro),(0x2000,data))):
        struct.pack_into('<III',header,0x10+0x10*k,0x100+0x1000*k,off,len(seg));struct.pack_into('<I',header,0x60+4*k,len(seg))
    header[0x40:0x50]=bytes(range(16));path.write_bytes(header+text+ro+data)

class AndroidWidenDisabled(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory();self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name);self.exefs=self.root/'exefs';self.exefs.mkdir()
        synthetic_nso(self.exefs/'main');(self.exefs/'main.npdm').write_bytes(b'fixture')
        self.out=self.root/'out'
    def rewrite(self, caps):
        (self.root/'s2a_caps.tsv').write_text(caps)
        stream=io.StringIO()
        with contextlib.redirect_stdout(stream):pack.rewrite(str(self.exefs),str(self.out))
        return stream.getvalue()
    def test_disabled_cannot_instrument_candidates(self):
        log=self.rewrite('plat\tandroid\nwiden\t0\n')
        self.assertFalse((self.out/'main.widen.tsv').exists(), 'widen=0 must not emit or instrument candidate table')
        match=re.search(r'rewrite main: main (\{[^}]*\})',log)
        self.assertIsNotNone(match, f'actual rewriter must expose module counters: {log!r}')
        counters=ast.literal_eval(match.group(1))
        self.assertEqual(counters, {}, f'unexpected rewrite counters: {counters}')
        self.assertRegex(log, r'patch 0\b.*slot_refs 0\b')
    def test_enabled_candidates_are_instrumented_and_carried(self):
        self.rewrite('plat\tandroid\nwiden\t1\n')
        table = self.out / 'main.widen.tsv'
        self.assertTrue((self.out / 'main.patched.bin').is_file())
        self.assertTrue(table.is_file(), 'enabled candidates must be emitted for the APK loader')
        self.assertTrue(table.read_text().strip(), 'enabled candidate table must not be empty')
        nacp = self.root / 'control.nacp'
        data = bytearray(0x4000); data[:9] = b'Synthetic'; struct.pack_into('<Q', data, 0x3038, 0x0100000000001000); nacp.write_bytes(data)
        packaged = self.root / 'packed'
        pack.write_pack(str(packaged), [('modules', str(self.out)), ('ctl/control.nacp', str(nacp))])
        index = (packaged / 'index.tsv').read_text()
        self.assertIn('modules/main.widen.tsv\t', index)
        artifact = json.loads((packaged / 'game-build-artifact.json').read_text())
        self.assertEqual(artifact['modules'][0]['widen'], 'modules/main.widen.tsv')
        self.assertEqual((packaged / 'modules/main.widen.tsv').read_bytes(), table.read_bytes())
        apk = self.root / 'fixture.apk'
        def make_apk(include_widen):
            with zipfile.ZipFile(apk, 'w') as archive:
                archive.writestr('assets/game/game.properties', 'titleId=0100000000001000\nversionCode=1\n')
                for item in (packaged / 'modules').iterdir():
                    if item.name == 'main.widen.tsv' and not include_widen:
                        continue
                    archive.write(item, 'assets/game/modules/' + item.name)
        with mock.patch.object(game_apk, 'apk_signer_sha256', return_value='a' * 64), \
             mock.patch.object(game_apk, 'apk_identity', return_value=('org.s2arm.game.t0100000000001000', 1, False)):
            make_apk(False)
            with self.assertRaisesRegex(SystemExit, 'main.widen.tsv'):
                game_apk.resources(str(packaged), str(apk), str(self.root / 'missing-resources'))
            make_apk(True)
            resources = self.root / 'resources'
            game_apk.resources(str(packaged), str(apk), str(resources))
            bound = json.loads((resources / 'game-build-artifact.json').read_text())
            self.assertEqual(bound['modules'][0]['widen'], 'main.widen.tsv')
            self.assertEqual(bound['modules'][0]['source'], 'apk-asset')
            with zipfile.ZipFile(apk) as archive:
                self.assertEqual(archive.read('assets/game/modules/main.widen.tsv'), table.read_bytes())

    def test_invalid_or_duplicate_capability_fails_closed(self):
        for caps in ('plat\tandroid\n','plat\tandroid\nwiden\t0\nwiden\t1\n','plat\tandroid\nwiden\tbad\n','plat\tapple\nwiden\t0\n'):
            with self.subTest(caps=caps):
                with self.assertRaisesRegex(SystemExit,'红'):self.rewrite(caps)
                self.assertFalse((self.out/'main.patched.bin').exists())

if __name__=='__main__':unittest.main(verbosity=2)
