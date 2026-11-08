#!/bin/bash
# 门禁覆盖：tools/census/census.sh tools/tianyan_lane.py
# 普查天眼道出包（census.sh packone_tianyan，CENSUS_TIANYAN=1）：抽函数单跑，天眼道 / packone / census.py 用替身。期望按函数头注口径手写：
#   ① 天眼成功：meta = 款名 / 版本 / GB（1 GiB → 1.0），unpack_s = .qt_packed 第 3 列，exefs 拷进日志目录，packed/<键> 出现，不调 packone
#   ② 天眼退 75：记【红】并落回 packone（替身记一笔），不写失败行
#   ③ 天眼退 1：总表记「失败  出包（天眼）：<最后一行红>」，不进 packed/，不调 packone
#   ④ 天眼道被外部收掉（143 / 137 / 124）：总表记「未判  机器原因：天眼出包被外部收掉（rc=…」，不进 packed/，不调 packone（11-05 被另一线宽 pkill 收掉的两单记成了游戏失败）
set -u
H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
export S2A_DISK_FREE_GB=999 S2A_DISK_DIR=$T/diskadmit   # 工作盘准入：假剩余与临时账本
chk() { if [ "$2" = "$3" ]; then echo "通 $1"; else echo "不通 $1：期望「$2」→ 真结果「$3」"; bad=$((bad + 1)); fi; }
FN=$(sed -n '/^# >>> packone_tianyan/,/^# <<< packone_tianyan/p' "$H/tools/census/census.sh")
[ -n "$FN" ] || { echo "不通 抽不出 packone_tianyan"; exit 1; }
mkdir -p "$T/r/tools/census" "$T/r/.git"
# 天眼道替身：按 FAKE_RC 退出；成功时照 --census 落盘布局写（roots/<款>@现行/exefs/main + .qt_packed）
cat > "$T/r/tools/tianyan_lane.py" <<'PY'
import os, sys, pathlib
a = sys.argv; out = pathlib.Path(a[a.index('--out') + 1]); rc = int(os.environ['FAKE_RC'])
open(os.environ['FAKE_ARGS'], 'w').write(a[a.index('--batch') + 1] if '--batch' in a else '（没传）')
(out / 'tianyan').mkdir(parents=True, exist_ok=True); (out / 'tianyan' / 'lane_timing.tsv').write_text('代码\t1\n')
(out / 'tianyan' / 'direct_fail.tsv').write_text('键\t类别\t错误\nf3385a478d85b435\tmetal failed\t假\n')   # 天眼道拉回的编不过清单
if rc == 0:
    v = out / 'roots' / 'tk@tianyan-1'; (v / 'exefs').mkdir(parents=True); (v / 'exefs' / 'main').write_bytes(b'M')
    os.symlink('tk@tianyan-1', out / 'roots' / 'tk@现行'); (out / '.qt_packed').write_text('tk\t0100000000ABC000\t46\t561\n')
    print('🟢 天眼道完成')
elif rc == 75: print('【红】天眼 tianyan 不可达（假），落回本机出包')
else: print('【红】天眼出包失败 rc=1：light.log：rc=1；假的红行')
sys.exit(rc)
PY
cat > "$T/r/tools/census/census.py" <<'PY'
import sys; t = open(sys.argv[7], encoding='utf-8').read().splitlines()[1].split('\t'); print('\t'.join([sys.argv[2], sys.argv[3]] + t))
PY
SRCF=$T/src.nsp
run() {   # run <rc>：新批次目录里跑一次 packone_tianyan，返回批次目录（子 shell 里 T 是总表，原件路径先存 SRCF）
  local B=$T/b$1; mkdir -p "$B/work" "$B/packed"; : > "$B/总表.tsv"; : > "$B/批次.log"
  ( R=$T/r; PY=python3; PQ=$B/packed; T=$B/总表.tsv; L=$B/批次.log; export FAKE_RC=$1 FAKE_ARGS=$B/lane_batch.txt
    git() { echo deadbeef; }; bat_ok() { :; }; log() { echo "$*" >> "$L"; }; work_rm() { rm -rf "$1"; }
    packone() { echo "packone $*" >> "$B/packone.called"; }
    eval "$FN"; packone_tianyan 0100000000ABC000 测试款 1.0 1073741824 "$SRCF" )
  echo "$B"; }
: > "$SRCF"
B=$(run 0); W=$B/work/0100000000ABC000
chk "① 传批次名 = 批次目录名（stop --batch 按它收）" "$(basename "$B")" "$(cat "$B/lane_batch.txt" 2> /dev/null)"
chk "① meta" "测试款	1.0	1.0" "$(cat "$W/meta" 2> /dev/null)"
chk "① unpack_s 取 .qt_packed 第 3 列" "46" "$(cat "$W/p/logs/0100000000ABC000/unpack_s" 2> /dev/null)"
chk "① exefs 拷进日志目录" "M" "$(cat "$W/p/logs/0100000000ABC000/exefs/main" 2> /dev/null)"
chk "① 编不过清单落到普查读的 logs/<键>/direct_fail.tsv" "f3385a478d85b435	metal failed	假" "$(tail -1 "$W/p/logs/0100000000ABC000/direct_fail.tsv" 2> /dev/null)"
chk "① 进 packed/、不调 packone" "1 0" "$(ls "$B/packed" | wc -l | tr -d ' ') $([ -f "$B/packone.called" ] && echo 1 || echo 0)"
B=$(run 75)
chk "② 退 75 落回 packone、不写失败行" "1 0" "$([ -f "$B/packone.called" ] && echo 1 || echo 0) $(grep -c . "$B/总表.tsv")"
chk "② 记【红】" "1" "$(grep -c '【红】.*天眼道不可用' "$B/批次.log")"
B=$(run 1)
chk "③ 失败行" "0100000000ABC000	测试款	失败	出包（天眼）：【红】天眼出包失败 rc=1：light.log：rc=1；假的红行" "$(cat "$B/总表.tsv")"
chk "③ 不进 packed/、不调 packone" "0 0" "$(ls "$B/packed" | wc -l | tr -d ' ') $([ -f "$B/packone.called" ] && echo 1 || echo 0)"
for rc in 143 137 124; do B=$(run $rc)
  chk "④ rc=$rc 记未判机器原因" "0100000000ABC000	测试款	未判	机器原因：天眼出包被外部收掉（rc=$rc" "$(sed 's/，.*//' "$B/总表.tsv")"
  chk "④ rc=$rc 不进 packed/、不调 packone" "0 0" "$(ls "$B/packed" | wc -l | tr -d ' ') $([ -f "$B/packone.called" ] && echo 1 || echo 0)"; done
[ $bad = 0 ] && echo "✓ t_census_tianyan" || { echo "✗ census_tianyan：$bad 不通"; exit 1; }
