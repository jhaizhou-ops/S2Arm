"""Original synthetic NSO; expected addresses/sizes are fixed, not tool-derived."""
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
import lz4.block

ROOT = Path(__file__).resolve().parents[1]
TOOL = Path(os.environ.get('S2A_SDK_MEM_LOC', ROOT / 'tools/sdk_mem_loc.py'))
sys.path.insert(0, str(ROOT / 'tools'))
spec = importlib.util.spec_from_file_location('sdk_mem_loc', TOOL)
loc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(loc)


def fixture(symbols=None, compressed=False, tags=None):
    # NSO text 0..0x200, ro 0x1000..0x1800, data 0x2000..0x2010.
    # MOD0 at 0x20, dynamic at 0x1000, symtab 0x1100,
    # strtab 0x1400, SYSV hash 0x1600. No real SDK/game bytes.
    if symbols is None:
        symbols = [('memcpy', 0x12, 1, 0x100, 16),
                   ('memset', 0x22, 1, 0x120, 32),
                   ('_ZN2nn2os14FlushDataCacheEPKvm', 0x12, 1, 0x160, 12)]
    text, ro, data = bytearray(0x200), bytearray(0x800), bytes(16)
    struct.pack_into('<I', text, 4, 0x20)
    text[0x20:0x24] = b'MOD0'
    struct.pack_into('<i', text, 0x24, 0xFE0)
    strings = bytearray(b'\0')
    for i, (name, info, section, address, size) in enumerate(symbols, 1):
        off = len(strings)
        strings += name.encode() + b'\0'
        struct.pack_into('<IBBHQQ', ro, 0x100 + 24*i, off, info, 0, section, address, size)
    ro[0x400:0x400+len(strings)] = strings
    count = len(symbols)+1
    struct.pack_into('<II', ro, 0x600, 1, count)
    # bucket 0 and nchain zeroes: count is authoritative; lookup not required.
    entries = [(4, 0x1600), (5, 0x1400), (6, 0x1100), (10, len(strings)), (11, 24), (0, 0)]
    for i, (tag, val) in enumerate(entries if tags is None else tags):
        struct.pack_into('<qQ', ro, i*16, tag, val)
    header, payload = bytearray(0x100), bytearray()
    header[:4] = b'NSO0'
    for i, (base, segment) in enumerate(((0, text), (0x1000, ro), (0x2000, data))):
        encoded = lz4.block.compress(bytes(segment), store_size=False) if compressed else segment
        struct.pack_into('<III', header, 0x10+16*i, 0x100+len(payload), base, len(segment))
        struct.pack_into('<I', header, 0x60+4*i, len(encoded))
        if compressed: header[12] |= 1 << i
        payload += encoded
    return bytes(header+payload)


class Tests(unittest.TestCase):
    def test_independent_addresses_sizes_and_identity(self):
        raw = fixture()
        r = loc.analyze(raw)
        self.assertEqual([(x['symbol'],x['address'],x['length']) for x in r['functions']],
                         [('memcpy','0x100',16),('memset','0x120',32),
                          ('_ZN2nn2os14FlushDataCacheEPKvm','0x160',12)])
        self.assertEqual(r['input_sha256'],hashlib.sha256(raw).hexdigest())
        self.assertEqual(r['address_kind'],'module_virtual_offset')
        self.assertFalse(r['runtime_verified'])
    def test_compressed_identical_locations(self):
        self.assertEqual(loc.analyze(fixture(compressed=True))['functions'],loc.analyze(fixture())['functions'])
    def test_import_object_local_and_substring_excluded(self):
        syms = [('memcpy',0x12,0,0,0),('memset',0x11,1,0x100,16),
                ('memmove',0x02,1,0x120,16),('not_memcpy',0x12,1,0x140,16),
                ('_ZN2nn2os14FlushDataCacheExtraEv',0x12,1,0x160,16)]
        self.assertEqual(loc.analyze(fixture(syms))['functions'],[])
    def test_zero_length_not_inferred_from_next_symbol(self):
        r=loc.analyze(fixture([('memcpy',0x12,1,0x100,0),('memset',0x12,1,0x120,16)]))
        self.assertEqual(len(r['functions']),1)
        self.assertEqual(r['unresolved'][0]['reason'],'zero_symbol_size')
    def test_invalid_target_ranges_rejected(self):
        for addr,size in [(0x1FC,8),(0x1000,4),(0x101,4),(0x100,3),(2**64-4,8)]:
            with self.subTest(addr=addr,size=size),self.assertRaises(ValueError):
                loc.analyze(fixture([('memcpy',0x12,1,addr,size)]))
    def test_bad_header_and_truncation(self):
        raw=fixture()
        for bad in (b'',b'NSO0',raw[:0x120],b'XXXX'+raw[4:]):
            with self.assertRaises(ValueError):loc.analyze(bad)
    def test_required_dynamic_metadata_not_guessed(self):
        for tags in [[(5,0x1400),(6,0x1100),(10,10),(11,24),(0,0)],
                     [(4,0x1600),(5,0x1400),(6,0x1100),(10,10),(11,16),(0,0)],
                     [(4,0x1600),(5,0x1400),(6,0x1100),(10,10),(11,24),(6,0x1120),(0,0)]]:
            with self.assertRaises(ValueError):loc.analyze(fixture(tags=tags))
    def test_string_bounds_and_termination(self):
        raw=bytearray(fixture())
        struct.pack_into('<I',raw,0x300+0x100+24,0x800)
        with self.assertRaises(ValueError):loc.analyze(bytes(raw))
        raw=bytearray(fixture())
        raw[0x300+0x400+1:0x300+0x400+8]=b'memcpyX'
        # Truncate DT_STRSZ before any NUL following this name.
        struct.pack_into('<Q',raw,0x300+3*16+8,8)
        with self.assertRaises(ValueError):loc.analyze(bytes(raw))
    def test_duplicate_export_not_silently_selected(self):
        with self.assertRaises(ValueError):
            loc.analyze(fixture([('memcpy',0x12,1,0x100,16),('memcpy',0x12,1,0x120,16)]))
    def test_symbol_count_limit(self):
        with self.assertRaises(ValueError):loc.analyze(fixture(),max_symbols=2)
    def test_gnu_hash_count_and_malformed_chain(self):
        raw=bytearray(fixture(tags=[(0x6FFFFEF5,0x1600),(5,0x1400),(6,0x1100),(10,48),(11,24),(0,0)]))
        # Bloom, one bucket starting at symbol 1, three chain entries.
        struct.pack_into('<IIIIQIIII',raw,0x900,1,1,1,5,0,1,0x100,0x200,0x301)
        r=loc.analyze(bytes(raw))
        self.assertEqual(r['count_sources'],['DT_GNU_HASH'])
        self.assertEqual([(x['address'],x['length']) for x in r['functions']],
                         [('0x100',16),('0x120',32),('0x160',12)])
        struct.pack_into('<I',raw,0x900+36,0x300)
        with self.assertRaises(ValueError):loc.analyze(bytes(raw),max_symbols=4)
    def test_hash_count_disagreement(self):
        tags=[(4,0x1600),(0x6FFFFEF5,0x1680),(5,0x1400),(6,0x1100),(10,48),(11,24),(0,0)]
        raw=bytearray(fixture(tags=tags))
        struct.pack_into('<IIIIQII',raw,0x980,1,1,1,5,0,1,0x101)
        with self.assertRaises(ValueError):loc.analyze(bytes(raw))
    def test_missing_mod0_and_unbacked_dynamic(self):
        for offset,value in [(0x120,0),(0x124,0x700)]:
            raw=bytearray(fixture());struct.pack_into('<I',raw,offset,value)
            with self.assertRaises(ValueError):loc.analyze(bytes(raw))
    def test_bad_null_symbol(self):
        raw=bytearray(fixture());raw[0x400]=1
        with self.assertRaises(ValueError):loc.analyze(bytes(raw))
    def test_hidden_and_protected_visibility(self):
        raw=bytearray(fixture());raw[0x400+24+5]=2
        self.assertEqual(len(loc.analyze(bytes(raw))['functions']),2)
        raw[0x400+24+5]=3
        self.assertEqual(len(loc.analyze(bytes(raw))['functions']),3)
    def test_reserved_absolute_section_is_not_module_offset(self):
        with self.assertRaises(ValueError):loc.analyze(fixture([('memcpy',0x12,0xFFF1,0x100,16)]))
    def test_exact_extra_symbol_and_all_memory_names(self):
        names=['memmove','memcmp','memchr','bcopy','bzero','_ZN2nn2os14StoreDataCacheEPKvm',
               '_ZN2nn2os19InvalidateDataCacheEPvm','custom_memory']
        raw=fixture([(name,0x12,1,0x100,4) for name in names])
        self.assertEqual(len(loc.analyze(raw)['functions']),7)
        r=loc.analyze(raw,symbols=['custom_memory'])
        self.assertEqual(r['functions'][-1]['family'],'explicit_symbol')
    def test_overlapping_segments_and_byte_budget(self):
        raw=bytearray(fixture());struct.pack_into('<I',raw,0x24,0x100)
        with self.assertRaises(ValueError):loc.analyze(bytes(raw))
        with self.assertRaises(ValueError):loc.analyze(fixture(),max_bytes=100)
    def test_digest_verified_not_ignored(self):
        raw=bytearray(fixture());raw[12]|=8
        raw[0xA0:0xC0]=hashlib.sha256(raw[0x100:0x300]).digest()
        self.assertEqual(len(loc.analyze(bytes(raw))['functions']),3)
        raw[0x200]^=1
        with self.assertRaises(ValueError):loc.analyze(bytes(raw))
    def test_cli_fifo_rejected_without_blocking(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'fifo';os.mkfifo(p)
            # 卡住是无限期阻塞（没有写端的 fifo 打开就不返回），上限只为分开「拒绝」与「卡住」，不量快慢：给 60 秒，满负载 mini 起 Python 也到不了
            #   （原 5 秒：11-02 mini 普查并发时解释器启动 + 导入就超 5 秒，无缓存实跑假红）
            r=subprocess.run([sys.executable,str(TOOL),str(p)],capture_output=True,text=True,timeout=60)
            self.assertEqual(r.returncode,2);self.assertEqual(r.stdout,'')
    def test_cli_read_only_and_no_partial_error_report(self):
        with tempfile.TemporaryDirectory() as d:
            p=Path(d)/'sdk'; p.write_bytes(fixture()); before=p.read_bytes()
            r=subprocess.run([sys.executable,str(TOOL),str(p)],capture_output=True,text=True)
            self.assertEqual(r.returncode,0,r.stderr)
            self.assertEqual(json.loads(r.stdout)['functions'][0]['address'],'0x100')
            self.assertEqual(p.read_bytes(),before)
            p.write_bytes(b'invalid')
            r=subprocess.run([sys.executable,str(TOOL),str(p)],capture_output=True,text=True)
            self.assertEqual(r.returncode,2);self.assertEqual(r.stdout,'')

if __name__=='__main__':unittest.main()
