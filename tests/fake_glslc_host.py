#!/usr/bin/env python3
# 门禁手动：辅助脚本（假宿主），由 tests/glslc_offline_test.sh 写进包装脚本 exec、并 import 取常量，本身不是单测
# 假宿主（单测用，tests/glslc_offline_test.sh）：只说 GLSLC 工具模式的协议（runtime/src/glslc_tool.c DM_GLSLC_JOB：读 "DMGJ" 作业、写 <作业>.out "DMGR"），不跑任何游戏代码。
# 假编译器：源码里写 gl_Position 的只在阶段 0（顶点）编得过，带 "BAD" 的哪个阶段都不过，其余只在阶段 1（片元）编得过。
# 编出的输出按真 GLSLC 输出的布局拼（shader_split.py glslc_section 头注）：+0 魔数 91 68 86 19、+0x44 整份长度、+0x4c 段数 1、+0x90 段头
#   {u32 段长、u32 段数据偏移（相对输出）、u32 类型 0 = GPU 代码；+0x30 控制段偏移、+0x34 代码区偏移（相对段数据）、+0x38 代码区长、+0x3c 控制段长}；
#   控制段 0x880 字节（+0 魔数 34 12 76 98、+0x20 自身长度、+0x704 代码区长），代码区 = 78 56 34 12 头 + SPH（字 0 第 10..13 位：顶点 1、片元 5）+ 由源码哈希定的字节。
#   填充字节都 < 0x80，不会凑出两个魔数（都含 ≥ 0x80 的字节）
# FAKE_GLSLC_DIE=1：一条不编、直接退 134（模拟宿主崩）；FAKE_GLSLC_HANG=1：睡 30 秒不出结果（模拟宿主卡住）
import hashlib, os, struct, sys

def output(src, stage):
    h = hashlib.sha256(src + bytes([stage])).digest()
    fill = lambda n: bytes(b & 0x7f for b in (h * (n // len(h) + 1))[:n])
    code = bytearray(b'\x78\x56\x34\x12' + fill(0x2c) + struct.pack('<I', (1 if stage == 0 else 5) << 10 | 1) + fill(0x4c) + fill(0x100))
    ctl = bytearray(fill(0x880)); ctl[0:4] = b'\x34\x12\x76\x98'; struct.pack_into('<I', ctl, 0x20, 0x880); struct.pack_into('<I', ctl, 0x704, len(code))
    data = bytes(ctl) + bytes(code)
    soff = 0x90 + 0x90
    hdr = bytearray(fill(soff)); hdr[0:4] = b'\x91\x68\x86\x19'
    struct.pack_into('<I', hdr, 0x44, soff + len(data)); struct.pack_into('<I', hdr, 0x4c, 1)
    struct.pack_into('<III', hdr, 0x90, len(data), soff, 0); struct.pack_into('<4I', hdr, 0x90 + 0x30, 0, len(ctl), len(code), len(ctl))
    return bytes(hdr) + data

def main():
    job = os.environ['DM_GLSLC_JOB']
    if os.environ.get('FAKE_GLSLC_DIE'): print('[s2a] FATAL 【红】DM_GLSLC_JOB：假宿主按要求崩', file=sys.stderr); sys.exit(134)
    if os.environ.get('FAKE_GLSLC_HANG'): import time; time.sleep(30)
    d = open(job, 'rb').read(); assert d[:4] == b'DMGJ'
    n = struct.unpack_from('<I', d, 4)[0]; o = 8; out = [b'DMGR' + struct.pack('<I', n)]; ok = 0
    for _ in range(n):
        k = struct.unpack_from('<I', d, o)[0]; st = struct.unpack_from(f'<{k}I', d, o + 4); o += 4 + 4 * k
        ln = struct.unpack_from('<I', d, o)[0]; src = d[o + 4:o + 4 + ln]; o += 4 + ln
        want = None if b'BAD' in src else 0 if b'gl_Position' in src else 1
        used = want if want in st else None
        if used is None: out.append(struct.pack('<II', 0xffffffff, 0)); continue
        b = output(src, used); out.append(struct.pack('<II', used, len(b)) + b); ok += 1
    open(job + '.out', 'wb').write(b''.join(out))
    print(f'[s2a] DM_GLSLC_JOB：用游戏 subsdk0 的 glslcCompile 编成 {ok} 条、编不过 {n - ok} 条（假宿主）', file=sys.stderr)

if __name__ == '__main__': main()
