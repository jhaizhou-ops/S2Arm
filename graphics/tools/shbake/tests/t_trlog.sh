#!/bin/bash
# 翻译告警分类计数单测 + 棘轮（graphics/tools/shbake/TrLogSelfTest.cs，期望值手算）：编 shbake 到仓外目录后跑 selftest-trlog，再拿端到端烘焙出的 translator_log.tsv 对基线：
#   基线 tests/trlog_baseline.tsv（种类<TAB>次数上限）：每种次数 ≤ 上限、不许出现基线外的种类（只减不增；减了同笔改小基线）。退出 0 = 全过
#   样本：仓库里没有真实着色器（游戏抽出集是私有数据），端到端样本是 TrLogSelfTest 手拼的 1 个程序（1 条 Invalid + 1 条 Bpt stub）。
#   给真实烘焙产物对基线：T_TRLOG_TSV=<输出根>/translator_log.tsv T_TRLOG_BASE=<基线> bash t_trlog.sh（不跑单测，只做棘轮）
#   T_TRLOG_BAKE=<另一份 S2A.ShBake>：用它出端到端产物（反证：给旧版应红）
set -u
R=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)
BASE=${T_TRLOG_BASE:-$R/graphics/tools/shbake/tests/trlog_baseline.tsv}
ratchet() {   # $1 = translator_log.tsv
  awk -F'\t' -v base="$BASE" 'BEGIN { while ((getline l < base) > 0) { if (l ~ /^#/ || l == "") continue; split(l, f, "\t"); lim[f[1]] = f[2]; nb++ } }
    /^#/ { next } { n++; tot += $2; if (!($1 in lim)) { bad++; print "  新种类 " $1 " ×" $2 "（首键 " $3 "）" } else if ($2 + 0 > lim[$1] + 0) { bad++; print "  超基线 " $1 "：" $2 " > " lim[$1] } }
    END { printf "翻译告警棘轮：%d 种 %d 条（基线 %d 种），超出 %d → %s\n", n, tot, nb, bad, bad ? "红" : "绿"; exit bad ? 1 : 0 }' "$1"
}
if [ -n "${T_TRLOG_TSV:-}" ]; then [ -f "$T_TRLOG_TSV" ] || { echo "没有 $T_TRLOG_TSV → 红"; exit 1; }; ratchet "$T_TRLOG_TSV"; exit $?; fi
O=${T_VTG_OUT:-$R/build/t_vtg}; mkdir -p "$O"
dotnet build -c Release "$R/graphics/tools/shbake/S2A.ShBake.csproj" --artifacts-path "$O/art" -p:OutDir="$O/bin/" > "$O/build.log" 2>&1 || { echo "编 S2A.ShBake 失败（$O/build.log）"; tail -5 "$O/build.log"; exit 1; }
W="$O/trlog"; rm -rf "$W"; mkdir -p "$W"
timeout 200 "$O/bin/S2A.ShBake" selftest-trlog "$W" ${T_TRLOG_BAKE:+"$T_TRLOG_BAKE"}; rc=$?
if [ -f "$W/o/translator_log.tsv" ]; then ratchet "$W/o/translator_log.tsv"; r2=$?; else echo "翻译告警棘轮：没有端到端产物 → 红"; r2=1; fi
rm -rf "$W"
echo "t_trlog：单测退出 ${rc}、棘轮退出 ${r2}（期望 0 / 0）"
[ $rc = 0 ] && [ $r2 = 0 ]
