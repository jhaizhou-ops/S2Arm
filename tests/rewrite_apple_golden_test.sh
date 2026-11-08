#!/bin/bash
# 九款真实 NSO 苹果改写 golden：出包实际 C 命令行对 golden 表（10-31 删 Python 改写器前两路都对同一表，表值当时两边一致）。
# 门禁覆盖：runtime/rewriter/* pack/rewriter.py tests/fixtures/rewrite_apple_golden_inputs.tsv
# golden 表 tests/fixtures/rewrite_apple_golden.tsv 随代码走列车：改写器若有意改苹果产物，在同一提交里更新表，
#   列车审 diff 一眼看到「苹果产物变了几款」（门禁数据随代码走列车）。改了改写器又没更新表 → 本测红、不绿不合。
# 九款 NSO 不进仓库（约 330 MB、只在 mini / 本机常驻）：读 $HOME/.s2arm/data/<款>/exefs/main——
#   本机 GATE_HOST=local 是真路径；mini 门禁经 tools/remote.sh --sync @gate 同步到假家目录同相对路径（两边一份写法）。
#   文件不在就报一行判红、不静默跳过（否则门禁绿着失效）。
# 输入身份（10-31 总指挥 #1092：金样第二、三列是改写产物摘要，别人拿自己的 main 对表对不上）：tests/fixtures/rewrite_apple_golden_inputs.tsv
#   存每款输入 main 的 SHA-256、字节数、NSO 构建号；读到的输入和表不符先报「输入不是金样版本」（判红，写明是构建号不同还是只差字节），再比产物
set -u
H=$(cd "$(dirname "$0")/.." && pwd)
GOLDEN=$H/tests/fixtures/rewrite_apple_golden.tsv
INPUTS=$H/tests/fixtures/rewrite_apple_golden_inputs.tsv
EXTRA_REW=${REW:-}   # REW 仍可追加候选实现做反证，不能替代必跑的出包 C 一路
PY=${S2A_PY:-$HOME/.s2arm/venv/bin/python3}   # 钉版解释器（tools/rewriter-requirements.txt）
NSO_DIR=${S2A_REWRITE_GOLDEN_DIR:-$HOME/.s2arm/data}
[ -f "$GOLDEN" ] || { echo "🔴 golden 表缺 $GOLDEN"; exit 1; }
[ -f "$INPUTS" ] || { echo "🔴 金样输入身份表缺 $INPUTS"; exit 1; }
C_REW=$("$PY" "$H/pack/rewriter.py" c-path 2>/dev/null | tail -1); [ -x "$C_REW" ] || { echo "🔴 不能取得出包 C 改写器，九款金样失败"; exit 1; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
bad=0; same_c=0
unset S2A_TARGET
input_check() {   # input_check <款> <NSO>：输入与金样输入身份表一致 → 0；不一致打一行「输入不是金样版本」→ 1
  local g=$1 nso=$2 row sha sz bid gsha gsz gbid
  row=$(awk -F'\t' -v g="$g" '$1 == g { print; exit }' "$INPUTS")
  [ -n "$row" ] || { echo "🔴 $g 输入不是金样版本：输入身份表里没有这一款（${INPUTS}）"; return 1; }
  IFS=$'\t' read -r _ sha sz bid <<< "$row"
  gsha=$(shasum -a 256 "$nso" | cut -d' ' -f1); gsz=$(wc -c < "$nso" | tr -d ' '); gbid=$(xxd -s 0x40 -l 32 -p "$nso" | tr -d '\n')
  [ "$gsha" = "$sha" ] && return 0
  if [ "$gbid" != "$bid" ]; then echo "🔴 $g 输入不是金样版本：NSO 构建号不同（金样 ${bid:0:40}… 实 ${gbid:0:40}…），游戏版本不同，这一款金样不适用"
  else echo "🔴 $g 输入不是金样版本：构建号相同、字节不同（金样 ${sz} 字节 ${sha:0:12}…，实 ${gsz} 字节 ${gsha:0:12}…），多半是 NSO 压缩状态不同，用仓库 nx_unpack 从原始游戏包重解 exefs/main"; fi
  return 1
}
golden_run() {
  local label=$1 rew=$2 g=$3 bexp=$4 fexp=$5 nso=$6 o bgot fgot
  o=$T/$label/$g; mkdir -p "$o"
  if ! "$PY" "$H/tests/rewriter_exec.py" "$rew" "$nso" "$o" main > "$o.log" 2>&1; then
    echo "🔴 $label $g 改写失败（见 $o.log）"; return 1
  fi
  bgot=$(shasum -a 256 "$o/main.patched.bin" | cut -d' ' -f1)
  fgot=$(shasum -a 256 "$o/main.fixups.tsv" | cut -d' ' -f1)
  if [ "$bgot" = "$bexp" ] && [ "$fgot" = "$fexp" ]; then echo "✓ $label $g"; return 0; fi
  echo "🔴 $label $g 苹果产物变了：patched.bin $([ "$bgot" = "$bexp" ] && echo 同 || echo "异(golden ${bexp:0:12}… 实 ${bgot:0:12}…)") / fixups $([ "$fgot" = "$fexp" ] && echo 同 || echo 异)"
  return 1
}
while IFS=$'\t' read -r g bexp fexp; do
  [ -n "$g" ] || continue
  NSO=$NSO_DIR/$g/exefs/main
  if [ ! -f "$NSO" ]; then echo "🔴 缺 $g 的 exefs/main（${NSO}）"; bad=1; continue; fi
  input_check "$g" "$NSO" || bad=1
  if golden_run C "$C_REW" "$g" "$bexp" "$fexp" "$NSO"; then same_c=$((same_c + 1)); else bad=1; fi
  if [ -n "$EXTRA_REW" ] && [ ! "$EXTRA_REW" -ef "$C_REW" ]; then
    golden_run REW "$EXTRA_REW" "$g" "$bexp" "$fexp" "$NSO" || bad=1
  fi
done < "$GOLDEN"
n=$(LC_ALL=C /usr/bin/grep -cE '.' "$GOLDEN")
echo "=== golden 对拍：C $same_c / $n 同 ==="
if [ $bad = 0 ] && [ "$same_c" = "$n" ]; then echo "✅ 九款 C 苹果产物与 golden 全同"; else
  echo "🔴 苹果产物与 golden 不符：有意改了就在同一提交更新 tests/fixtures/rewrite_apple_golden.tsv，没动改写器却红就是回归"; exit 1
fi
