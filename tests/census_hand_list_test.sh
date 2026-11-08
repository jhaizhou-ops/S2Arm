#!/bin/bash
# 待手测总清单单测（tools/census/hand_test_list.py，11-04）：bash tests/census_hand_list_test.sh，约 3 秒
# 夹具：临时普查目录里两批总表（c1101a 日期 11-01、c1102b 日期 11-02）+ 手测结果.tsv，host.log 只给 E 一份；期望都手写：
#   ① 后一批进局 → 移出（A：前批通过没进局、后批进局）；同日两批按总表修改时间取新（H：同日、后改的那批进局 → 移出）
#   ② 新出现的通过没进局 → 加入（E）；一次成功 = 待手测 → 加入（F）；只在前批、没后续 → 留着（D）
#   ③ 失败款不进（B）；前批进局、后批失败也不进（G）
#   ④ 手测已判 是 / 否 不进（M1 / M2）；手测备注「待多手柄」照进、状态写待多手柄（M3）
#   排序：局时用完族排后（E 源GB 最大也排最后），族内源GB 大的在前 → D F M3 E；表头 11 列照旧；不留 .new
#   ⑤ 批次类型（11-04 总指挥）：c1101a 主批（.census_batch type=）、c1102b 复判（批次类型.tsv 补登）照算；
#     c1103e 实验批（最新、日期最晚）里 D 进局了、K 通过没进局 → 都不算（D 留着、K 不进）；c1103u 没类型 → 一行【红】、U 不进
#   ⑥ 起批（tools/census/census.sh，沙箱仓库 + 临时 HOME）：不给 --type → 退出 2、红「起批要写批次类型」、不建批次目录；
#     --type 乱写 → 退出 2、红「不认得的批次类型」；--type 实验 → .census_batch 写成 type=实验（之后照常因没给 --src 退出）
#   负对照：把「取最新一行」改成取最早一行 → A、H 回到清单；去掉类型过滤 → D 被实验批移出、K 进来；缺类型默认算主批 → U 进来；
#     起批去掉 batch_type 段 → 不给 --type 也起批、写出 type= 空 → 各自同一判据判不通
#   ⑦ 暂缓由规则算（在跑批没判的、带存档跑的），见下
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(cd "$(mktemp -d)" && pwd -P); bad=0   # 物理路径：census.sh 要求批次目录在 HOME 下（按 pwd -P 比）
trap 'rm -rf "$T"' EXIT
C=$T/census; mkdir -p "$C/c1101a" "$C/c1102b" "$C/c1103e" "$C/c1103u" "$C/c1102b/work/0100EEEE00000000/r/logs/0100EEEE00000000"
echo type=主批 > "$C/c1101a/.census_batch"; echo type=实验 > "$C/c1103e/.census_batch"; : > "$C/c1103u/.census_batch"
printf '批次\t类型\t依据\nc1102b\t复判\t单测\n' > "$C/批次类型.tsv"
HD='键	名称	结论	进局	日期	源GB	一次成功'
r() { printf '0100%s00000000\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "${7:-}"; }
{ echo "$HD"
  r AAAA 甲 通过 否 2026-11-01 8; r BBBB 乙 失败 否 2026-11-01 9; r DDDD 丁 通过 否 2026-11-01 20
  r GGGG 庚 通过 是 2026-11-01 3; r HHHH 辛 通过 否 2026-11-02 7
  r 0M01 判是 通过 否 2026-11-01 6; r 0M02 判否 通过 否 2026-11-01 6; r 0M03 多手柄 通过 否 2026-11-01 5
} > "$C/c1101a/总表.tsv"
{ echo "$HD"
  r AAAA 甲 通过 是 2026-11-02 8; r EEEE 戊 通过 否 2026-11-02 30; r FFFF 己 通过 是 2026-11-02 10 待手测
  r GGGG 庚 失败 否 2026-11-02 3; r HHHH 辛 通过 是 2026-11-02 7
} > "$C/c1102b/总表.tsv"
{ echo "$HD"; r DDDD 丁 通过 是 2026-11-03 20; r KKKK 癸 通过 否 2026-11-03 40; } > "$C/c1103e/总表.tsv"
{ echo "$HD"; r UUUU 子 通过 否 2026-11-03 50; } > "$C/c1103u/总表.tsv"
touch -t 202611010000 "$C/c1101a/总表.tsv"; touch -t 202611020000 "$C/c1102b/总表.tsv"; touch -t 202611030000 "$C/c1103e/总表.tsv" "$C/c1103u/总表.tsv"
printf '键\t手测\n01000M0100000000\t是\n01000M0200000000\t否\n01000M0300000000\t待多手柄\n' > "$C/手测结果.tsv"
printf '自动玩家结论：没到 MARK；导航卡住（离收局只剩 32 秒，不再问驾驶员）；按键 87 下\n' > "$C/c1102b/work/0100EEEE00000000/r/logs/0100EEEE00000000/host.log"
WANT='0100DDDD00000000 0100FFFF00000000 01000M0300000000 0100EEEE00000000'
HEADW='程序号	款名	最近判定批	日期	驾驶员没进局原因族	族内款数	手测备注	源GB	host.log	优先级	状态'
judge() {   # $1 = 被测脚本；打一行读数，判据全中返回 0
  local o=$T/out.tsv; rm -f "$o"
  CENSUS_ACTIVE= CENSUS_HDD_GLOB=$T/nohdd python3 "$1" "$o" --census "$C" > "$T/stdout" 2>&1 || { echo "跑不起来：$(tail -1 "$T/stdout")"; return 2; }
  got=$(tail -n +2 "$o" | cut -f1 | tr '\n' ' ' | sed 's/ $//'); st=$(awk -F'\t' '$1 == "01000M0300000000" {print $11}' "$o")
  fe=$(awk -F'\t' '$1 == "0100EEEE00000000" {print $5}' "$o"); first=$(head -1 "$T/stdout"); red=$(grep '^【红】' "$T/stdout" | tr '\n' ' ')
  echo "清单「${got}」、M3 状态「${st}」、E 族「${fe}」、首行「${first}」、红行「${red}」"
  [ "$got" = "$WANT" ] && [ "$(head -1 "$o")" = "$HEADW" ] && [ "$st" = 待多手柄 ] && [ "$fe" = '导航卡住（局时用完（离收局几十秒还在菜单））' ] \
    && [ "$first" = '待手测 4 款' ] && [ ! -e "$o.new" ] && [ "$(grep -c '^【红】' "$T/stdout")" = 1 ] && grep -q '^【红】批次 c1103u 读不到类型' "$T/stdout"
}
ck() { if [ "$2" = "$3" ]; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
m=$(judge "$H/tools/census/hand_test_list.py"); rc=$?
ck "四条口径 + 批次类型 + 排序（期望 ${WANT}、红行只有 c1103u）：$m" 0 $rc
M=$T/mut.py; sed 's/out\[k\] = rs\[-1\]/out[k] = rs[0]/' "$H/tools/census/hand_test_list.py" > "$M"
grep -q 'out\[k\] = rs\[0\]' "$M" || { echo "不通 负对照没改到「取最新一行」那句"; bad=1; }
m=$(judge "$M"); rc=$?
ck "负对照（取最早一行）判不通：$m" 1 $rc
mut() {   # mut <标签> <sed 式> <改后应出现的串>
  sed "$2" "$H/tools/census/hand_test_list.py" > "$M"; grep -qF "$3" "$M" || { echo "不通 负对照没改到（$1）"; bad=1; return; }
  m=$(judge "$M"); rc=$?; ck "负对照（${1}）判不通：$m" 1 $rc; }
mut 去掉类型过滤 's/        if t not in OK_TYPES: continue/        pass/' '        pass'
mut 缺类型默认算主批 "s/continue   # 缺类型不算进/t = '主批'/" "t = '主批'"
# ⑥ 起批类型：沙箱仓库只放 census.sh 起批前段用到的文件；HOME / 运行区指临时目录，不给 --src、不设索引表 → 过了类型检查后在「没给 --src」处退出 2
SB=$T/repo; mkdir -p "$SB/tools/census" "$T/home" "$T/run"; cp "$H/tools/_timeout.sh" "$H/tools/data_vol_check.sh" "$SB/tools/"; cp -R "$H/tools/bin" "$SB/tools/"
start() {   # start <census.sh> <批次名> [参数…]：打「退出码|首行|.census_batch 内容」
  local cs=$1 b=$T/home/$2; shift 2
  out=$(env -u S2A_LIBRARY_INDEX HOME=$T/home S2A_RUN_ROOT=$T/run CENSUS_OWN_SESSION=1 bash "$cs" "$b" "$@" 2>&1); rc=$?
  echo "${rc}|$(echo "$out" | head -1 | cut -c1-40)|$(cat "$b/.census_batch" 2> /dev/null || echo 无批次标记)"; }
cp "$H/tools/census/census.sh" "$SB/tools/census/census.sh"
s1=$(start "$SB/tools/census/census.sh" b1); s2=$(start "$SB/tools/census/census.sh" b2 --type 乱写); s3=$(start "$SB/tools/census/census.sh" b3 --type 实验)
ok1() { case $1 in "2|🔴【红】起批要写批次类型"*"|无批次标记") [ ! -e "$T/home/$2" ];; *) false;; esac; }
ck "⑥ 不给 --type：「${s1}」（期望 2、红、无批次目录）" 0 "$(ok1 "$s1" b1; echo $?)"
ck "⑥ --type 乱写：「${s2}」（期望 2、红「不认得的批次类型」）" 0 "$(case $s2 in "2|🔴【红】不认得的批次类型"*"|无批次标记") echo 0;; *) echo 1;; esac)"
ck "⑥ --type 实验：「${s3}」（期望 .census_batch = type=实验）" 0 "$(case $s3 in *"|type=实验") echo 0;; *) echo 1;; esac)"
sed '/^# >>> batch_type/,/^# <<< batch_type/d' "$H/tools/census/census.sh" > "$SB/tools/census/census.sh"
grep -q '>>> batch_type' "$SB/tools/census/census.sh" && { echo "不通 负对照没删掉 batch_type 段"; bad=1; }
s4=$(start "$SB/tools/census/census.sh" b4)
ck "负对照（起批去掉 batch_type 段）判不通：「${s4}」" 1 "$(ok1 "$s4" b4; echo $?)"
# ⑦ 暂缓由规则算（11-04 总指挥：自动刷新把手写的「暂缓」冲掉了）：同一夹具复制一份，c1102b 当在跑（CENSUS_ACTIVE=c1102b）、
#   队列 queue.tsv 有 D、总表没 D → D「暂缓：c1102b 还没判」；F 最新一行那局 host.log 有「S2A 带存档起局：account ← …」→ F「暂缓：上次带存档跑，待不带存档复判」；
#   期望（手写）：顺序 M3 E D F（暂缓排最后，暂缓内按源GB D 20 > F 10），优先级 1 2 - -，状态 待多手柄 待 暂缓… 暂缓…，首行「待手测 4 款」
C7=$T/c7; cp -Rp "$C" "$C7"; printf '键\t名称\n0100DDDD00000000\t丁\n0100AAAA00000000\t甲\n' > "$C7/c1102b/queue.tsv"
mkdir -p "$C7/c1102b/work/0100FFFF00000000/r/logs/0100FFFF00000000"
printf 'S2A 带存档起局：account ← /x/saves/t0100ffff00000000_y@community/account（2 个文件，10 字节）\n' > "$C7/c1102b/work/0100FFFF00000000/r/logs/0100FFFF00000000/host.log"
hold7() { local o=$T/out7.tsv; CENSUS_ACTIVE=c1102b CENSUS_HDD_GLOB=$T/nohdd python3 "$1" "$o" --census "$C7" > "$T/stdout7" 2>&1 || { echo 跑不起来; return; }
  echo "$(tail -n +2 "$o" | awk -F'\t' '{printf "%s:%s:%s;", substr($1,5,4), $10, $11}')|$(head -1 "$T/stdout7")"; }
W7='0M03:1:待多手柄;EEEE:2:待;DDDD:-:暂缓：c1102b 还没判;FFFF:-:暂缓：上次带存档跑，待不带存档复判;|待手测 4 款'
ck "⑦ 暂缓按规则算：「$(hold7 "$H/tools/census/hand_test_list.py")」" "$W7" "$(hold7 "$H/tools/census/hand_test_list.py")"
sed 's/    if os.environ.get(.CENSUS_ACTIVE.) is not None: return {b for b in os.environ\[.CENSUS_ACTIVE.\].split(.,.) if b}/    return set()/' "$H/tools/census/hand_test_list.py" > "$M"
grep -q '^    return set()$' "$M" || { echo "不通 负对照没改到在跑批判定"; bad=1; }
ck "⑦ 负对照（不认在跑批）判不通：「$(hold7 "$M")」" 1 "$([ "$(hold7 "$M")" = "$W7" ] && echo 0 || echo 1)"
sed 's/        return any(re.match(r.S2A 带存档起局：(account|device) ., l) for l in fh)/        return False/' "$H/tools/census/hand_test_list.py" > "$M"
grep -q '^        return False$' "$M" || { echo "不通 负对照没改到带存档判定"; bad=1; }
ck "⑦ 负对照（不认带存档局）判不通：「$(hold7 "$M")」" 1 "$([ "$(hold7 "$M")" = "$W7" ] && echo 0 || echo 1)"
# ⑧ 重生成读回旧表（11-05 总指挥：普查重生成把装机进度「已装 测试机2…」冲回「待」）：同夹具，输出路径先放一张旧表——
#   E 状态「已装 测试机2（单测）」、备注「双手柄放最后」；M3 旧状态「待多手柄」（规则缺省，照新算）；人手加的 Z 行（最近判定批空）；
#   期望（手写）：E 状态与备注原样；M3 仍「待多手柄」；D、F 是旧表没有的新款 → 规则缺省「待」；Z 行留在末尾、状态原样；其余列照新算
keep8() { local o=$T/out8.tsv
  { printf '%s\n' "$HEADW"
    printf '0100EEEE00000000\t戊\tc1102b\t2026-11-02\t旧族\t1\t双手柄放最后\t30\t\t9\t已装 测试机2（单测）\n'
    printf '01000M0300000000\t多手柄\tc1101a\t2026-11-01\t旧族\t1\t待多手柄\t5\t\t1\t待多手柄\n'
    printf '0100ZZZZ00000000\t壬\t\t2026-11-05\t卡在开场页\t\t等合入\t\t\t7\t等合入 → 测试机2\n'; } > "$o"
  CENSUS_ACTIVE= CENSUS_HDD_GLOB=$T/nohdd python3 "$1" "$o" --census "$C" > "$T/stdout8" 2>&1 || { echo 跑不起来; return; }
  tail -n +2 "$o" | awk -F'\t' '{printf "%s:%s:%s:%s;", substr($1,5,4), $11, $7, $5}'; }
W8='DDDD:待::无日志;FFFF:待::无日志;0M03:待多手柄:待多手柄:无日志;EEEE:已装 测试机2（单测）:双手柄放最后:导航卡住（局时用完（离收局几十秒还在菜单））;ZZZZ:等合入 → 测试机2:等合入:卡在开场页;'
ck "⑧ 重生成读回旧表状态 / 备注、人手加的行留着：「$(keep8 "$H/tools/census/hand_test_list.py")」" "$W8" "$(keep8 "$H/tools/census/hand_test_list.py")"
sed 's/    write(args\[0\], keep_state(args\[0\], rows, load_manual(C)))/    write(args[0], rows)/' "$H/tools/census/hand_test_list.py" > "$M"
grep -q '^    write(args\[0\], rows)$' "$M" || { echo "不通 负对照没去掉读回旧表"; bad=1; }
ck "⑧ 负对照（去掉读回旧表）判不通：「$(keep8 "$M")」" 1 "$([ "$(keep8 "$M")" = "$W8" ] && echo 0 || echo 1)"
[ $bad = 0 ] && echo "✅ 待手测总清单全通" || { echo "🔴 待手测总清单有不通项"; exit 1; }
