#!/bin/bash
# 进局检查（tools/entry_check.sh）局时限只算游戏局单测：要证「宿主在局槽外编好，局里 make 空转」——
#   替身 Makefile 真编一次就往 builds.log 记一行「在不在局槽里」（替身局槽给命令带 S2A_FAKE_IN_SLOT=1）。
#   编译在时限外做完 → 只记 1 行「槽外」、局里 make 空转；编译挪进局里（10-27 前的写法）→ 记「槽内」。
#   按事件判、不按秒数赌（10-31 mini 全套并发：原「编译 3 秒 vs 局时限 2 秒」在负载下局里空转也超 2 秒，rc=124 假红）
#   时限外编好后带 S2A_HOST_PREBUILT=1 给 run_mac.sh：槽内不再 make（替身 run_mac.sh 同真实写法，记下收到的值）
#   缺省直连（10-27 jhz「直连才是主力」）：根里没有本链直连库 → 退出 5「待直连根」、不起局；宿主没走直连 → 「没走直连」退出 1；S2A_ENTRY_GFX=generic 才强制通用
# 门禁覆盖：tools/entry_check.sh
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d "${TMPDIR:-/tmp}/entry-check.XXXXXX"); trap 'rm -rf "$T"' EXIT; bad=0
R=$T/r; mkdir -p $R/tools $R/runtime $R/graphics/widen/scan $R/graphics/nvn/gfx/nvn $T/roots/tg@现行/exefs $T/roots/tg@现行/shaders/direct/b-abc123
echo '#define DMSH_CHAIN "abc123"' > $R/graphics/nvn/gfx/nvn/dmsh_chain.h; mkidx() { python3 - "$1" "$2" <<'PYE'
import struct, sys   # 合法 lib.idx：头 48 字节 + 1 个分片（lib.000.pak 共 100 字节）+ 0 条记录
d, n = sys.argv[1], int(sys.argv[2])
h = b'S2ALIB\0\0' + struct.pack('<IIII', 1, 0, 1, 0) + b'abc123'.ljust(12, b'\0') + bytes(12) + struct.pack('<QQ', n, 0)
open(d + '/lib.idx', 'wb').write(h); open(d + '/lib.000.pak', 'wb').write(bytes(n))
PYE
}
mkidx $T/roots/tg@现行/shaders/direct/b-abc123 100
mkdir -p $T/roots/old@现行/exefs $T/roots/old@现行/shaders/direct/b-0ld000; head -c 96 /dev/zero > $T/roots/old@现行/exefs/main
cp "${ENTRY_CHECK_UNDER_TEST:-$H/tools/entry_check.sh}" $R/tools/entry_check.sh; cp $H/tools/direct_shards.py $R/tools/direct_shards.py; cp $H/tools/host_build.sh $R/tools/
head -c 96 /dev/zero > $T/roots/tg@现行/exefs/main
printf 'host: build/done\nbuild/done:\n\tmkdir -p build; touch build/done; echo "slot=$${S2A_FAKE_IN_SLOT:-0}" >> builds.log\n' > $R/Makefile
printf 'import shutil,sys; shutil.copytree(sys.argv[1], sys.argv[2])\n' > $R/tools/clonedir.py
printf 'exit 0\n' > $R/graphics/widen/scan/save_pick.sh
cp $H/tools/mac_slot_frozen.sh $H/tools/s2a_machine.sh $R/tools/; export S2A_MAC_SLOT_BIN=$R/tools/mac_slot.sh   # 入口经冻结副本包装调局槽：副本指向下面的替身
cat > $R/tools/mac_slot.sh <<'S'
# 替身局槽：run <名> <局时限> -- <命令…>，超时杀掉退出 124
shift 2; cap=$1; shift 2; S2A_FAKE_IN_SLOT=1 "$@" & p=$!; ( sleep "$cap"; kill $p 2> /dev/null ) & w=$!
wait $p; rc=$?; kill $w 2> /dev/null; [ $rc -ge 128 ] && exit 124; exit $rc
S
cat > $R/runtime/run_mac.sh <<'S'
R=$(cd "$(dirname "$0")/.." && pwd); D=$2; echo "${S2A_HOST_PREBUILT:-}" > "$D/prebuilt"; [ "${S2A_HOST_PREBUILT:-}" = 1 ] || make -C "$R" -s host || exit 1
[ -n "${S2A_FAKE_NOSUM:-}" ] || echo '{"marked": true, "mark_frame": 7, "first_frame_to_mark_s": 1.0}' > "$D/ap_summary.json"
# 替身宿主：S2A_GFX=generic 或 S2A_FAKE_GENERIC=1 → 通用，否则直连（同 runtime/src/gfxmode.c 的 host.log 行）
if [ -n "${S2A_GFX:-}${S2A_FAKE_GENERIC:-}" ]; then echo "[s2a] 图形模式：通用（依据 测试）" > "$D/host.log"; else echo "[s2a] 图形模式：直连（依据 测试）" > "$D/host.log"; fi
[ -n "${S2A_FAKE_NOSUM:-}" ] && echo "[s2a] S2A 标记 MARK：帧 42" >> "$D/host.log"; true
S
# 局时限给 60 秒（只兜底挂死；要证的是编译在不在槽里，由 builds.log 判，不靠时限卡）
o=$(S2A_ROOTS=$T/roots S2A_LOOP_CAP=60 S2A_LOOP_SEC=1 bash $R/tools/entry_check.sh tg handheld $T/out 2>&1); rc=$?
bl=$(tr '\n' ' ' < $R/builds.log 2> /dev/null)
if [ $rc = 0 ] && echo "$o" | grep -q '过 tg' && [ "$bl" = "slot=0 " ]; then echo "通 编译在局槽外做完、局里 make 空转：期望 过 / 退出 0、builds.log「slot=0」1 行 → 真结果 builds.log「${bl}」$(echo "$o" | tail -1)"
else echo "不通 编译在局槽外做完、局里 make 空转：期望 过 / 退出 0、builds.log「slot=0」1 行 → 真结果 rc=$rc builds.log「${bl:-无}」$(echo "$o" | tail -1)"; bad=1; fi
[ "$(cat $T/out/prebuilt 2> /dev/null)" = 1 ] && echo "通 宿主已在时限外编好 → 带 S2A_HOST_PREBUILT=1 给 run_mac.sh（槽内不再 make）" || { echo "不通 没把 S2A_HOST_PREBUILT=1 带给 run_mac.sh：期望 1 → 真结果「$(cat $T/out/prebuilt 2> /dev/null)」"; bad=1; }
c() { local name=$1 want_rc=$2 want=$3; shift 3; o=$(env S2A_ROOTS=$T/roots S2A_LOOP_CAP=10 S2A_LOOP_SEC=1 "$@" 2>&1); r=$?
  if [ $r = ${want_rc} ] && echo "$o" | grep -q "${want}"; then echo "通 ${name}：期望 退出 ${want_rc}「${want}」→ 真结果 $(echo "$o" | tail -1 | cut -c1-90)"
  else echo "不通 ${name}：期望 退出 ${want_rc}「${want}」→ 真结果 rc=$r $(echo "$o" | tail -1)"; bad=1; fi; }
c "缺省直连、根只有旧链库 → 待直连根、不起局" 5 "待直连根 old" bash $R/tools/entry_check.sh old handheld $T/o1
[ ! -e $T/o1 ] || { echo "不通 待直连根时不该建局目录"; bad=1; }
# 直连库分片核对（11-01 究极4：出包时分片在、快照里没有，丢在出包后某步；原先只查 lib.idx 在不在）：期望按 idx 手写（1 个分片、应 100 字节）
cp -R $T/roots/tg@现行 $T/roots/miss@现行; rm $T/roots/miss@现行/shaders/direct/b-abc123/lib.000.pak
c "分片文件缺 → 报红点名 lib.000.pak 与完整路径、退出 2、不起局" 2 "lib.000.pak（.*miss@现行/shaders/direct/b-abc123/lib.000.pak，应 100 字节）" bash $R/tools/entry_check.sh miss handheld $T/o2
[ ! -e $T/o2/in_snap ] || { echo "不通 分片缺时不该做快照"; bad=1; }
cp -R $T/roots/tg@现行 $T/roots/sz@现行; head -c 40 /dev/zero > $T/roots/sz@现行/shaders/direct/b-abc123/lib.000.pak
c "分片大小不符 → 报红点名「实 40 应 100」" 2 "大小不符：lib.000.pak（.*实 40 应 100）" bash $R/tools/entry_check.sh sz handheld $T/o3
printf 'import shutil,sys,glob,os; shutil.copytree(sys.argv[1], sys.argv[2]); [os.remove(f) for f in glob.glob(sys.argv[2]+"/shaders/direct/*/lib.*.pak")]\n' > $R/tools/clonedir_drop.py
cp $R/tools/clonedir.py $R/tools/clonedir_ok.py; cp $R/tools/clonedir_drop.py $R/tools/clonedir.py
c "源根分片齐、克隆后快照丢分片（丢在 clonedir 这步）→ 报红点名快照里缺哪一片、说明丢在 clonedir" 2 "快照里直连库分片不全.*丢在 clonedir" bash $R/tools/entry_check.sh tg handheld $T/o4
/usr/bin/grep -q "分片清点\[进局检查·源根\].*在且大小相符 1/1" $T/o4/shard_inventory.log && /usr/bin/grep -q "分片清点\[进局检查·快照\].*缺：lib.000.pak" $T/o4/shard_inventory.log && echo "通 分片清点日志：源根 1/1 齐、快照缺 lib.000.pak（下次复现一眼看出丢在克隆）" || { echo "不通 分片清点日志不对：$(cat $T/o4/shard_inventory.log 2> /dev/null | cut -c1-200)"; bad=1; }
cp $R/tools/clonedir_ok.py $R/tools/clonedir.py
c "缺省直连、宿主退成通用 → 没走直连" 1 "没走直连 tg" env S2A_FAKE_GENERIC=1 bash $R/tools/entry_check.sh tg handheld $T/o2
c "显式 S2A_ENTRY_GFX=generic → 通用局照判过（只验兜底）" 0 "过 tg" env S2A_ENTRY_GFX=generic S2A_ROOT_TAG=现行 bash $R/tools/entry_check.sh tg handheld $T/o3
c "显式通用对旧链根也照跑（不受直连预判拦）" 0 "过 old" env S2A_ENTRY_GFX=generic bash $R/tools/entry_check.sh old handheld $T/o4
c "没有小结（收局前被收）→ 按日志「S2A 标记 MARK：帧 42」判过" 0 "过 tg.*MARK 帧 42" env S2A_FAKE_NOSUM=1 bash $R/tools/entry_check.sh tg handheld $T/o5
# 同树 make host 串行（11-02 幻想水浒：几道局同时重链同一个宿主，拿到没链 C# 的宿主）：期望按规则手写——3 个进局检查同时起，
#   替身 make 每次都重做、做的时候发现另一个在做就记 overlap；串行则 3 个都过、builds2.log 3 行、没有 overlap
printf '.PHONY: host\nhost:\n\t@if [ -e building ]; then touch overlap; fi; touch building; sleep 1; rm -f building; echo x >> builds2.log\n' > $R/Makefile
rm -f $R/overlap $R/builds2.log
for i in 1 2 3; do ( S2A_ROOTS=$T/roots S2A_LOOP_CAP=60 S2A_LOOP_SEC=1 bash $R/tools/entry_check.sh tg handheld $T/p$i > $T/p$i.out 2>&1; echo $? > $T/p$i.rc ) & done; wait
rcs="$(cat $T/p1.rc $T/p2.rc $T/p3.rc | tr '\n' ' ')"; nb=$(grep -c . $R/builds2.log 2> /dev/null)
if [ "$rcs" = "0 0 0 " ] && [ ! -e $R/overlap ] && [ "$nb" -ge 3 ]; then echo "通 同树 make host 串行：3 个进局检查同时起，替身 make 没见过并发、3 个都过"
else echo "不通 同树 make host 串行：期望 rc 0 0 0、无 overlap、builds2.log ≥3 行 → 真结果 rc ${rcs}overlap=$([ -e $R/overlap ] && echo 有 || echo 无) 行数 ${nb}"; bad=1; fi
exit $bad
