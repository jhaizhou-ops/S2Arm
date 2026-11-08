#!/bin/bash
# 离线库合编按阶段分子批（graphics/metal/tools/gal_offline.py，10-24：vpull-fast 只改顶点，怪猎 MSL 仍重编 13661 / 14199）单测：
#   手造 12 支 MSL，键 …01–…0c，奇数键顶点、偶数键片元交替；GAL_UNITY_N=4（键 mod 4 == 0 处切批，每批顶点片元混着）。
#   第一次冷编（空缓存），再只改 6 支顶点的 MSL 编第二次。期望（手算）：第二次缓存命中 6（片元）、现编 6（顶点）；分片仍是连续键区间（gal.shards 首键升序、每支能按首键二分落到含它的片）。
#   反证：给旧版 gal_offline.py（参数 1，可选）时第二次命中 0（每批都含变了的顶点，整批键变）
set -u
R=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd); GO=${1:-$R/graphics/metal/tools/gal_offline.py}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/out/msl" "$T/cache"
cp "$R/graphics/metal/tests/t_offline_stage.idx" "$T/out/gal.idx" 2>/dev/null || : > "$T/out/gal.idx"
mk() {   # mk <轮>：写 12 支；顶点那 6 支带轮次注释（第二轮改它们）
  for i in $(seq 1 12); do k=$(printf '%016x' $i)
    if [ $((i % 2)) = 1 ]; then printf '#include <metal_stdlib>\nusing namespace metal;\n// 轮 %s\nvertex float4 s%s(uint v [[vertex_id]]) { return float4(float(v) * %d.0, 0.0, 0.0, 1.0); }\n' "$1" "$k" "$i" > "$T/out/msl/$k.metal"
    else printf '#include <metal_stdlib>\nusing namespace metal;\nfragment float4 s%s() { return float4(%d.0, 0.0, 0.0, 1.0); }\n' "$k" "$i" > "$T/out/msl/$k.metal"; fi
  done; }
run() { GAL_XC_DONE=1 GAL_UNITY_N=4 GAL_AIR_CACHE="$T/cache" GAL_SHARD_MB=0.001 J=4 python3 "$GO" "$T/in" "$T/out" macos 2>&1; }
mkdir -p "$T/in"; mk 1; r1=$(run); mk 2; r2=$(run)
hit=$(echo "$r2" | grep -oE '缓存命中 [0-9]+' | tail -1 | grep -oE '[0-9]+'); built=$(echo "$r2" | grep -oE '现编 [0-9]+' | tail -1 | grep -oE '[0-9]+')
n=0; bad=0
ck() { n=$((n + 1)); if eval "$2"; then echo "✓ $1"; else echo "✗ $1"; bad=$((bad + 1)); fi; }
ck "第一次冷编：现编 12（实得 $(echo "$r1" | grep -oE '现编 [0-9]+' | tail -1)）" 'echo "$r1" | grep -q "现编 12"'
ck "只改顶点后第二次：缓存命中 6（片元）、现编 6（顶点）（实得 命中 ${hit:-?}、现编 ${built:-?}）" '[ "${hit:-}" = 6 ] && [ "${built:-}" = 6 ]'
# 分片：gal.shards 首键升序；每支按首键二分落到的片，片里确实有它（metallib 里的函数名表用 strings 查）
sh_ok=$(python3 - "$T/out" <<'PY'
import bisect, os, subprocess, sys
o = sys.argv[1]; rows = [l.split('\t') for l in open(os.path.join(o, 'gal.shards')) if l.strip()]
firsts = [int(r[0], 16) for r in rows]; ok = firsts == sorted(firsts)
for i in range(1, 13):
    j = bisect.bisect_right(firsts, i) - 1
    names = subprocess.run(['strings', os.path.join(o, rows[j][1].strip())], capture_output=True, text=True).stdout
    ok &= j >= 0 and f's{i:016x}' in names
print(1 if ok else 0)
PY
)
ck "分片仍是连续键区间：12 支按首键二分都落到含它的片（$(wc -l < "$T/out/gal.shards" | tr -d ' ') 片）" '[ "$sh_ok" = 1 ]'
echo "t_offline_stage：$n 项，失败 $bad"
[ $bad = 0 ]
