#!/bin/bash
# tools/nso_sym.py 单测：现造一个最小的合成 NSO0（不要游戏）—— text 里一个导出函数 fn_a（0x100，长 0x20）和一个 PLT 跳板（0x200：
#   adrp x16 / ldr x17,[x16,#8] / add / br x17，GOT 槽 0x2008 由 JUMP_SLOT 重定位指向导入函数 imported_fn）。期望按构造手算：
#   ① sym 0x110 → fn_a+0x10 在函数内；0x130 → fn_a+0x30 在函数外（长 0x20）
#   ② plt 0x200 → GOT 0x2008、imported_fn；plt 0x100 → 不是 PLT 跳板
#   ③ find fn_ → 只列 fn_a（导入函数值为 0，不算导出）
# 门禁覆盖：tools/nso_sym.py tests/nso_sym_test.sh
set -u
H=$(cd "$(dirname "$0")/.." && pwd)
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}   # 钉版解释器（capstone，与改写器同一份 tools/rewriter-requirements.txt）
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
"$PY" - "$T/syn.nso" << 'EOF'
import struct, sys
img = bytearray(0x3000)
struct.pack_into('<I', img, 4, 0x10)                                  # MOD0 偏移
img[0x10:0x14] = b'MOD0'; struct.pack_into('<i', img, 0x14, 0x1800 - 0x10)   # .dynamic 相对 MOD0
for i, w in enumerate((0xD0000010, 0xF9400611, 0x91002210, 0xD61F0220)):     # PLT 跳板 @0x200 → GOT 0x2008
    struct.pack_into('<I', img, 0x200 + 4 * i, w)
struct.pack_into('<IBBHQQ', img, 0x1000 + 24, 1, 0x12, 0, 1, 0x100, 0x20)   # 符号 1：fn_a
struct.pack_into('<IBBHQQ', img, 0x1000 + 48, 6, 0x12, 0, 0, 0, 0)          # 符号 2：imported_fn（未定义）
img[0x1400:0x1400 + 18] = b'\0fn_a\0imported_fn\0'
struct.pack_into('<II', img, 0x1600, 1, 3)                            # DT_HASH：nbucket 1、nchain 3
struct.pack_into('<QQq', img, 0x1700, 0x2008, (2 << 32) | 1026, 0)    # JUMP_SLOT → 符号 2
for i, (tag, val) in enumerate(((4, 0x1600), (5, 0x1400), (6, 0x1000), (10, 18), (11, 24), (23, 0x1700), (2, 24), (0, 0))):
    struct.pack_into('<qQ', img, 0x1800 + 16 * i, tag, val)
hdr = bytearray(0x100); hdr[:4] = b'NSO0'
for k in range(3):
    struct.pack_into('<III', hdr, 0x10 + 16 * k, 0x100 + 0x1000 * k, 0x1000 * k, 0x1000)
    struct.pack_into('<I', hdr, 0x60 + 4 * k, 0x1000)
open(sys.argv[1], 'wb').write(bytes(hdr) + bytes(img))
EOF
bad=0
check() {   # check <说明> <期望子串> <命令输出>
  if printf '%s' "$3" | grep -q -F -- "$2"; then echo "通 $1"; else echo "  ✗ $1：期望含「$2」，真结果「$3」"; bad=$((bad + 1)); fi
}
N="$PY $H/tools/nso_sym.py"
check "① sym 0x110 在 fn_a 内" $'fn_a+0x10\t内' "$($N sym "$T/syn.nso" 0x110)"
check "① sym 0x130 在 fn_a 外" 'fn_a+0x30	外' "$($N sym "$T/syn.nso" 0x130)"
check "② plt 0x200 → GOT 0x2008 imported_fn" $'GOT 0x2008\timported_fn' "$($N plt "$T/syn.nso" 0x200)"
check "② plt 0x100 不是跳板" '不是 PLT 跳板' "$($N plt "$T/syn.nso" 0x100)"
f=$($N find "$T/syn.nso" fn_)
check "③ find 只列导出函数 fn_a" $'0x100\t0x20\tfn_a' "$f"
[ "$(printf '%s\n' "$f" | grep -c .)" = 1 ] || { echo "  ✗ ③ find 应只 1 行，真结果「${f}」"; bad=$((bad + 1)); }
echo "期望 0 处不符 → 真结果 $bad 处"
[ $bad = 0 ] && echo "nso_sym 单测全过" || { echo "nso_sym 单测有不通"; exit 1; }
