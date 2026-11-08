#!/bin/bash
# NVN 覆盖表对账脚本（graphics/nvn/tools/nvn_cover_status.py）：三种注册形态都要认，四类差异都要判对。
# 门禁覆盖：graphics/nvn/tools/nvn_cover_status.py
set -eu
H=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cat > "$T/hle.c" <<'C'
NVN(nvnAlphaDo, int, int x) { return x; }
NVN_NOPROTO(nvnBetaDo, void, int x) { (void)x; }
static const char *const g_nops[] = {
    "nvnGammaNoop",
};
C
printf '函数\t直连层\tS2Arm\t动森用到\t丝之歌用到\t差异\nnvnAlphaDo\t语义\t已做\t是\t是\t\nnvnBetaDo\t语义\t未做\t是\t是\t\nnvnGammaNoop\t空\t未做\t是\t是\t\nnvnMissingOne\t语义\t未做\t是\t是\t\nnvnGhostDone\t语义\t已做\t是\t是\t\n' > "$T/table.tsv"

out=$(python3 "$H/graphics/nvn/tools/nvn_cover_status.py" --src "$T/hle.c" --table "$T/table.tsv")
fail=0
chk() { case "$out" in *"$1"*) ;; *) echo "🔴 期望出现：$1"; fail=1;; esac; }
chk '表 5 行'
chk '代码侧 3 个名字'          # NVN + NVN_NOPROTO + g_nops，三种形态都认到
chk '表落后（写未做、代码有）：2'   # nvnBetaDo（NOPROTO）/ nvnGammaNoop（名字表）
chk '表虚高（写已做、代码没有）：1' # nvnGhostDone
chk '真实缺口：1'               # nvnMissingOne

# --check：不一致时退出 1
if python3 "$H/graphics/nvn/tools/nvn_cover_status.py" --src "$T/hle.c" --table "$T/table.tsv" --check > /dev/null 2>&1; then
  echo "🔴 --check 在不一致时应退出非 0"; fail=1
fi

# --update：只改 S2Arm 列，改完 --check 应为 0
python3 "$H/graphics/nvn/tools/nvn_cover_status.py" --src "$T/hle.c" --table "$T/table.tsv" --update > /dev/null
col=$(awk -F'\t' '$1=="nvnBetaDo"||$1=="nvnGammaNoop"||$1=="nvnGhostDone"{printf "%s:%s ", $1, $3}' "$T/table.tsv")
[ "$col" = "nvnBetaDo:已做 nvnGammaNoop:已做 nvnGhostDone:未做 " ] || { echo "🔴 --update 结果不符：$col"; fail=1; }
if ! python3 "$H/graphics/nvn/tools/nvn_cover_status.py" --src "$T/hle.c" --table "$T/table.tsv" --check > /dev/null 2>&1; then
  echo "🔴 --update 之后 --check 应通过"; fail=1
fi

[ $fail = 0 ] || exit 1
echo '覆盖表对账：三种注册形态、四类差异、--check / --update → 通过'
