#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 真实阶段 + 真实收集器；仅 guest-new 语义判定和烘焙键为协议夹具，不运行 GPU。
# 期望独立给定：缺一个缓存文件 → collector=1、阶段=1、不跳过；成功/禁用 → 阶段=0。
set -eu
H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/repo/pack/stages" "$T/repo/tools" "$T/repo/graphics/tools/shbake" "$T/roots/sample@seed/shaders/shcache/0100" "$T/tmp"
cp "$H/pack/stages/shaders.sh" "$T/repo/pack/stages/"
cp "$H/pack/roots.sh" "$H/pack/stage_keyfiles.sh" "$T/repo/pack/"
cp "$H/tools/stage_deps.py" "$T/repo/tools/"
cp -R "$H/tools/stage_deps_hook" "$T/repo/tools/"
cp "$H/graphics/tools/shbake/shcollect.sh" "$H/graphics/tools/shbake/"*.py "$T/repo/graphics/tools/shbake/"
cat > "$T/repo/graphics/tools/shader_pack.sh" <<'SH'
[ "$1" = --key ] && { echo fixture-key; exit 0; }
echo unexpected-bake >&2; exit 99
SH
cat > "$T/guest-new" <<'SH'
#!/bin/bash
[ "$2" = /nonexistent ] && { echo '没有 shared.toc'; exit 1; }
[ "$2" = --code ] && { echo '新 0 总 1'; exit 0; }
echo '新 1 总 1'
SH
chmod +x "$T/guest-new"
export S2A_ROOTS="$T/roots" S2A_ROOTS_SHARED="$T/shared" S2A_ROOTS_PRIV="$T/private"
export S2A_SHCOLLECT="$T/col" S2A_SCHED_DIR="$T/sched" S2A_SHBAKE="$T/guest-new" TMPDIR="$T/tmp"
export S2A_REFLIB=0 S2A_SHADER_LAZY=0 S2A_PACK_PLAT=ios S2A_SHADER_NO_PSO=0
unset S2A_PSO_OS S2A_PSO_ARCHS S2A_SHCOLLECT_BASE S2A_SHCOLLECT_LIST S2A_SHADER_PACK
unset NXGAL_VPULL S2A_RUNTIME_STATE S2A_PSO_P PSO_NTJ
ln -s sample@seed "$T/roots/sample@现行"
# 无 deps 清单时真实 stage_deps_key 在明确基础键后加 ~d；缓存命中只用来终止成功路径，不烘焙。
printf 'fixture-key~d\n' > "$T/roots/sample@seed/.stage_shaders"
J="$T/sched/jobs/j1/out_1"
mkdir -p "$J/shcache_rt" "$J/pkg_shcache"
printf 'GAME=sample\n' > "$T/sched/jobs/j1/job.env"
printf 'base\n' > "$J/pkg_shcache/shared.toc"
for f in shared.toc shared.data guest.toc; do printf 'synthetic %s\n' "$f" > "$J/shcache_rt/$f"; done
bad=0; n=0
ck() { n=$((n + 1)); if eval "$2"; then echo "通 $n $1"; else echo "不通 $n $1"; bad=1; fi; }
run_stage() { bash "$T/repo/pack/stages/shaders.sh" sample; }
r=0; o=$(bash "$T/repo/graphics/tools/shbake/shcollect.sh" sample 2>&1) || r=$?
ck '真实收集器缺 guest.data 退出 1、末行明确拷贝失败' '[ "$r" = 1 ] && [[ "$o" == *拷贝失败* ]]'
r=0; o=$(S2A_SHCOLLECT_RUN=1 run_stage 2>&1) || r=$?
ck '开启收集失败必须中止，不能缓存命中跳过' '[ "$r" = 1 ] && [[ "$o" == *拷贝失败* ]] && [[ "$o" != *跳过* ]]'
ck '失败不发布新根、不覆盖阶段键' '[ "$(readlink "$T/roots/sample@现行")" = sample@seed ] && [ "$(cat "$T/roots/sample@seed/.stage_shaders")" = fixture-key~d ] && [ "$(find "$T/roots" -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 1 ]'
r=0; o=$(S2A_SHCOLLECT_RUN=0 run_stage 2>&1) || r=$?
ck '显式禁用不运行坏缓存收集，原跳过路径成功' '[ "$r" = 0 ] && [[ "$o" == *跳过* ]] && [[ "$o" != *拷贝失败* ]]'
r=0; o=$(unset S2A_SHCOLLECT_RUN; run_stage 2>&1) || r=$?
ck '缺省禁用仍成功跳过' '[ "$r" = 0 ] && [[ "$o" == *跳过* ]] && [[ "$o" != *拷贝失败* ]]'
# 成功但无候选：仍实际调用 collector（有末行），不应把 0 当失败。
mkdir -p "$T/empty-sched"
r=0; o=$(S2A_SHCOLLECT_RUN=1 S2A_SCHED_DIR="$T/empty-sched" run_stage 2>&1) || r=$?
ck '开启且真实收集成功，保留末行与原跳过路径' '[ "$r" = 0 ] && [[ "$o" == *"候选 0 份"* ]] && [[ "$o" == *跳过* ]]'
# 缺入口的真实 bash 127 也必须原样传播，不依赖末行有没有【红】文字。
rm "$T/repo/graphics/tools/shbake/shcollect.sh"
r=0; o=$(S2A_SHCOLLECT_RUN=1 run_stage 2>&1) || r=$?
ck '收集器入口缺失传播 127，不按日志文字猜成功' '[ "$r" = 127 ] && [[ "$o" != *跳过* ]]'
echo "shcollect_stage_rc: $n 项，bad=$bad"; exit "$bad"
