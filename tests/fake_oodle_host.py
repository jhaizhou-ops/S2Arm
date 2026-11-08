#!/usr/bin/env python3
# 门禁手动：辅助脚本（假宿主），由 tests/oodle_proto_test.sh、tests/ue_pak_test.sh 经 DM_OODLE_HOST 交给被测工具执行，本身不是单测
# 假宿主（单测用，tests/oodle_proto_test.sh、tests/ue_pak_test.sh ④）：只说 Oodle 工具模式的协议（runtime/src/oodle_tool.c DM_OODLE_SERVE：stdin 每请求 u64 压缩长 u64 原长 + 字节，
#   stdout u64 解出长 + 字节，0 = 失败），不解真 Oodle——「压缩块」= 8C 0A（Oodle Mermaid 块头）+ zlib 流，解出 = zlib 解压；块头不对 / 长度不符 → 应答 0，与真宿主一致。
# 参数：<模块目录>（不读，只核客户端传了）。没设 DM_OODLE_SERVE 退出 2（核对客户端给了环境变量）。stdin 结束后退出：有失败退 1。只用标准库，系统 python3 就能跑
import os, struct, sys, zlib
if not os.environ.get('DM_OODLE_SERVE'): print('假宿主：没设 DM_OODLE_SERVE', file=sys.stderr); sys.exit(2)
if len(sys.argv) < 2: print('假宿主：没给模块目录参数', file=sys.stderr); sys.exit(2)
if os.environ.get('FAKE_OODLE_DIE_NOISE'):   # 模拟宿主没起来（11-01 勇者斗恶龙 XI S：宿主不带 C#、LZ5 起不来）：先写 N 行到 stderr，一个请求都不答就退出
    for k in range(int(os.environ['FAKE_OODLE_DIE_NOISE'])): print(f'假宿主噪声第 {k} 行 ' + 'x' * 40, file=sys.stderr)
    sys.exit(3)
i, o = sys.stdin.buffer, sys.stdout.buffer; n = bad = 0
while True:
    h = i.read(16)
    if len(h) < 16: break
    cl, rl = struct.unpack('<QQ', h); c = i.read(cl); out = b''
    if c[:2] == b'\x8c\x0a':
        try: out = zlib.decompress(c[2:])
        except zlib.error: out = b''
    if len(out) != rl: out = b''; bad += 1
    o.write(struct.pack('<Q', len(out)) + out); o.flush(); n += 1
print(f'假宿主：{n} 个请求，{bad} 个失败', file=sys.stderr); sys.exit(1 if bad else 0)
