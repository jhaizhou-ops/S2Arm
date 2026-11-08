#!/bin/bash
# 宽屏第二层：社区超宽屏补丁映射到我方候选（graphics/widen/scan/comm_map.py，合成数据，约 1 秒）：bash tests/widen_comm_map_test.sh
# 合成：main 构建号 = 0x40 起 16 字节 11..（AA 重复），main.npdm 的 ACI0 程序号 0100AAAA0000B000；候选表 main 0x1000 / 0x1004 / 0x3000 / 0x5000。补丁（手算期望，不跑被测实现）：
#   ① 程序号对、@nsobid 对、带 offset_shift 0x100：0x1000（候选）、0x2000（不是候选）、@stop 之后 0x3000（候选，但已停）→ 出 0x1000
#   ② 程序号对（更新包号 …B800 归 …B000）、@nsobid 对、不带 offset_shift：0x1104 − 0x100 = 0x1004（候选）→ 出 0x1004
#   ③ 程序号对、@nsobid 是别的构建号：0x5000（候选）→ 不出
#   ④ 别的程序号、@nsobid 对：0x3000 → 不出
# 期望：main:0x1000,main:0x1004。旧代码反证：没有 comm_map.py（红）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}; CM=${CM:-$H/graphics/widen/scan/comm_map.py}
mkdir -p "$T/exefs" "$T/idx/p"
"$PY" - "$T" <<'PYEOF'
import struct, sys, os
T = sys.argv[1]
nso = bytearray(0x100); nso[:4] = b'NSO0'; nso[0x40:0x50] = bytes.fromhex('11' + 'AA' * 15)
open(f'{T}/exefs/main', 'wb').write(bytes(nso))
npdm = bytearray(0x200); npdm[:4] = b'META'; struct.pack_into('<I', npdm, 0x70, 0x80); npdm[0x80:0x84] = b'ACI0'; struct.pack_into('<Q', npdm, 0x90, 0x0100AAAA0000B000)
open(f'{T}/exefs/main.npdm', 'wb').write(bytes(npdm))
open(f'{T}/sites.tsv', 'w').write('模块\t偏移\t种类\t原字\nmain\t0x1000\taspdiv\t1e201820\nmain\t0x1004\tmovz\t52800000\nmain\t0x3000\tasp\t5291c728\nmain\t0x5000\tf32\t44f00000\n')
bid = '11' + 'AA' * 15
P = {'a.pchtxt': f'@nsobid-{bid}\n@flag offset_shift 0x100\n@enabled\n00001000 00001E21\n00002000 12345678\n@stop\n00003000 00000000\n',
     'b.pchtxt': f'@nsobid-{bid}0000\n@enabled\n00001104 08AE8152\n',
     'c.pchtxt': '@nsobid-' + 'BB' * 16 + '\n@flag offset_shift 0x100\n@enabled\n00005000 00000000\n',
     'd.pchtxt': f'@nsobid-{bid}\n@flag offset_shift 0x100\n@enabled\n00003000 00000000\n'}
for k, v in P.items(): open(f'{T}/idx/p/{k}', 'w').write(v)
rows = [('0100AAAA0000B000', 'a.pchtxt'), ('0100AAAA0000B800', 'b.pchtxt'), ('0100AAAA0000B000', 'c.pchtxt'), ('0100CCCC0000B000', 'd.pchtxt')]
with open(f'{T}/idx/INDEX.tsv', 'w') as o:
    o.write('game\ttitle_id\tversion\tbuild_id\taspect\tkind\tui_fix\tsource\tpath\n')
    for t, p in rows: o.write(f'g\t{t}\t1.0.0\t-\t21:9\tpchtxt\tyes\ts\tp/{p}\n')
PYEOF
got=$("$PY" "$CM" points "$T/idx" "$T/exefs" "$T/sites.tsv" 2> "$T/err.log")
if [ "$got" = "main:0x1000,main:0x1004" ]; then echo "通 社区补丁只映射本程序号、本构建号、@enabled 段里落在候选上的点（实得：${got}）"; echo "✓ widen_comm_map_test"; exit 0; fi
echo "不通 期望 main:0x1000,main:0x1004，实得「${got}」"; cat "$T/err.log"; echo "✗ widen_comm_map_test"; exit 1
