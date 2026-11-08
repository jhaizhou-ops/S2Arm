#!/bin/bash
# 目录快照跨卷单测（tools/clonedir.py，约 5 秒）：bash tests/clonedir_test.sh
# 背景：10-26 运维线把一键出包 --out 放外置 APFS 盘，追加内容从本机缓存克隆到产物根报「Cross-device link」，刷新停在追加内容。
# 期望（按规则手写）：
#   ① 同卷：克隆出的文件内容一致、顶层软链跟进去成实体（clonefile 行为）、目录里的软链照原样、跳过名单生效、只读目录补上属主写权限
#   ② 跨卷（现建一个 4 MB APFS 镜像挂成第二个卷）：退出 0，与 ① 同样的结果（顶层软链成实体、目录里的软链照原样、跳过名单生效）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0; MNT=
trap '[ -n "$MNT" ] && hdiutil detach -quiet -force "$MNT"; rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
S=$T/src; mkdir -p "$S/a/b" "$S/ro" "$S/skipme"; echo hi > "$S/a/b/f"; ln -s a/b/f "$S/lnk"; ln -s b/f "$S/a/inner"; echo x > "$S/ro/g"; chmod 555 "$S/ro"
python3 "$H/tools/clonedir.py" "$S" "$T/same" skipme; r1=$?
ck "① 同卷：rc=${r1}、内容 $(cat "$T/same/a/b/f" 2> /dev/null)、顶层软链 $([ -L "$T/same/lnk" ] && echo 仍是软链 || cat "$T/same/lnk")、内层软链 $(readlink "$T/same/a/inner")、跳过 $([ -e "$T/same/skipme" ] && echo 没跳 || echo 已跳)、只读目录可写 $([ -w "$T/same/ro" ] && echo 是 || echo 否)" \
  '[ $r1 = 0 ] && [ "$(cat "$T/same/a/b/f")" = hi ] && [ ! -L "$T/same/lnk" ] && [ "$(cat "$T/same/lnk")" = hi ] && [ "$(readlink "$T/same/a/inner")" = b/f ] && [ ! -e "$T/same/skipme" ] && [ -w "$T/same/ro" ]'
hdiutil create -quiet -size 4m -fs APFS -volname s2a_xvol "$T/v.dmg" && MNT=$(hdiutil attach -nobrowse -noverify "$T/v.dmg" | awk -F'\t' '/s2a_xvol/ {print $NF}')
[ -d "$MNT" ] || { echo "不通 ② 建不了第二个卷（hdiutil）"; exit 1; }
python3 "$H/tools/clonedir.py" "$S" "$MNT/out" skipme 2> "$T/x.err"; r2=$?
ck "② 跨卷：rc=${r2}$( [ -s "$T/x.err" ] && echo "（$(head -1 "$T/x.err")）")、内容 $(cat "$MNT/out/a/b/f" 2> /dev/null)、顶层软链 $([ -L "$MNT/out/lnk" ] && echo 仍是软链 || cat "$MNT/out/lnk")、内层软链 $(readlink "$MNT/out/a/inner")、跳过 $([ -e "$MNT/out/skipme" ] && echo 没跳 || echo 已跳)" \
  '[ $r2 = 0 ] && [ "$(cat "$MNT/out/a/b/f")" = hi ] && [ ! -L "$MNT/out/lnk" ] && [ "$(cat "$MNT/out/lnk")" = hi ] && [ "$(readlink "$MNT/out/a/inner")" = b/f ] && [ ! -e "$MNT/out/skipme" ] && [ "$(cat "$MNT/out/ro/g")" = x ]'
chmod -R u+w "$S"
[ $bad = 0 ] && echo "clonedir 单测全过" || { echo "clonedir 单测有不通"; exit 1; }
