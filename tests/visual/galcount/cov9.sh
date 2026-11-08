#!/bin/bash
# 门禁手动：要私有游戏数据：九款 GAL 录像语料（run/s2arm/replay 等），要传输出目录
# 九款 GAL 录像语料计数（docs/研究/图形接口覆盖盘点.md 的「九款语料」列）：只解析不回放，按调用类型和参数取值计数。
# 用法：bash tests/visual/galcount/cov9.sh <输出目录>   → <输出目录>/<录像名>.tsv 各一份 + cov_matrix.tsv（键 × 九款，全部次数）
# 语料源（只读）：run/s2arm/replay/gal/<款>/*.rec.zst（逐份解压到临时目录、计完即删）+ ~/.s2arm/gate_data/diffrec/*.rec + run/s2arm/visual/recs/*.rec
set -u -o pipefail
O=${1:?输出目录}; S=${S2A_RUN:-${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm}; H=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$O/out" || exit 1
B=$O/build; timeout 300 dotnet build -c Release --artifacts-path "$B" "$H/galcount.csproj" > "$O/build.log" 2>&1 || { echo "【红】galcount 编译失败，见 $O/build.log"; exit 1; }
X=$(ls "$B"/bin/galcount/release*/galcount 2> /dev/null | head -1); [ -x "$X" ] || { echo "【红】找不到 galcount 可执行文件（${B}）"; exit 1; }
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
n=0; red=0; t0=$SECONDS
run() { timeout 280 "$X" "$2" "$O/out/$1.tsv" || { red=1; echo "【红】$1 计数失败（rc=$?）"; }; n=$((n + 1)); }
for z in "$S"/replay/gal/*/*.rec.zst; do
  g=$(basename "$(dirname "$z")"); b=$(basename "$z" .rec.zst)
  zstd -q -d -c "$z" > "$TMP/r.rec" || { red=1; echo "【红】解压失败 $z"; continue; }
  run "replay__${g}__$b" "$TMP/r.rec"; rm -f "$TMP/r.rec"
done
for f in "${S2A_DIFF_RECS:-$HOME/.s2arm/gate_data/diffrec}"/*.rec; do [ -f "$f" ] && run "diffrec__$(basename "$f" .rec)" "$f"; done
for f in "$S"/visual/recs/*.rec; do [ -f "$f" ] && run "visual__$(basename "$f" .rec)" "$f"; done
python3 - "$O" <<'EOF'
import glob, os, re, sys, collections
O = sys.argv[1]; GS = ['acnh', 'mk8d', 'd2r', 'd3', 'botw', 'octopath2', 'silksong', 'witcher3', 'mhrise']
M = collections.defaultdict(collections.Counter); nf = collections.Counter()
for f in sorted(glob.glob(O + '/out/*.tsv')):
    n = os.path.basename(f)[:-4]; g = next((x for x in GS if re.search(r'(^|_)' + x + r'(_|$)', n)), None)
    if g is None: print('不认得款名：', n); continue
    nf[g] += 1
    for line in open(f):
        if line.startswith('#'): continue
        k, a, _ = line.rstrip('\n').split('\t'); M[g][k] += int(a)
keys = sorted(set(k for g in GS for k in M[g]))
with open(O + '/cov_matrix.tsv', 'w') as w:
    w.write('键\t' + '\t'.join(GS) + '\n')
    for k in keys: w.write(k + '\t' + '\t'.join(str(M[g][k]) for g in GS) + '\n')
print('各款录像份数', dict(nf), '键数', len(keys))
EOF
echo "录像 $n 份，$((SECONDS - t0)) 秒$([ $red = 1 ] && echo '，有红')"; exit $red
