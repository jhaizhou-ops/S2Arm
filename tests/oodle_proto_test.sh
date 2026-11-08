#!/bin/bash
# Oodle 工具模式协议层单测（不读游戏、不起真宿主，约 2 秒）：bash tests/oodle_proto_test.sh
# 被测：translator/uepak.py OodleHost / oodle_host_find、graphics/tools/shbake/pkz.py entries / read 的 Oodle 分支、pack/ue_pak.py OodleDecoder / decompress。
# 宿主用假的（tests/fake_oodle_host.py，「压缩块」= 8C 0A + zlib 流），期望值 = 压缩前的原文，不跑被测实现算：
#   ① OodleHost：好块解回原文；坏块（zlib 流被改）→ 宿主答 0 → 客户端抛错；坏块之后宿主还活着，下一块照解
#   ② oodle_host_find：没宿主 / 没模块目录各自点名；两样都有才回 (宿主, 目录)；目录缺省取 RomFS 的父目录（有 main.fixups.tsv 才算）
#   ③ pkz：entries() 缺省拒 OodleKraken、oodle=True 放行；read() 没给解码器 → FormatError 点名 DM_OODLE_HOST；给了 → 原文；解码器回长度不符 → FormatError
#   ④ ue_pak：OodleDecoder 没宿主时一调就抛 Unsupported 并带原因；decompress('Oodle') 没给解码器 → Unsupported；给了假宿主 → 原文
#   ⑤ 宿主没起来（写 200 行噪声后退出）：设了 DM_OODLE_LOG_DIR → 报错头一行点名 oodle_host.<进程号>.log，文件里 200 行全在（首行、末行都在），报错只带末 3000 字
#   ⑥ oodle_needs_sdk.py：手造 NSO（三段不压缩），只读段带 \0LZ5_decompress_safe\0 → yes；不带 → no；不是 NSO → 答 no 并说明；文件不在 → 退 2
# 门禁覆盖：translator/uepak.py translator/oodle_needs_sdk.py graphics/tools/shbake/pkz.py pack/ue_pak.py tests/fake_oodle_host.py
set -u; H=$(cd "$(dirname "$0")/.." && pwd); PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}
cd "$H" && "$PY" -B - "$H" <<'PY'
import os, struct, sys, tempfile, unittest, zlib, importlib.util
H = sys.argv[1]
def load(name, rel):
    spec = importlib.util.spec_from_file_location(name, os.path.join(H, rel)); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m
U = load('uepak', 'translator/uepak.py')
sys.path.insert(0, os.path.join(H, 'graphics/tools/shbake')); import pkz
sys.path.insert(0, os.path.join(H, 'pack')); import ue_pak
FAKE = os.path.join(H, 'tests/fake_oodle_host.py')
def blk(raw): return b'\x8c\x0a' + zlib.compress(raw)
A, B = b'alpha-shader-' * 40, b'beta-shader-' * 70

class Proto(unittest.TestCase):
    def setUp(self):
        self.t = tempfile.mkdtemp(); self.mods = os.path.join(self.t, 'root'); os.makedirs(os.path.join(self.mods, 'romfs'))
        open(os.path.join(self.mods, 'main.fixups.tsv'), 'w').write('# 假\n')
        for k in ('DM_OODLE_HOST', 'DM_OODLE_MODULES'): os.environ.pop(k, None)
    def test_1_host_protocol(self):
        h = U.OodleHost(FAKE, self.mods)
        self.assertEqual(h(blk(A), len(A)), A)
        bad = bytearray(blk(B)); bad[10] ^= 0xff
        with self.assertRaises(ValueError): h(bytes(bad), len(B))
        self.assertEqual(h(blk(B), len(B)), B)   # 坏块之后宿主还在
        with self.assertRaises(ValueError): h(blk(A), len(A) + 1)   # 原长报错 → 宿主答 0
        self.assertEqual(h.n, 2); h.close()
    def test_5_host_output_kept(self):
        logd = os.path.join(self.t, 'logs'); os.makedirs(logd)
        os.environ['FAKE_OODLE_DIE_NOISE'] = '200'; os.environ['DM_OODLE_LOG_DIR'] = logd
        try:
            h = U.OodleHost(FAKE, self.mods)
            with self.assertRaises(ValueError) as cm: h(blk(A), len(A))
        finally:
            os.environ.pop('FAKE_OODLE_DIE_NOISE'); os.environ.pop('DM_OODLE_LOG_DIR')
        msg = str(cm.exception); logs = [f for f in os.listdir(logd) if f.startswith('oodle_host.') and f.endswith('.log')]
        self.assertEqual(len(logs), 1); full = open(os.path.join(logd, logs[0])).read()
        self.assertIn(os.path.join(logd, logs[0]), msg)
        self.assertIn('假宿主噪声第 0 行', full); self.assertIn('假宿主噪声第 199 行', full); self.assertNotIn('假宿主噪声第 0 行', msg)
        h.close()
    def test_6_needs_sdk(self):
        tool = os.path.join(H, 'translator/oodle_needs_sdk.py')
        def nso(ro):
            segs = [b'\x00' * 0x40, ro, b'\x00' * 0x10]; hdr = bytearray(0x100); hdr[:4] = b'NSO0'; off = 0x100
            for k, sg in enumerate(segs):
                struct.pack_into('<III', hdr, 0x10 + k * 0x10, off, off, len(sg)); struct.pack_into('<I', hdr, 0x60 + k * 4, len(sg)); off += len(sg)
            p = os.path.join(self.t, 'main'); open(p, 'wb').write(bytes(hdr) + b''.join(segs)); return p
        import subprocess
        run = lambda p: subprocess.run([sys.executable, tool, p], capture_output=True, text=True)
        self.assertEqual(run(nso(b'abc\0LZ5_decompress_safe\0def')).stdout.strip(), 'yes')
        self.assertEqual(run(nso(b'abc\0OodleLZ_Decompress\0def')).stdout.strip(), 'no')
        p = os.path.join(self.t, 'junk'); open(p, 'wb').write(b'not an nso'); r = run(p); self.assertEqual((r.returncode, r.stdout.strip()), (0, 'no')); self.assertIn('不是能解的 NSO', r.stderr)
        self.assertEqual(run(os.path.join(self.t, 'missing')).returncode, 2)
    def test_2_find(self):
        os.environ['DM_OODLE_HOST'] = os.path.join(self.t, 'nohost')
        found, why = U.oodle_host_find(os.path.join(self.t, 'elsewhere'))
        self.assertIsNone(found); self.assertIn('DM_OODLE_HOST', why); self.assertIn('不存在', why); self.assertIn('DM_OODLE_MODULES', why)
        os.environ['DM_OODLE_HOST'] = FAKE
        found, why = U.oodle_host_find(os.path.join(self.mods, 'romfs'))
        self.assertEqual(found, (FAKE, self.mods), why)
        os.environ['DM_OODLE_MODULES'] = self.t   # 指了目录但里面没有 main.fixups.tsv
        found, why = U.oodle_host_find(None)
        self.assertIsNone(found); self.assertIn('main.fixups.tsv', why)
    def test_3_pkz(self):
        comp = blk(A); data = b'head' + comp
        m = pkz.Member('a.dat', 'OodleKraken', len(A), 4, len(comp))
        def no_zstd(*a): self.fail('Oodle 成员不该走 Zstandard 解码器')
        with self.assertRaises(pkz.FormatError) as cm: pkz.read(data, m, no_zstd)
        self.assertIn('DM_OODLE_HOST', str(cm.exception))
        h = U.OodleHost(FAKE, self.mods)
        self.assertEqual(pkz.read(data, m, no_zstd, h), A)
        with self.assertRaises(pkz.FormatError): pkz.read(data, m, no_zstd, lambda c, n: A[:-1])
        h.close()
        # 容器级：索引里一个 OodleKraken 成员，entries() 缺省拒、oodle=True 放行
        names = b'a.dat\0OodleKraken\0'; table = struct.pack('<IIQQQ', 0, 6, len(A), 32 + 32 + len(names), len(comp))
        body = b'pkzl' + b'\0' * 4 + struct.pack('<Q', 32 + 32 + len(names) + len(comp)) + struct.pack('<III', 1, 32, len(names)) + b'\0' * 4 + table + names + comp
        with self.assertRaises(pkz.FormatError): pkz.entries(body)
        ents = pkz.entries(body, oodle=True)
        self.assertEqual([(e.name, e.compression, e.size) for e in ents], [('a.dat', 'OodleKraken', len(A))])
    def test_4_ue_pak(self):
        d = ue_pak.OodleDecoder(os.path.join(self.t, 'elsewhere', 'romfs'))
        self.assertIsNone(d.found)
        with self.assertRaises(ue_pak.Unsupported) as cm: d(blk(A), len(A))
        self.assertIn('DM_OODLE', str(cm.exception))
        with self.assertRaises(ue_pak.Unsupported): ue_pak.decompress('Oodle', blk(A), len(A))
        os.environ['DM_OODLE_HOST'] = FAKE
        d = ue_pak.OodleDecoder(os.path.join(self.mods, 'romfs'))
        self.assertEqual(ue_pak.decompress('Oodle', blk(A), len(A), d), A)
        self.assertEqual(ue_pak.decompress('LZ5', blk(B), len(B), d), B)
        self.assertEqual((d.n, d.nbytes), (2, len(A) + len(B))); d.close()
unittest.main(argv=['oodle_proto_test'], verbosity=1)
PY
rc=$?; [ $rc = 0 ] && echo "oodle 协议层单测全过（6 组）" || { echo "oodle 协议层单测有不通"; exit 1; }
