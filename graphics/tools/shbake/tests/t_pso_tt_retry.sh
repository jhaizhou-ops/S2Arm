#!/bin/bash
# pso_chunk.sh Metal 3 分支（PSO_M3=1，metal-tt 出归档）的 metal-tt 偶发失败重试单测（约 3 秒）：bash graphics/tools/shbake/tests/t_pso_tt_retry.sh
#   10-24：metal-tt 并发起进程时偶发「air-tt: No available translator for '<架构>'」（本机 18 路并行 720 次失败 83 次），同一输入重跑即过；
#   只对这一句重试（至多 5 次），其余失败照旧立即报（10-29 t_m3pack ② 本机高负载下撞上、归档 0 字节）。假 metal-tt（S2A_METAL_TT）前 N 次按给定报错失败，之后写一个假产物成功。期望按规则手算：
#   ① 前 2 次找不到翻译器 → 出归档、调 3 次、没有 .fail；② 别的错 → .fail、只调 1 次、没有归档；③ 一直找不到 → .fail、调 6 次（1 + 重试 5）
#   ④ metal-tt 带按工具链版本的 DIRHELPER_USER_DIR_SUFFIX（10-29 根修：各版本各一份 air-tt 查询缓存，别的版本冲不掉）
set -u
R=$(cd "$(dirname "$0")/../../../.." && pwd)
source "$R/tools/toolchain.sh" || exit 2
T=$(mktemp -d "${TMPDIR:-/tmp}/t_pso_tt_retry.XXXXXX"); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "✓ $1"; else echo "✗ $1"; bad=1; fi; }
cat > "$T/tt" <<'EOF'
#!/bin/bash
[ "${1:-}" = -version ] && { echo 'AIR-TT 9.9-fake'; exit 0; }   # 查询缓存后缀的版本：假工具路径里没有 MetalToolchain-v，入口退到 -version 首行（不计调用次数）
n=$(cat "$TT_STATE" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$TT_STATE"
printf '%s' "${DIRHELPER_USER_DIR_SUFFIX:-}" > "$TT_STATE.suffix"
if [ "$n" -le "$TT_FAIL_N" ]; then printf 'air-tt: %s\nair-tt: air-tt command failed\n' "$TT_MSG" >&2; exit 1; fi
o=; while [ $# -gt 0 ]; do [ "$1" = -o ] && o=$2; shift; done; printf 'fake' > "$o"
EOF
chmod +x "$T/tt"
# 后缀：假工具路径里没有 MetalToolchain-v 版本号 → 统一入口 tools/tt_env.sh 退到「-version」首行的 AIR-TT 版本（假工具答 9.9-fake），后缀 = s2a-tt-<版本>（基础设施线 10-29 约定），期望按约定手写
want=s2a-tt-9.9-fake
# pso_chunk.sh Metal 3 分支：一片脚本（libraries.paths 一个假库），没有分片键（不进缓存，每次都现编）
mkdir -p "$T/pc"; printf '{"libraries": {"paths": [{"path": "%s"}]}}\n' "$T/pc/gal.0.metallib" > "$T/pc/pso.0.mtlp-json"
pc() {   # $1 = 用例名 $2 = 前几次失败 $3 = 报错；回显退出码
  rm -f "$T/state"; mkdir -p "$T/pc_$1/o" "$T/pc_$1/w"
  TT_STATE=$T/state TT_FAIL_N=$2 TT_MSG=$3 S2A_METAL_TT=$T/tt PSO_M3=1 PSO_M3VER=26.0 PSO_A=applegpu_test PSO_PLAT=macos PSO_M=26 \
    PSO_O=$T/pc_$1/o PSO_W=$T/pc_$1/w PSO_PC=$T/pc_$1/c bash "$R/graphics/tools/shbake/pso_chunk.sh" "$T/pc/pso.0.mtlp-json" > "$T/pc_$1.log" 2>&1; echo $?
}
pbin() { [ -s "$T/pc_$1/o/gal_pso.applegpu_test.macos26.0.bin" ]; }; pfail() { [ -e "$T/pc_$1/w/pso_applegpu_test.macos26.0.fail" ]; }
rc=$(pc e 2 "No available translator for 'applegpu_test'")
ck "① pso_chunk 前 2 次找不到翻译器：出归档、调 3 次、没有 .fail（rc ${rc}，调 $(cat "$T/state") 次）" '[ "$rc" = 0 ] && [ "$(cat "$T/state")" = 3 ] && pbin e && ! pfail e'
SFX_E=$(cat "$T/state.suffix" 2> /dev/null)
rc=$(pc f 1 "error: something else")
ck "② pso_chunk 别的错不重试：.fail、只调 1 次、没有归档（rc ${rc}，调 $(cat "$T/state") 次）" '[ "$(cat "$T/state")" = 1 ] && pfail f && ! pbin f'
rc=$(pc g 99 "No available translator for 'applegpu_test'")
ck "③ pso_chunk 一直找不到：.fail、调 6 次（rc ${rc}，调 $(cat "$T/state") 次）" '[ "$(cat "$T/state")" = 6 ] && pfail g && ! pbin g'
ck "④ pso_chunk 的 metal-tt 带按版本的查询缓存后缀（实得 ${SFX_E:-无}）" '[ "$SFX_E" = "$want" ]'
echo "pso_chunk metal-tt 重试单测：$([ $bad = 0 ] && echo 全过 || echo 有失败)"; exit $bad
