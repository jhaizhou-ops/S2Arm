#!/bin/bash
# 普查计分单测（tools/census/score.py，11-06 总指挥：分母直接读不计入名单，不靠人对账）：bash tests/census_score_test.sh，约 1 秒
# 夹具：一批主批总表 8 款 + 手测结果.tsv + 不计入分母.tsv；期望都手写：
#   A 一次成功 是 → 成功；B 待手测、手测 是 → 成功；C 待手测、手测先否后是（追加登记）→ 成功（同键最后一行为准）
#   D 待手测、手测 否 → 手测否；E 待手测 → 待手测；F 一次成功 否 → 未成功
#   G 否、名单类「原件坏」→ 不计入（不进分母、不进各状态）；H 否、名单类「别的」→ 一行【红】、照算未成功
#   名单里 K 总表没有 → 打「名单里有、总表没有 1 款」，不影响分母
#   计数：成功 3、手测否 1、待手测 1、未成功 2，分母 7；上线线 ⌈7×95%⌉ = 7，差 4
#   上线线公式：205 → 195（194.75 向上取整）、20 → 19（正好 19.0 不进位）、7 → 7、0 → 0
#   负对照：删掉 不计入分母.tsv → 分母 8（G 回到未成功，未成功 3），第三行「不计入 0 款」
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0; trap 'rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
C=$T/census; mkdir -p "$C/c1101a"; echo type=主批 > "$C/c1101a/.census_batch"
r() { printf '0100%s00000000\t%s\t%s\t否\t2026-11-01\t%s\n' "$1" "$2" "$3" "$4"; }
{ printf '键\t名称\t结论\t进局\t日期\t一次成功\n'
  r AAAA 甲 通过 是; r BBBB 乙 通过 待手测; r CCCC 丙 通过 待手测; r DDDD 丁 通过 待手测; r EEEE 戊 通过 待手测
  r FFFF 己 失败 否; r GGGG 庚 源文件坏 否; r HHHH 辛 失败 否; } > "$C/c1101a/总表.tsv"
printf '键\t手测\t备注\n0100BBBB00000000\t是\tx\n0100CCCC00000000\t否\tx\n0100DDDD00000000\t否\tx\n0100CCCC00000000\t是\t复测过\n' > "$C/手测结果.tsv"
printf '键\t类\t依据\n0100GGGG00000000\t原件坏\t哈希校验不过\n0100HHHH00000000\t别的\t写错\n0100KKKK00000000\t要架构\t不在总表\n' > "$C/不计入分母.tsv"
python3 "$H/tools/census/score.py" --census "$C" --out "$T/latest.tsv" > "$T/o.txt" 2>&1; rc=$?
ck "退出 0" '[ $rc = 0 ]'
ck "第一行：一次成功 3 / 7、上线线 7 差 4（$(head -1 $T/o.txt)）" '[ "$(head -1 $T/o.txt)" = "一次成功 3 / 7 = 42.9%｜上线线 7（95%）差 4" ]'
ck "第二行：成功 3 手测否 1 待手测 1 未成功 2（$(sed -n 2p $T/o.txt)）" '[ "$(sed -n 2p $T/o.txt)" = "成功 3　手测否 1　待手测 1　未成功 2" ]'
ck "第三行：不计入 1 款 G、名单里有总表没有 1 款 K（$(sed -n 3p $T/o.txt)）" '[ "$(sed -n 3p $T/o.txt)" = "不计入 1 款：0100GGGG00000000；名单里有、总表没有 1 款：0100KKKK00000000" ]'
ck "H 类不认得 → 一行【红】" '/usr/bin/grep -aq "【红】不计入分母.tsv：0100HHHH00000000" $T/o.txt'
ck "latest.tsv：G 写「不计入：原件坏」、C 成功、H 未成功" '/usr/bin/grep -aq "^不计入：原件坏	0100GGGG00000000" $T/latest.tsv && /usr/bin/grep -aq "^成功	0100CCCC00000000" $T/latest.tsv && /usr/bin/grep -aq "^未成功	0100HHHH00000000" $T/latest.tsv'
ck "latest.tsv 8 行、不留 .new" '[ $(wc -l < $T/latest.tsv) = 8 ] && [ ! -e $T/latest.tsv.new ]'
ck "上线线公式 205→195、20→19、7→7、0→0" '[ "$(cd $H/tools/census && python3 -c "import score; print([score.launch_line(n) for n in (205, 20, 7, 0)])")" = "[195, 19, 7, 0]" ]'
rm "$C/不计入分母.tsv"; python3 "$H/tools/census/score.py" --census "$C" > "$T/o2.txt" 2>&1
ck "负对照：没有名单 → 分母 8、未成功 3、不计入 0 款" '[ "$(head -1 $T/o2.txt)" = "一次成功 3 / 8 = 37.5%｜上线线 8（95%）差 5" ] && [ "$(sed -n 3p $T/o2.txt)" = "不计入 0 款：无" ]'
[ $bad = 0 ] && echo "census_score 单测全过" || { echo "census_score 单测有不通"; exit 1; }
