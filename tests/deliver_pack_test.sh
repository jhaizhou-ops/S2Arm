#!/bin/bash
# 一键出包交付资源包单测（pack/oneclick/deliver_pack.py，约 1 秒）：bash tests/deliver_pack_test.sh
# 期望（按资源包目录约定手写：index.tsv 列的文件 + index.tsv + manifest.json）：
#   ① 目标不存在 → 整份：克隆 3 个、删 0、目标文件逐字节等于源、带清单
#   ② 源只改了 a.bin、删了 sub/c.bin、新增 d.bin → 增量：克隆 2 个（a、d）、删 1 个，没变的 b.bin 不重做（inode 不变），sub/ 删空后目录也没了，内容逐字节等于源
#   ③ 目标里没变的文件被截短（大小对不上）→ 照样重克隆（克隆 1 个），不信旧索引
#   ④ 目标缺 manifest.json（上次中途失败）→ 整份重做
#   ⑤ 源没有 manifest.json（资源包不完整）→ 退出非 0
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0; trap 'rm -rf "$T"' EXIT
PY=${S2A_PY:-python3}
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
mk() {   # mk <目录> <文件:内容>…：写文件、index.tsv（路径 字节数 SHA-256）与 manifest.json
  local d=$1 kv p; shift; rm -rf "$d"; mkdir -p "$d"
  for kv in "$@"; do p=${kv%%:*}; mkdir -p "$d/$(dirname "$p")"; printf '%s' "${kv#*:}" > "$d/$p"; done
  for kv in "$@"; do p=${kv%%:*}; printf '%s\t%s\t%s\n' "$p" "$(wc -c < "$d/$p" | tr -d ' ')" "$(shasum -a 256 "$d/$p" | cut -c1-64)"; done > "$d/index.tsv"
  echo '{"version":2}' > "$d/manifest.json"; }
same() { diff -r "$1" "$2" > /dev/null; }
DP() { "$PY" "$H/pack/oneclick/deliver_pack.py" "$@"; }
mk $T/s a.bin:AAA b.bin:BBBB sub/c.bin:CC
o1=$(DP $T/s $T/d); r1=$?
ck "① 整份：rc=${r1}、输出「${o1}」" '[ $r1 = 0 ] && [ "$(cut -f3,4,5 <<< "$o1")" = "3	0	整份" ] && same $T/s $T/d'
ib=$(stat -f %i $T/d/b.bin 2> /dev/null || stat -c %i $T/d/b.bin)
mk $T/s a.bin:AAAX b.bin:BBBB d.bin:DDDDD
o2=$(DP $T/s $T/d); r2=$?; ib2=$(stat -f %i $T/d/b.bin 2> /dev/null || stat -c %i $T/d/b.bin)
ck "② 增量：rc=${r2}、输出「${o2}」、b.bin inode ${ib} → ${ib2}、sub/ $([ -e $T/d/sub ] && echo 还在 || echo 没了)" \
  '[ $r2 = 0 ] && [ "$(cut -f1,3,4,5 <<< "$o2")" = "3	2	1	增量" ] && [ "$ib" = "$ib2" ] && [ ! -e $T/d/sub ] && same $T/s $T/d'
printf 'B' > $T/d/b.bin; o3=$(DP $T/s $T/d); r3=$?
ck "③ 目标文件被截短：rc=${r3}、输出「${o3}」" '[ $r3 = 0 ] && [ "$(cut -f3,5 <<< "$o3")" = "1	增量" ] && same $T/s $T/d'
rm $T/d/manifest.json; o4=$(DP $T/s $T/d); r4=$?
ck "④ 目标缺清单 → 整份：rc=${r4}、输出「${o4}」" '[ $r4 = 0 ] && [ "$(cut -f3,5 <<< "$o4")" = "3	整份" ] && same $T/s $T/d'
rm $T/s/manifest.json; DP $T/s $T/d > /dev/null 2>&1; r5=$?
ck "⑤ 源不完整 → 退出非 0：rc=${r5}" '[ $r5 != 0 ]'
[ $bad = 0 ] && echo "deliver_pack 单测全过" || { echo "deliver_pack 单测有不通"; exit 1; }
