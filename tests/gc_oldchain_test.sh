#!/bin/bash
# gc 作废链号直连库回收单测（tools/gc.sh 盘低回收 ⑤，临时目录，约 5 秒）：bash tests/gc_oldchain_test.sh
# 期望（按规则手写）：cache/direct 两款 0100000000000001 / 0100000000000002，各 mac/ ios/ 下三个链号：
#   当前 aaaaaaaaaaaa（临时仓库 origin/main 的 graphics/nvn/gfx/nvn/dmsh_chain.h）、在用 bbbbbbbbbbbb（在跑的 <树>/pack/refresh.sh 的工作树）、作废 cccccccccccc / dddddddddddd
#   ① 盘低（假剩余 50 GB < 100）、缺口大：只删作废的 c / d（两款 × 两平台 = 8 份），a / b 全留
#   ② 盘不低（999 GB）：一个不删；③ S2A_GC_OLDCHAIN=0：一个不删
#   ④ 作废目录里 30 分钟内改过一个文件 → 那份留、别的作废照删；带 .keep 的作废目录留（prot）
#   ⑤ 缺口 1 KB：有 getattrlist 时按独占字节只删最旧一份；没有时记账以 du 开头，字节缺口不收手（S2A_GC_FREE_GB 把 df 停关掉）→ 作废 c / d 全删
#   ⑥ 某款有活的 work.stage.<进程号>（direct_lib.sh 在出这款）→ 这款整款不动，另一款照删
#   ⑦ 远端（S2A_GC_REMOTE_ROOT）：main 链号取 <远端根>/S2Arm.git 的 refs/s2a/om/*，在跑远端命令（wt/<名>.pid 活着）的工作树链号留
#   ⑧ 有出包进程认不出工作树（拿不准）→ 整段不删
#   ⑨ 系统没有 getattrlist（privsize 调用才抛）→ 退回 du 记账照删；⑩ 扫描中途出错 → 打【红】「扫描中途失败」，不写「删 0 份」（#619 审计）
#   ⑪ 着色器中间缓存：真实 privsize 在没有 getattrlist 的系统上调用才抛，退回后按分配块删够 100 KB（c1 c2），不许 traceback
#   ⑫ 同一段用会抛的 privsize + 稀疏文件：收手按 st_blocks×512（du -k 的分配块），不按表观大小（BSD du -A / GNU du --apparent-size）。造完比分配块和表观大小，分配块不少于表观大小就跳过，不算失败
#   ⑬ 假 privsize 调用成功（独占 = 分配块，模拟非克隆文件）：缺口 1 KB 仍只删最旧一份。苹果机真 getattrlist 走同一收手条件
# 反证：把 tools/gc.sh 里 KC=$(printf '%s\n' "$CM" $UC …) 的 "$CM" 去掉（= 不保留当前链号），①④⑤⑥⑦ 应红（当前链号 a / 远端 c 的目录被删；10-28 实跑：这五条红、②③⑧ 通）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0; PIDS=
trap 'for p in $PIDS; do pkill -P "$p" 2> /dev/null; kill "$p" 2> /dev/null; wait "$p" 2> /dev/null; done; chmod -R u+w "$T"; rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
export S2A_GC_REMOTE_EVICT_H=0 S2A_WT_ROOT=$T/wt_none S2A_BOARD=$T/board.tsv S2A_ROOTS_SSD= S2A_GC_WT_DIRS=$T/wt_none S2A_GC_CDDELTA=$T/cd_none GAL_PSO_CACHE=$T/pc_none GAL_AIR_CACHE=$T/air_none GAL_DL_CACHE=$T/dl_none S2A_PACK_SLOT_DIR=$T/locks_none S2A_GC_FREE_CMD="echo 999"
DH=graphics/nvn/gfx/nvn/dmsh_chain.h
hdr() { mkdir -p "$(dirname "$1/$DH")"; printf '// gen\n#define DMSH_CHAIN "%s"\n' "$2" > "$1/$DH"; }
# 临时仓库：origin/main 上链号 a；本地工作区文件另写 e（证明取的是 origin/main，不是本树文件）
R=$T/repo; git init -q --bare $T/origin.git; git clone -q $T/origin.git $R 2> /dev/null; hdr $R aaaaaaaaaaaa
git -C $R add -A; git -C $R -c user.email=t@t -c user.name=t commit -qm i; git -C $R branch -M main; git -C $R push -q origin main 2> /dev/null; git -C $R fetch -q origin; hdr $R eeeeeeeeeeee
export S2A_REPO=$R
# 在用：一棵假工作树里的 pack/refresh.sh 在跑，链号 b。假「在用」进程一律 sleep 3600、由 EXIT 陷阱收（10-29：原 sleep 60，负载下整份单测跑 97 秒，
#   后半段假进程已退、在用的 b 被当作废删掉 → ⑬ 在 main 上常红；寿命跟单测走，不按秒数赌）
W=$T/wtu; hdr $W bbbbbbbbbbbb; mkdir -p $W/pack; echo 'sleep 3600' > $W/pack/refresh.sh
# 按事件等假进程 exec 完（10-29 列车线：mini 高负载误红类——原先固定睡 0.3 秒：子 shell 还没 cd / exec 时命令行是本单测的，gc 认不出在用的出包）：
#   uptil <pid> <命令行>：轮询到命令行变成 exec 之后的样子（cd 在 exec 之前），上限 60 秒
uptil() { local i; for i in $(seq 1 600); do [ "$(ps -o args= -p "$1" 2> /dev/null)" = "$2" ] && return 0; sleep 0.1; done; echo "（60 秒内进程 $1 的命令行没变成「$2」）"; }
(cd $W && exec bash $W/pack/refresh.sh) & PIDS="$PIDS $!"; uptil $! "bash $W/pack/refresh.sh"
# 只让 gc 看见本单测起的进程（S2A_GC_PS）：门禁在 mini / 本机跑时有真出包进程，混进来会被判「认不出工作树」整段不删
gps() { local p; for p in $PIDS; do ps -ww -o pid=,command= -p "$p" 2> /dev/null; done; }; export -f gps; export PIDS; export S2A_GC_PS=gps
old() { find "$@" -exec touch -t 202610200100 {} + ; }
mk() { rm -rf $1; local t p c i=0; for t in 0100000000000001 0100000000000002; do for p in mac ios; do for c in aaaaaaaaaaaa bbbbbbbbbbbb cccccccccccc dddddddddddd; do
  mkdir -p $1/cache/direct/$t/$p/b-$c; head -c 65536 /dev/urandom > $1/cache/direct/$t/$p/b-$c/k_b.metallib; done; done; mkdir -p $1/cache/direct/$t/mac/cas $1/cache/direct/$t/work; done
  old $1/cache/direct; for d in $1/cache/direct/*/*/b-*; do i=$((i + 1)); touch -t 2026102001$(printf %02d $i) $d; done; }   # 修改时间按「款、平台、链号」顺序递增
left() { (cd $1/cache/direct && ls -d */*/b-* | sed 's|/b-\(.\).*| \1|' | sort | awk '{print $2}' | tr -d '\n'); }   # 每款每平台剩下的链号首字母
S=$T/run; mkdir -p $S/sched/pkgs
mk $S; o=$(S2A_RUN=$S S2A_GC_FREE_GB=50 S2A_GC_NEED_KB=100000000 bash $H/tools/gc.sh 2>&1)
ck "① 盘低：只删作废 c / d 共 8 份，当前 a、在用 b 全留（剩 $(left $S)；$(grep -o 'gc：作废链号的直连库删.*' <<< "$o")）" '[ "$(left $S)" = abababab ] && grep -q "gc：作废链号的直连库删 8 份" <<< "$o" && grep -q "保留链号 aaaaaaaaaaaa bbbbbbbbbbbb （当前 main aaaaaaaaaaaa）" <<< "$o" && [ -d $S/cache/direct/0100000000000001/mac/cas ]'
mk $S; o=$(S2A_RUN=$S S2A_GC_FREE_GB=999 bash $H/tools/gc.sh 2>&1)
ck "② 盘不低：一个不删（剩 $(left $S)）" '[ "$(left $S)" = abcdabcdabcdabcd ] && ! grep -q 作废链号 <<< "$o"'
o=$(S2A_RUN=$S S2A_GC_FREE_GB=50 S2A_GC_NEED_KB=100000000 S2A_GC_OLDCHAIN=0 bash $H/tools/gc.sh 2>&1)
ck "③ S2A_GC_OLDCHAIN=0：盘低也不删（剩 $(left $S)）" '[ "$(left $S)" = abcdabcdabcdabcd ] && ! grep -q 作废链号 <<< "$o"'
touch $S/cache/direct/0100000000000001/ios/b-cccccccccccc/k_b.metallib; touch $S/cache/direct/0100000000000002/mac/b-dddddddddddd/.keep; old $S/cache/direct/0100000000000002/mac/b-dddddddddddd
o=$(S2A_RUN=$S S2A_GC_FREE_GB=50 S2A_GC_NEED_KB=100000000 bash $H/tools/gc.sh 2>&1)
ck "④ 30 分钟内改过的 1/ios/b-c 留、带 .keep 的 2/mac/b-d 留，其余作废删（剩 $(left $S)）" '[ "$(left $S)" = abcabababd ] && grep -q "在用，不删 .*0100000000000001/ios/b-cccccccccccc（30 分钟内改过）" <<< "$o" && grep -q "受保护，不删 .*0100000000000002/mac/b-dddddddddddd" <<< "$o"'
mk $S; o=$(S2A_RUN=$S S2A_GC_FREE_GB=50 S2A_GC_NEED_KB=1 bash $H/tools/gc.sh 2>&1)
if python3 -c 'import ctypes,ctypes.util; ctypes.CDLL(ctypes.util.find_library("c")).getattrlist' >/dev/null 2>&1; then
  ck "⑤ 缺口 1 KB（getattrlist）：只删最旧的作废 1/ios/b-c（剩 $(left $S)）" '[ "$(left $S)" = abdabcdabcdabcd ] && [ ! -e $S/cache/direct/0100000000000001/ios/b-cccccccccccc ] && grep -q "gc：作废链号的直连库删 1 份，独占" <<< "$o"'
else
  ck "⑤ 缺口 1 KB（无 getattrlist，du 不按字节收手）：作废 c / d 全删（剩 $(left $S)；$(grep -o 'gc：作废链号的直连库删.*' <<< "$o")）" '[ "$(left $S)" = abababab ] && grep -q "gc：作废链号的直连库删 8 份，du（无 privsize" <<< "$o"'
fi
mk $S; sleep 3600 & SP=$!; PIDS="$PIDS $SP"; export PIDS; mkdir -p $S/cache/direct/0100000000000001/work.stage.$SP
o=$(S2A_RUN=$S S2A_GC_FREE_GB=50 S2A_GC_NEED_KB=100000000 bash $H/tools/gc.sh 2>&1)
ck "⑥ 款 1 有活的 work.stage：整款不动，款 2 照删（剩 $(left $S)）" '[ "$(left $S)" = abcdabcdabab ] && grep -q "在用，不删 .*0100000000000001（direct_lib.sh 进程 $SP 在出这款）" <<< "$o"'
# ⑦ 远端：<远端根>/S2Arm.git 的 refs/s2a/om/<名> 指向链号 c 的提交；在跑远端命令 wt/job1 的工作树链号 d；本机仓库（S2A_REPO 的 a）不该用到
RR=$T/rr; RS=$RR/home/.s2arm/run/s2arm; mkdir -p $RR/wt $RS/sched/pkgs; git init -q --bare $RR/S2Arm.git; RW=$T/rwork; git clone -q $RR/S2Arm.git $RW 2> /dev/null; hdr $RW cccccccccccc
git -C $RW add -A; git -C $RW -c user.email=t@t -c user.name=t commit -qm r; git -C $RW push -q origin HEAD:refs/s2a/om/x 2> /dev/null
hdr $RR/wt/job1 dddddddddddd; sleep 3600 & RP=$!; PIDS="$PIDS $RP"; export PIDS; echo $RP > $RR/wt/job1.pid
mk $RS; o=$(HOME=$RR/home S2A_RUN=$RS S2A_GC_REMOTE_ROOT=$RR S2A_GC_FREE_GB=50 S2A_GC_NEED_KB=100000000 bash $H/tools/gc.sh 2>&1)
ck "⑦ 远端：留远端 main 的 c、远端在跑命令的 d、本机在跑出包的 b，删 a（剩 $(left $RS)）" '[ "$(left $RS)" = bcdbcdbcdbcd ] && grep -q "当前 main cccccccccccc" <<< "$o"'
# ⑧ 认不出工作树的出包进程：命令行只有相对路径、当前目录不在任何工作树里
mkdir -p $T/nowt/pack; echo 'sleep 3600' > $T/nowt/pack/direct_lib.sh; (cd $T/nowt && exec bash pack/direct_lib.sh) & UP=$!; PIDS="$PIDS $UP"; export PIDS; uptil $UP "bash pack/direct_lib.sh"
mk $S; o=$(S2A_RUN=$S S2A_GC_FREE_GB=50 S2A_GC_NEED_KB=100000000 bash $H/tools/gc.sh 2>&1)
ck "⑧ 有出包进程认不出工作树：整段不删（剩 $(left $S)）" '[ "$(left $S)" = abcdabcdabcdabcd ] && grep -q "在跑的出包进程 $UP 认不出工作树" <<< "$o"'
pkill -P "$UP" 2> /dev/null; kill "$UP" 2> /dev/null; wait "$UP" 2> /dev/null; PIDS=${PIDS/ $UP/}; export PIDS   # ⑧ 的「认不出工作树」进程收掉，不挡后面
# ⑨ 系统没有 getattrlist（#619 审计：非苹果机导入 privsize 照过、调用才抛）：探测失败退回 du 记账，照删作废 c / d，打「du（无 privsize」
F=$T/fake; mkdir -p $F; cp -R $H/tools $H/pack $F/; printf 'def tree(d):\n    raise AttributeError("undefined symbol: getattrlist")\ndef private_size(p):\n    raise AttributeError("undefined symbol: getattrlist")\n' > $F/tools/privsize.py
mk $S; o=$(S2A_RUN=$S S2A_GC_FREE_GB=50 S2A_GC_NEED_KB=100000000 bash $F/tools/gc.sh 2>&1)
ck "⑨ 没有 getattrlist：退回 du 记账照删作废 c / d（剩 $(left $S)；$(grep -o 'gc：作废链号的直连库删.*' <<< "$o")）" '[ "$(left $S)" = abababab ] && grep -q "gc：作废链号的直连库删 8 份，du（无 privsize" <<< "$o"'
# ⑩ 扫描中途出错（款 2 的 ios/ 读不了）：打【红】「扫描中途失败」，不许写「删 0 份」，一个不删
mk $S; chmod 000 $S/cache/direct/0100000000000002/ios; o=$(S2A_RUN=$S S2A_GC_FREE_GB=50 S2A_GC_NEED_KB=100000000 bash $H/tools/gc.sh 2>&1); chmod 755 $S/cache/direct/0100000000000002/ios
ck "⑩ 扫描中途出错：报红、不写「删 0 份」（剩 $(left $S)；$(grep -o '【红】gc：作废链号.*' <<< "$o" | cut -c1-80)）" '[ "$(left $S)" = abcdabcdabcdabcd ] && grep -q "【红】gc：作废链号的直连库扫描中途失败（PermissionError" <<< "$o" && ! grep -q "gc：作废链号的直连库删 0 份" <<< "$o"'
# ⑪ 着色器中间缓存用真实 privsize.py。四个各 64 KB、缺口 100 KB：删最旧 c1 c2。没有 getattrlist 时调用会抛，退回前这四份都留着
PC=$T/pc11; R11=$T/r11; mkdir -p $PC $R11/sched/pkgs
python3 - $PC <<'PY'
import os, sys, time
now = time.time()
for n, h in (('c1', 30), ('c2', 20), ('c3', 10), ('c4', 1 / 6)):
    p = os.path.join(sys.argv[1], n); open(p, 'wb').write(os.urandom(64 * 1024)); os.utime(p, (now - h * 3600, now - h * 3600))
PY
o=$(S2A_RUN=$R11 GAL_DL_CACHE=$PC GAL_AIR_CACHE=$T/air_none S2A_GC_FREE_GB=50 S2A_GC_NEED_KB=100 bash $H/tools/gc.sh 2>&1)
ck "⑪ 着色器缓存缺口 100 KB：删 c1 c2、留 c3 与 1 小时内的 c4，没有 Traceback（剩 $(ls $PC | tr '\n' ' ')；$(grep -o 'gc：着色器中间缓存.*' <<< "$o")）" '[ "$(ls $PC | tr "\n" " ")" = "c3 c4 " ] && grep -q "着色器中间缓存删 2 条" <<< "$o" && ! grep -q Traceback <<< "$o"'
# ⑫ 调用即抛的 privsize + 稀疏文件。分配块（st_blocks×512，du -k）填不满 100 KB 还要继续删；表观大小（du -A / --apparent-size）删稀疏那一份就停。
#    洞取 16 MB：APFS 上 1 MB 的 seek 洞会被整段分配（10-28 本机实测 1 MB 洞分配 1052672、16 MB 洞只分配 4096），洞太小 Mac 上 ⑫ 永远跳过
#    造完比分配块和表观大小：分配块不少于表观大小（文件系统不支持稀疏文件）→ 打一行跳过，不算失败
SP=$T/sp; R12=$T/r12; mkdir -p $SP $R12/sched/pkgs
python3 - $SP $T/keep_blocks $T/keep_apparent <<'PY'
import os, sys, time
d, kb, ka = sys.argv[1:]
now = time.time()
def wr(name, age_h, sparse=False):
    p = os.path.join(d, name)
    with open(p, 'wb') as f:
        if sparse:
            f.seek(16 << 20); f.write(b'x' * 4096)
        else:
            f.write(os.urandom(64 * 1024))
    os.utime(p, (now - age_h * 3600, now - age_h * 3600))
wr('s', 30, True); wr('a', 20); wr('b', 10); wr('c', 5); wr('n', 0.1)
st = os.lstat(os.path.join(d, 's'))
if st.st_blocks * 512 >= st.st_size: sys.exit(2)   # 造完不是稀疏文件
need = 100 * 1024
items = []
for name in os.listdir(d):
    p = os.path.join(d, name); st = os.lstat(p)
    if now - st.st_mtime < 3600: continue
    items.append((st.st_mtime, name, st.st_blocks * 512, st.st_size))
items.sort()
if not (items[0][1] == 's' and items[0][3] >= need and items[0][2] < need):
    sys.exit(1)
def remain(idx):
    got, keep = 0, []
    for m, name, alloc, app in items:
        sz = (alloc, app)[idx]
        if got >= need: keep.append(name); continue
        got += sz
    keep.append('n')
    return keep
open(kb, 'w').write(''.join(n + '\n' for n in sorted(remain(0))))
open(ka, 'w').write(''.join(n + '\n' for n in sorted(remain(1))))
if open(kb).read() == open(ka).read(): sys.exit(1)
PY
prc=$?
if [ "$prc" = 2 ]; then echo "本机文件系统造不出稀疏文件，⑫ 跳过"
elif [ "$prc" != 0 ]; then echo "不通 ⑫ 夹具分不出分配块和表观大小"; bad=1
else
  o=$(S2A_RUN=$R12 GAL_DL_CACHE=$SP GAL_AIR_CACHE=$T/air_none S2A_GC_FREE_GB=50 S2A_GC_NEED_KB=100 bash $F/tools/gc.sh 2>&1)
  blk=$(sort $T/keep_blocks | tr '\n' ' '); app=$(sort $T/keep_apparent | tr '\n' ' '); leftsp=$(ls $SP | sort | tr '\n' ' ')
  ck "⑫ 稀疏文件按分配块收手、不按表观大小（剩 ${leftsp}；分配块应剩 ${blk}；表观会剩 ${app}；$(grep -o 'gc：着色器中间缓存.*' <<< "$o")）" '[ "$leftsp" = "$blk" ] && [ "$leftsp" != "$app" ] && grep -q "着色器中间缓存删 .*du（无 privsize" <<< "$o" && ! grep -q Traceback <<< "$o"'
fi
# ⑬ 假 privsize 调用成功：独占记账，缺口 1 KB 只删最旧一份（与苹果机非克隆文件的 getattrlist 收手同一条）
G=$T/fakeok; mkdir -p $G; cp -R $H/tools $H/pack $G/
cat > $G/tools/privsize.py <<'PY'
import os
def private_size(p):
    try: st = os.lstat(p)
    except OSError: return None
    return st.st_blocks * 512
def tree(d):
    du = n = 0
    for r, _, fs in os.walk(d):
        for f in fs:
            p = os.path.join(r, f)
            if not os.path.isfile(p) or os.path.islink(p): continue
            n += 1; du += os.lstat(p).st_blocks * 512
    return du, du, n
PY
mk $S; o=$(S2A_RUN=$S S2A_GC_FREE_GB=50 S2A_GC_NEED_KB=1 bash $G/tools/gc.sh 2>&1)
ck "⑬ 独占记账（调用成功的假 privsize）缺口 1 KB：只删最旧的作废 1/ios/b-c（剩 $(left $S)；$(grep -o 'gc：作废链号的直连库删.*' <<< "$o")）" '[ "$(left $S)" = abdabcdabcdabcd ] && [ ! -e $S/cache/direct/0100000000000001/ios/b-cccccccccccc ] && grep -q "gc：作废链号的直连库删 1 份，独占" <<< "$o"'
[ $bad = 0 ] && echo "✓ gc 作废链号单测全过" || { echo "gc 作废链号单测有不通"; exit 1; }
