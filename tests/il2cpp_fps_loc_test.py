#!/usr/bin/env python3
"""原创 v29 字节夹具；固定地址 oracle，不依赖定位器生成输入。"""
import importlib.util
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import json
import hashlib
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('locator', ROOT / 'tools/il2cpp_fps_loc.py')
loc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(loc)


def fixture():
    metadata = bytearray(1024)
    struct.pack_into('<II', metadata, 0, 0xFAB11BAF, 29)
    strings = b'UnityEngine.CoreModule.dll\0UnityEngine\0Application\0QualitySettings\0set_targetFrameRate\0set_vSyncCount\0'
    metadata[256:256 + len(strings)] = strings
    def name(s): return strings.index(s.encode() + b'\0')
    for pair, offset, size in [(2,256,len(strings)), (5,400,64), (19,480,176), (20,672,40)]:
        struct.pack_into('<II', metadata, 8 + pair * 8, offset, size)
    for i, (cls, meth) in enumerate([('Application','set_targetFrameRate'),('QualitySettings','set_vSyncCount')]):
        struct.pack_into('<II', metadata, 480 + i*88, name(cls),name('UnityEngine'))
        struct.pack_into('<i', metadata, 480+i*88+36, i)
        struct.pack_into('<H', metadata, 480+i*88+64, 1)
        struct.pack_into('<IiiiiIHHHH',metadata,400+i*32,name(meth),i,0,0,-1,0x06000001+i,0x10,0,0xffff,1)
    struct.pack_into('<IiiI',metadata,672,name('UnityEngine.CoreModule.dll'),0,0,2)
    image = bytearray(1024)
    image[512:538] = b'UnityEngine.CoreModule.dll\0'
    struct.pack_into('<QQQ',image,768,0x1200,2,0x1340)
    struct.pack_into('<QQ',image,832,0x1080,0x1090)
    # Fixed forward and backward BL words: 0x1040 -> 0x1080; 0x10a0 -> 0x1090.
    struct.pack_into('<I',image,64,0x94000010)
    struct.pack_into('<I',image,160,0x97fffffc)
    return metadata,image


class TestLocator(unittest.TestCase):
    def run_loc(self, m=None, b=None, **kw):
        a,c=fixture()
        return loc.locate(bytes(a if m is None else m),bytes(c if b is None else b),0x1000,0x1300,0x1040,0x80,**kw)
    def test_mapping_and_direct_calls(self):
        result=self.run_loc()
        self.assertEqual([(x['entry_va'],x['direct_bl_candidates']) for x in result['methods']],[(0x1080,[0x1040]),(0x1090,[0x10a0])])
        self.assertEqual(result['entry_kind'],'generated_method_not_resolved_engine_icall')
    def test_token_rid_not_global_method_index(self):
        m,b=fixture()
        struct.pack_into('<I',m,420,0x06000002)
        struct.pack_into('<I',m,452,0x06000001)
        result=self.run_loc(m,b)
        self.assertEqual([(x['entry_va'],x['direct_bl_candidates']) for x in result['methods']],[(0x1090,[0x10a0]),(0x1080,[0x1040])])
    def test_unknown_version(self):
        m,b=fixture();struct.pack_into('<I',m,4,99)  # 不存在的版本
        with self.assertRaises(loc.Invalid): self.run_loc(m,b)
    def test_module_mismatch(self):
        m,b=fixture();b[512]=ord('X')
        with self.assertRaises(loc.Invalid): self.run_loc(m,b)
    def test_null_pointer(self):
        m,b=fixture();struct.pack_into('<Q',b,832,0)
        with self.assertRaises(loc.Invalid): self.run_loc(m,b)
    def test_token_out_of_range(self):
        m,b=fixture();struct.pack_into('<I',m,420,0x06000003)
        with self.assertRaises(loc.Invalid): self.run_loc(m,b)
    def test_declaring_type_mismatch(self):
        m,b=fixture();struct.pack_into('<i',m,404,1)
        with self.assertRaises(loc.Invalid): self.run_loc(m,b)
    def test_outside_text(self):
        m,b=fixture();struct.pack_into('<Q',b,832,0x1200)
        with self.assertRaises(loc.Invalid): self.run_loc(m,b)
    def test_section_overlap(self):
        m,b=fixture();struct.pack_into('<I',m,168,480)
        with self.assertRaises(loc.Invalid): self.run_loc(m,b)
    def test_non_call_and_outside_text_ignored(self):
        m,b=fixture();struct.pack_into('<I',b,64,0x14000010);struct.pack_into('<I',b,0,0x94000020)
        self.assertEqual(self.run_loc(m,b)['methods'][0]['direct_bl_candidates'],[])
    def test_ambiguous_setter(self):
        m,b=fixture()
        # Both types now describe Application; there is no QualitySettings.
        struct.pack_into('<I',m,568,struct.unpack_from('<I',m,480)[0])
        struct.pack_into('<I',m,432,struct.unpack_from('<I',m,400)[0])
        with self.assertRaises(loc.Invalid): self.run_loc(m,b)
    def test_bad_strings(self):
        m,b=fixture();struct.pack_into('<I',m,480,999999)
        with self.assertRaises(loc.Invalid): self.run_loc(m,b)
    def test_bad_pointer_table(self):
        m,b=fixture();struct.pack_into('<Q',b,784,0x13ff)
        with self.assertRaises(loc.Invalid): self.run_loc(m,b)
    def test_invalid_signature(self):
        m,b=fixture();struct.pack_into('<H',m,424,0)
        with self.assertRaises(loc.Invalid): self.run_loc(m,b)
    def test_cli_read_only_and_error_atomicity(self):
        m,b=fixture()
        with tempfile.TemporaryDirectory() as td:
            mp,bp=Path(td)/'metadata.dat',Path(td)/'mapped.bin'
            mp.write_bytes(m);bp.write_bytes(b)
            cmd=[sys.executable,str(ROOT/'tools/il2cpp_fps_loc.py'),str(mp),str(bp),'--image-base','0x1000','--codegen-module','0x1300','--text-start','0x1040','--text-size','0x80']
            result=subprocess.run(cmd,capture_output=True,text=True)
            self.assertEqual(result.returncode,0,result.stderr)
            self.assertEqual(json.loads(result.stdout)['image_sha256'],hashlib.sha256(b).hexdigest())
            self.assertEqual(mp.read_bytes(),bytes(m));self.assertEqual(bp.read_bytes(),bytes(b))
            struct.pack_into('<Q',b,840,0);bp.write_bytes(b)
            result=subprocess.run(cmd,capture_output=True,text=True)
            self.assertEqual(result.returncode,1);self.assertEqual(result.stdout,'')
            self.assertEqual(json.loads(result.stderr)['status'],'unresolved')
    def test_short_input(self):
        with self.assertRaises(loc.Invalid): self.run_loc(b'bad')

if __name__=='__main__': unittest.main()
