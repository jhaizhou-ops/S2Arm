#!/bin/bash
# 保留规则 gc 单测（tools/gc.sh，临时运行目录，约 2 秒）：bash tests/gc_test.sh
# 期望（按规则手写）：产物根每款留现行 + 上一版——acnh 三个版本（a 最旧、b、c 现行）→ 删 a、留 b c；结论行「删 1 项」、逐项打「删 <路径>」；
#   冻结副本形态（tools/ 下只有 gc.sh + 同目录 roots.sh，没有 ../pack/）同样能删（10-20 夜冻结副本取不到删除函数、一直没删）；干跑只打「会删」不删
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0; trap 'chmod -R u+w "$T"; rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
export S2A_WT_ROOT=$T/wt S2A_REPO=$T/repo S2A_BOARD=$T/board.tsv   # 工作树 / 仓库一律临时的：gc 会 git worktree remove，绝不能碰真工作树
# 盘余量一律假定充足：不然宿主真盘紧（mini 剩 21 GB）时按余量回收会多删、别的用例不通；只有两条余量用例自己覆盖
export S2A_GC_FREE_GB=999 S2A_GC_WT_DIRS=$T/wt_none S2A_GC_CDDELTA=$T/cd_none GAL_PSO_CACHE=$T/pc_none GAL_AIR_CACHE=$T/air_none GAL_DL_CACHE=$T/dl_none S2A_PACK_SLOT_DIR=$T/locks_none   # 着色器中间缓存 / 出包槽一律临时目录：不碰本机真缓存、不读真烘焙道持有者
old() { find "$@" -exec touch -t 202610200100 {} + ; }   # 把目录树里所有文件 / 目录的修改时间拨到很久以前（闲）
mk() { rm -rf $T/run; mkdir -p $T/run/roots $T/run/sched; i=0; for v in a b c; do mkdir -p $T/run/roots/acnh@$v/romfs; echo $v > $T/run/roots/acnh@$v/romfs/f; touch -t 20261020010$i $T/run/roots/acnh@$v; i=$((i + 1)); done; ln -s acnh@c $T/run/roots/acnh@现行; }
mk; o=$(S2A_RUN=$T/run bash $H/tools/gc.sh --dry 2>&1)
ck "干跑：只打「会删 acnh@a」、一个不删" 'grep -q "会删 .*/acnh@a$" <<< "$o" && [ -d $T/run/roots/acnh@a ]'
o=$(S2A_RUN=$T/run bash $H/tools/gc.sh 2>&1)
ck "仓库形态：删 acnh@a、留 b c，逐项打出、结论「删 1 项」（${o##*$'\n'}）" '[ ! -e $T/run/roots/acnh@a ] && [ -d $T/run/roots/acnh@b ] && [ -d $T/run/roots/acnh@c ] && grep -q "^删 .*/acnh@a$" <<< "$o" && grep -q "gc：删 1 项" <<< "$o"'
mk; F=$T/frozen; mkdir -p $F; cp $H/tools/gc.sh $H/tools/sched.sh $H/tools/plock.sh $H/tools/flock_hold.py $F/; cp $H/pack/roots.sh $F/roots.sh
o=$(S2A_RUN=$T/run bash $F/gc.sh 2>&1)
ck "冻结副本形态（同目录 roots.sh）：照样删 acnh@a、不报红" '[ ! -e $T/run/roots/acnh@a ] && ! grep -q "【红】" <<< "$o" && grep -q "gc：删 1 项" <<< "$o"'
# 整机 nxaot 缓存（services/nxaot.sh 取用即刷新目录时间）：24 小时没用的删、30 分钟内用过的留；超过 10 份删最久没用的（下面单独一组）；
#   编到一半的 .tmp：持锁进程已死且 2 小时没动 → 删；持锁进程活着 → 留
# 全机解包缓存 cache/unpack/<程序号>-<键>（11-02）：手算期望——A 两份留新的 A2、删 A1；总量按「最近用过在前」累加 .size：D 10 KB、A2 1 KB、B 100 GB、C 60 GB → 到 C 超 150 GB 删 C；
#   D 10 分钟前用过（1 小时内）留；B 留
mk; N=$T/run/cache/unpack; for e in 0100AAAA00000000-a1:180:1 0100AAAA00000000-a2:120:1 0100BBBB00000000-b1:150:104857600 0100CCCC00000000-c1:240:62914560 0100DDDD00000000-d1:10:10; do
  IFS=: read -r d m z <<< "$e"; mkdir -p $N/$d/exefs; echo "$z" > $N/$d.size; python3 -c "import os,sys,time;t=time.time()-60*int(sys.argv[2]);os.utime(sys.argv[1],(t,t))" $N/$d $m; done
o=$(S2A_UNPACK_CACHE_GB=150 S2A_RUN=$T/run bash $H/tools/gc.sh 2>&1)
ck "解包缓存：同程序号留最近 1 份（删 A1）、超 150 GB 从最久没用的删（删 C）、B / D / A2 留" '[ ! -e $N/0100AAAA00000000-a1 ] && [ -d $N/0100AAAA00000000-a2 ] && [ -d $N/0100BBBB00000000-b1 ] && [ ! -e $N/0100CCCC00000000-c1 ] && [ ! -e $N/0100CCCC00000000-c1.size ] && [ -d $N/0100DDDD00000000-d1 ]'
# 同一组条目再验三条（11-02 22:5x 主 2T 67 GB 事故）：期望手写——① --versions 也跑总量上限（删 A1、C）；② C 的程序号在 .keep → C 留；
#   ③ 有进程命令行带 C 的条目名（正从它克隆）→ C 留
mkunp() { mk; N=$T/run/cache/unpack; for e in 0100AAAA00000000-a1:180:1 0100AAAA00000000-a2:120:1 0100BBBB00000000-b1:150:104857600 0100CCCC00000000-c1:240:62914560 0100DDDD00000000-d1:10:10; do
  IFS=: read -r d m z <<< "$e"; mkdir -p $N/$d/exefs; echo "$z" > $N/$d.size; python3 -c "import os,sys,time;t=time.time()-60*int(sys.argv[2]);os.utime(sys.argv[1],(t,t))" $N/$d $m; done; }
mkunp; S2A_UNPACK_CACHE_GB=150 S2A_RUN=$T/run bash $H/tools/gc.sh --versions > /dev/null 2>&1
ck "解包缓存：--versions 也按总量上限删（删 A1、C）" '[ ! -e $N/0100AAAA00000000-a1 ] && [ ! -e $N/0100CCCC00000000-c1 ] && [ -d $N/0100BBBB00000000-b1 ]'
mkunp; echo 0100CCCC00000000 > $N/.keep; S2A_UNPACK_CACHE_GB=150 S2A_RUN=$T/run bash $H/tools/gc.sh --versions > /dev/null 2>&1
ck "解包缓存：.keep 里的程序号超上限也不删（C 留）" '[ -d $N/0100CCCC00000000-c1 ] && [ ! -e $N/0100AAAA00000000-a1 ]'
mkunp; ( exec -a "clonedir 0100CCCC00000000-c1" sleep 30 ) & BUSY=$!; sleep 0.3; S2A_UNPACK_CACHE_GB=150 S2A_RUN=$T/run bash $H/tools/gc.sh --versions > /dev/null 2>&1; kill $BUSY 2> /dev/null; wait $BUSY 2> /dev/null   # 等它真退出：残留会让下一次运行的前两例误判 C 在用
ck "解包缓存：进程命令行带条目名（正在克隆）→ C 留" '[ -d $N/0100CCCC00000000-c1 ]'
mkunp; sleep 30 & LIVE=$!; mkdir -p $N/0100EEEE00000000-e1.tmp.999999 $N/0100EEEE00000000-e1.tmp.$LIVE; S2A_UNPACK_CACHE_GB=150 S2A_RUN=$T/run bash $H/tools/gc.sh --versions > /dev/null 2>&1; kill $LIVE 2> /dev/null; wait $LIVE 2> /dev/null
ck "解包缓存：写入进程已死的 .tmp.<pid> 清掉、活着的留" '[ ! -e $N/0100EEEE00000000-e1.tmp.999999 ] && [ -d $N/0100EEEE00000000-e1.tmp.$LIVE ]'
mk; N=$T/run/cache/nxaot; mkdir -p $N; for i in 1 2 3 4 5; do mkdir -p $N/osx-arm64-000000000000000$i; python3 -c "import os,sys,time;t=time.time()-90000+int(sys.argv[2]);os.utime(sys.argv[1],(t,t))" $N/osx-arm64-000000000000000$i $i; done
touch $N/osx-arm64-0000000000000002   # 刚被取用
mkdir -p $N/osx-arm64-aaaaaaaaaaaaaaaa.tmp $N/osx-arm64-bbbbbbbbbbbbbbbb.tmp $N/.lock-osx-arm64-bbbbbbbbbbbbbbbb; for x in $N/*.tmp; do python3 -c "import os,sys,time;t=time.time()-90000;os.utime(sys.argv[1],(t,t))" $x; done
sleep 60 & LIVE=$!; echo $LIVE > $N/.lock-osx-arm64-bbbbbbbbbbbbbbbb/pid
o=$(S2A_RUN=$T/run bash $H/tools/gc.sh 2>&1); kill $LIVE 2>/dev/null
ck "nxaot：刚用过的留、一天前的删；死锁的 .tmp 删、活锁的 .tmp 留" '[ -d $N/osx-arm64-0000000000000002 ] && [ ! -e $N/osx-arm64-0000000000000001 ] && [ ! -e $N/osx-arm64-0000000000000005 ] && [ ! -e $N/osx-arm64-aaaaaaaaaaaaaaaa.tmp ] && [ -d $N/osx-arm64-bbbbbbbbbbbbbbbb.tmp ]'
mk; N=$T/run/cache/nxaot; mkdir -p $N; for i in $(seq 10 21); do mkdir -p $N/ios-arm64-00000000000000$i; python3 -c "import os,sys,time;t=time.time()-7200+int(sys.argv[2]);os.utime(sys.argv[1],(t,t))" $N/ios-arm64-00000000000000$i $i; done; touch $N/ios-arm64-0000000000000010
o=$(S2A_RUN=$T/run bash $H/tools/gc.sh 2>&1); left=$(ls $N | grep -c ios-arm64)
ck "nxaot 12 份都在一天内：留 10 份（删最久没用的 11、12 号；刚用过的 10 号留）（剩 ${left}）" '[ "$left" = 10 ] && [ -d $N/ios-arm64-0000000000000010 ] && [ ! -e $N/ios-arm64-0000000000000011 ] && [ ! -e $N/ios-arm64-0000000000000012 ]'
# 预编壳缓存 cache/shell/<壳编号>/（pack/ipa.sh 用时 touch；11-04 全外置）：24 小时没用的删、30 分钟内用过的留；出到一半的 .tmp.* 2 小时没动删；超过 6 份删最久没用的
age() { python3 -c "import os,sys,time;t=time.time()-int(sys.argv[2]);os.utime(sys.argv[1],(t,t))" "$1" "$2"; }
mk; N=$T/run/cache/shell; mkdir -p $N/old1 $N/now2 $N/hr3 $N/.tmp.x.999999 $N/.tmp.y.1; age $N/old1 90000; age $N/hr3 7200; age $N/.tmp.x.999999 10800; age $N/.tmp.y.1 600; touch $N/now2
o=$(S2A_RUN=$T/run bash $H/tools/gc.sh 2>&1)
ck "壳缓存：一天没用的删、刚用的与 2 小时前用的留；3 小时没动的 .tmp 删、10 分钟前的 .tmp 留" '[ ! -e $N/old1 ] && [ -d $N/now2 ] && [ -d $N/hr3 ] && [ ! -e $N/.tmp.x.999999 ] && [ -d $N/.tmp.y.1 ]'
mk; N=$T/run/cache/shell; mkdir -p $N/old1 $N/now2; age $N/old1 90000; touch $N/now2 $N/.old1.toolchain $N/.now2.toolchain $N/.gone3.toolchain
o=$(S2A_RUN=$T/run bash $H/tools/gc.sh 2>&1)
ck "壳旁工具链记录（审计 #1534 P1-107）：壳删了 / 壳早没了的记录删，壳还在的留" '[ ! -e $N/.old1.toolchain ] && [ ! -e $N/.gone3.toolchain ] && [ -f $N/.now2.toolchain ] && [ -d $N/now2 ]'
mk; N=$T/run/cache/shell; mkdir -p $N; for i in 1 2 3 4 5 6 7 8; do mkdir -p $N/s$i; age $N/s$i $((3600 + 60 * i)); done; touch $N/s8
o=$(S2A_RUN=$T/run bash $H/tools/gc.sh 2>&1); left=$(ls $N | grep -c '^s')
ck "壳缓存 8 份都在一天内：留 6 份（刚用过的 s8 + 最近的 s1–s5；删最久没用的 s6、s7）（剩 ${left}）" '[ "$left" = 6 ] && [ -d $N/s8 ] && [ -d $N/s1 ] && [ -d $N/s5 ] && [ ! -e $N/s6 ] && [ ! -e $N/s7 ]'
# 门禁 iOS 编译的按树目录 gate_ios/<树号>/：25 小时没用的删，刚用过的留，持锁（正在编）的即使旧也留
mk; G=$T/run/gate_ios; mkdir -p $G/aaaaaaaaaaaa/src $G/bbbbbbbbbbbb/src $G/cccccccccccc/src.lock; for x in $G/aaaaaaaaaaaa $G/cccccccccccc; do python3 -c "import os,sys,time;t=time.time()-90000;os.utime(sys.argv[1],(t,t))" $x; done
o=$(S2A_RUN=$T/run bash $H/tools/gc.sh 2>&1)
ck "门禁按树目录：旧的删、新的留、持锁的留" '[ ! -e $G/aaaaaaaaaaaa ] && [ -d $G/bbbbbbbbbbbb ] && [ -d $G/cccccccccccc ]'
# gate_ios 新规则（10-21 晚总指挥）：留最近 2 小时用过的、最多 8 份、按最久没用先删；持锁的不动
#   10 份 2 小时内用过（第 1 份最新）→ 删第 9、10 份；3 小时前用过的 old 删、3 小时前用过但持锁的 lk 留
mk; G=$T/run/gate_ios; mkdir -p $G; for i in $(seq 1 10); do d=$G/n$(printf %02d $i); mkdir -p $d/src; python3 -c "import os,sys,time;t=time.time()-60*int(sys.argv[2]);os.utime(sys.argv[1],(t,t))" $d $i; done
mkdir -p $G/old/src $G/lk/src.lock; for d in $G/old $G/lk; do python3 -c "import os,sys,time;t=time.time()-10800;os.utime(sys.argv[1],(t,t))" $d; done
S2A_RUN=$T/run bash $H/tools/gc.sh > /dev/null 2>&1; left=$(ls $G | tr '\n' ' ')
ck "gate_ios：留最新 8 份 n01–n08、持锁的 lk，删 n09 n10 与 3 小时没用的 old（剩 ${left}）" '[ "$left" = "lk n01 n02 n03 n04 n05 n06 n07 n08 " ]'
# 10-21 扩范围：私有根 6 小时闲整删 / 在用的每款留现行 + 上一版；各线私有区每项 6 小时闲删；已合入干净闲 2 小时的工作树删、留着的树 build/ 6 小时闲删；.keep 一律不动
mk; P=$T/run/roots_priv; mkdir -p $P/old1/acnh@x $P/kept/acnh@x $P/live; touch $P/kept/.keep
for v in v1 v2 v3; do mkdir -p $P/live/acnh@$v/romfs; echo $v > $P/live/acnh@$v/romfs/f; done; ln -s acnh@v3 $P/live/acnh@现行
old $P/old1 $P/kept $P/live/acnh@v1 $P/live/acnh@v2; touch -t 202610200101 $P/live/acnh@v2; touch $P/live/acnh@v3/romfs/f
Z=$T/run/perf_wip; mkdir -p $Z/x/a $Z/y $Z/z $T/run/wip/画幅/k; echo 1 > $Z/x/a/f; echo 1 > $Z/y/f; echo 1 > $Z/z/f; touch $Z/z/.keep; echo 1 > $T/run/wip/画幅/k/f; echo 1 > $Z/old.log
old $Z/x $Z/z $T/run/wip/画幅/k $Z/old.log
R=$T/repo; git init -q --bare $T/origin.git; git clone -q $T/origin.git $R 2> /dev/null; git -C $R config user.email t@t; git -C $R config user.name t
echo build/ > $R/.gitignore; git -C $R add -A; git -C $R commit -qm i; git -C $R branch -M main; git -C $R push -q origin main; git -C $R fetch -q origin
mkdir -p $T/wt; for w in wA wB wC wD wE gfx-other gfx-ok gfx-young; do git -C $R worktree add -q $T/wt/$( case $w in (w?) echo test-$w;; (*) echo $w;; esac ) origin/main 2> /dev/null; done
(cd $T/wt/test-wC && echo c > c && git add c && git -c user.email=t@t -c user.name=t commit -qm c); mkdir -p $T/wt/test-wC/build $T/wt/test-wA/build; echo b > $T/wt/test-wC/build/o; echo b > $T/wt/test-wA/build/o
for w in test-wA gfx-other gfx-ok; do (cd $T/wt/$w && echo "$w" > "own_$w" && git add "own_$w" && git -c user.email=t@t -c user.name=t commit -qm "$w 自己的提交"); git -C $R merge -q --no-edit "$(git -C $T/wt/$w rev-parse HEAD)"; done; git -C $R push -q origin main; git -C $R fetch -q origin   # 11-05：真合入 = 有自己的提交且已进 main
echo 脏 > $T/wt/test-wD/dirty; touch $T/wt/test-wE/.keep; touch $T/wt/gfx-ok/.gc_ok; mkdir -p $T/wt/.train; old $T/wt/gfx-other $T/wt/gfx-ok $T/wt/test-wA $T/wt/test-wC $T/wt/test-wD $T/wt/test-wE; touch $T/wt/test-wB/.gitignore
python3 -c "import os,sys,time;t=time.time()-3*3600
for r,ds,fs in os.walk(sys.argv[1]):
    for n in ds+fs: os.utime(os.path.join(r,n),(t,t))
os.utime(sys.argv[1],(t,t))" $T/wt/gfx-young   # 别的线、已合入干净、3 小时没动（< 6 小时）
o=$(S2A_RUN=$T/run bash $H/tools/gc.sh 2>&1)
ck "私有根：6 小时闲整删、带 .keep 不删；在用的根每款留现行 v3 + 上一版 v2、删 v1" '[ ! -e $P/old1 ] && [ -d $P/kept ] && [ ! -e $P/live/acnh@v1 ] && [ -d $P/live/acnh@v2 ] && [ -d $P/live/acnh@v3 ]'
ck "私有区：perf_wip 闲项 x / 散文件删、新项 y 留、带 .keep 的 z 留；wip/画幅/k 闲删" '[ ! -e $Z/x ] && [ ! -e $Z/old.log ] && [ -d $Z/y ] && [ -d $Z/z ] && [ ! -e $T/run/wip/画幅/k ]'
ck "工作树（10-29 起别的线的也收）：别的线已合入干净几天没动的 gfx-other 删、3 小时没动的 gfx-young 留（< 6 小时）；放了 .gc_ok 的 gfx-ok 删" '[ ! -e $T/wt/gfx-other ] && [ -d $T/wt/gfx-young ] && [ ! -e $T/wt/gfx-ok ]'
# 10-29 护栏：别的线没合入的树连 build/ 也不碰；单测覆盖了 S2A_WT_ROOT 而没给 S2A_GC_WT_OTHERS 时不扫 $HOME/.s2arm/wt（绝不碰真工作树）
git -C $R worktree add -q $T/wt/gfx-wip origin/main 2> /dev/null; (cd $T/wt/gfx-wip && echo w > w && git add w && git -c user.email=t@t -c user.name=t commit -qm w); mkdir -p $T/wt/gfx-wip/build; echo b > $T/wt/gfx-wip/build/o
mkdir -p $T/fh/.s2arm/wt; git -C $R worktree add -q $T/fh/.s2arm/wt/other-old origin/main 2> /dev/null; old $T/wt/gfx-wip $T/fh/.s2arm/wt/other-old
HOME=$T/fh S2A_RUN=$T/run bash $H/tools/gc.sh > /dev/null 2>&1
ck "护栏：别的线没合入的 gfx-wip 和它的 build/ 都留；假家目录 ~/.s2arm/wt 下已合入干净几天没动的 other-old 不扫、留" '[ -d $T/wt/gfx-wip/build ] && [ -d $T/fh/.s2arm/wt/other-old ]'
ck "工作树：已合入干净闲的 wA 删（git 也不再登记）；刚动过的 wB、脏的 wD、带 .keep 的 wE、. 开头的留；没合入的 wC 留但闲 build/ 删" '[ ! -e $T/wt/test-wA ] && ! git -C $R worktree list | grep -q "/test-wA " && [ -d $T/wt/test-wB ] && [ -d $T/wt/test-wD ] && [ -d $T/wt/test-wE ] && [ -d $T/wt/.train ] && [ -d $T/wt/test-wC ] && [ ! -e $T/wt/test-wC/build ] && grep -q "删 $T/wt/test-wA（工作树" <<< "$o"'
# 硬保护：调度局目录每款只留最近 10 绿；被记分板「局目录」列 / milestones 里文件引用的旧局不删
# 包快照 pkgstore（10-21 总指挥）：每款留现行登记包 + sched.sh refs（在排作业引用的、每台测试机上各应用身份现装的）+ 其余最近 1 个旧包；其余删
#   acnh 五份：r 登记、q 在排、d 测试机1 上现装的（那局装了包；之后测试机1 又跑过 mk8d，10-22 总指挥「测试机上正装着给 jhz 用的包」不能删）、o1 较新的旧包、o2 → 只删 o2
#   d 是五份里最旧的：按「其余留最近 1 个」它该删，只有「现装」引用保得住它（原规则只看每台最近一局 → 最近一局是 mk8d，d 被删）
mk; P=$T/run/sched/pkgstore; J=$T/run/sched/jobs; mkdir -p $T/run/sched/pkgs $T/run/sched/queue $J/acnh_1021000000_1/out_1 $J/mk8d_1021000100_1/out_1; for x in r q d o1 o2; do mkdir -p $P/acnh-$x; echo $x > $P/acnh-$x/f; done
k=0; for x in d o2 o1 q r; do k=$((k + 1)); touch -t 20261021010$k $P/acnh-$x; done
printf 'PKG=%q\n' $P/acnh-r > $T/run/sched/pkgs/acnh.env; printf 'PKG=%q\n' $P/acnh-q > $T/run/sched/queue/5_1_1.job
printf 'PKG=%q\nCOMMIT=d\n' $P/acnh-d > $J/acnh_1021000000_1.job; echo RESULT=done > $J/acnh_1021000000_1/r.txt; printf 'DEV=1\nBUNDLE=io.s2arm.acnh\n' > $J/acnh_1021000000_1/job.env
echo '[01:00:05] 装包 acnh.ipa（d）' > $J/acnh_1021000000_1/out_1/run.log; touch -t 202610210100 $J/acnh_1021000000_1.job
printf 'PKG=%q\nCOMMIT=m\n' $P/mk8d-m > $J/mk8d_1021000100_1.job; echo RESULT=done > $J/mk8d_1021000100_1/r.txt; printf 'DEV=1\nBUNDLE=io.s2arm.mk8d\n' > $J/mk8d_1021000100_1/job.env
echo '[01:01:05] 装包：机上已是同一包（m），不重装' > $J/mk8d_1021000100_1/out_1/run.log; touch -t 202610210101 $J/mk8d_1021000100_1.job
o=$(S2A_RUN=$T/run bash $H/tools/gc.sh 2>&1); left=$(ls $P | tr '\n' ' ')
ck "pkgstore：留登记 r、在排 q、测试机1 现装 d（最近一局是 mk8d 也留）、最近旧包 o1，删 o2（剩 ${left}）；现装表补出两台 × 身份" '[ "$left" = "acnh-d acnh-o1 acnh-q acnh-r " ] && grep -q "删 .*/acnh-o2$" <<< "$o" && [ -f $T/run/sched/installed/1_io.s2arm.acnh ] && [ -f $T/run/sched/installed/1_io.s2arm.mk8d ]'
mk; J=$T/run/sched/jobs; for i in $(seq 10 23); do d=$J/acnh_10210000${i}_1; mkdir -p $d/out_1; echo RESULT=done > $d/r.txt; touch -t 2026102000$i $d; done
printf 'h\th\th\th\th\th\th\th\th\th\th\n%s\n' "$(printf 'x\t%.0s' 1 2 3 4 5 6 7 8 9 10)$J/acnh_1021000010_1/out_1" > $T/board.tsv
mkdir -p $T/run/milestones/M9; echo "证据：截图与 $J/acnh_1021000011_1/out_1/host.log" > $T/run/milestones/M9/note.md
o=$(S2A_RUN=$T/run bash $H/tools/gc.sh 2>&1)
ck "调度局：14 个绿局留最近 10 个；最旧 4 个里被记分板引用的 _10、被 milestones 引用的 _11 留（打「受保护」），_12 _13 删" '[ -d $J/acnh_1021000010_1 ] && [ -d $J/acnh_1021000011_1 ] && [ ! -e $J/acnh_1021000012_1 ] && [ ! -e $J/acnh_1021000013_1 ] && [ -d $J/acnh_1021000014_1 ] && grep -q "受保护，不删 $J/acnh_1021000010_1" <<< "$o" && grep -q "受保护，不删 $J/acnh_1021000011_1" <<< "$o"'
# 按盘余量回收（10-22 总指挥）：剩余 < 门槛才动；先删没登记 / 没作业引用的包快照，再按最近使用时间从旧到新删管线归档缓存到补够缺口，1 小时内用过的不动。
#   手算期望：缓存 4 个各 64 KB 的条目，最近使用 c1 30 小时前、c2 20 小时前、c3 10 小时前、c4 10 分钟前；缺口 100 KB → 删 c1、c2（128 KB ≥ 100）、留 c3 c4
rm -rf $T/run; mkdir -p $T/run/sched/pkgstore/acnh-old/pack $T/run/sched/pkgstore/acnh-cur/pack $T/run/sched/pkgs $T/run/sched/queue $T/pc
printf 'PKG=%q\nCOMMIT=x\n' "$T/run/sched/pkgstore/acnh-cur" > $T/run/sched/pkgs/acnh.env
python3 - $T/pc <<'PY'
import os, sys, time
now = time.time()
for n, h in (('c1', 30), ('c2', 20), ('c3', 10), ('c4', 1 / 6)):
    p = os.path.join(sys.argv[1], n); open(p, 'wb').write(os.urandom(64 * 1024)); os.utime(p, (now - h * 3600, now - h * 3600))
PY
o1=$(S2A_RUN=$T/run GAL_DL_CACHE=$T/pc S2A_GC_FREE_GB=110 bash $H/tools/gc.sh 2>&1)
ck "剩 110 GB（≥ 门槛 100）：不触发，包快照与缓存都不动" '! grep -q "回收到" <<< "$o1" && [ -d $T/run/sched/pkgstore/acnh-old ] && [ "$(ls $T/pc | wc -l | tr -d " ")" = 4 ]'
o2=$(S2A_RUN=$T/run GAL_DL_CACHE=$T/pc S2A_GC_FREE_GB=50 S2A_GC_NEED_KB=100 bash $H/tools/gc.sh 2>&1)
ck "剩 50 GB、缺口 100 KB：删没登记的 acnh-old、留登记的 acnh-cur；gal_dl_cache 删最旧 c1 c2（各独占 64 KB，够 100 KB）、留 c3 和 1 小时内的 c4（$(ls $T/pc | tr '\n' ' ')）" '[ ! -e $T/run/sched/pkgstore/acnh-old ] && [ -d $T/run/sched/pkgstore/acnh-cur ] && [ "$(ls $T/pc | tr "\n" " ")" = "c3 c4 " ] && grep -q "着色器中间缓存删 2 条" <<< "$o2"'
# 同时只跑一份（10-22 两份 gc 并发截断 gc_last.log）：锁 <运行目录>/.gc.lock 被活进程持有 → 打「另一份 gc 在跑」、什么都不删；持有者已死 → 收回照跑、跑完锁收掉
rm -rf $T/run; mkdir -p $T/run/sched/pkgstore/acnh-old $T/run/sched/pkgs $T/run/sched/queue
sleep 30 & LIVE2=$!; mkdir $T/run/.gc.lock; echo $LIVE2 > $T/run/.gc.lock/pid
o=$(S2A_RUN=$T/run S2A_GC_FREE_GB=50 S2A_GC_NEED_KB=1 bash $H/tools/gc.sh 2>&1); kill $LIVE2 2> /dev/null; wait $LIVE2 2> /dev/null
ck "锁被活进程持有：打「另一份 gc 在跑」、没登记的包快照照留、锁还在（$(head -1 <<< "$o")）" 'grep -q "^gc：另一份 gc 在跑（pid ${LIVE2}）" <<< "$o" && [ -d $T/run/sched/pkgstore/acnh-old ] && [ -d $T/run/.gc.lock ]'
o=$(S2A_RUN=$T/run S2A_GC_FREE_GB=50 S2A_GC_NEED_KB=1 bash $H/tools/gc.sh 2>&1)
ck "持有者已死：收回锁照跑（没登记的包快照删掉）、跑完锁收掉" '! grep -q "另一份 gc" <<< "$o" && [ ! -e $T/run/sched/pkgstore/acnh-old ] && [ ! -e $T/run/.gc.lock ]'
# 产物根 .tmp 持有者（10-23：排烘焙道 2 小时 10 分钟的 .tmp 被按时间删掉、出包中途失败）：都拨到 3 小时前——
#   活 = 持有者记录是活进程（同 pid、同起始时间）→ 留并打「在用，不删」；死 = 记录里的进程已退出 → 删；旧 = 没有记录 → 按时间兜底删；
#   复用 = pid 活着但起始时间对不上（pid 被复用）→ 当死删
mk; R=$T/run/roots_priv/x; mkdir -p $R/acnh@live.tmp $R/acnh@dead.tmp $R/acnh@old.tmp $R/acnh@reuse.tmp
sleep 60 & LP=$!; sleep 0.2; ( exit 0 ) & DP=$!; wait $DP
echo "$LP $(ps -o lstart= -p $LP)" > $R/acnh@live.tmp/.root_pid   # 原样写（含多余空白）：判活按规整后的比
echo "$DP Thu Jan  1 00:00:00 2026" > $R/acnh@dead.tmp/.root_pid
echo "$LP Thu Jan  1 00:00:00 2026" > $R/acnh@reuse.tmp/.root_pid
mkdir -p $R/acnh@live2.tmp; echo "$LP $(ps -o lstart= -p $LP | sed 's/ /  /2')" > $R/acnh@live2.tmp/.root_pid   # 个位数日期 ps 出双空格（如「Oct  3」）：月日之间人为加一个空格，也要认
for x in $R/*.tmp; do python3 -c "import os,sys,time;t=time.time()-10800;os.utime(sys.argv[1],(t,t))" $x; done
o=$(S2A_RUN=$T/run bash $H/tools/gc.sh 2>&1); kill $LP 2> /dev/null; wait $LP 2> /dev/null
ck "超时 .tmp：持有者活着留（打「在用，不删」）、持有者死了删、无记录按时间删、pid 复用当死删" '[ -d $R/acnh@live.tmp ] && [ -d $R/acnh@live2.tmp ] && grep -q "^在用，不删 .*acnh@live.tmp" <<< "$o" && [ ! -e $R/acnh@dead.tmp ] && [ ! -e $R/acnh@old.tmp ] && [ ! -e $R/acnh@reuse.tmp ]'
# root_begin 写持有者 = 调用脚本自己（$(…) 里 $$ 不变）、起始时间对得上；root_commit 不把记录带进已提交版本
rm -rf $T/run; mkdir -p $T/run/roots_priv/y; o=$(cd $T && S2A_ROOTS=$T/run/roots_priv/y bash -c 'source '"$H"'/pack/roots.sh; w=$(root_begin acnh v1) || exit 9; read -r p t < "$w/.root_pid"; [ "$p" = $$ ] && root_tmp_live "$w" && echo LIVE; root_commit acnh v1 > /dev/null 2>&1; ls -A "$S2A_ROOTS/acnh@v1"' 2>&1)
ck "root_begin 记的持有者是调用脚本、判活成立；root_commit 后已提交版本里没有 .root_pid（${o//$'\n'/ }）" 'grep -q "^LIVE$" <<< "$o" && ! grep -q "\.root_pid" <<< "$o"'
# 局目录瘦身（10-23 总指挥：读数已进记分板的局删可再生大文件、留小证据）：12 小时前的 shcache_rt / framecap.bin 删、gal.rec 24 小时内留、host.log 留、push.tar 直接删；
#   实验局 .keep 超过 24 小时同样瘦身、1 小时内的不动；验收 .keep（内容不含「的实验局」）不动
ago() { python3 -c "import os,sys,time;t=time.time()-float(sys.argv[1])*3600;[os.utime(f,(t,t)) for f in sys.argv[2:]]" "$@"; }
big() { mkdir -p "$(dirname $1)"; dd if=/dev/zero of=$1 bs=1048576 count=2 2> /dev/null; }
rm -rf $T/run; J=$T/run/sched/jobs; mkdir -p $T/run/sched/pkgs
# 局的年龄 = 收局（局目录 r.txt 写下 RESULT=）至今（10-26 起；之前按各文件 mtime，cp -c 进来的存档带原件旧时刻、刚交单就被删）
fin() { echo RESULT=done > "$1/r.txt"; ago "$2" "$1/r.txt"; }
A=$J/acnh_1023000001_1/out_1; A49=$J/acnh_1023000009_1/out_1; B=$J/acnh_1023000002_1/out_1; C=$J/acnh_1023000003_1/out_1; D=$J/acnh_1023000004_1/out_1
for d in $A $B $C $D; do big $d/shcache_rt/guest.data; big $d/framecap.bin; big $d/host.log; done; big $A/gal.rec; big $A/push.tar;
for f in mark end; do big $A49/screen/$f.png; done   # 截图瘦身（10-24）：收局 48 小时以上才删收局截图，MARK 截图不删
for d in $A $B $C $D; do fin ${d%/out_1} 13; done; fin ${A49%/out_1} 49
A1=$J/acnh_1023000010_1; for f in push.tar g.ipa save/s.bin shcache_rt/guest.data gal.rec; do big $A1/$f; done; ago 150 $A1/save/s.bin $A1/g.ipa; fin $A1 1
echo "测试出包 的实验局：结论回收后 tools/sched.sh unkeep x" > ${B%/out_1}/.keep; ago 25 ${B%/out_1}/.keep; echo "验收批" > ${C%/out_1}/.keep; ago 25 ${C%/out_1}/.keep; echo "帧率能耗 的实验局：结论回收后 x" > ${D%/out_1}/.keep
# 10-26 运维线：刚交单、还没收局的局，存档 / ipa / push.tar 是 cp -c 克隆进来的（带原件 10-20 的旧 mtime）→ 一个都不碰
P2=$J/mhrise_1026095152_1; mkdir -p $P2/save/account; big $P2/save/account/data001Slot.bin; big $P2/push.tar; big $P2/g.ipa; ago 150 $P2/save/account/data001Slot.bin $P2/push.tar $P2/g.ipa
o=$(S2A_RUN=$T/run bash $H/tools/gc.sh 2>&1)
ck "瘦身：收局 13 小时的局删 shcache_rt / framecap / push.tar / gal.rec（同时满 12 小时白名单），留 host.log" '[ ! -e $A/shcache_rt/guest.data ] && [ ! -e $A/framecap.bin ] && [ ! -e $A/push.tar ] && [ ! -e $A/gal.rec ] && [ -s $A/host.log ]'
ck "瘦身：刚收局 1 小时的局只删收局残留 push.tar / ipa，存档副本、shcache_rt、gal.rec 留" '[ ! -e $A1/push.tar ] && [ ! -e $A1/g.ipa ] && [ -s $A1/save/s.bin ] && [ -s $A1/shcache_rt/guest.data ] && [ -s $A1/gal.rec ]'
ck "瘦身：25 小时前的实验局 .keep 照样瘦身（framecap / shcache_rt 删、host.log 留）" '[ ! -e $B/framecap.bin ] && [ ! -e $B/shcache_rt/guest.data ] && [ -s $B/host.log ]'
ck "截图瘦身：收局 49 小时的局删 end.png，mark.png 不删" '[ ! -e $A49/screen/end.png ] && [ -s $A49/screen/mark.png ]'
ck "瘦身（10-26）：没收局的局，cp -c 带旧 mtime 的存档 / push.tar / ipa 都不删（$(grep -c mhrise <<< "$o") 行提到它）" '[ -s $P2/save/account/data001Slot.bin ] && [ -s $P2/push.tar ] && [ -s $P2/g.ipa ]'
ck "瘦身：验收 .keep 不动、1 小时内的实验局 .keep 不动" '[ -s $C/framecap.bin ] && [ -s $C/shcache_rt/guest.data ] && [ -s $D/framecap.bin ] && [ -s $D/shcache_rt/guest.data ]'
# 12 小时白名单瘦身（10-24 总指挥，24 → 12 小时）：25 小时前的局，>256 KB 的只留 frames.tsv / host.log / screen/mark.png / shots_ap/ap_mark.png，其余删；小文件 r.txt 留；
#   验收 .keep 的同龄局整局不动；13 小时的局同样瘦身；6 小时的局不受这条影响
E=$J/botw_1023000005_1/out_1; F=$J/botw_1023000006_1/out_1; G2=$J/botw_1023000007_1/out_1
for d in $E $F $G2; do for f in gal.rec pkg_shcache/guest.data screen/end.png screen/mark.png shots_ap/ap_mark.png shots_ap/ap_mid.png frames.tsv host.log r.index; do big $d/$f; done; echo RESULT=done > ${d%/out_1}/r.txt; done   # r.txt 在局目录根（sched.sh 写 $J/r.txt）
echo "验收批" > ${F%/out_1}/.keep
for d in $E $F; do find ${d%/out_1} -exec python3 -c "import os,sys,time;t=time.time()-25*3600;os.utime(sys.argv[1],(t,t))" {} \; ; done
find ${G2%/out_1} -exec python3 -c "import os,sys,time;t=time.time()-6*3600;os.utime(sys.argv[1],(t,t))" {} \;
H2=$J/botw_1023000008_1/out_1; for f in gal.rec screen/mark.png; do big $H2/$f; done; echo RESULT=done > ${H2%/out_1}/r.txt; find ${H2%/out_1} -exec python3 -c "import os,sys,time;t=time.time()-13*3600;os.utime(sys.argv[1],(t,t))" {} \;
o=$(S2A_RUN=$T/run bash $H/tools/gc.sh 2>&1)
ck "12 小时白名单：25 小时前的局删 gal.rec / pkg_shcache / end.png / ap_mid.png / r.index，有 ap_mark.png 时重复的 screen/mark.png 也删，留 frames.tsv / host.log / ap_mark.png / r.txt" '[ ! -e $E/gal.rec ] && [ ! -e $E/pkg_shcache/guest.data ] && [ ! -e $E/screen/end.png ] && [ ! -e $E/shots_ap/ap_mid.png ] && [ ! -e $E/r.index ] && [ -s $E/frames.tsv ] && [ -s $E/host.log ] && [ ! -e $E/screen/mark.png ] && [ -s $E/shots_ap/ap_mark.png ] && [ -s ${E%/out_1}/r.txt ]'
ck "12 小时白名单：13 小时的局 gal.rec 删、没有 ap_mark.png 的 screen/mark.png 留（唯一 MARK 证据）" '[ ! -e $H2/gal.rec ] && [ -s $H2/screen/mark.png ]'
ck "12 小时白名单：同龄的验收 .keep 局整局不动；6 小时的局 gal.rec / ap_mid 留（白名单只管 12 小时以上）" '[ -s $F/gal.rec ] && [ -s $F/r.index ] && [ -s $G2/gal.rec ] && [ -s $G2/shots_ap/ap_mid.png ]'
# 翻译缓存每程序号留 2 份、1 小时内动过的不删；宽屏门禁 rec/ 2 小时没动删、lib/ 留最近 2 键（10-24）
rm -rf $T/run; mkdir -p $T/run/sched/pkgs; BC=$T/run/cache/bake; WG=$T/run/cache/widen_gate
for k in a1 a2 a3 a4; do mkdir -p $BC/0100000000001111-$k; echo x > $BC/0100000000001111-$k/f; done; mkdir -p $BC/0100000000002222-b1 && echo x > $BC/0100000000002222-b1/f
ago 5 $BC/0100000000001111-a1 $BC/0100000000001111-a2; ago 4 $BC/0100000000001111-a3; ago 0.2 $BC/0100000000001111-a4; ago 6 $BC/0100000000002222-b1
mkdir -p $WG/rec $WG/lib/k1 $WG/lib/k2 $WG/lib/k3 $WG/lib/k4; echo x > $WG/rec/old.rec; echo x > $WG/rec/new.rec; ago 3 $WG/rec/old.rec
for k in k1 k2 k3 k4; do echo x > $WG/lib/$k/l; done; ago 9 $WG/lib/k1/l $WG/lib/k1 $WG/lib/k2/l $WG/lib/k2; ago 8 $WG/lib/k3/l $WG/lib/k3; ago 0.1 $WG/lib/k4/l $WG/lib/k4
o=$(S2A_RUN=$T/run bash $H/tools/gc.sh 2>&1)
ck "翻译缓存：1111 留最近 2 份（a4 新、a3），删 a1 / a2；只有 1 份的 2222 不动" '[ -d $BC/0100000000001111-a4 ] && [ -d $BC/0100000000001111-a3 ] && [ ! -e $BC/0100000000001111-a1 ] && [ ! -e $BC/0100000000001111-a2 ] && [ -d $BC/0100000000002222-b1 ]'
ck "宽屏门禁：rec 3 小时前的删、新的留；lib 留最近 2 键（k4、k3），删 k1 / k2" '[ ! -e $WG/rec/old.rec ] && [ -s $WG/rec/new.rec ] && [ -d $WG/lib/k4 ] && [ -d $WG/lib/k3 ] && [ ! -e $WG/lib/k1 ] && [ ! -e $WG/lib/k2 ]'
# 盘低回收（10-23 总指挥）：只被「机上装着」保住的快照删（sched.sh refs 硬引用不算 installed/），登记的留
rm -rf $T/run; mkdir -p $T/run/sched/pkgstore/acnh-inst/pack $T/run/sched/pkgstore/acnh-cur/pack $T/run/sched/pkgs $T/run/sched/queue $T/run/sched/installed $T/pcx; : > $T/run/sched/installed/.scanned
printf 'PKG=%q\nCOMMIT=x\n' "$T/run/sched/pkgstore/acnh-cur" > $T/run/sched/pkgs/acnh.env; printf 'PKG=%q\nCOMMIT=y\nJOB=j\n' "$T/run/sched/pkgstore/acnh-inst" > $T/run/sched/installed/1_io.s2arm-exp.acnh
o=$(S2A_RUN=$T/run GAL_PSO_CACHE=$T/pcx S2A_GC_FREE_GB=999 bash $H/tools/gc.sh 2>&1)
ck "盘充足：机上装着的 acnh-inst 留（原规则）" '[ -d $T/run/sched/pkgstore/acnh-inst ]'
o=$(S2A_RUN=$T/run GAL_PSO_CACHE=$T/pcx S2A_GC_FREE_GB=50 S2A_GC_NEED_KB=100 bash $H/tools/gc.sh 2>&1)
ck "盘低（50 GB）：只被机上装着保住的 acnh-inst 删、登记的 acnh-cur 留" '[ ! -e $T/run/sched/pkgstore/acnh-inst ] && [ -d $T/run/sched/pkgstore/acnh-cur ]'
mkdir -p $T/run/sched/pkgstore/acnh-fb/pack $T/run/sched/fallback; printf 'PKG=%q\nCOMMIT=z\n' "$T/run/sched/pkgstore/acnh-fb" > $T/run/sched/fallback/acnh.env
o=$(S2A_RUN=$T/run GAL_PSO_CACHE=$T/pcx S2A_GC_FREE_GB=50 S2A_GC_NEED_KB=100 bash $H/tools/gc.sh 2>&1)
ck "盘低（50 GB）：回退包 fallback/acnh.env 指向的 acnh-fb 不删（10-23 总指挥：回退包算硬引用）" '[ -d $T/run/sched/pkgstore/acnh-fb ]'
# 着色器中间缓存常规规则（10-23 画面·着色器线交）：超过 72 小时删；air 的 ios/ 下不在 u?? 合编子目录的逐支条目超过 6 小时删、u01 里的同龄条目留；1 小时内的不动；
#   管线归档缓存 gal_pso_cache 盘低也不再删（独占 0）；烘焙道有活持有者照清（cache-touch 起在用条目 1 小时内被刷新，按「1 小时内动过的不动」护住）
rm -rf $T/run $T/air $T/pcz; mkdir -p $T/run $T/air/ios/u01 $T/air/macos $T/pcz; python3 - $T/air $T/pcz <<'PY'
import os, sys, time
now = time.time(); a, pz = sys.argv[1], sys.argv[2]
for rel, h in (('ios/old80', 80), ('ios/br7', 7), ('ios/u01/u7', 7), ('macos/m7', 7), ('ios/new', 0.1)):
    p = os.path.join(a, rel); open(p, 'wb').write(os.urandom(8192)); os.utime(p, (now - h * 3600, now - h * 3600))
p = os.path.join(pz, 'z30'); open(p, 'wb').write(os.urandom(8192)); os.utime(p, (now - 30 * 3600, now - 30 * 3600))
PY
o=$(S2A_RUN=$T/run GAL_AIR_CACHE=$T/air GAL_PSO_CACHE=$T/pcz S2A_GC_FREE_GB=50 S2A_GC_NEED_KB=1 bash $H/tools/gc.sh 2>&1)
ck "着色器中间缓存：80 小时的删、ios 逐支 7 小时删；u01 里 7 小时留、macos 7 小时留（缺口 1 KB 已被前两条补够）、刚写的留；pso 缓存 30 小时的盘低也不删" '[ ! -e $T/air/ios/old80 ] && [ ! -e $T/air/ios/br7 ] && [ -e $T/air/ios/u01/u7 ] && [ -e $T/air/macos/m7 ] && [ -e $T/air/ios/new ] && [ -e $T/pcz/z30 ] && grep -q "着色器中间缓存删 2 条" <<< "$o"'
touch -t 202610100000 $T/air/macos/m7; echo hot > $T/air/macos/hot
o=$(S2A_RUN=$T/run GAL_AIR_CACHE=$T/air bash $H/tools/gc.sh 2>&1)
ck "着色器中间缓存按时间清：13 天前的 m7 删；刚命中（刚刷新时间）的 hot 留" '[ ! -e $T/air/macos/m7 ] && [ -e $T/air/macos/hot ] && ! grep -q "本次不清" <<< "$o"'

# 远端假家目录按最后使用回收（10-25 mini 盘剩 18 GB、gc 删 0 项）：LOW 60 / HIGH 80，假 df = 50 + 10 × 已删的候选数
#   候选（最后使用）：dlink/in_link 派生 6 小时（dlink 里另有同步镜像 direct 2 小时，所以 dlink 往下拆）、roots/mk8d@现行 同步镜像标记 5 小时（文件本身 10 天前，按标记算）、mk8_mem/in_snap 同步 4 小时、mk8_mem/run_A 派生 3 小时、
#   roots/acnh@现行 同步 7 小时但在跑命令登记了、wire-c/x 10 分钟前；sched/ 有自己的规则不算候选
#   期望：in_link → mk8d → in_snap 删三个到 80 GB 停（acnh 在用跳过、不计数）；run_A、wire-c/x 留；不带 S2A_GC_REMOTE_ROOT（本机 gc）一个不删
rgc() { rm -rf $T/rr; RS=$T/rr/home/.s2arm/run/s2arm; mkdir -p $T/rr/wt $RS/sched/jobs $RS/roots $RS/gj_play/mk8_mem $RS/gj_play/dlink $RS/wire-c/x
  for d in roots/mk8d@现行 roots/acnh@现行 gj_play/mk8_mem/in_snap gj_play/dlink/direct; do mkdir -p $RS/$d/romfs; echo x > $RS/$d/romfs/f; old $RS/$d; echo "fp 1" > $RS/$d/.s2a_sync; done
  mkdir -p $RS/gj_play/dlink/in_link/a $RS/gj_play/mk8_mem/run_A; echo y > $RS/gj_play/dlink/in_link/a/f; echo z > $RS/gj_play/mk8_mem/run_A/f; echo w > $RS/wire-c/x/f
  ago() { python3 -c "import os,sys,time;t=time.time()-3600*float(sys.argv[1])
for p in sys.argv[2:]: os.utime(p,(t,t))" "$@"; }
  ago 6 $RS/gj_play/dlink/in_link $RS/gj_play/dlink/in_link/a $RS/gj_play/dlink/in_link/a/f; ago 5 $RS/roots/mk8d@现行/.s2a_sync; ago 4 $RS/gj_play/mk8_mem/in_snap/.s2a_sync
  ago 3 $RS/gj_play/mk8_mem/run_A $RS/gj_play/mk8_mem/run_A/f; ago 7 $RS/roots/acnh@现行/.s2a_sync; ago 2 $RS/gj_play/dlink/direct/.s2a_sync
  sleep 60 & RP=$!; echo $RP > $T/rr/wt/job1.pid; printf '.s2arm/run/s2arm/roots/acnh@现行\n\n' > $T/rr/wt/job1.uses
  FC="n=0; for d in $RS/gj_play/dlink/in_link $RS/roots/mk8d@现行 $RS/gj_play/mk8_mem/in_snap $RS/gj_play/mk8_mem/run_A $RS/wire-c/x; do [ -e \$d ] || n=\$((n + 1)); done; echo \$((50 + 10 * n))"; }
rgc; o=$(HOME=$T/rr/home S2A_RUN=$RS S2A_GC_REMOTE_ROOT=$T/rr S2A_GC_FREE_CMD="$FC" S2A_GC_FREE_GB=50 S2A_GC_LOW_GB=60 S2A_GC_HIGH_GB=80 bash $H/tools/gc.sh 2>&1); kill $RP 2>/dev/null
ck "远端回收：删 in_link、mk8d@现行、in_snap 到 80 GB 停；在跑命令登记的 acnh@现行、3 小时前的 run_A、刚用的 wire-c/x 留；sched 不动" '[ ! -e $RS/gj_play/dlink/in_link ] && [ ! -e $RS/roots/mk8d@现行 ] && [ ! -e $RS/gj_play/mk8_mem/in_snap ] && [ -d $RS/gj_play/mk8_mem/run_A ] && [ -d $RS/roots/acnh@现行 ] && [ -d $RS/wire-c/x ] && [ -d $RS/sched/jobs ] && grep -q "在用，不删 .*acnh@现行（在跑的远端命令登记了它）" <<< "$o"'
ck "远端回收：删前按最后使用从旧到新（in_link 在 mk8d 前、mk8d 在 in_snap 前）" '[ "$(grep "^删 " <<< "$o" | sed "s|.*/||" | tr "\n" " ")" = "in_link mk8d@现行 in_snap " ]'
ck "远端回收：每删一项按 df 前后记实回量（假 df 每删一项 +10 → 「这项实回 10 GB」$(grep -c "这项实回 10 GB" <<< "$o") 行）" '[ "$(grep -c "这项实回 10 GB" <<< "$o")" = 3 ]'
rgc; o=$(HOME=$T/rr/home S2A_RUN=$RS S2A_GC_FREE_CMD="$FC" S2A_GC_FREE_GB=50 S2A_GC_LOW_GB=60 S2A_GC_HIGH_GB=80 bash $H/tools/gc.sh 2>&1); kill $RP 2>/dev/null
ck "本机 gc（不带 S2A_GC_REMOTE_ROOT）：远端段不跑，五个候选都在" '[ -d $RS/gj_play/dlink/in_link ] && [ -d $RS/roots/mk8d@现行 ] && [ -d $RS/gj_play/mk8_mem/in_snap ] && ! grep -q 远端假家目录 <<< "$o"'
# 删前重核（10-29 画面线 sewant_PB：清单开头列好，删到时正在被同步 / 新命令用上，边写边删，同步报传完、romfs 没了）：
#   假 df 钩子第 3 次起（清单已列完、删第一项之前）模拟：一份同步碰了 mk8d@现行 的标记、一条新命令登记了 in_snap
#   期望：in_link 照删；mk8d「刚用过」留、in_snap「在用」留；不够 80 GB 接着删 run_A
rgc; : > $T/fcn; sleep 60 & RP2=$!
FC2="echo x >> $T/fcn; if [ \$(wc -l < $T/fcn) -ge 3 ]; then touch $RS/roots/mk8d@现行/.s2a_sync; echo $RP2 > $T/rr/wt/job2.pid; printf '.s2arm/run/s2arm/gj_play/mk8_mem/in_snap\\n' > $T/rr/wt/job2.uses; fi; $FC"
o=$(HOME=$T/rr/home S2A_RUN=$RS S2A_GC_REMOTE_ROOT=$T/rr S2A_GC_FREE_CMD="$FC2" S2A_GC_FREE_GB=50 S2A_GC_LOW_GB=60 S2A_GC_HIGH_GB=80 bash $H/tools/gc.sh 2>&1); kill $RP $RP2 2>/dev/null
ck "远端回收删前重核：列清单后被同步碰过的 mk8d@现行、新登记的 in_snap 都留；in_link、run_A 照删（$(grep -c '^删 ' <<< "$o") 删；$(grep -o '刚用过，不删[^（]*\|在用，不删[^（]*' <<< "$o" | sed 's|.*/||' | tr '\n' ' ')）" \
  '[ ! -e $RS/gj_play/dlink/in_link ] && [ -f $RS/roots/mk8d@现行/romfs/f ] && [ -f $RS/gj_play/mk8_mem/in_snap/romfs/f ] && [ ! -e $RS/gj_play/mk8_mem/run_A ] && grep -q "刚用过，不删 .*mk8d@现行" <<< "$o" && grep -q "在用，不删 .*in_snap" <<< "$o"'
# 私有根目录是空的：通配不展开，不能把字面量「roots_priv/*」记成删了一项（10-29 mini gc 日志「删 …/roots_priv/*」，被读成删了一份私有根）
rm -rf $T/rp; mkdir -p $T/rp/run/roots_priv; o=$(S2A_RUN=$T/rp/run HOME=$T/rp bash $H/tools/gc.sh 2>&1)
ck "私有根目录空：不打「删 …roots_priv/*」" '! grep -q "roots_priv/\*" <<< "$o"'
# 登记命令已退出：job1.pid 换成一个正常退出的子 shell 的 pid。不能 rgc 完立刻 kill 那个 sleep——bash 5.2 的后台子进程在 exec 前挨 TERM 会跑本单测的
#   EXIT 陷阱（rm -rf ${T}），整个临时目录被子进程删掉（10-25 并行门禁里 6 份红 5 份；独立复现 200 次 9 次）。sleep 等 gc 跑完再杀（那时早已 exec）
rgc; ( exit 0 ) & DP=$!; wait $DP; echo $DP > $T/rr/wt/job1.pid; o=$(HOME=$T/rr/home S2A_RUN=$RS S2A_GC_REMOTE_ROOT=$T/rr S2A_GC_FREE_CMD="echo 30" S2A_GC_FREE_GB=30 S2A_GC_LOW_GB=60 S2A_GC_HIGH_GB=80 bash $H/tools/gc.sh 2>&1); kill $RP 2>/dev/null
ck "删光候选还不够（假 df 恒 30）：闲的都删（含 run_A、direct、登记命令已退出的 acnh）、刚用的 wire-c/x 留，打「gc 管不到的大头」" '[ ! -e $RS/roots/acnh@现行 ] && [ ! -e $RS/gj_play/mk8_mem/run_A ] && [ ! -e $RS/gj_play/dlink/direct ] && [ -d $RS/wire-c/x ] && grep -q "^gc：盘上 gc 管不到的大头：" <<< "$o"'

# 顶层分类目录往下拆一层（10-25 Air：roots/ 整块算一个单位，里面一份刚写过，24 GB 的旧镜像跟着删不掉）：roots/ 下两份没标记的镜像，旧的（7 小时）删、新的留
rm -rf $T/rr; RS=$T/rr/home/.s2arm/run/s2arm; mkdir -p $T/rr/wt $RS/roots/acnh@现行/romfs $RS/roots/mk8d@现行/romfs; echo a > $RS/roots/acnh@现行/romfs/f; echo m > $RS/roots/mk8d@现行/romfs/f
python3 -c "import os,sys,time;t=time.time()-7*3600
for p in sys.argv[1:]: os.utime(p,(t,t))" $RS/roots/acnh@现行 $RS/roots/acnh@现行/romfs $RS/roots/acnh@现行/romfs/f
o=$(HOME=$T/rr/home S2A_RUN=$RS S2A_GC_REMOTE_ROOT=$T/rr S2A_GC_FREE_CMD="echo 30" S2A_GC_FREE_GB=30 S2A_GC_LOW_GB=60 S2A_GC_HIGH_GB=80 bash $H/tools/gc.sh 2>&1)
ck "顶层分类目录往下拆：7 小时没用的 roots/acnh@现行 删、刚写过的 roots/mk8d@现行 留" '[ ! -e $RS/roots/acnh@现行 ] && [ -d $RS/roots/mk8d@现行 ]'
# 命令行引用算在用（10-27 Air：着色器线 ssh 直起的普查不经 remote.sh 登记、当前目录也不在工作区里，gc 把它的 dcensus_r/out 当 70 分钟没用删了）：
#   7 小时没动的 dcensus_r/out 被一个只在命令行里带着它路径的进程引用 → 留、打「在用，不删」；同样旧、没人引用的 dcensus_r/old 照删
rm -rf $T/rr; RS=$T/rr/home/.s2arm/run/s2arm; mkdir -p $T/rr/wt $RS/dcensus_r/out $RS/dcensus_r/old; echo o > $RS/dcensus_r/out/f; echo d > $RS/dcensus_r/old/f
python3 -c "import os,sys,time;t=time.time()-7*3600
for p in sys.argv[1:]: os.utime(p,(t,t))" $RS/dcensus_r $RS/dcensus_r/out $RS/dcensus_r/out/f $RS/dcensus_r/old $RS/dcensus_r/old/f
# 按事件等假普查进程 exec 完、命令行带上 out 路径（10-29 列车线：mini 高负载误红类——原先固定睡 0.3 秒，没 exec 前命令行是本单测的、out 被当没人用删掉），上限 60 秒
( exec -a "dcensus.sh $RS/dcensus_r/out" sleep 60 ) & CP=$!; for i in $(seq 1 600); do [[ "$(ps -o args= -p $CP 2> /dev/null)" == "dcensus.sh $RS/dcensus_r/out"* ]] && break; sleep 0.1; done
o=$(HOME=$T/rr/home S2A_RUN=$RS S2A_GC_REMOTE_ROOT=$T/rr S2A_GC_FREE_CMD="echo 30" S2A_GC_FREE_GB=30 S2A_GC_LOW_GB=60 S2A_GC_HIGH_GB=80 bash $H/tools/gc.sh 2>&1); kill $CP 2>/dev/null
ck "命令行引用算在用：被普查进程参数引用的 dcensus_r/out 留并打「在用，不删」、没人引用的 dcensus_r/old 删" '[ -d $RS/dcensus_r/out ] && [ ! -e $RS/dcensus_r/old ] && grep -q "^在用，不删 .*dcensus_r/out（有进程当前目录在里面，或命令行引用它）" <<< "$o"'

# 存档按路径保护（10-27 mini：saves/ 是 rsync -a 拷的、保留 10-2x 旧修改时间，盘低「按最后使用」第一批被整个删掉）：
#   旧修改时间的 saves/、深层 vk2job/comm/saves、带 .keep 的目录都留；同样旧的普通目录 junk 照删
#   系统归档同样按路径保护（10-29 总指挥：systemdata/ 是起局必需的种子数据，不是缓存）：各线自建目录（gj_play）里拷来的产物根 systemdata/ 留，同根同样旧的 exefs/ 照删
rm -rf $T/rr; RS=$T/rr/home/.s2arm/run/s2arm; PS=$RS/gj_play/itt/t01@pkg-x; mkdir -p $T/rr/wt $RS/saves_backup/duo_x $RS/deps/rewriter-deps/lib $RS/saves/smo_friend/account $RS/vk2job/comm/saves/k1 $RS/vk2job/comm/rr $RS/kept/x $RS/junk/y $PS/systemdata/0100000000000823 $PS/exefs
echo b > $RS/saves_backup/duo_x/f; echo d > $RS/deps/rewriter-deps/lib/libcapstone.a; echo s > $RS/saves/smo_friend/account/a.sav; echo k > $RS/vk2job/comm/saves/k1/b.sav; echo r > $RS/vk2job/comm/rr/r; : > $RS/kept/.keep; echo x > $RS/kept/x/f; echo j > $RS/junk/y/f
echo a > $PS/systemdata/0100000000000823/data; echo e > $PS/exefs/main
python3 -c "import os,sys,time;t=time.time()-30*86400
for r,ds,fs in os.walk(sys.argv[1]):
    for n in ds+fs: os.utime(os.path.join(r,n),(t,t))" $RS
o=$(HOME=$T/rr/home S2A_RUN=$RS S2A_GC_REMOTE_ROOT=$T/rr S2A_GC_FREE_CMD="echo 30" S2A_GC_FREE_GB=30 S2A_GC_LOW_GB=60 S2A_GC_HIGH_GB=80 bash $H/tools/gc.sh 2>&1)
ck "存档 / 依赖按路径保护：30 天前修改时间的 deps/rewriter-deps、saves/、saves_backup/（存档备份）、vk2job/comm/saves、带 .keep 的 kept/ 都留，同样旧的 junk/y 与 vk2job/comm/rr 删" '[ -f $RS/deps/rewriter-deps/lib/libcapstone.a ] && [ -f $RS/saves/smo_friend/account/a.sav ] && [ -f $RS/vk2job/comm/saves/k1/b.sav ] && [ -f $RS/kept/x/f ] && [ -f $RS/saves_backup/duo_x/f ] && [ ! -e $RS/junk/y ] && [ ! -e $RS/vk2job/comm/rr ]'
ck "系统归档按路径保护：30 天前 gj_play 产物根里的 systemdata/0100000000000823 留，同根同样旧的 exefs/ 删" '[ -f $PS/systemdata/0100000000000823/data ] && [ ! -e $PS/exefs ]'
# 安卓固定源码缓存（10-29 #939 缺省挪到 $HOME/.cache/s2arm-build；mini 门禁 HOME = 远端假家目录，三份源码门禁时不现下、缺了安卓步就红）：
#   远端回收只管 ${S2A_RUN_ROOT:-$HOME/.s2arm/run}/s2arm（S），不碰假家目录的 .cache——30 天前的源码包留；同样旧的 run/s2arm/junk2/y 照删（证明回收真跑了）
rm -rf $T/rr; RS=$T/rr/home/.s2arm/run/s2arm; QC=$T/rr/home/.cache/s2arm-build/codecs/sources; mkdir -p $T/rr/wt $QC $RS/junk2/y; echo l > $QC/8901129497b2.tar.gz; echo j > $RS/junk2/y/f
python3 -c "import os,sys,time;t=time.time()-30*86400
for d in sys.argv[1:]:
    for r,ds,fs in os.walk(d):
        for n in ds+fs: os.utime(os.path.join(r,n),(t,t))" $T/rr/home/.cache $RS
o=$(HOME=$T/rr/home S2A_RUN=$RS S2A_GC_REMOTE_ROOT=$T/rr S2A_GC_FREE_CMD="echo 30" S2A_GC_FREE_GB=30 S2A_GC_LOW_GB=60 S2A_GC_HIGH_GB=80 bash $H/tools/gc.sh 2>&1)
ck "远端回收不碰假家目录的 .cache/s2arm-build：30 天前的安卓源码包留、同样旧的 run/s2arm/junk2/y 删（顶层分类往下拆一层）" '[ -f $QC/8901129497b2.tar.gz ] && [ ! -e $RS/junk2/y ]'
# 本机：局目录里的 save/ 存档副本不再按 12 小时瘦身删（同类坑 10-26 gc-slims-job-save-before-push）
rm -rf $T/run; J=$T/run/sched/jobs/acnh_1027000000_1; mkdir -p $J/save/account $T/run/sched/pkgs; echo s > $J/save/account/a.sav; head -c 2000000 /dev/zero > $J/save/account/big.sav; echo "RESULT=done out=$J/out_x" > $J/r.txt   # 收过局（没收局的局本来就不瘦身）
python3 -c "import os,sys,time;t=time.time()-30*86400
for r,ds,fs in os.walk(sys.argv[1]):
    for n in ds+fs: os.utime(os.path.join(r,n),(t,t))" $J
S2A_RUN=$T/run bash $H/tools/gc.sh > /dev/null 2>&1
ck "本机：30 天前的局里 save/ 存档副本（含 >1 MB 的）留着" '[ -f $J/save/account/a.sav ] && [ -f $J/save/account/big.sav ]'
# 盘低回收 ③ 工作树 / ④ 装包增量缓存（10-27）：干净且 HEAD 已推、24 小时没动的工作树删；有未提交 / 没推的留；装包增量缓存 1 天前的删、新的留
WR=$T/wtrepo; git init -q --bare $WR/o.git && git clone -q $WR/o.git $WR/main 2> /dev/null && git -C $WR/main -c user.name=t -c user.email=t@t commit -q --allow-empty -m a && git -C $WR/main push -q origin HEAD:main 2> /dev/null
mkdir -p $WR/wt; for n in clean dirty local; do git -C $WR/main worktree add -q --detach $WR/wt/$n 2> /dev/null; done
echo x > $WR/wt/dirty/f; git -C $WR/wt/local -c user.name=t -c user.email=t@t commit -q --allow-empty -m b
git -C $WR/wt/clean -c user.name=t -c user.email=t@t commit -q --allow-empty -m own && git -C $WR/wt/clean push -q origin HEAD:main 2> /dev/null && git -C $WR/main fetch -q origin   # 真合入：有自己的提交且已进 origin/main
# 11-05 总指挥（瓦力欧 aux_rd：分支从 main 建出、从没提交，被当成「已合入、干净」删掉）：
#   wipmod 有自己已合入的提交 + 改了已跟踪文件 → 留；headmain 分支头 = main 旧提交、从没提交 + 未跟踪文件 → 留；
#   neverc 分支头 = main 旧提交、从没提交、干净（aux_rd 原样）→ 留（旧规则删）；deep 真合入干净、但 build/a/b/c（忽略的深层文件）刚写过 → 留
printf 'build/\n' > $WR/main/.gitignore; git -C $WR/main add .gitignore; git -C $WR/main -c user.name=t -c user.email=t@t commit -qm ign; git -C $WR/main push -q origin HEAD:main 2> /dev/null; git -C $WR/main fetch -q origin
for n in wipmod deep; do git -C $WR/main worktree add -q --detach $WR/wt/$n origin/main 2> /dev/null; git -C $WR/wt/$n -c user.name=t -c user.email=t@t commit -q --allow-empty -m "own $n" && git -C $WR/wt/$n push -q origin HEAD:main 2> /dev/null; git -C $WR/main fetch -q origin; done
git -C $WR/main worktree add -q -b fix/headmain $WR/wt/headmain origin/main~1 2> /dev/null; git -C $WR/main worktree add -q -b fix/neverc $WR/wt/neverc origin/main~1 2> /dev/null
echo 改 > $WR/wt/wipmod/.gitignore; echo 新 > $WR/wt/headmain/new_src.c
find $WR/wt/wipmod $WR/wt/headmain $WR/wt/neverc $WR/wt/deep -exec touch -t 202610200000 {} +; mkdir -p $WR/wt/deep/build/a/b; echo now > $WR/wt/deep/build/a/b/c
mkdir -p $T/cdd/old.app $T/cdd/new.app; find $WR/wt $T/cdd/old.app -exec touch -t 202610200000 {} +
o=$(S2A_RUN=$T/run S2A_GC_WT_DIRS=$WR/wt S2A_GC_CDDELTA=$T/cdd S2A_GC_FREE_GB=50 S2A_GC_NEED_KB=1 bash $H/tools/gc.sh 2>&1)
ck "盘低：干净已推的旧工作树 clean 删、有未提交的 dirty 和没推的 local 留；装包增量缓存旧的删、新的留（$(ls $WR/wt | tr '\n' ' ')/ $(ls $T/cdd | tr '\n' ' ')）" '[ ! -e $WR/wt/clean ] && [ -d $WR/wt/dirty ] && [ -d $WR/wt/local ] && [ ! -e $T/cdd/old.app ] && [ -d $T/cdd/new.app ]'
ck "工作树三条（11-05）：有未提交改动的 wipmod、分支头 = main 且有未跟踪文件的 headmain、分支头 = main 从没提交的 neverc、深层刚写过的 deep 都留；真合入干净的 clean 删" '[ -d $WR/wt/wipmod ] && [ -d $WR/wt/headmain ] && [ -d $WR/wt/neverc ] && [ -d $WR/wt/deep ] && [ ! -e $WR/wt/clean ]'
ck "删前记日志：gc_worktrees.log 有 clean 的路径与头提交" 'grep -q "$WR/wt/clean" $T/run/gc_worktrees.log' 
# --versions（10-29 总指挥：被取代的版本常态回收，挂运维线 15 分钟巡检）：期望按规则手写——
#   ① 本机：acnh 三版（a 最旧、b、c 现行）→ 删 a、留 b c；同时放一个 30 天前的调度局目录 → 不动（--versions 只剪版本，别的规则不跑）
#   ② 远端：rpack/roots 下 witcher3 三版（rx 最旧、ex、dl 现行）+ 写了一半的 x.tmp → 删 rx、留 ex dl 与 x.tmp；mk8d 两版但在跑命令登记了它 → 不动
rm -rf $T/vv; VS=$T/vv/run; mkdir -p $VS/roots $VS/sched/jobs/acnh_1001000000_1
for v in a b c; do mkdir -p $VS/roots/acnh@$v; echo $v > $VS/roots/acnh@$v/f; done; ln -s acnh@c $VS/roots/acnh@现行
python3 -c "import os,sys,time;[os.utime(p,(time.time()-d,time.time()-d)) for p,d in ((sys.argv[1],300),(sys.argv[2],200),(sys.argv[3],100))]" $VS/roots/acnh@a $VS/roots/acnh@b $VS/roots/acnh@c
echo "RESULT=done" > $VS/sched/jobs/acnh_1001000000_1/r.txt; python3 -c "import os,sys,time;t=time.time()-30*86400;os.utime(sys.argv[1],(t,t))" $VS/sched/jobs/acnh_1001000000_1
o=$(S2A_RUN=$VS HOME=$T/vv bash $H/tools/gc.sh --versions 2>&1)
ck "--versions 本机：删 acnh@a、留 b c；30 天前的局目录不动（$(tail -1 <<< "$o" | cut -c1-60)）" '[ ! -e $VS/roots/acnh@a ] && [ -d $VS/roots/acnh@b ] && [ -d $VS/roots/acnh@c ] && [ -d $VS/sched/jobs/acnh_1001000000_1 ] && grep -q "^gc --versions：剪掉被取代的版本 1 项" <<< "$o"'
rm -rf $T/vr; RP=$T/vr/home/rpack/roots; mkdir -p $RP $T/vr/wt $T/vr/home/.s2arm/run/s2arm
for v in rx ex dl; do mkdir -p $RP/witcher3@$v; echo $v > $RP/witcher3@$v/f; done; ln -s witcher3@dl $RP/witcher3@现行; mkdir -p $RP/witcher3@x.tmp
for v in o n; do mkdir -p $RP/mk8d@$v; done; mkdir -p $RP/mk8d@m; ln -s mk8d@n $RP/mk8d@现行
python3 -c "import os,sys,time;[os.utime(p,(time.time()-d,time.time()-d)) for p,d in zip(sys.argv[1:],(400,300,200,500,450,100))]" $RP/witcher3@rx $RP/witcher3@ex $RP/witcher3@dl $RP/mk8d@o $RP/mk8d@m $RP/mk8d@n
sleep 60 & VP=$!; echo $VP > $T/vr/wt/j.pid; printf 'rpack/roots/mk8d@现行\n' > $T/vr/wt/j.uses
o=$(HOME=$T/vr/home S2A_RUN=$T/vr/home/.s2arm/run/s2arm S2A_GC_REMOTE_ROOT=$T/vr bash $H/tools/gc.sh --versions 2>&1); kill $VP 2> /dev/null
ck "--versions 远端 rpack：删 witcher3@rx、留 ex dl 与 x.tmp；mk8d 在用三版都留（$(grep -c '^删 ' <<< "$o") 删）" '[ ! -e $RP/witcher3@rx ] && [ -d $RP/witcher3@ex ] && [ -d $RP/witcher3@dl ] && [ -d $RP/witcher3@x.tmp ] && [ -d $RP/mk8d@o ] && [ -d $RP/mk8d@m ] && grep -q "在用，不剪 rpack mk8d" <<< "$o"'
# 远端按款空闲淘汰（10-29 出包线）：直连缓存 OLD（7 小时没动）删、NEW（刚写）留、USED（7 小时没动但在跑命令登记了）留；rpack 常驻根 w 两版 + 现行 7 小时没动整款删、m 刚用留
rm -rf $T/ve; VC=$T/ve/home/.s2arm/run/s2arm/cache/direct; RQ=$T/ve/home/rpack/roots; mkdir -p $VC/OLD/mac $VC/NEW/mac $VC/USED/mac $RQ/w@a $RQ/w@b $RQ/m@c $T/ve/wt
for f in $VC/OLD/mac/x $VC/NEW/mac/x $VC/USED/mac/x $RQ/w@a/f $RQ/w@b/f $RQ/m@c/f; do echo x > $f; done; ln -s w@b $RQ/w@现行; ln -s m@c $RQ/m@现行
python3 -c "import os,sys,time;t=time.time()-7*3600;[os.utime(p,(t,t),follow_symlinks=False) for p in sys.argv[1:]]" $VC/OLD/mac/x $VC/OLD/mac $VC/OLD $VC/USED/mac/x $VC/USED/mac $VC/USED $RQ/w@a/f $RQ/w@a $RQ/w@b/f $RQ/w@b $RQ/w@现行
sleep 60 & VP=$!; echo $VP > $T/ve/wt/j.pid; printf '.s2arm/run/s2arm/cache/direct/USED\n' > $T/ve/wt/j.uses
o=$(HOME=$T/ve/home S2A_RUN=$T/ve/home/.s2arm/run/s2arm S2A_GC_REMOTE_ROOT=$T/ve bash $H/tools/gc.sh --versions 2>&1); kill $VP 2> /dev/null
ck "远端按款空闲淘汰：删直连缓存 OLD 与 rpack w 整款、留 NEW / 在用 USED / 刚用的 m" '[ ! -e $VC/OLD ] && [ -d $VC/NEW ] && [ -d $VC/USED ] && [ ! -e $RQ/w@a ] && [ ! -e $RQ/w@b ] && [ ! -L $RQ/w@现行 ] && [ -d $RQ/m@c ] && [ -L $RQ/m@现行 ] && grep -q "在用，不淘汰直连缓存 USED" <<< "$o"'
# 普查远端款目录：c1/work/A（2 小时没动）删、c1/work/B（刚写）留、c1/work/C（2 小时没动但在跑命令登记了）留；整批 c0（2 天没动）删
rm -rf $T/vf; VW=$T/vf/home/.s2arm/run/s2arm/census; mkdir -p $VW/c1/work/A/p $VW/c1/work/B/p $VW/c1/work/C/p $VW/c0/work/Z $T/vf/wt
for f in $VW/c1/work/A/p/x $VW/c1/work/B/p/x $VW/c1/work/C/p/x $VW/c0/work/Z/x; do echo x > $f; done
python3 -c "import os,sys,time;[os.utime(p,(time.time()-int(a),time.time()-int(a))) for a,p in zip(sys.argv[1::2],sys.argv[2::2])]" 7200 $VW/c1/work/A/p/x 7200 $VW/c1/work/A/p 7200 $VW/c1/work/A 7200 $VW/c1/work/C/p/x 7200 $VW/c1/work/C/p 7200 $VW/c1/work/C 172800 $VW/c0/work/Z/x 172800 $VW/c0/work/Z 172800 $VW/c0/work 172800 $VW/c0
sleep 60 & VP=$!; echo $VP > $T/vf/wt/j.pid; printf '.s2arm/run/s2arm/census/c1/work/C/p/work/C/extract\n' > $T/vf/wt/j.uses
o=$(HOME=$T/vf/home S2A_RUN=$T/vf/home/.s2arm/run/s2arm S2A_GC_REMOTE_ROOT=$T/vf bash $H/tools/gc.sh --versions 2>&1); kill $VP 2> /dev/null
ck "普查远端款目录：删空闲的 A 与整批 c0、留刚写的 B 和在用的 C" '[ ! -e $VW/c1/work/A ] && [ -d $VW/c1/work/B ] && [ -d $VW/c1/work/C ] && [ ! -e $VW/c0 ]'
# 11-01 私有根被整删（mx84ce / mx2f9f）：S2A_ROOTS 在局的环境变量里、命令行看不到。空闲私有根：环境里引用它的进程在 → 留；出包队列单提到 priv:<名> → 留；真空闲的删并写日志行
mk; P=$T/run/roots_priv; mkdir -p $P/envuse/g@v1 $P/queued/g@v1 $P/idle/g@v1 $P/idlekeep/g@v1 $T/run/packq/run $T/run/packq/req; touch $P/idlekeep/.keep
for x in envuse queued idle idlekeep; do echo x > $P/$x/g@v1/f; done; old $P/envuse $P/queued $P/idle $P/idlekeep
echo '{"roots":"priv:queued"}' > $T/run/packq/run/q1.json
S2A_ROOTS=$P/envuse bash -c 'sleep 40; true' & EP=$!; sleep 1
o=$(S2A_RUN=$T/run bash $H/tools/gc.sh 2>&1); kill $EP 2> /dev/null
ck "私有根空闲：环境引用的留、队列单用的留、带 .keep 的留、真空闲的删并有日志行" '[ -d $P/envuse ] && [ -d $P/queued ] && [ -d $P/idlekeep ] && [ ! -e $P/idle ] && grep -q "私有根留 $P/envuse" <<< "$o" && grep -q "私有根留 $P/queued" <<< "$o" && grep -q "删 $P/idle" <<< "$o"'
# 内置盘旧录像 frame_rec.local（11-05：frame_rec 改 2T 软链后留在内置盘的那批）：整款 24 小时没动删；钉住表带原因的留；钉了没写原因的不认、照删；深层 1 小时前动过的留
mk; FL=$T/run/frame_rec.local; for x in fa fb fn fc; do mkdir -p $FL/$x/r1/rec/f1; echo m > $FL/$x/r1/rec/f1/mem.bin; done; old $FL; touch $FL/fc/r1/rec/f1/mem.bin
printf '%s\t%s\n%s\n' "$T/run/frame_rec/fb" "画面线对照要用" "$FL/fn" > $T/pins
o=$(S2A_RUN=$T/run S2A_GC_PINS=$T/pins bash $H/tools/gc.sh 2>&1)
ck "内置盘旧录像：闲 fa 删、钉住带原因 fb 留、钉了没写原因 fn 删、深层刚动过 fc 留" '[ ! -e $FL/fa ] && [ -d $FL/fb ] && [ ! -e $FL/fn ] && [ -d $FL/fc ] && grep -q "录像留 .*fb（钉住：画面线对照要用）" <<< "$o"'
# 软链目录（11-06 总指挥亲手清盘 95 → 507 GB 复盘：运行区的 sched/jobs、sched/pkgstore 是软链到工作盘的目录，find 不跟起点软链，
#   「超龄局目录整删」扫到 0 个，5417 个旧局一直没清；pkgstore 只遍历有登记的款，没登记的款快照永远轮不到）。期望（按规则手写）：
#   sched/jobs 是软链、里面 30 天前已出结果的局 → 删；sched/pkgstore 是软链、没登记也没任何引用的款 zz 两份快照 → 都删；有登记的款 acnh 现行那份留
rm -rf $T/sl; SL=$T/sl/run; SD2=$T/sl/data; mkdir -p $SL/roots $SL/sched/pkgs $SL/sched/queue $SD2/jobs/acnh_1001000000_1 $SD2/pkgstore/zz-a $SD2/pkgstore/zz-b $SD2/pkgstore/acnh-cur
ln -s $SD2/jobs $SL/sched/jobs; ln -s $SD2/pkgstore $SL/sched/pkgstore; echo "PKG=$SL/sched/pkgstore/acnh-cur" > $SL/sched/pkgs/acnh.env
echo "RESULT=done" > $SD2/jobs/acnh_1001000000_1/r.txt; find $SD2/jobs/acnh_1001000000_1 -exec touch -t "$(date -v-30d +%Y%m%d%H%M)" {} +
o=$(S2A_RUN=$SL HOME=$T/sl bash $H/tools/gc.sh 2>&1)
ck "软链目录：30 天前的局删、没登记无引用的款 zz 两份快照删、acnh 现行留（$(grep -c . <<< "$o") 行输出）" '[ ! -e $SD2/jobs/acnh_1001000000_1 ] && [ ! -e $SD2/pkgstore/zz-a ] && [ ! -e $SD2/pkgstore/zz-b ] && [ -d $SD2/pkgstore/acnh-cur ]'
[ $bad = 0 ] && echo "✓ gc 单测全过" || { echo "gc 单测有不通"; exit 1; }
