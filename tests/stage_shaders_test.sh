#!/bin/bash
# 着色器阶段单测（pack/stage_shaders.sh，假 shader_pack.sh，临时产物根，约 2 秒）：bash tests/stage_shaders_test.sh
# 期望按规则手写：全绿 → 提交、无 red.txt、🟢；有红但产物齐全 → 提交为部分包、shaders/red.txt 记红数、🟡 且有【红】行、退出 0；
# 有红且缺离线库 → 中止、现行不动、退出 1；明细副本都留在 <根>/.failed/<款>_shaders/
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0
unset S2A_PSO_OS   # 外层（门禁开头 source tools/toolchain.sh）解析出的目标 iOS 大版本不漏进来：键里的 -os 只由用例自己给（10-25 派 mini 时整批键多出 -os26 / -os27 判红）
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
mkdir -p $T/repo/pack $T/repo/tools $T/repo/graphics/tools $T/roots
cp "$H/pack/stage_keyfiles.sh" $T/repo/pack/; cp "$H/tools/stage_deps.py" $T/repo/tools/; cp -R "$H/tools/stage_deps_hook" $T/repo/tools/   # 各阶段实际读入进键（pack/stage_keyfiles.sh，10-30）
mkdir -p $T/repo/graphics/tools/shbake; cp "$H/graphics/tools/shbake/shcollect.sh" "$H/graphics/tools/shbake/speccombo.py" "$H/graphics/tools/shbake/specpipe.py" "$H/graphics/tools/shbake/fbrvars.py" "$H/graphics/tools/shbake/psouse.py" "$H/graphics/tools/shbake/guest_cache.py" $T/repo/graphics/tools/shbake/; cp "$H/pack/roots.sh" "$H/pack/stage_shaders.sh" $T/repo/pack/; cp -R "$H/pack/stages" $T/repo/pack/; cp "$H/tools/clonedir.py" "$H/tools/plock.sh" "$H/tools/flock_hold.py" $T/repo/tools/
# 着色器预编按进度判卡死（10-23）：stage_shaders 经 graphics/tools/timeout_snap.sh（依赖 tools/safe_killpg.sh）跑 shader_pack
# romfs_list.py：仓库里唯一的 RomFS 遍历（11-03），被测脚本经它列 RomFS
mkdir -p $T/repo/graphics/nvn/tools; cp "$H/graphics/nvn/tools/romfs_list.py" $T/repo/graphics/nvn/tools/; cp "$H/graphics/nvn/tools/gfx_api.py" $T/repo/graphics/nvn/tools/   # 出包分流判法（假 main 不是 NSO → unknown，照常烘）
cp "$H/graphics/tools/timeout_snap.sh" $T/repo/graphics/tools/; cp "$H/tools/safe_killpg.sh" $T/repo/tools/
cat > $T/repo/graphics/tools/shader_pack.sh <<'EOF'
[ "$1" = --key ] && { echo "k${FAKE_KEY:-1}"; exit 0; }
[ -n "${FAKE_CALLS:-}" ] && echo 1 >> "$FAKE_CALLS"; sleep "${FAKE_SLEEP:-0}"
[ -n "${FAKE_ARGLOG:-}" ] && echo "$*" > "$FAKE_ARGLOG"
[ -n "${FAKE_PREVLOG:-}" ] && echo "${S2A_SHADERS_PREV:-}" > "$FAKE_PREVLOG"
[ "${FAKE_SAME:-0}" = 1 ] && { echo "产出指纹 abcd1234 与现行相同"; exit 3; }   # ②½ 产出指纹与现行相同（graphics/tools/shbake/out_fp.py）
[ "${FAKE_ZERO:-0}" != 0 ] && { mkdir -p "$2/work"; echo x > "$2/work/extract.log"; [ "$FAKE_ZERO" = 1 ] && echo "pak 条目不支持：压缩方式 Oodle 703" > "$2/work/zero_unsupported.txt" || : > "$2/work/zero_unsupported.txt"; exit 4; }   # ① 抽取 0 支（10-27 最终幻想 共鸣）：1 = 抽取器有「不支持」项，2 = 包里没有可认的容器
[ -n "${FAKE_ENVLOG:-}" ] && echo "J=${J:-} PSO_J=${S2A_PSO_J:-}" > "$FAKE_ENVLOG"
O=$2; [ "${FAKE_RACE:-0}" = 1 ] && bash -c 'source "$0/pack/roots.sh"; W=$(root_begin acnh race) && echo r > "$W/race.txt" && root_commit acnh race' "$(cd "$(dirname "$0")/../.." && pwd)"   # 烘的过程中别的树提交了同一款
mkdir -p "$O/shcache/${FAKE_TID:-0100}" "$O/work"; [ "${FAKE_NOTOC:-0}" = 1 ] || echo s > "$O/shcache/${FAKE_TID:-0100}/shared.toc"; [ "${FAKE_NOLIB:-0}" = 1 ] || { echo m > "$O/gal.0.metallib"; printf "0000000000000000\tgal.0.metallib\n" > "$O/gal.shards"; echo i > "$O/gal.idx"; }
printf '{"red": {"no_rule": %s, "xlate": 0}, "wall_s": 3, "pso": {"chunks": %s}, "pso_archive_kb": %s}\n' "${FAKE_RED:-0}" "${FAKE_PSO_N:-2}" "${FAKE_PSO_KB:-100}" > "$O/shader_pack.json"; [ "${FAKE_RED:-0}" = 0 ]
EOF
(cd $T/repo && git init -q && git add -A && git -c user.email=t@t -c user.name=t commit -qm x)
export S2A_SHADERS_REUSE=0   # 下面各例测的是重烘逻辑（同出包口径）；开发刷新的「口径同就复用」在末尾两例单测
export S2A_ROOTS=$T/roots S2A_ROOTS_SHARED=$T/shared S2A_SHCOLLECT=$T/shcollect S2A_SCHED_DIR=$T/sched   # 收集目录 / 调度作业隔离到本单测（不读真的收回缓存）
mkdir -p $T/roots/acnh@s0/romfs; echo r > $T/roots/acnh@s0/romfs/f; ln -s acnh@s0 $T/roots/acnh@现行
S() { bash $T/repo/pack/stage_shaders.sh acnh; }
cur() { basename "$(cd -P $T/roots/acnh@现行 && pwd)"; }
o=$(FAKE_KEY=1 S 2>&1); r=$?; c=$(cd -P $T/roots/acnh@现行 && pwd)
ck "全绿 → 提交、无 red.txt、🟢（$(echo "$o" | tail -1 | cut -c1-60)）" '[ $r = 0 ] && [ -s $c/shaders/gal.idx ] && [ ! -e $c/shaders/red.txt ] && [ ! -d $c/shaders/work ] && [[ "$o" == *🟢* ]]'
o=$(FAKE_KEY=2 FAKE_RED=3 S 2>&1); r=$?; c=$(cd -P $T/roots/acnh@现行 && pwd)
ck "有红但产物齐全 → 部分包：提交、red.txt 记「no_rule 3」、🟡 + 【红】行、退出 0" '[ $r = 0 ] && grep -q "no_rule 3" $c/shaders/red.txt && [ "$(cat $c/.stage_shaders)" = k2 ] && [[ "$o" == *🟡* ]] && [[ "$o" == *【红】*部分包* ]]'
ck "部分包也留明细副本" '[ -f $T/roots/.failed/acnh_shaders/shader_pack.json ]'
o=$(FAKE_KEY=4 FAKE_RACE=1 S 2>&1); r=$?; c=$(cd -P $T/roots/acnh@现行 && pwd)
ck "烘的过程中别的树提交了同一款 → 重放到新现行：两边产物都在（race.txt + shaders）、键 = k4" '[ $r = 0 ] && [ -f $c/race.txt ] && [ -s $c/shaders/gal.idx ] && [ "$(cat $c/.stage_shaders)" = k4 ]'
b=$(cur); o=$(FAKE_KEY=3 FAKE_RED=2 FAKE_NOLIB=1 S 2>&1); r=$?
ck "有红且缺离线库 → 中止、退出 1、现行不动（${b}）" '[ $r = 1 ] && [ "$(cur)" = "$b" ] && [[ "$o" == *产物不全* ]] && [ -z "$(ls -d $T/roots/*.tmp 2>/dev/null)" ]'
# Ryujinx 缓存硬判据（10-26 总指挥，星露谷根 shcache/<程序号>/ 空目录照报成功）：shcache 下本款目录没有 shared.toc → 中止、退出 1、现行不动、点名缺 shared.toc
b=$(cur); o=$(FAKE_KEY=6 FAKE_NOTOC=1 S 2>&1); r=$?
ck "shcache/0100/ 没有 shared.toc → 中止、退出 1、现行不动（${b}）、点名" '[ $r = 1 ] && [ "$(cur)" = "$b" ] && [[ "$o" == *"0100/ 没有 shared.toc"* ]] && [ -z "$(ls -d $T/roots/*.tmp 2>/dev/null)" ]'
# 管线归档硬判据（10-21）：有分片而归档 0 KB（三款 harden 后全片失败仍提交成现行）→ 中止、退出 1、现行不动、点名「管线归档 0 KB」；没有分片（程序 0）照常提交
b=$(cur); o=$(FAKE_KEY=5 FAKE_RED=3 FAKE_PSO_N=27 FAKE_PSO_KB=0 S 2>&1); r=$?
ck "有分片、归档 0 KB → 中止、退出 1、现行不动（${b}）、点名 27 片" '[ $r = 1 ] && [ "$(cur)" = "$b" ] && [[ "$o" == *"管线归档 0 KB（27 片全部失败"* ]] && [ -z "$(ls -d $T/roots/*.tmp 2>/dev/null)" ]'
# 兜底不出管线归档（S2A_SHADER_NO_PSO=1，10-24 快速通用模式方案）：有分片、归档 0 KB 也照常提交；键带 -nopso（与出归档的包不共用产物）
o=$(S2A_SHADER_NO_PSO=1 FAKE_KEY=5n FAKE_PSO_N=27 FAKE_PSO_KB=0 S 2>&1); r=$?; c=$(cd -P $T/roots/acnh@现行 && pwd)
ck "S2A_SHADER_NO_PSO=1：27 片、归档 0 KB → 照常提交 🟢、着色器键带 -nopso（$(cat $c/.stage_shaders 2>/dev/null)）" '[ $r = 0 ] && [[ "$(cat $c/.stage_shaders)" == k5n*-nopso* ]] && [[ "$o" == *🟢* ]] && [[ "$o" != *"管线归档 0 KB"* ]]'
o=$(FAKE_KEY=6 FAKE_PSO_N=0 FAKE_PSO_KB=0 S 2>&1); r=$?; c=$(cd -P $T/roots/acnh@现行 && pwd)
ck "没有分片（程序 0）、归档 0 KB → 照常提交 🟢" '[ $r = 0 ] && [ "$(cat $c/.stage_shaders)" = k6 ] && [[ "$o" == *🟢* ]]'
# 重烘暂停已撤（10-25 总指挥）：产物根留着旧的 .pause_shaders 标记 → 键变了照常重烘（退出 0、现行换新），不再挡
echo "等 pso-fc 合入" > $T/roots/.pause_shaders; b=$(cur); o=$(FAKE_KEY=7 S 2>&1); r=$?; rm -f $T/roots/.pause_shaders
ck "旧 .pause_shaders 标记不挡重烘：键变了 → 照常烘（退出 ${r}、现行 ${b} → $(cur)）、不报「重烘暂停」" '[ $r = 0 ] && [ "$(cur)" != "$b" ] && [[ "$o" != *重烘暂停* ]]'
# 并行度：没给 J / S2A_CPU_BAKE 时 J = 9、本机管线分片 S2A_PSO_J = J（每片单线程）；调用方给了就用调用方的
#   给定 S2A_MEM_BAKE_GB：不让「按本机物理内存降路数」掺进来（10-25 派 Air：16 GB 机器 acnh 12 GB 放不下 → 4 路，判红；降路数由下面 bake_fit 一条专测）
(unset J S2A_PSO_J S2A_CPU_BAKE; S2A_MEM_BAKE_GB=12 FAKE_ENVLOG=$T/env1 FAKE_KEY=21 S > /dev/null 2>&1); (J=6 S2A_PSO_J=2 S2A_MEM_BAKE_GB=12 FAKE_ENVLOG=$T/env2 FAKE_KEY=22 S > /dev/null 2>&1)
ck "重烘并行度：缺省 J=9、PSO_J=9（实为 $(cat $T/env1 2>/dev/null)）；调用方给 J=6 PSO_J=2 照用（实为 $(cat $T/env2 2>/dev/null)）" '[ "$(cat $T/env1)" = "J=9 PSO_J=9" ] && [ "$(cat $T/env2)" = "J=6 PSO_J=2" ]'
# 管线归档参数进阶段键：取缺省值（S2A_PSO_P=40、PSO_NTJ=1）键不变 → 跳过；非缺省（PSO_NTJ=2、PSO_NTJ 空串 = 编译器自定、S2A_PSO_P=300）→ 键带后缀、重烘
(unset PSO_NTJ S2A_PSO_P; FAKE_KEY=31 S > /dev/null 2>&1); o5=$(PSO_NTJ=1 S2A_PSO_P=40 FAKE_KEY=31 S 2>&1); r5=$?
(PSO_NTJ=2 FAKE_KEY=31 S > /dev/null 2>&1); k6=$(cat $T/roots/acnh@现行/.stage_shaders); (PSO_NTJ= FAKE_KEY=31 S > /dev/null 2>&1); k7=$(cat $T/roots/acnh@现行/.stage_shaders)
(unset PSO_NTJ; S2A_PSO_P=300 FAKE_KEY=31 S > /dev/null 2>&1); k8=$(cat $T/roots/acnh@现行/.stage_shaders)
ck "归档参数进键：缺省值显式给 → 跳过（退出 ${r5}）；PSO_NTJ=2 → ${k6}、空串 → ${k7}、P=300 → ${k8}" '[ $r5 = 0 ] && [[ "$o5" == *跳过* ]] && [ "$k6" = k31-j2 ] && [ "$k7" = k31-j ] && [ "$k8" = k31-p300 ]'
# 首局根治 C①：收集目录里有收回的运行时缓存 → 键带 -rg<各份指纹>、每份作 --ref-guest 交给 shader_pack；没有就不带（上面各例）
mkdir -p $T/shcollect/acnh/0100/aaaa $T/shcollect/acnh/0100/bbbb; touch $T/shcollect/acnh/0100/aaaa/shared.toc $T/shcollect/acnh/0100/bbbb/shared.toc
o=$(FAKE_KEY=9 FAKE_ARGLOG=$T/args S 2>&1); r=$?; c=$(cd -P $T/roots/acnh@现行 && pwd)
ck "有收回缓存 → 键 k9-rg…、shader_pack 收到两份 --ref-guest" '[ $r = 0 ] && [[ "$(cat $c/.stage_shaders)" == k9-rg* ]] && grep -q -- "--ref-guest $T/shcollect/acnh/0100/aaaa --ref-guest $T/shcollect/acnh/0100/bbbb" $T/args'
k1=$(cat $c/.stage_shaders); o=$(FAKE_KEY=9 S 2>&1); ck "同一批收回缓存再跑 → 键不变、跳过" '[[ "$o" == *跳过* ]]'
mkdir -p $T/shcollect/acnh/0100/cccc; touch $T/shcollect/acnh/0100/cccc/shared.toc; o=$(FAKE_KEY=9 S 2>&1); c=$(cd -P $T/roots/acnh@现行 && pwd)
ck "多收一份 → 键变、重烘" '[ "$(cat $c/.stage_shaders)" != "$k1" ] && [[ "$(cat $c/.stage_shaders)" == k9-rg* ]]'
# 特化组合表（10-22）：调度作业（不分款）host.log 里有「特化组合」→ 收成全款表、指纹进键（-sc）；烘焙键没变只换表（不调 shader_pack）、表不变跳过、烘焙键变了整份重烘并带上表
mkdir -p $T/sched/jobs/j1/out_1; echo GAME=mk8d > $T/sched/jobs/j1/job.env
printf '[gal] 特化组合 v1 65 0 0 0 0 0 0 0 0 1\n' > $T/sched/jobs/j1/out_1/host.log
kb=$(cat $T/roots/acnh@现行/.stage_shaders); : > $T/calls; o=$(FAKE_KEY=9 FAKE_CALLS=$T/calls S 2>&1); r=$?; c=$(cd -P $T/roots/acnh@现行 && pwd)
ck "别的款的局收到组合、烘焙键没变 → 只换表：不调 shader_pack、键 = 原键-sc…、shaders/spec_combos.tsv 1 条（$(echo "$o" | tail -1 | cut -c1-50)）" '[ $r = 0 ] && [ ! -s $T/calls ] && [[ "$(cat $c/.stage_shaders)" == "$kb"-sc* ]] && [ "$(grep -vc "^#" $c/shaders/spec_combos.tsv)" = 1 ] && [ -s $c/shaders/gal.idx ]'
ks=$(cat $c/.stage_shaders); o=$(FAKE_KEY=9 FAKE_CALLS=$T/calls S 2>&1); ck "表不变再跑 → 跳过" '[[ "$o" == *跳过* ]] && [ ! -s $T/calls ]'
printf '[gal] 特化组合 v1 90 0 1 1 5 6 1 2 2 15\n' >> $T/sched/jobs/j1/out_1/host.log; o=$(FAKE_KEY=9 FAKE_CALLS=$T/calls S 2>&1); c=$(cd -P $T/roots/acnh@现行 && pwd)
ck "多收一条 → 仍只换表：不调 shader_pack、键变、表 2 条" '[ ! -s $T/calls ] && [ "$(cat $c/.stage_shaders)" != "$ks" ] && [ "$(grep -vc "^#" $c/shaders/spec_combos.tsv)" = 2 ]'
o=$(FAKE_KEY=10 FAKE_CALLS=$T/calls S 2>&1); c=$(cd -P $T/roots/acnh@现行 && pwd)
ck "烘焙键变了 → 整份重烘（调 shader_pack 1 次）、表照带" '[ "$(wc -l < $T/calls | tr -d " ")" = 1 ] && [[ "$(cat $c/.stage_shaders)" == k10-rg*-sc* ]] && [ "$(grep -vc "^#" $c/shaders/spec_combos.tsv)" = 2 ]'
# 新款第一次烘焙（10-23 用户体验线，奥德赛一键出包烘了两遍）：现行根还没有 shaders/shcache/，程序号取 unpack.tsv → 第一遍就带社区参考库（键 -rl…）；
#   烘完 shcache/<程序号小写> 出现，再刷新键不变、跳过（改前：第一遍不带 -rl、第二遍带上、整份重烘）
mkdir -p $T/roots/newg@s0/romfs $T/rl/v3; echo r > $T/roots/newg@s0/romfs/f; printf 'title_id\t0100abcdef012000\n' > $T/roots/newg@s0/unpack.tsv; ln -s newg@s0 $T/roots/newg@现行
echo ref > $T/rl/v3/0100ABCDEF012000.s2rl; : > $T/calls
N() { S2A_REFLIB_ROOT=$T/rl S2A_REFLIB_DIRS=v3 FAKE_TID=0100abcdef012000 FAKE_KEY=50 FAKE_CALLS=$T/calls bash $T/repo/pack/stage_shaders.sh newg; }
o1=$(N 2>&1); k1=$(cat $T/roots/newg@现行/.stage_shaders); o2=$(N 2>&1); k2=$(cat $T/roots/newg@现行/.stage_shaders)
ck "新款第一遍：键带 -rl（${k1}）、shader_pack 只调 1 次（$(wc -l < $T/calls | tr -d ' ')）、再刷新跳过、键不变" '[[ "$k1" == k50-rl* ]] && [ "$k1" = "$k2" ] && [ "$(wc -l < $T/calls | tr -d " ")" = 1 ] && [[ "$o2" == *跳过* ]]'
# 客体着色器缓存（10-27 王国之泪 yuzu v10 社区缓存 + 用户自带导入）：社区目录 / 用户目录里 <程序号>/ 下的 yuzu 系缓存 → --ref-bundle、键带 -gc；
#   坏文件不中止：社区的【红】、用户的【黄】；S2A_GUEST_CACHE=0 → 不并、键不带 -gc；社区按 version.tsv 版本门控（原件 1.4.3 不在登记里 / 没登记 → 不并、🟡 版本不符），用户的不门控。期望按 shaders.sh 头注释手写；合成缓存 = 一条计算记录（yuzu v10 布局）
mkdir -p $T/roots/newh@s0/romfs $T/gc/v10/0100ABCDEF013000 $T/ugc; echo r > $T/roots/newh@s0/romfs/f; printf 'title_id\t0100abcdef013000\ndisplay_version\t1.4.3\n' > $T/roots/newh@s0/unpack.tsv; printf 'versions\t1.4.3 1.4.2\n' > $T/gc/v10/0100ABCDEF013000/version.tsv; ln -s newh@s0 $T/roots/newh@现行
python3 -c "import struct,sys;open(sys.argv[1],'wb').write(b'yuzucach'+struct.pack('<I',10)+struct.pack('<I',1)+struct.pack('<QQQQQ',8,0,0,0,0)+struct.pack('<IIIIIII',0,0,0x100,0x100,0x100,0,5)+b'\x22'*8+struct.pack('<IIII',32,1,1,0)+b'\x33'*24)" $T/gc/v10/0100ABCDEF013000/vulkan.bin
GH() { S2A_REFLIB_ROOT=$T/gc S2A_REFLIB_DIRS=none S2A_GUEST_CACHE_DIRS=v10 S2A_USER_SHCACHE=$T/ugc S2A_RUN_ROOT=$T/run FAKE_TID=0100abcdef013000 FAKE_CALLS=$T/callsg FAKE_ARGLOG=$T/argsg bash $T/repo/pack/stage_shaders.sh newh; }
o=$(FAKE_KEY=60 GH 2>&1); r=$?; k=$(cat $T/roots/newh@现行/.stage_shaders)
ck "社区客体缓存 → 退出 ${r}、键带 -gc（${k}）、交 shader_pack --ref-bundle 且包在、🟢 并入社区" '[ $r = 0 ] && [[ "$k" == k60*-gc* ]] && grep -q -- "--ref-bundle $T/run/s2arm/cache/guestbundle/[0-9a-f]*\.s2gb" $T/argsg && [ -s "$(grep -o -- "--ref-bundle [^ ]*" $T/argsg | cut -d" " -f2)" ] && [[ "$o" == *并入社区客体着色器缓存* ]]'
mkdir -p $T/ugc/0100ABCDEF013000; cp $T/gc/v10/0100ABCDEF013000/vulkan.bin $T/ugc/0100ABCDEF013000/opengl.bin; printf '\x44' >> $T/ugc/0100ABCDEF013000/opengl.bin
o=$(FAKE_KEY=61 GH 2>&1); r=$?
ck "用户目录放坏文件（末尾多 1 字节）→ 退出 ${r}、【黄】点名、社区那份照并" '[ $r = 0 ] && [[ "$o" == *【黄】*用户客体着色器缓存转不出* ]] && [ "$(grep -o -- "--ref-bundle" $T/argsg | wc -l | tr -d " ")" = 1 ]'
cp $T/gc/v10/0100ABCDEF013000/vulkan.bin $T/ugc/0100ABCDEF013000/opengl.bin; o=$(FAKE_KEY=62 GH 2>&1); k2=$(cat $T/roots/newh@现行/.stage_shaders)
ck "用户目录放好文件 → 两份都并（--ref-bundle × $(grep -o -- "--ref-bundle" $T/argsg | wc -l | tr -d " ")）、🟢 并入用户" '[[ "$o" == *并入用户客体着色器缓存* ]] && [ "$(grep -o -- "--ref-bundle" $T/argsg | wc -l | tr -d " ")" = 2 ]'
printf 'yuzucach\x0a\x00\x00\x00junk' > $T/gc/v10/0100ABCDEF013000/vulkan.bin; o=$(FAKE_KEY=63 GH 2>&1); r=$?
ck "社区目录坏文件 → 退出 ${r}、【红】点名、用户那份照并" '[ $r = 0 ] && [[ "$o" == *【红】*社区客体着色器缓存转不出* ]] && [ "$(grep -o -- "--ref-bundle" $T/argsg | wc -l | tr -d " ")" = 1 ]'
cp $T/ugc/0100ABCDEF013000/opengl.bin $T/gc/v10/0100ABCDEF013000/vulkan.bin; printf 'versions\t1.0.0 1.1.0\n' > $T/gc/v10/0100ABCDEF013000/version.tsv; o=$(FAKE_KEY=65 GH 2>&1); r=$?
ck "社区缓存录制版本 1.0.0 / 1.1.0、原件 1.4.3 → 退出 ${r}、🟡 版本不符未并入、用户那份照并（--ref-bundle × $(grep -o -- "--ref-bundle" $T/argsg | wc -l | tr -d " ")）" '[ $r = 0 ] && [[ "$o" == *版本不符未并入*录制\ 1.0.0\ 1.1.0*原件\ 1.4.3* ]] && [ "$(grep -o -- "--ref-bundle" $T/argsg | wc -l | tr -d " ")" = 1 ]'
rm $T/gc/v10/0100ABCDEF013000/version.tsv; o=$(FAKE_KEY=66 GH 2>&1)
ck "社区缓存没登记版本 → 不并、🟡 写「未登记」" '[[ "$o" == *版本不符未并入*未登记* ]] && [ "$(grep -o -- "--ref-bundle" $T/argsg | wc -l | tr -d " ")" = 1 ]'
printf 'versions\t1.4.3\n' > $T/gc/v10/0100ABCDEF013000/version.tsv
o=$(S2A_GUEST_CACHE=0 FAKE_KEY=64 GH 2>&1); k3=$(cat $T/roots/newh@现行/.stage_shaders)
ck "S2A_GUEST_CACHE=0 → 键不带 -gc（${k3}）、不交 --ref-bundle" '[[ "$k3" != *-gc* ]] && ! grep -q -- "--ref-bundle" $T/argsg'
# 产出与现行相同（10-24 总指挥「输出不变就不算变」）：shader_pack 收到 S2A_SHADERS_PREV = 现行 shaders/ 的真实路径；退出 3 → 沿用现行着色器（逐文件相同）、只记新键、🟢、退出 0；
#   反证：退出 0（产出不同）→ 用新产出（标记文件在）
c0=$(cd -P $T/roots/acnh@现行 && pwd); cp -cR $c0/shaders $T/sh_before
o=$(FAKE_KEY=70 FAKE_SAME=1 FAKE_PREVLOG=$T/prev S 2>&1); r=$?; c=$(cd -P $T/roots/acnh@现行 && pwd)
ck "产出与现行相同 → 退出 ${r}、沿用现行着色器（逐文件比对）、键 = k70…（$(cat $c/.stage_shaders | cut -c1-12)）、交出的现行路径 = $(cat $T/prev 2>/dev/null)" '[ $r = 0 ] && [[ "$o" == *产出与现行相同* ]] && [[ "$(cat $c/.stage_shaders)" == k70* ]] && diff -r $T/sh_before $c/shaders > /dev/null && [ "$(cat $T/prev)" = "$c0/shaders" ]'
o=$(FAKE_KEY=70 S 2>&1); ck "沿用后同键再跑 → 跳过" '[[ "$o" == *跳过* ]]'
o=$(FAKE_KEY=71 S 2>&1); r=$?; c=$(cd -P $T/roots/acnh@现行 && pwd)
ck "反证：产出不同（退出 0）→ 用新产出、键 = k71…" '[ $r = 0 ] && [[ "$(cat $c/.stage_shaders)" == k71* ]] && [[ "$o" != *产出与现行相同* ]]'
# 开发刷新复用（S2A_SHADERS_REUSE 缺省 1，pack/ipa.sh 设 0）：现行包离线索引口径与 Ryujinx 缓存翻译器版本都同本树 → 不烘、现行不动、🟡；口径不同 → 照烘
mkdir -p $T/repo/graphics/metal $T/repo/compat/tree/src/Ryujinx.Graphics.Gpu/Shader/DiskCache
printf '#define NXGAL_XC_VERSION 19u\n' > $T/repo/graphics/metal/gal_abi.h
printf '        public const uint CodeGenVersion = 7354 + 6;\n' > $T/repo/compat/tree/src/Ryujinx.Graphics.Gpu/Shader/DiskCache/DiskCacheHostStorage.cs
(cd $T/repo && git add -A && git -c user.email=t@t -c user.name=t commit -qm caps)
c=$(cd -P $T/roots/acnh@现行 && pwd); python3 -c "import struct,sys; open(sys.argv[1],'wb').write(struct.pack('<5I',0x494c4147,1,19,0,0))" $c/shaders/gal.idx
for d in $c/shaders/shcache/*/; do python3 -c "import struct,sys; open(sys.argv[1],'wb').write(struct.pack('<3I',0,0,7360))" $d/shared.toc; done
b0=$(cur); : > $T/calls; o=$(unset S2A_SHADERS_REUSE; FAKE_KEY=61 FAKE_CALLS=$T/calls S 2>&1); r=$?
ck "复用：口径同本树（离线索引 19、Ryujinx 7360）→ 不调 shader_pack（$(wc -l < $T/calls | tr -d ' ') 次）、现行不动、🟡（$(echo "$o" | tail -1 | cut -c1-40)）" '[ $r = 0 ] && [ "$(wc -l < $T/calls | tr -d " ")" = 0 ] && [ "$(cur)" = "$b0" ] && [[ "$(echo "$o" | tail -1)" == 🟡*复用* ]]'
python3 -c "import struct,sys; open(sys.argv[1],'wb').write(struct.pack('<5I',0x494c4147,1,18,0,0))" $c/shaders/gal.idx
: > $T/calls; o=$(unset S2A_SHADERS_REUSE; FAKE_KEY=62 FAKE_CALLS=$T/calls S 2>&1); r=$?
ck "复用：离线索引口径 18 ≠ 本树 19 → 照烘（shader_pack $(wc -l < $T/calls | tr -d ' ') 次）、点名口径" '[ $r = 0 ] && [ "$(wc -l < $T/calls | tr -d " ")" = 1 ] && [[ "$o" == *"离线索引口径 18 ≠ 本树 19"* ]]'
# 直连就绪款的通用兜底不预编（C.3，10-26 总指挥；pack/refresh.sh 直连库出成后才给 S2A_SHADER_LAZY=1）：不调 shader_pack、新根里通用产物（离线库 / Ryujinx 缓存）清掉、
#   直连库 shaders/direct/ 原样留着、键带 -lazy、🟢；同键再跑跳过；反证：不给开关（直连没出成）→ 照旧全量烘出离线库——
#   现行是 -lazy 根时不能被「只换特化组合表」快路径当成烘焙键没变（键剥掉 -sc 后与烘焙键相等），首版就栽在这里
c=$(cd -P $T/roots/acnh@现行 && pwd); mkdir -p $c/shaders/direct; printf 'k\n' > $c/shaders/direct/keys.tsv
: > $T/calls; o=$(S2A_SHADER_LAZY=1 FAKE_KEY=80 FAKE_CALLS=$T/calls S 2>&1); r=$?; c2=$(cd -P $T/roots/acnh@现行 && pwd)
ck "兜底不预编：不调 shader_pack（$(wc -l < $T/calls | tr -d ' ') 次）、现行换新根、无 gal.idx / shcache、直连库在、键 sh…-lazy 不取烘焙键 k80（$(cat $c2/.stage_shaders)；一包通用 10-30：烘焙键含目标机型归档对）、🟢" '[ $r = 0 ] && [ ! -s $T/calls ] && [ "$c2" != "$c" ] && [ ! -e $c2/shaders/gal.idx ] && [ ! -e $c2/shaders/shcache ] && [ -s $c2/shaders/direct/keys.tsv ] && [[ "$(cat $c2/.stage_shaders)" == sh*-lazy ]] && [[ "$(cat $c2/.stage_shaders)" != *k80* ]] && [[ "$o" == *🟢*不预编* ]]'
o=$(S2A_SHADER_LAZY=1 FAKE_KEY=80 FAKE_CALLS=$T/calls S 2>&1); ck "兜底不预编同键再跑 → 跳过、不调 shader_pack" '[[ "$o" == *跳过* ]] && [ ! -s $T/calls ]'
lk=$(cat $c2/.stage_shaders); o=$(S2A_SHADER_LAZY=1 S2A_PSO_ARCHS=applegpu_g19p S2A_PSO_OS=26 FAKE_KEY=80 FAKE_CALLS=$T/calls S 2>&1)
ck "一包通用：兜底不预编换目标架构 / 系统大版本 → 键不变（${lk}）、跳过（修前带 -a / -os 后缀另出一版根）" '[[ "$o" == *跳过* ]] && [ ! -s $T/calls ] && [ "$(cat $(cd -P $T/roots/acnh@现行 && pwd)/.stage_shaders)" = "$lk" ]'
o=$(FAKE_KEY=80 FAKE_CALLS=$T/calls S 2>&1); r=$?; c=$(cd -P $T/roots/acnh@现行 && pwd)
ck "反证：不给开关 → 全量烘（shader_pack $(wc -l < $T/calls | tr -d ' ') 次）、gal.idx 回来、键不带 -lazy" '[ $r = 0 ] && [ "$(wc -l < $T/calls | tr -d " ")" = 1 ] && [ -s $c/shaders/gal.idx ] && [[ "$(cat $c/.stage_shaders)" != *-lazy ]]'
: > $T/calls; o=$(S2A_PSO_ARCHS=applegpu_g19p S2A_PSO_OS=26 FAKE_KEY=80 FAKE_CALLS=$T/calls S 2>&1); c=$(cd -P $T/roots/acnh@现行 && pwd)
ck "反证：通用兜底（全量烘）仍按设备出归档 → 键带 -os26 与 -aapplegpu_g19p、重烘（$(cat $c/.stage_shaders)）" '[[ "$(cat $c/.stage_shaders)" == *-os26*-aapplegpu_g19p* ]] && [ "$(wc -l < $T/calls | tr -d " ")" = 1 ]'
# 抽取 0 支（shader_pack.sh 退出 4，10-27 最终幻想 共鸣：着色器全在 Oodle 压缩的 pak 条目里）：只记键、不出通用离线库、退出 0（出包照常往下走）；
#   原因读 shader_pack 写的 work/zero_unsupported.txt：有「不支持」项 = 抽取器缺口 →【红】点名、不中止；空 = 包里真没有可认容器 →【黄】。
#   原先整包停在「产物复制失败」（反证：同样没有离线库、退出 1 的 → 照旧中止）
b=$(cur); o=$(FAKE_KEY=89 FAKE_ZERO=2 S 2>&1); r=$?; c=$(cd -P $T/roots/acnh@现行 && pwd)
ck "抽取 0 支、没有不支持项 → 退出 ${r}、现行换新根、无 gal.idx、【黄】、无【红】（$(echo "$o" | grep 【黄】 | cut -c1-60)）" '[ $r = 0 ] && [ "$(cur)" != "$b" ] && [ ! -e $c/shaders/gal.idx ] && [[ "$(cat $c/.stage_shaders)" == k89* ]] && [[ "$o" == *【黄】*"没有可认的着色器容器"* ]] && [[ "$o" != *【红】* ]]'
b=$(cur); o=$(FAKE_KEY=90 FAKE_ZERO=1 S 2>&1); r=$?; c=$(cd -P $T/roots/acnh@现行 && pwd)
ck "抽取 0 支、抽取器不支持 Oodle → 红行不致命：退出 ${r}、现行换新根、无 gal.idx / shcache / work、键 k90…、【红】点名 Oodle 全文、无【黄】（$(echo "$o" | grep 【红】 | cut -c1-80)）" '[ $r = 0 ] && [ "$(cur)" != "$b" ] && [ ! -e $c/shaders/gal.idx ] && [ ! -e $c/shaders/shcache ] && [ ! -e $c/shaders/work ] && [[ "$(cat $c/.stage_shaders)" == k90* ]] && [[ "$o" == *【红】*"着色器抽取缺口：pak 条目不支持：压缩方式 Oodle 703；"* ]] && [[ "$o" != *【黄】* ]]'
o=$(FAKE_KEY=90 FAKE_CALLS=$T/calls0 S 2>&1); ck "抽取 0 支同键再跑 → 跳过、不调 shader_pack" '[[ "$o" == *跳过* ]] && [ ! -s $T/calls0 ]'
b=$(cur); o=$(FAKE_KEY=91 FAKE_NOLIB=1 FAKE_RED=1 S 2>&1); r=$?
ck "反证：没有离线库的其它失败（退出 1）→ 照旧中止、现行不动" '[ $r = 1 ] && [ "$(cur)" = "$b" ] && [[ "$o" == *产物不全* ]]'
# 小内存机器降并行（10-24 #253：24 GB Mac mini）：bake_fit <按款峰值> <J> <物理内存> → 「J 峰值」，期望手算（上限 = 物理 / 2、每路 = ⌈预留 ÷ J⌉）
eval "$(sed -n '/^bake_fit() {/,/; }$/p' "$H/pack/stages/shaders.sh")"
bf=$(printf '%s|' "$(bake_fit 36 9 24)" "$(bake_fit 36 9 128)" "$(bake_fit 12 9 24)" "$(bake_fit 36 9 8)")
ck "24 GB 机器新款 36 GB → 3 路 12 GB；128 GB 不变 9 路 36 GB；12 GB 的款 24 GB 机器放得下不变；8 GB 机器至少 1 路 4 GB（${bf}）" '[ "$bf" = "3 12|9 36|9 12|1 4|" ]'
chmod -R u+w $T; rm -rf $T; [ $bad = 0 ] && echo "stage_shaders 单测全过" || { echo "stage_shaders 单测有不通"; exit 1; }
