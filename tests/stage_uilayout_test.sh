#!/bin/bash
# 在两种 sed 上用临时文件完成同一替换。
sed_edit() { sed -i.s2a-bak "$1" "$2" && rm -f "$2.s2a-bak"; }
# 宽屏界面布局阶段单测（pack/stage_uilayout.sh，假生成工具，临时产物根，约 2 秒）：bash tests/stage_uilayout_test.sh
# 假工具同真工具的调用约定（ui_lyt.py <romfs> <输出目录> <W>，输出目录下按 romfs 相对路径写）：把原版 Layout/a.zs 读进来、前面加上工具里写死的前缀输出（FAKE_NONE=1 时什么都不出）；期望按规则手写：
#   ① 现行 romfs 已含上一版覆盖（a.zs = old-a、b.zs = old-b，清单两个都有）→ 新 a.zs = 「v1:orig-a」（从原版生成，不是 v1:old-a），b.zs 恢复成原版 orig-b，清单只剩 a
#   ② 同工具再跑 → 跳过、现行不动
#   ③ 工具改了（前缀 v2）→ 重新生成：a.zs = 「v2:orig-a」（不复用 v1 覆盖包）
#   ④ 新工具什么都不改 → a.zs 恢复成原版 orig-a、清单空
#   ⑤ 现行 seed.txt 没记原版目录 → 报红、退出 1、现行不动
#   ⑦ 覆盖包里有原版没有的文件（假工具 FAKE_EXTRA=1 多写 Layout/z.zs）→ 打黄、退出 0（宽屏不挡出包）、a.zs 照样覆盖、z.zs 不进产物根也不进清单
#   ⑧ 生成工具部分报错、退出 1（假工具 FAKE_FAIL=1：写了 a.zs 再报「报错 3」）→ 打黄、退出 0（宽屏不挡出包）、已生成的 a.zs 照样覆盖
#   ⑨ 原版 romfs 换了内容、构建号与工具都没变 → 重新生成，不照盖上一份覆盖（审计 #1534 P1-54）
#   ⑥ 生成覆盖包期间别的阶段提交了新现行、起跑时的现行版本被删（假工具 FAKE_RACE=1 模拟；10-26 斯普拉遁3 普查）→ 照样提交：a.zs = 「v5:orig-a」、b.zs 原版
# 旧代码反证：STAGE=<旧版 stage_uilayout.sh> bash tests/stage_uilayout_test.sh（旧版从现行 romfs 生成、覆盖包只按构建号 + 屏宽缓存、不恢复，①③④不通；10-21 前的版本留着旧 romfs.s2aidx，「旧索引一并删」不通；
#   10-26 前的版本在起跑时记下的现行目录里核「只许替换」，⑥ 报红不通）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
mkdir -p $T/repo/pack $T/repo/tools $T/repo/graphics/widen/scan $T/roots $T/widen $T/data/g/romfs/Layout
mkdir -p $T/repo/graphics/nvn/tools; cp "$H/graphics/nvn/tools/romfs_list.py" $T/repo/graphics/nvn/tools/; cp "$H/pack/roots.sh" $T/repo/pack/; cp "${STAGE:-$H/pack/stage_uilayout.sh}" $T/repo/pack/stage_uilayout.sh; cp "$H/tools/clonedir.py" "$H/tools/plock.sh" "$H/tools/flock_hold.py" $T/repo/tools/
gen() { cat > $T/repo/graphics/widen/scan/ui_lyt.py <<EOF
import os, sys
if os.environ.get('FAKE_RACE') == '1':   # 并行阶段在生成期间提交：新现行 g@race，起跑时的版本删掉（同 pack/roots.sh 的「只留现行 + 上一版」）
    import shutil
    link = os.path.join(os.environ['S2A_ROOTS'], 'g@现行'); cur = os.path.realpath(link); new = os.path.join(os.environ['S2A_ROOTS'], 'g@race')
    shutil.copytree(cur, new, symlinks=True); os.remove(link); os.symlink('g@race', link); shutil.rmtree(cur)
if os.environ.get('FAKE_NONE') == '1': sys.exit(0)
FAIL = os.environ.get('FAKE_FAIL') == '1'   # 写完 a.zs 再报「报错 3」、退出 1（部分包解不开）
if os.environ.get('FAKE_EXTRA') == '1':
    os.makedirs(os.path.join(sys.argv[2], 'Layout'), exist_ok=True); open(os.path.join(sys.argv[2], 'Layout', 'z.zs'), 'w').write('extra')
d = os.path.join(sys.argv[2], 'Layout'); os.makedirs(d, exist_ok=True)
open(os.path.join(d, 'a.zs'), 'w').write('$1:' + open(os.path.join(sys.argv[1], 'Layout', 'a.zs')).read())
if FAIL: print('界面布局：…报错 3（屏幕宽 2346）'); sys.exit(1)
EOF
}
gen v1; echo y > $T/repo/graphics/widen/scan/yaz0enc.c
(cd $T/repo && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm x)
export S2A_ROOTS=$T/roots S2A_ROOTS_SHARED=$T/shared S2A_WIDEN_DIR=$T/widen
printf orig-a > $T/data/g/romfs/Layout/a.zs; printf orig-b > $T/data/g/romfs/Layout/b.zs; printf orig-c > $T/data/g/romfs/Layout/c.zs
C0=$T/roots/g@s0; mkdir -p $C0/exefs $C0/romfs/Layout; head -c 96 /dev/zero > $C0/exefs/main; printf 'src=%s\ntag=s0\n' "$T/data/g" > $C0/seed.txt
printf old-a > $C0/romfs/Layout/a.zs; printf old-b > $C0/romfs/Layout/b.zs; printf orig-c > $C0/romfs/Layout/c.zs; printf 'Layout/a.zs\nLayout/b.zs\n' > $C0/ui_overlay.tsv; echo oldkey > $C0/.stage_uilayout
echo stale-index > $C0/romfs.s2aidx; echo oldidx > $C0/.stage_romfsidx; ln -s g@s0 $T/roots/g@现行
S() { bash $T/repo/pack/stage_uilayout.sh g; }
c() { cd -P $T/roots/g@现行 && pwd; }
rd() { cat "$(c)/romfs/Layout/$1"; }
o=$(S 2>&1); r=$?
ck "① 从原版生成：a.zs = v1:orig-a（$(rd a.zs)）" '[ $r = 0 ] && [ "$(rd a.zs)" = v1:orig-a ]'
ck "① 上一版改过、这一版不改的 b.zs 恢复成原版（$(rd b.zs)）" '[ "$(rd b.zs)" = orig-b ]'
ck "① 未涉及的 c.zs 不动、清单只剩 a" '[ "$(rd c.zs)" = orig-c ] && [ "$(cat "$(c)/ui_overlay.tsv")" = Layout/a.zs ]'
ck "① romfs 改了 → 同一次提交里旧索引 romfs.s2aidx 与 .stage_romfsidx 一并删（不留「索引与文件对不上」的现行）" '[ ! -e "$(c)/romfs.s2aidx" ] && [ ! -e "$(c)/.stage_romfsidx" ]'
ck "① 原版 romfs 没被写" '[ "$(cat $T/data/g/romfs/Layout/a.zs)" = orig-a ] && [ "$(cat $T/data/g/romfs/Layout/b.zs)" = orig-b ]'
b=$(c); o=$(S 2>&1); r=$?
ck "② 同工具再跑 → 跳过、现行不动" '[ $r = 0 ] && [ "$(c)" = "$b" ] && [[ "$o" == *跳过* ]]'
gen v2; o=$(S 2>&1); r=$?
ck "③ 工具改了 → 重新生成：a.zs = v2:orig-a（$(rd a.zs)）" '[ $r = 0 ] && [ "$(rd a.zs)" = v2:orig-a ]'
gen v3; o=$(FAKE_NONE=1 S 2>&1); r=$?
ck "④ 新工具不改任何文件 → a.zs 恢复原版、清单空（$(rd a.zs)）" '[ $r = 0 ] && [ "$(rd a.zs)" = orig-a ] && [ ! -s "$(c)/ui_overlay.tsv" ]'
b=$(c); sed_edit '/^src=/d' "$b/seed.txt"; gen v4; o=$(S 2>&1); r=$?
ck "⑤ 现行没记原版目录 → 报红、退出 1、现行不动" '[ $r = 1 ] && [ "$(c)" = "$b" ] && [[ "$o" == *【红】* ]]'
printf 'src=%s\n' "$T/data/g" >> "$(c)/seed.txt"; gen v5; o=$(FAKE_RACE=1 S 2>&1); r=$?
ck "⑥ 生成期间现行换了、起跑时的版本被删 → 照样提交：a.zs = v5:orig-a（$(rd a.zs)，退出 ${r}）" '[ $r = 0 ] && [ "$(rd a.zs)" = v5:orig-a ] && [ "$(rd b.zs)" = orig-b ] && [ "$(basename "$(c)")" != g@race ]'
gen v6; o=$(FAKE_EXTRA=1 S 2>&1); r=$?
ck "⑦ 覆盖包有原版没有的 z.zs → 打黄、退出 ${r}、a.zs = v6:orig-a（$(rd a.zs)）、z.zs 不进产物根与清单" '[ $r = 0 ] && [[ "$o" == *【黄】*z.zs* ]] && [ "$(rd a.zs)" = v6:orig-a ] && [ ! -e "$(c)/romfs/Layout/z.zs" ] && ! grep -q z.zs "$(c)/ui_overlay.tsv"'
gen v7; o=$(FAKE_FAIL=1 S 2>&1); r=$?
ck "⑧ 生成工具部分报错 → 打黄、退出 ${r}、已生成的 a.zs = v7:orig-a（$(rd a.zs)）" '[ $r = 0 ] && [[ "$o" == *【黄】*报错\ 3* ]] && [ "$(rd a.zs)" = v7:orig-a ]'
# ⑨ 审计 #1534 P1-54：同工具、构建号没变，原版 romfs 的 a.zs 换了内容（重解包 / 只换数据的更新；同大小、修改时间变）→ 重新生成：a.zs = v7:new-a，不照盖上一份覆盖
printf new-a > $T/data/g/romfs/Layout/a.zs; touch -t 202601010000 $T/data/g/romfs/Layout/a.zs; o=$(S 2>&1); r=$?
ck "⑨ 原版换了、构建号与工具都没变 → 重新生成：a.zs = v7:new-a（$(rd a.zs)，退出 ${r}）" '[ $r = 0 ] && [ "$(rd a.zs)" = v7:new-a ]'
b=$(c); o=$(S 2>&1); r=$?
ck "⑨ 再跑 → 跳过、现行不动" '[ $r = 0 ] && [ "$(c)" = "$b" ] && [[ "$o" == *跳过* ]]'
chmod -R u+w $T; rm -rf $T; [ $bad = 0 ] && echo "stage_uilayout 单测全过" || { echo "stage_uilayout 单测有不通"; exit 1; }
