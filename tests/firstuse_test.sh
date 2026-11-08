#!/bin/bash
# 首遇现编扫描单测（tools/firstuse_scan.py；期望按造的行手数）：bash tests/firstuse_test.sh
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
mkdir -p $T/a $T/b $T/c
printf '[gal] 管线现建：顶点 sA 片元 sB（3.8 ms，第 1 条，异步）\n[gal] 【首遇】程序 34 编译中，跳过本次绘制（管线异步现建中）（第 2 次）\n[gal] 管线现建：计算 sC（1.0 ms，第 2 条）\n[gal] 【首遇】管线特化慢：22.8 ms\n[gal] 包归档特化预编读数：首遇特化改由包归档直接取 7 次\n' > $T/a/host.log
printf 'frame\twall_us\tshader_miss\txlate_n\tpso_n\n1\t0\t0\t0\t0\n2\t33333\t2\t1\t1\n3\t33333\t1\t0\t1\n' > $T/a/frames.tsv
o=$(python3 $H/tools/firstuse_scan.py $T/a); ck "现建 2 + 编译中跳过 1 + 特化慢 1 = 4（同目录 frames.tsv 是测试局的、不算；「包归档特化预编」不算）（${o}）" '[ "${o%%	*}" = 4 ] && grep -q "现建管线 2、程序编译中跳过绘制 1、特化慢 1$" <<< "$o"'
printf '[gal] 帧节拍：交换间隔 2\n' > $T/b/host.log
o=$(python3 $H/tools/firstuse_scan.py $T/b/host.log); ck "没有首遇行 → 0" '[ "${o%%	*}" = 0 ]'
o=$(python3 $H/tools/firstuse_scan.py $T/c); ck "目录里什么都没有 → 0、不报错" '[ "${o%%	*}" = 0 ]'
mkdir -p $T/a/logs; printf '[gal] 管线现建：顶点 sX 片元 sY（1.0 ms，第 1 条）\n' > $T/a/logs/host-20261106-090000.log
o=$(python3 $H/tools/firstuse_scan.py $T/a); ck "同目录往局日志 logs/host-*.log 的现建 1 次一并算 → 5" '[ "${o%%	*}" = 5 ]'
printf '[gal] 管线现建：顶点 sZ 片元 sW（1.0 ms，第 1 条）\n[gal] 管线现建：顶点 sZ 片元 sV（1.0 ms，第 2 条）\n' > $T/a/logs/host-20261106-091500_02.log
o=$(python3 $H/tools/firstuse_scan.py $T/a); ck "再加一份往局日志的现建 2 次 → 7" '[ "${o%%	*}" = 7 ]'
rm -rf $T; [ $bad = 0 ] && echo "firstuse 单测全过" || { echo "firstuse 单测有不通"; exit 1; }
