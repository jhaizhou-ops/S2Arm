#!/bin/bash
# 改写器回归语料单测（#149 / #58 H04，合成 NSO、不用游戏文件，约 1 分钟）：bash tests/rewrite_corpus_test.sh
# 门禁覆盖：runtime/rewriter/* tests/rewrite_corpus/*
# 语料在 tests/rewrite_corpus/cases.py（20 种跳转表 / 改写窗口形态，每例旁写手算期望），执行器 tests/rewrite_corpus/run.py（clang 汇编 → 合成 NSO → 苹果 / 安卓各改写一遍 → 比落点集合）。
#   ① 工作树改写器：没有「不通」；标了 known 的形态还是缺口时记「已知缺口」不判红，修好了记「已知缺口已修」（提示去掉 known 标记）
# REW=<改写器> 可换被测改写器；STRICT=1 时 ① 也不放过已知缺口（在修复分支上用）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
PY=${PY:-${S2A_PY:-$HOME/.s2arm/venv/bin/python3}}   # 改写器钉死的解释器（tools/rewriter-requirements.txt）
REW=${REW:-$(python3 "$H/pack/rewriter.py" c-path 2>/dev/null | tail -1)}; [ -x "$REW" ] || { echo "🔴 取不到 C 改写器（python3 pack/rewriter.py c-path）"; exit 1; }
PY=$PY "$PY" "$H/tests/rewrite_corpus/run.py" "$REW" > "$T/cur.log" 2>&1; r1=$?
grep -E '^(不通|已知缺口|已知缺口已修) ' "$T/cur.log" | sed 's/：.*//; s/^/  /'
s1=$(tail -1 "$T/cur.log")
ck "① 工作树改写器：${s1}" '[ "$r1" = 0 ] && [[ $s1 == rewrite_corpus：* ]]'
[ $bad = 0 ] && echo "✅ 改写器回归语料全通" || { echo "🔴 改写器回归语料有不通项（明细：bash tests/rewrite_corpus_test.sh 或直接跑 tests/rewrite_corpus/run.py）"; tail -40 "$T/cur.log"; exit 1; }
