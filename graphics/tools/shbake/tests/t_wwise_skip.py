#!/usr/bin/env python3
# Wwise 音频包整份不扫的边界单测（graphics/tools/shbake/nxsh_extract.py top_wwise / skip_wwise，11-01 出包线）：约 1 秒，退出 0 = 全过。
# 构造（期望手写）：一支片元着色器（控制段 0x800 + 带图形代码头的机器码，同 t_adj_ghost ③）zlib 压缩后放进三种文件：
#   ① 假 AKPK 包（'AKPK' 头长 16 版本 1）：按头认作 Wwise → 整份跳过，抽不到（这就是规则的边界：真塞了着色器的 Wwise 包会漏，靠核查模式数反例）；
#   ② 同样字节、核查模式 NXSH_WWISE_AUDIT=1：照扫，抽到 1 支，汇总记反例 1；
#   ③ 头像 AKPK 但版本 7（不是确证的 Wwise）：不跳，照扫抽到 1 支。
import os, sys, struct, zlib, tempfile, subprocess, collections
H = os.path.dirname(os.path.dirname(os.path.abspath(__file__))); sys.path.insert(0, H)
fail = 0; n = 0
def ck(ok, msg):
    global fail, n
    n += 1; print(('✓ ' if ok else '✗ ') + msg); fail += 0 if ok else 1
CN, DN = 0x800, 0x40
NOP, EXIT = 0x50b0000000070f00, 0xe30000000007000f
c = bytearray(CN); c[0:8] = bytes.fromhex('3412769801000000')
struct.pack_into('<I', c, 0x20, CN); struct.pack_into('<I', c, 0x700, DN); struct.pack_into('<I', c, 0x704, DN)
w = [0] * (DN // 8); w[-2] = EXIT; w[-1] = NOP
code = bytearray(struct.pack(f'<{len(w)}Q', *w)); code[0:16] = bytes.fromhex('78563412') + bytes(12); struct.pack_into('<I', code, 0x30, 5 << 10)
shader = bytes(0x40) + bytes(c) + bytes(code) + bytes(0x40)
body = zlib.compress(shader * 4, 9) + bytes(4096)
def run(head, audit):
    d = tempfile.mkdtemp(); r = os.path.join(d, 'romfs'); os.makedirs(r); o = os.path.join(d, 'out')
    open(os.path.join(r, 'snd.pck'), 'wb').write(head + body)
    env = dict(os.environ, J='1', **({'NXSH_WWISE_AUDIT': '1'} if audit else {}))
    p = subprocess.run([sys.executable, os.path.join(H, 'nxsh_extract.py'), o, r], capture_output=True, text=True, env=env)
    keys = [l for l in open(os.path.join(o, 'index.tsv')) if not l.startswith('#')] if os.path.exists(os.path.join(o, 'index.tsv')) else []
    return len(keys), p.stdout + p.stderr
akpk = b'AKPK' + struct.pack('<II', 16, 1) + bytes(16)
k, log = run(akpk, False)
ck(k == 0 and '跳过 Wwise 音频包（AKPK）：snd.pck' in log, f'① 确证 AKPK：跳过、日志记路径，抽到 0 支（实得 {k}）')
k, log = run(akpk, True)
ck(k == 1 and '跳过规则反例' in log and '【红】Wwise 核查反例' in log, f'② 核查模式：照扫抽到 1 支并记反例（实得 {k}）')
k, log = run(b'AKPK' + struct.pack('<II', 16, 7) + bytes(16), False)
ck(k == 1 and '跳过 Wwise' not in log, f'③ 版本不是 1 的「AKPK」：不跳，抽到 1 支（实得 {k}）')
print(f't_wwise_skip：{n} 项，失败 {fail}')
sys.exit(1 if fail else 0)
