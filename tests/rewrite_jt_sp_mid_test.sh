#!/bin/bash
# 改写器跳转表分派块搬 sp 访存的单测（runtime/rewriter/rewriter.c 的 sp_rebase / sp_mid_ok，合成 NSO，约 5 秒）：bash tests/rewrite_jt_sp_mid_test.sh
# 门禁覆盖：runtime/rewriter/* tests/rewrite_corpus/*
# 形态 = 语料 03d（女神异闻录5 乱战 main 0x494864–0x4948e0）：ldrsw 与 br 之间的 stp w0,w0,[sp,#0x44]、str w0,[sp,#0x78] 随桩搬进分派块。
#   苹果块只用 sp 下方暂存、不动 sp → 原样搬；安卓块先 sub sp,sp,#32 → 偏移各加 0x20：stp …[sp,#0x64]、str …[sp,#0x98]（期望手算，不跑被测实现）
# ① 苹果补丁区有 stp w0, w0, [sp, #0x44] 与 str w0, [sp, #0x78]，没有 +0x20 的版本
# ② 安卓补丁区有 stp w0, w0, [sp, #0x64] 与 str w0, [sp, #0x98]，没有原偏移的版本
# ③ 偏移为负的 sp 访存（stur w0,[sp,#-8]，会碰苹果块的 sp 下方暂存）不搬：br 报缺口
set -u; H=$(cd "$(dirname "$0")/.." && pwd); bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
PY=${PY:-${S2A_PY:-$HOME/.s2arm/venv/bin/python3}}   # 改写器钉死的解释器（tools/rewriter-requirements.txt）
REW=${REW:-$(python3 "$H/pack/rewriter.py" c-path 2>/dev/null | tail -1)}; [ -x "$REW" ] || { echo "不通 取不到 C 改写器（python3 pack/rewriter.py c-path）"; exit 1; }
out=$("$PY" - "$H/tests/rewrite_corpus" "$REW" <<'EOF'
import os, sys, struct
sys.path.insert(0, sys.argv[1]); sys.argv = [sys.argv[0], sys.argv[2]]
import run
from capstone import Cs, CS_ARCH_ARM64, CS_MODE_ARM
case = next(c for c in run.CASES if c['name'] == '03d_word_rel_base_copy_sp_mids')
neg = case['asm'].replace('str w0, [sp, #0x78]', 'stur w0, [sp, #-8]')
md = Cs(CS_ARCH_ARM64, CS_MODE_ARM)
for tag, asm in (('pos', case['asm']), ('neg', neg)):
    code = run.assemble(tag, asm)
    for target in ('apple', 'android'):
        d = os.path.join(run.T, tag + target); os.makedirs(d)
        run.nso(code, case['ro'], 4 * len(code), os.path.join(d, 'main'))
        rc, gaps, _, _ = run.rewrite(os.path.join(d, 'main'), d, target)
        if rc:
            print(f'{tag} {target} rc={rc} gaps={[(hex(a), k) for a, k in gaps]}'); continue
        b = open(os.path.join(d, 'main.patched.bin'), 'rb').read()
        po = int([l.split('\t')[1] for l in open(os.path.join(d, 'main.fixups.tsv')) if l.startswith('# PATCH_OFF')][0], 16)
        ins = {f'{i.mnemonic} {i.op_str}' for i in md.disasm(b[po:], po)}
        for want in ('stp w0, w0, [sp, #0x44]', 'str w0, [sp, #0x78]', 'stp w0, w0, [sp, #0x64]', 'str w0, [sp, #0x98]'):
            print(f'{tag} {target} rc=0 {want} {"有" if want in ins else "无"}')
EOF
)
echo "$out" | sed 's/^/  /'
has() { grep -qxF "$1" <<< "$out"; }
ck "① 苹果原样搬（#0x44 / #0x78 有、#0x64 / #0x98 无）" 'has "pos apple rc=0 stp w0, w0, [sp, #0x44] 有" && has "pos apple rc=0 str w0, [sp, #0x78] 有" && has "pos apple rc=0 stp w0, w0, [sp, #0x64] 无" && has "pos apple rc=0 str w0, [sp, #0x98] 无"'
ck "② 安卓偏移 +0x20（#0x64 / #0x98 有、#0x44 / #0x78 无）" 'has "pos android rc=0 stp w0, w0, [sp, #0x64] 有" && has "pos android rc=0 str w0, [sp, #0x98] 有" && has "pos android rc=0 stp w0, w0, [sp, #0x44] 无" && has "pos android rc=0 str w0, [sp, #0x78] 无"'
ck "③ 负偏移 sp 访存不搬、br(0x128) 报缺口" 'has "neg apple rc=3 gaps=[('"'"'0x128'"'"', '"'"'br_x18'"'"')]" && has "neg android rc=3 gaps=[('"'"'0x128'"'"', '"'"'br_x18'"'"')]"'
[ $bad = 0 ] && echo "✅ 跳转表分派块搬 sp 访存全通" || { echo "🔴 跳转表分派块搬 sp 访存有不通项"; exit 1; }
