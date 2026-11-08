#!/bin/bash
# dsh_batch 临时目录接线检查（约 1 秒）：direct_lib.sh 起 dsh_batch build 时 TMPDIR 落哪儿。从 direct_lib.sh 原样抽出选目录那段 case，按几种调用方 TMPDIR 跑：
#   ① 调用方已把 TMPDIR 指到工作盘（oneclick_win.py：天眼 / Windows 出包 <工作目录>/tmp）→ 沿用，落 <它>/dsh_batch.<进程号>（11-07 天眼两次 rc=127 盘满：
#      原先写死 $W/tmp 把几十 GB 临时文件拉回常驻直连缓存所在的 T 盘）；② Mac 系统缺省 /var/folders/… → $W/tmp（不让内置盘被写爆，原口径）；
#   ③ 没设 → $W/tmp；④ Windows 用户 Temp（Git Bash 下 /c/Users/x/AppData/Local/Temp）→ $W/tmp；⑤ 只有一处起 dsh_batch build 且用的是 $BT
set -u; H=$(cd "$(dirname "$0")/.." && pwd); bad=0; F=$H/graphics/tools/direct/direct_lib.sh
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
SEL=$(sed -n '/^BTX=; case "${TMPDIR:-}" in/,/esac$/p' "$F")
pick() { ( W=/W; TMPDIR=$1; eval "$SEL"; echo "$BT|${BTX:-}" ); }
ck "① TMPDIR=/T/work/wtmp → 沿用其下子目录、退出时清（$(pick /T/work/wtmp)）" '[[ "$(pick /T/work/wtmp)" == /T/work/wtmp/dsh_batch.*\|/T/work/wtmp/dsh_batch.* ]]'
ck "② TMPDIR=/var/folders/ab/T/ → \$W/tmp（$(pick /var/folders/ab/T/)）" '[ "$(pick /var/folders/ab/T/)" = "/W/tmp|" ]'
ck "③ 没设 → \$W/tmp（$(pick '')）" '[ "$(pick "")" = "/W/tmp|" ]'
ck "④ Windows 用户 Temp → \$W/tmp（$(pick /c/Users/x/AppData/Local/Temp)）" '[ "$(pick /c/Users/x/AppData/Local/Temp)" = "/W/tmp|" ]'
L=$(grep -n 'dsh_batch.py" build' "$F" | head -1 | cut -d: -f2-)
ck "⑤ 只有一处起 dsh_batch build，带 TMPDIR=\"\$BT\"" '[ "$(grep -c "dsh_batch.py\" build" "$F")" = 1 ] && [[ "$L" == *TMPDIR=\"\$BT\"* ]]'
[ $bad = 0 ] && echo "dshb_tmp_wire 单测全过" || { echo "dshb_tmp_wire 单测有不通"; exit 1; }
