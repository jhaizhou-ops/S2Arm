#!/bin/bash
# 宽屏表超一个模块 1008 行上限（runtime/rewriter/rewriter.c widen；11-05 普查女神异闻录5R 自动宽屏表 2892 行，改写失败、整款出不了包）：bash tests/rewrite_widen_cap_test.sh（约 2 秒）
# 门禁覆盖：runtime/rewriter/rewriter.c
# 合成 NSO 同 tests/fps_rewrite_test.sh。期望（按规则手写）：
#   ① 宽屏表 1009 行（全是 main 模块的 f32 数据点）→ 改写退出 0、日志一行【红】「宽屏表 1009 行，超过…1008…不打宽屏补丁」、不产出 main.widen.tsv、patched.bin 照常产出
#   ② 宽屏表 1 行 f32 → 改写退出 0、产出 main.widen.tsv（数据点照常记）、日志没有那行红
#   ③ 1008 行（恰在上限）→ 照常记、产出 main.widen.tsv
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}; [ -x "$PY" ] || PY=python3
REW=${REW:-$(python3 "$H/pack/rewriter.py" c-path 2>/dev/null | tail -1)}; [ -x "$REW" ] || { echo "不通 取不到 C 改写器（python3 pack/rewriter.py c-path）"; exit 1; }
mkdir -p "$T/exefs" "$T/c"
$PY - "$T/exefs/main" <<'EOF'
import struct, sys
code = [0x3942f661, 0x1e221862, 0x1e210841, 0x94000002, 0xd65f03c0, 0xd65f03c0]
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
row() { for i in $(seq 1 "$1"); do printf 'main\t0x%x\tf32\n' $((0x1000 + 4 * i)); done; }
run() { rm -rf "$T/c$1"; mkdir -p "$T/c$1"; row "$1" > "$T/w$1.tsv"; "$REW" "$T/exefs/main" "$T/c$1" main "$T/w$1.tsv" > "$T/c$1.log" 2>&1; echo $?; }
r=$(run 1009); ck "① 1009 行：退出 0（${r}）、红行点名上限、无 widen.tsv、有 patched.bin" '[ "$r" = 0 ] && grep -q "宽屏表 1009 行，超过一个模块 1008 行的上限" "$T/c1009.log" && [ ! -e "$T/c1009/main.widen.tsv" ] && [ -s "$T/c1009/main.patched.bin" ]'
r=$(run 1); ck "② 1 行：退出 0（${r}）、有 widen.tsv、无上限红行" '[ "$r" = 0 ] && [ -s "$T/c1/main.widen.tsv" ] && ! grep -q "行的上限" "$T/c1.log"'
r=$(run 1008); ck "③ 1008 行：退出 0（${r}）、有 widen.tsv" '[ "$r" = 0 ] && [ -s "$T/c1008/main.widen.tsv" ] && ! grep -q "行的上限" "$T/c1008.log"'
[ $bad = 0 ] && echo "rewrite_widen_cap 单测全过" || { echo "rewrite_widen_cap 单测有不通"; exit 1; }
