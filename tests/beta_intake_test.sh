#!/bin/bash
# 内测诊断包入库单测（tools/beta_intake.py，合成诊断包，期望按造的数据手算）：bash tests/beta_intake_test.sh
#   A 包（manifest 齐）：host.log 正常退出、到 MARK、热状态最高 2、实占峰值 4700；host.prev.log 托管异常崩溃 → 签名「AccessViolationException @ Ryujinx.X.Y」
#   B 包（没有 manifest）：host.log 没有退出 / 崩溃行 → 结局 unknown、manifest 字段记「缺」；C 包含 ../ 路径 → 拒绝、不入库
#   再跑一次不重复入库；--report：A 款 × 机型 两条症状（正常 / 崩溃），B 一条「卡死或被杀」
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0; trap 'rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
I=$T/inbox; mkdir -p $I $T/a/logs $T/b/logs
cat > $T/a/manifest.json <<'J'
{"schema":1,"tester":{"id":"p01","group":"E","note":"跑了一会儿闪退"},"app":{"commit":"8cf4073a1abcdef"},"game":{"name":"mk8d"},"device":{"model":"iPhone16,1","ios":"27.0"}}
J
printf '[s2a] [心跳] 帧 300，热状态 1（0 正常 1 一般 2 严重 3 危急），进程实占 3000 MB，前台\nS2A 标记 MARK：帧 900\n[s2a] [心跳] 帧 1800，热状态 2（0 正常），进程实占 4700 MB，前台\n[s2a] 优雅退出完成（0.1 秒）\n' > $T/a/logs/host.log
printf '[s2a] [心跳] 帧 120，热状态 0（0 正常），进程实占 2500 MB，前台\nUnhandled exception.\nS2Arm[1:2] System.AccessViolationException: Attempted to read\n   at Ryujinx.X.Y(Int32) + 0x10\n   at Ryujinx.X.Z()\n[s2a] 【红】CRASH 信号 6 地址 0x1 pc __pthread_kill+0x8（宿主）\n' > $T/a/logs/host.prev.log
printf '[s2a] [心跳] 帧 50，热状态 0（0 正常），进程实占 1200 MB，前台\n' > $T/b/logs/host.log
(cd $T/a && zip -qr $I/s2a_diag_mk8d_A.zip .); (cd $T/b && zip -qr $I/s2a_diag_d3_B.zip .)
python3 - "$I/s2a_diag_x_C.zip" <<'P'
import zipfile, sys; z = zipfile.ZipFile(sys.argv[1], 'w'); z.writestr('../evil.txt', 'x'); z.writestr('manifest.json', '{}'); z.close()
P
o1=$(python3 $H/tools/beta_intake.py --inbox $I 2>&1); S=$I/summary.tsv
row() { awk -F'\t' -v z="$1" -v s="$2" '$18==z && $8==s' $S; }
A1=$(row s2a_diag_mk8d_A.zip host.log); A2=$(row s2a_diag_mk8d_A.zip host.prev.log); B1=$(row s2a_diag_d3_B.zip host.log)
ck "A host.log：exit、MARK 是、帧数 1800、热状态最高 2、实占峰值 4700、测试者 p01 组 E 机型 iPhone16,1、包提交前 9 位" '[ "$(echo "$A1" | cut -f9-13)" = "exit	是	1800	2	4700" ] && [ "$(echo "$A1" | cut -f2-7)" = "p01	E	mk8d	iPhone16,1	27.0	8cf4073a1" ]'
ck "A host.prev.log：crash、签名 AccessViolationException @ Ryujinx.X.Y、红行 1" '[ "$(echo "$A2" | cut -f9)" = crash ] && [ "$(echo "$A2" | cut -f14)" = "AccessViolationException @ Ryujinx.X.Y" ] && [ "$(echo "$A2" | cut -f15)" = 1 ]'
ck "B（无 manifest）：结局 unknown、款 / 机型记「缺」" '[ "$(echo "$B1" | cut -f9)" = unknown ] && [ "$(echo "$B1" | cut -f4,5)" = "缺	缺" ]'
ck "C（含 ../ 路径）：拒绝、不入库、没解到收件目录外" 'grep -q "s2a_diag_x_C.zip 解不开：可疑路径" <<< "$o1" && ! grep -q s2a_diag_x_C.zip $S && [ ! -e $I/evil.txt ] && [ ! -e $T/evil.txt ]'
n1=$(wc -l < $S | tr -d " "); o2=$(python3 $H/tools/beta_intake.py --inbox $I 2>&1); n2=$(wc -l < $S | tr -d " ")
ck "再跑一次不重复入库（${n1} → ${n2} 行，表头 + 3 行）、拒收的 C 也不再报" '[ "$n1" = 4 ] && [ "$n2" = 4 ] && ! grep -q s2a_diag_x_C <<< "$o2"'
o3=$(python3 $H/tools/beta_intake.py --inbox $I --report)
ck "汇总：mk8d × iPhone16,1 正常 1 / 崩溃 1；缺 × 缺 卡死或被杀 1" 'grep -q "^mk8d	iPhone16,1	正常	1$" <<< "$o3" && grep -q "^mk8d	iPhone16,1	崩溃:AccessViolationException @ Ryujinx.X.Y	1$" <<< "$o3" && grep -q "^缺	缺	卡死或被杀	1$" <<< "$o3"'
# App 首版导出的包（10-23 测试机2 实测）：全部文件套在一层同名文件夹里、中文文件名没带 UTF-8 标记 → 仍按 schema 1 解析（manifest 款名、机型、会话都在）
I2=$T/in2; mkdir -p $I2; python3 - $I2/s2a_diag_丝之歌_D.zip <<'PY'
import sys, zipfile, json
top = 's2a_diag_空洞骑士 丝之歌_D'
with zipfile.ZipFile(sys.argv[1], 'w') as z:
    for n, d in [('manifest.json', json.dumps({'schema': 1, 'game': {'name': '空洞骑士 丝之歌'}, 'device': {'model': 'iPhone18,2', 'ios': '27.0'}, 'app': {'commit': 'abcdef0123'}})),
                 ('logs/host.log', '[s2a] [心跳] 帧 30，热状态 1（1 正常），进程实占 900 MB，前台\n')]:
        i = zipfile.ZipInfo((top + '/' + n).encode('utf-8').decode('cp437')); i.flag_bits = 0; z.writestr(i, d)
PY
python3 $H/tools/beta_intake.py --inbox $I2 > /dev/null 2>&1; D1=$(awk -F'\t' 'NR==2' $I2/summary.tsv)
ck "顶级文件夹 + 无 UTF-8 标记：款「空洞骑士 丝之歌」、机型 iPhone18,2、会话 host.log、帧数 30" '[ "$(echo "$D1" | cut -f4)" = "空洞骑士 丝之歌" ] && [ "$(echo "$D1" | cut -f5)" = iPhone18,2 ] && [ "$(echo "$D1" | cut -f8)" = host.log ] && [ "$(echo "$D1" | cut -f11)" = 30 ]'

[ $bad = 0 ] && echo "beta_intake 单测全过" || { echo "beta_intake 单测有不通"; cat $S; echo "$o1"; echo "$o3"; exit 1; }
