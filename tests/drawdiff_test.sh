#!/bin/bash
# tests/visual/drawdiff.py 两遍定性单测（夹具内建，不跑 galplay）：六行比对各落一类，期望汇总行逐类各 1 次。
#   GPU 不定 = 两遍我方、参照哈希都不同（10-23 怪猎村子 51 处：两后端同处同时不定，原先先判我方全记成「不确定·我方」）
#   只我方哈希不同 = 不确定·我方；只参照不同 = 不确定·参照；哈希都同、无差异 = 同；哈希都同、有差异 = 确定分歧；哈希都不同但差异像素 0 = 位级不定
# 用法：bash tests/drawdiff_test.sh [drawdiff.py 路径]（缺省本树；给旧版路径即反证）
set -u
cd "$(dirname "$0")/.." || exit 2
DD=${1:-tests/visual/drawdiff.py}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
H=$'记录\t帧\t类\t通道起\t程序\t槽\t贴图\t格式\t尺寸\t差异像素\t总像素\t最大差\t首个差异像素\t差异框\t我方哈希\t参照哈希\t通道绘制\t反馈环\t丢弃后导数'
row() { printf '%s\t1\t通道\t%s\t7\t0\t%s\tRGBA8\t4x4\t%s\t16\t%s\t0,0\t0,0-1,1\t%s\t%s\t1\t\t\n' "$1" "$1" "$2" "$3" "$4" "$5" "$6"; }
mkdir -p "$T/a" "$T/b"
{ echo "$H"
  row 10 101 5 3 aaaa1111 rrrr1111     # GPU 不定：第 2 遍两边哈希都换
  row 20 102 5 3 bbbb1111 ssss1111     # 不确定·我方：只我方换
  row 30 103 5 3 cccc1111 tttt1111     # 不确定·参照：只参照换
  row 40 104 0 0 dddd1111 uuuu1111     # 同
  row 50 105 7 2 eeee1111 vvvv1111     # 确定分歧
  row 60 106 0 0 ffff1111 wwww1111     # 位级不定：两边都换但差异 0
} > "$T/a/diff.tsv"
{ echo "$H"
  row 10 101 9 3 aaaa2222 rrrr2222
  row 20 102 9 3 bbbb2222 ssss1111
  row 30 103 5 3 cccc1111 tttt2222
  row 40 104 0 0 dddd1111 uuuu1111
  row 50 105 7 2 eeee1111 vvvv1111
  row 60 106 0 0 ffff2222 wwww2222
} > "$T/b/diff.tsv"
out=$(python3 "$DD" "$T/a" "$T/b" 2>&1); rc=$?
head=$(printf '%s\n' "$out" | head -1)
bad=0
for want in '同 1、' '确定分歧 1、' '不确定·我方 1、' '不确定·参照 1、' 'GPU 不定 1（' '「位级不定」1）'; do
  case $head in *"$want"*) ;; *) echo "✗ 汇总行缺「${want}」"; bad=$((bad + 1));; esac
done
printf '%s\n' "$out" | grep -q '  GPU 不定 记录 10 ' || { echo "✗ 明细里没列出记录 10 的 GPU 不定"; bad=$((bad + 1)); }
printf '%s\n' "$out" | grep -q '  不确定·我方 记录 20 ' || { echo "✗ 明细里没列出记录 20 的不确定·我方"; bad=$((bad + 1)); }
if [ $bad = 0 ]; then echo "✓ drawdiff 两遍定性单测全过（6 类各 1，rc=${rc}）"; exit 0; fi
echo "✗ drawdiff 两遍定性单测 $bad 处不符；实得：$head"; exit 1
