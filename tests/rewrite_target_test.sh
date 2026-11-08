#!/bin/bash
# 改写器目标平台单测（runtime/rewriter/rewriter.c 的 S2A_TARGET，合成 NSO，约 3 秒）：bash tests/rewrite_target_test.sh
# 门禁覆盖：runtime/rewriter/*
# 合成模块的代码段（从 0x100 起；期望按 AArch64 编码与改写器头注释手算，不跑被测实现）：
#   0x100 mrs x0,tpidr_el0 / 0x104 msr tpidr_el0,x1 / 0x108 mrs x2,tpidrro_el0 / 0x10c add x3,x18,#8 / 0x110 mov x18,x4 / 0x114 svc #1 / 0x118 ret
# ① 缺省、apple、ios、macos 四种出的产物逐文件逐字节相同（苹果产物不随目标开关变）
# ② 苹果：0x100 改写块 = stur x16 → mrs x0,tpidrro_el0 → 键页取 KTLS（下标 1）→ add → ldr → ldur x16 → b 回 0x104；fixups 无 TARGET 行
# ③ 安卓：0 缺口、fixups 有「# TARGET android」；0x100 改写块 = 同上但 mrs x0,tpidr_el0 + ldur x0,[x0,#-8]（bionic_tls = TCB[-1]）
# ④ 安卓补丁区没有一条 mrs tpidrro_el0；每条 mrs tpidr_el0 后紧跟同寄存器 ldur #-8；条数与苹果的 mrs tpidrro_el0 相同；改写点清单与门数和苹果相同
# ⑤ ohos：0 缺口、fixups 有 TARGET ohos / REWRITE_ABI ohos-sp-safe-v1 / KEY_TSDOFF_IDX 4；0x100 改写块 = sp-safe 暂存 + mrs tpidr_el0 + TSDOFF 键页间接 + LDR + SUB#8 + KTLS 槽；补丁区无 sp 下方访问
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
PY=${PY:-${S2A_PY:-$HOME/.s2arm/venv/bin/python3}}   # 改写器钉死的解释器（tools/rewriter-requirements.txt）
REW=${REW:-$(python3 "$H/pack/rewriter.py" c-path 2>/dev/null | tail -1)}; [ -x "$REW" ] || { echo "不通 取不到 C 改写器（python3 pack/rewriter.py c-path）"; exit 1; }
mkdir -p "$T/exefs"
$PY - "$T/exefs/main" <<'EOF'
import struct, sys
code = [0xd53bd040, 0xd51bd041, 0xd53bd062, 0x91002243, 0xaa0403f2, 0xd4000021, 0x910023f2, 0xb4000052, 0xd503201f, 0xd65f03c0]
# 代码从 0x100 起；改写器要的模块骨架：text[4] = MOD0 偏移，MOD0 + 16 = eh_frame_hdr（一个 FDE 覆盖这段代码）
text = bytearray(0x1000); struct.pack_into('<II', text, 0, 0x14000040, 0x1000); struct.pack_into('<%dI' % len(code), text, 0x100, *code)
ro = bytearray(0x1000); EH, EF = 0x100, 0x200
struct.pack_into('<4sIIIii', ro, 0, b'MOD0', 0, 0, 0, EH, EH + 0x20)
struct.pack_into('<BBBBiIii', ro, EH, 1, 0x1B, 0x03, 0x3B, (0x1000 + EF) - (0x1000 + EH + 4), 1, 0x100 - (0x1000 + EH), (0x1000 + EF + 0x18) - (0x1000 + EH))
cie = struct.pack('<II', 0x14, 0) + bytes([1]) + b'zR\0' + bytes([4, 0x78, 30, 1, 0x1B]) + bytes(7)
ro[EF:EF + 0x18] = cie; f = 0x1000 + EF + 0x18
struct.pack_into('<IIii', ro, EF + 0x18, 0x10, (f + 4) - (0x1000 + EF), 0x100 - (f + 8), 4 * len(code))
text, ro, data = bytes(text), bytes(ro), bytes(0x1000)
h = bytearray(0x100); h[:4] = b'NSO0'; fo = 0x100
for k, (mo, seg) in enumerate(((0, text), (0x1000, ro), (0x2000, data))):
    struct.pack_into('<III', h, 0x10 + 0x10 * k, fo + 0x1000 * k, mo, len(seg)); struct.pack_into('<I', h, 0x60 + 4 * k, len(seg))
h[0x40:0x50] = bytes(range(16))
open(sys.argv[1], 'wb').write(bytes(h) + text + ro + data)
EOF
rew() { local o=$1; shift; mkdir -p "$T/$o"; env "$@" $PY "$H/tests/rewriter_exec.py" "$REW" "$T/exefs/main" "$T/$o" main > "$T/$o.log" 2>&1; echo $?; }
r0=$(rew dflt); r1=$(rew apple S2A_TARGET=apple); r2=$(rew ios S2A_TARGET=ios); r3=$(rew macos S2A_TARGET=macos); ra=$(rew android S2A_TARGET=android); rx=$(rew ohos S2A_TARGET=ohos)
[ "$r0" = 0 ] || tail -5 "$T/dflt.log"; [ "$ra" = 0 ] || tail -5 "$T/android.log"
same=1; for o in apple ios macos; do diff -r "$T/dflt" "$T/$o" > /dev/null || same=0; done
ck "① 缺省 / apple / ios / macos 产物逐字节相同（rc=${r0} ${r1} ${r2} ${r3}）" '[ "$r0$r1$r2$r3" = 0000 ] && [ $same = 1 ] && ls "$T/dflt"/main.patched.bin > /dev/null 2>&1'
# 取 0x100 处 B 指向的改写块（到第一条 b 为止），以及整片补丁区里线程槽基址相关指令的统计
dis() { $PY - "$T/$1" "$2" <<'EOF'
import re, struct, sys
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
d, mode = sys.argv[1], sys.argv[2]
hdr = {l.split('\t')[0][2:]: l.rstrip('\n').split('\t')[1] for l in open(d + '/main.fixups.tsv') if l.startswith('# ')}
key, po = int(hdr['KEY_PAGE_OFF'], 16), int(hdr['PATCH_OFF'], 16)
b = open(d + '/main.patched.bin', 'rb').read(); md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
if mode == 'blk':
    w, = struct.unpack_from('<I', b, 0x100); assert w >> 26 == 0b000101, f'0x100 不是 B：{w:#x}'
    imm = w & 0x3ffffff; t = 0x100 + 4 * (imm - (1 << 26) if imm >> 25 else imm); out = []
    for i in md.disasm(b[t:t + 64], t):
        out.append(f'{i.mnemonic} {i.op_str}'.replace(f'#{key:#x}', '#键页').replace('#0x104', '#+4'))
        if i.mnemonic == 'b': break
    print(';'.join(out))
elif mode == 'sum':
    ins = list(md.disasm(b[po:], po)); ro = tp = ok = 0
    for k, i in enumerate(ins):
        if i.mnemonic != 'mrs': continue
        r, sr = i.op_str.split(', ')
        if sr == 'tpidrro_el0': ro += 1
        if sr == 'tpidr_el0':
            tp += 1; nx = ins[k + 1] if k + 1 < len(ins) else None
            ok += nx is not None and nx.mnemonic == 'ldur' and nx.op_str == f'{r}, [{r}, #-8]'
    print(f'tpidrro={ro} tpidr={tp} ldur_ok={ok} target={hdr.get("TARGET", "-")}')
if mode == 'sp':
    bad = []
    for i in md.disasm(b[po:], po):
        if not i.mnemonic.startswith(('ldr', 'str', 'ldp', 'stp', 'ldur', 'stur', 'ldxr', 'stxr', 'ldaxr', 'stlxr')): continue
        if ']!' in i.op_str or '], #' in i.op_str: continue          # pre/post-index moves sp with the access
        if re.search(r'\[sp, #-', i.op_str):
            bad.append(f'{i.address:#x}:{i.mnemonic} {i.op_str}')
    print(f'below_sp={len(bad)}' + ('' if not bad else ' ' + ';'.join(bad[:3])))
EOF
}
ba=$(dis dflt blk 2>&1); sa=$(dis dflt sum 2>&1); bn=$(dis android blk 2>&1); sn=$(dis android sum 2>&1); ss=$(dis android sp 2>&1); bo=$(dis ohos blk 2>&1); so=$(dis ohos sum 2>&1); spo=$(dis ohos sp 2>&1)
ck "② 苹果 0x100 改写块（实得：${ba}；${sa}）" '[ "$ba" = "stur x16, [sp, #-0x10];mrs x0, tpidrro_el0;adrp x16, #键页;ldr x16, [x16, #8];add x0, x0, x16;ldr x0, [x0];ldur x16, [sp, #-0x10];b #+4" ] && [[ $sa == *" target=-" ]]'
ck "③ 安卓 0 缺口、0x100 改写块（rc=${ra}；实得：${bn}）" '[ "$ra" = 0 ] && [ "$bn" = "str x16, [sp, #-0x10]!;mrs x0, tpidr_el0;ldur x0, [x0, #-8];adrp x16, #键页;ldr x16, [x16, #8];add x0, x0, x16;ldr x0, [x0];ldr x16, [sp], #0x10;b #+4" ] && grep -qx "# TARGET	android" "$T/android/main.fixups.tsv" && grep -qx "# REWRITE_ABI	android-sp-safe-v1" "$T/android/main.fixups.tsv"'
na=${sa#tpidrro=}; na=${na%% *}
ck "④ 安卓补丁区：无 tpidrro、tpidr 后紧跟 ldur #-8、条数同苹果 ${na}（实得：${sn}）；改写点 / 门同苹果" '[ "$sn" = "tpidrro=0 tpidr=$na ldur_ok=$na target=android" ] && [ "$na" -ge 5 ] && diff -q "$T/dflt/main.sites.tsv" "$T/android/main.sites.tsv" > /dev/null && [ "$(cut -f2- "$T/dflt/main.gates.tsv" | grep -cv "^#")" = "$(cut -f2- "$T/android/main.gates.tsv" | grep -cv "^#")" ]'
ck "⑤ ohos 成功且 TLS/SP/表头正确（rc=${rx}；块：${bo}；sum：${so}；sp：${spo}）" '[ "$rx" = 0 ] && [ "$bo" = "str x16, [sp, #-0x10]!;mrs x0, tpidr_el0;adrp x16, #键页;ldr x16, [x16, #0x20];add x0, x0, x16;ldr x0, [x0];sub x0, x0, #8;adrp x16, #键页;ldr x16, [x16, #8];add x0, x0, x16;ldr x0, [x0];ldr x16, [sp], #0x10;b #+4" ] && grep -qx "# TARGET	ohos" "$T/ohos/main.fixups.tsv" && grep -qx "# REWRITE_ABI	ohos-sp-safe-v1" "$T/ohos/main.fixups.tsv" && grep -qx "# KEY_TSDOFF_IDX	4" "$T/ohos/main.fixups.tsv" && [[ $so == *" target=ohos" ]] && [ "$spo" = "below_sp=0" ]'
ck "⑥ 安卓补丁区没有 sp 下方访问（实得：${ss}）" '[ "$ss" = "below_sp=0" ]'
[ $bad = 0 ] && echo "改写器目标平台 期望全通 → 全通" || { echo "改写器目标平台 期望全通 → 有不通"; exit 1; }
