#!/bin/bash
# 远端资源包缓存回收单测（tools/packs_evict.sh，临时目录，约 1 秒）：bash tests/packs_evict_test.sh
#   可用量注入：S2A_PACKS_FREE_CMD = 100 − 10 × 包目录数（每删一款回 10 GB），期望值按这个手算
set -u; R=$(cd "$(dirname "$0")/.." && pwd); E=$R/tools/packs_evict.sh; T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0; ck() { if eval "$2"; then echo "  ✓ $1"; else echo "  ✗ $1"; fails=$((fails + 1)); fi; }
export S2A_PACKS_FREE_CMD="echo \$(( 100 - 10 * \$(ls -d $T/packs/*/ 2> /dev/null | wc -l) ))" S2A_PACKS_FLOOR_GB=40
mk() { rm -rf "$T/packs" "$T/jobs"; mkdir -p "$T/packs" "$T/jobs"; local s=1000000000
  for g in "$@"; do mkdir -p "$T/packs/$g"; echo x > "$T/packs/$g/manifest.json"; touch -t "$(date -r $s +%Y%m%d%H%M.%S)" "$T/packs/.used_$g"; s=$((s + 100)); done; }
left() { ls "$T/packs" | LC_ALL=C sort -f | tr '\n' ' '; }

# ① 五款（a 最旧 … G 最新；可用 50），这份 30 GB、余量线 40 → 要可用 ≥ 70 → 留 3 款；b 被作业引用跳过 → 删 a、c，留 b d G
mk a b c d G; mkdir -p "$T/jobs/j1"; ln -s "$T/packs/b" "$T/jobs/j1/pack"
o=$(bash "$E" "$T/packs" G 30)
ck "① 按最久未用删 a、c，作业引用的 b 与这次的 G 不删（实得：$(left)）" '[ "$(left)" = "b d G " ]'
ck "① 打清理读数（实得：${o}）" '[[ "$o" == *"清掉 a c"*"50 → 70"* ]]'
ck "① 删掉的款 .used 标记也清掉" '[ ! -e "$T/packs/.used_a" ] && [ ! -e "$T/packs/.used_c" ] && [ -e "$T/packs/.used_d" ]'

# ② 余量够（两款，可用 80，这份 30）→ 一款不删、不出声
mk a G; o=$(bash "$E" "$T/packs" G 30)
ck "② 余量够：不删（实得：$(left)，输出「${o}」）" '[ "$(left)" = "a G " ] && [ -z "$o" ]'

# ③ 这次的款最旧也不删；别的全删完仍不够 → 报黄、退出 0（推包照走，由 rsync 自己报盘满）
mk G a b c d e f; o=$(bash "$E" "$T/packs" G 80); rc=$?
ck "③ 只剩 G（实得：$(left)）" '[ "$(left)" = "G " ]'
ck "③ 不够余量线报黄、退出 0（rc=${rc}）" '[ $rc = 0 ] && [[ "$o" == *"【黄】"* ]]'

# ④ 没有 .used 标记的旧款（本修复前推的）按目录时间排：a 目录时间 2000 年、b 标记 2001 年 → 先删 a；
#   三款可用 70，这份 20、余量线 60 → 删一款（80 − 20 = 60）即停
mk b G; mkdir -p "$T/packs/a"; touch -t 200001010000 "$T/packs/a"; export S2A_PACKS_FLOOR_GB=60
o=$(bash "$E" "$T/packs" G 20)
ck "④ 无标记旧款按目录时间先回收，够了即停（实得：$(left)）" '[ "$(left)" = "b G " ]'

# ⑥ 上次被掐断留下的残骸 .del_x.<pid>（#799）→ 开头清掉、不算包；被删的款先改名再删，不留半截的同名目录
mk a G; mkdir -p "$T/packs/.del_x.123/sub"; echo y > "$T/packs/.del_x.123/sub/f"; export S2A_PACKS_FLOOR_GB=40
o=$(bash "$E" "$T/packs" G 50)
ck "⑥ 残骸 .del_* 清掉、a 被删且没有半截目录（实得：$(ls -a $T/packs | tr '\n' ' ')）" '[ ! -e "$T/packs/.del_x.123" ] && [ ! -e "$T/packs/a" ] && ! ls -a "$T/packs" | grep -q "^\.del_"'

# ⑤ packs 目录不存在（首次推包前）→ 静默退出 0
bash "$E" "$T/nope" G 10 > /dev/null; ck "⑤ 目录不存在退出 0" '[ $? = 0 ]'

[ $fails = 0 ] && echo "✓ packs_evict_test 全过" || { echo "✗ packs_evict_test $fails 项失败"; exit 1; }
