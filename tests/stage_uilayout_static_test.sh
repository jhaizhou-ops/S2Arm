#!/bin/bash
# 宽屏界面布局阶段·逐游戏静态覆盖单测（pack/stage_uilayout.sh 的 romfs_patch.tsv 一路，临时产物根，约 2 秒）：bash tests/stage_uilayout_static_test.sh
# 夹具：游戏 g 的原版 romfs 只有 Scripts/a.lua（原版行 X = 40）；仓库表目录 g_<构建号>/romfs_patch.tsv 写一条规则把它改成 X = 80。
# 假产物根的 main 是 96 字节全零，构建号即 32 个 0，表目录名据此写死。
# 期望：1 跑阶段后产物根 a.lua 被覆盖成打好版（缩进保留）、清单只有 Scripts/a.lua、原版没被写；
#       2 再跑跳过、现行不动；
#       3 原版数据换版（行变 X = 41，计数对不上）报红、退出 1、现行不动；
#       4 删掉规则文件再跑，a.lua 恢复成原版、清单空。
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
BID=00000000000000000000000000000000
STOCK=$(printf 'line1\n\tX = 40,\nline3'); PATCHED=$(printf 'line1\n\tX = 80,\nline3'); OTHER=$(printf 'line1\n\tX = 41,\nline3')
mkdir -p $T/bin $T/repo/pack $T/repo/tools $T/repo/graphics/widen/scan $T/repo/graphics/widen/tables/g_$BID $T/repo/graphics/nvn/tools $T/roots $T/widen $T/data/g/romfs/Scripts
# 阶段用 xxd 读构建号；个别环境没有 xxd，给一个只支持「-s 偏移 -l 长度 -p 文件」的替身，保证构建号在本测试里恒为 32 个 0
cat > $T/bin/xxd <<'EOF'
#!/bin/bash
off=0; len=0; file=
while [ $# -gt 0 ]; do case "$1" in -s) off=$2; shift 2 ;; -l) len=$2; shift 2 ;; -p) shift ;; *) file=$1; shift ;; esac; done
tail -c +$((off + 1)) "$file" | head -c "$len" | od -An -tx1 -v | tr -d ' \n'; echo
EOF
chmod +x $T/bin/xxd; export PATH="$T/bin:$PATH"
cp "$H/graphics/nvn/tools/romfs_list.py" $T/repo/graphics/nvn/tools/; cp "$H/pack/roots.sh" $T/repo/pack/; cp "${STAGE:-$H/pack/stage_uilayout.sh}" $T/repo/pack/stage_uilayout.sh
cp "$H/graphics/widen/scan/romfs_patch.py" $T/repo/graphics/widen/scan/; cp "$H/tools/clonedir.py" "$H/tools/plock.sh" "$H/tools/flock_hold.py" $T/repo/tools/
echo dummy > $T/repo/graphics/widen/scan/ui_lyt.py; echo y > $T/repo/graphics/widen/scan/yaz0enc.c
printf 'Scripts/a.lua\tX = 40,\tX = 80,\t1\n' > $T/repo/graphics/widen/tables/g_$BID/romfs_patch.tsv
(cd $T/repo && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm x)
export S2A_ROOTS=$T/roots S2A_ROOTS_SHARED=$T/shared S2A_WIDEN_DIR=$T/widen
printf 'line1\n\tX = 40,\nline3\n' > $T/data/g/romfs/Scripts/a.lua
C0=$T/roots/g@s0; mkdir -p $C0/exefs $C0/romfs/Scripts; head -c 96 /dev/zero > $C0/exefs/main; printf 'src=%s\ntag=s0\n' "$T/data/g" > $C0/seed.txt
printf 'line1\n\tX = 40,\nline3\n' > $C0/romfs/Scripts/a.lua; ln -s g@s0 $T/roots/g@现行
S() { bash $T/repo/pack/stage_uilayout.sh g; }
c() { cd -P $T/roots/g@现行 && pwd; }
rd() { cat "$(c)/romfs/Scripts/a.lua"; }
o=$(S 2>&1); r=$?
ck "1 静态覆盖打上" '[ $r = 0 ] && [ "$(rd)" = "$PATCHED" ]'
ck "1 清单只有 Scripts/a.lua" '[ "$(cat "$(c)/ui_overlay.tsv")" = "Scripts/a.lua" ]'
ck "1 原版 romfs 没被写" '[ "$(cat $T/data/g/romfs/Scripts/a.lua)" = "$STOCK" ]'
b=$(c); o=$(S 2>&1); r=$?
ck "2 再跑跳过、现行不动" '[ $r = 0 ] && [ "$(c)" = "$b" ] && [ "${o#*跳过}" != "$o" ]'
printf 'line1\n\tX = 41,\nline3\n' > $T/data/g/romfs/Scripts/a.lua; b=$(c); o=$(S 2>&1); r=$?
ck "3 原版换版计数对不上报红、现行不动" '[ $r = 1 ] && [ "$(c)" = "$b" ] && [ "${o#*红}" != "$o" ]'
printf 'line1\n\tX = 40,\nline3\n' > $T/data/g/romfs/Scripts/a.lua; rm $T/repo/graphics/widen/tables/g_$BID/romfs_patch.tsv; o=$(S 2>&1); r=$?
ck "4 规则删掉后恢复原版、清单空" '[ $r = 0 ] && [ "$(rd)" = "$STOCK" ] && [ ! -s "$(c)/ui_overlay.tsv" ]'
chmod -R u+w $T; rm -rf $T
if [ $bad = 0 ]; then echo "stage_uilayout 静态覆盖单测全过"; else echo "stage_uilayout 静态覆盖单测有不通"; exit 1; fi
