#!/bin/bash
# 门禁覆盖：graphics/tools/direct/direct_lib.sh graphics/tools/direct/runtime_only_lib.sh tests/direct_lib_gap_test.sh
# 直连库现场抽取退 3（内容缺口）→ 运行时现编空直连库（11-06 天眼疯狂兔子 / 马力欧高尔夫：天眼链 pack/orch/oneclick_win.py 直接调 direct_lib.sh，
#   不走 Mac 链 pack/stage_extract.sh + pack/stage_direct.sh 的兜底，整单红）：bash tests/direct_lib_gap_test.sh（假仓库 + 桩，约 1 秒）
#   extract.sh 换成桩：打「直连库失败：直连抽取 0 支着色器（缺口：桩）」退 3。期望手写（同 tests/stage_direct_test.sh 空库那项）：
#   ① 退 0、末行 🟡「离线 0 支、运行时首遇现编」带原因；输出目录 b-v1/lib.idx 48 字节、头「S2ALIB」版本 1、0 条 0 分片、链号 v1；
#      b-v1/inputs.tsv 有 game 0100AAAA00000000、inputs runtime-only-x<11 位>；shader_map.tsv / keys.tsv 在且空；runtime_only.txt 带原因；game.tsv 拷自配置档
#      shader_facts.tsv / shader_pairs.tsv 在、只有注释行（宿主兜底现编载表要它们，空表 = 全部按缺省答；11-06 疯狂兔子缺表「no answer table」整支失败）
#   ② 输出目录里原有的旧库文件（b-old/old.pak）被换走（原子换进，不留旧链产物）
#   ③ 反证：桩退 1（基础设施错）→ 照旧退 1、🔴 抽取失败、输出目录不动（旧文件还在）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0; trap 'rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
P=$T/repo; mkdir -p $P/graphics/tools/direct $P/graphics/nvn/tools $P/translator $P/graphics/nvn/games $P/pack $P/tools $T/prof
cp "$H/graphics/tools/direct/direct_lib.sh" "$H/graphics/tools/direct/runtime_only_lib.sh" $P/graphics/tools/direct/
cp "$H/pack/srcs.sh" $P/pack/; cp "$H/tools/progress.sh" "$H/tools/clonedir.py" "$H/tools/nostall.py" $P/tools/; cp "$H/graphics/nvn/tools/romfs_list.py" $P/graphics/nvn/tools/
printf 'print("nvn\\t桩")\n' > $P/graphics/nvn/tools/gfx_api.py
printf 'import sys\nprint("%s")\n' "$T/prof" > $P/graphics/nvn/games/game.py; : > $P/graphics/nvn/games/zero_skip.tsv
printf 'def version(): return "v1"\n' > $P/translator/dmsh_chain.py
printf 'game\t0100AAAA00000000\n' > $T/prof/game.tsv
G=$T/root; mkdir -p $G/romfs $G/exefs; echo main > $G/exefs/main; printf 'title_id\t0100aaaa00000000\n' > $G/unpack.tsv
dl() { printf '#!/bin/bash\necho "[直连抽取] 直连库失败：直连抽取 0 支着色器（缺口：桩）"\nexit %s\n' "$1" > $P/graphics/tools/direct/extract.sh
  rm -rf $T/out $T/cache; mkdir -p $T/out/b-old; echo old > $T/out/b-old/old.pak
  env S2A_PY="$(command -v python3)" S2A_DIRECT_CACHE=$T/cache S2A_DIRECT_TARGETS=ios J=1 bash $P/graphics/tools/direct/direct_lib.sh $G $T/out > $T/log 2>&1; echo $?; }
rc=$(dl 3); D=$T/out
hdr=$(python3 -c 'import struct,sys; b=open(sys.argv[1],"rb").read(); print(len(b), b[:6]==b"S2ALIB", *struct.unpack_from("<III", b, 8), b[24:36].rstrip(b"\0").decode())' $D/b-v1/lib.idx 2>/dev/null)
ck "① 退 0（真 ${rc}）、🟡 运行时首遇现编带原因、空容器头「${hdr}」、inputs / 空表 / 原因 / game.tsv 都在" \
  '[ "$rc" = 0 ] && tail -1 $T/log | grep -q "🟡 0100AAAA00000000 离线 0 支、运行时首遇现编（直连库失败：直连抽取 0 支着色器" && [ "$hdr" = "48 True 1 0 0 v1" ] && grep -qx "game	0100AAAA00000000" $D/b-v1/inputs.tsv && grep -qE "^inputs	runtime-only-x[0-9a-f]{11}$" $D/b-v1/inputs.tsv && [ -f $D/shader_map.tsv ] && [ ! -s $D/shader_map.tsv ] && [ -f $D/keys.tsv ] && [ ! -s $D/keys.tsv ] && grep -q "直连抽取 0 支着色器" $D/runtime_only.txt && [ -f $D/game.tsv ] && [ -f $D/shader_facts.tsv ] && [ -f $D/shader_pairs.tsv ] && ! grep -qv "^#" $D/shader_facts.tsv $D/shader_pairs.tsv'
ck "② 旧库文件被换走" '[ ! -e $D/b-old ]'
rc=$(dl 1); ck "③ 反证：桩退 1 → 退 1（真 ${rc}）、🔴 抽取失败、旧文件还在" '[ "$rc" = 1 ] && grep -q "🔴 抽取失败" $T/log && [ -f $D/b-old/old.pak ]'
[ $bad = 0 ] && echo "🟢 直连库抽取缺口单测全通" || { echo "直连库抽取缺口单测：有不通"; tail -5 $T/log; exit 1; }
