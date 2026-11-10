#!/bin/bash
# 离线库大 MSL 单独编 + 编译按内存预算（graphics/metal/tools/gal_offline.py，10-26 交付线 Spare-host 斯普拉遁3：133 支一批里有 19.4 MB 的支，合编十几分钟被判挂死）单测：
#   手造 12 支 MSL（同 t_offline_stage：键 …01–…0c，奇数顶点、偶数片元），把键 …07 那支垫注释到约 8 KB；GAL_UNITY_N=4、GAL_UNITY_BIG_KB=4。
#   期望（按设定算）：① 日志「大 MSL（> 4 KB）单独编 1 支」；② msl/0000000000000007.air 是单编的（它不在任何批里）；③ 各片 metallib 里 12 个函数一个不少；
#   ④ 编译内存预算给到极小（GAL_COMP_MEM_GB=0.000001，每个任务都超）照样编完（一个都没在跑时照开，不死等），日志写出预算。
#   ⑤ 按运行时「最后一个首键 ≤ 函数键」查 12 个函数，每个都落进含它的那片（11-01 审计 P1-35）。
#   反证：给旧版 gal_offline.py（参数 1）时没有「单独编」这一行、也没有 …07 的单编 .air；P1-35 修前 ⑤ 红（首键乱序）
set -u
R=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd); GO=${1:-$R/graphics/metal/tools/gal_offline.py}
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/out/msl" "$T/cache" "$T/in"; : > "$T/out/gal.idx"
for i in $(seq 1 12); do k=$(printf '%016x' $i)
  if [ $((i % 2)) = 1 ]; then printf '#include <metal_stdlib>\nusing namespace metal;\nvertex float4 s%s(uint v [[vertex_id]]) { return float4(float(v) * %d.0, 0.0, 0.0, 1.0); }\n' "$k" "$i" > "$T/out/msl/$k.metal"
  else printf '#include <metal_stdlib>\nusing namespace metal;\nfragment float4 s%s() { return float4(%d.0, 0.0, 0.0, 1.0); }\n' "$k" "$i" > "$T/out/msl/$k.metal"; fi
done
python3 -c "import sys; open(sys.argv[1], 'a').write(''.join('// %s\n' % ('x' * 70) for _ in range(110)))" "$T/out/msl/0000000000000007.metal"
out=$(GAL_XC_DONE=1 GAL_UNITY_N=4 GAL_UNITY_BIG_KB=4 GAL_COMP_MEM_GB=0.000001 GAL_AIR_CACHE="$T/cache" GAL_SHARD_MB=0.001 J=4 timeout 120 python3 "$GO" "$T/in" "$T/out" macos 2>&1); rc=$?
n=0; bad=0
ck() { n=$((n + 1)); if eval "$2"; then echo "✓ $1"; else echo "✗ $1"; bad=$((bad + 1)); fi; }
ck "① 日志写大 MSL 单独编 1 支（$(echo "$out" | grep -o '大 MSL[^，]*' | head -1)）" 'echo "$out" | grep -q "大 MSL（> 4 KB）单独编 1 支"'
ck "② …07 单编出了自己的 .air" '[ -s "$T/out/msl/0000000000000007.air" ]'
allf=$(for f in "$T"/out/gal.*.metallib; do strings "$f"; done | grep -oE 's0{11}0[0-9a-f]{4}' | sort -u | wc -l | tr -d ' ')
ck "③ 各片 metallib 里 12 个函数一个不少（实得 ${allf}）" '[ "$allf" = 12 ]'
ck "④ 内存预算极小照样编完（退出 ${rc}）、日志写出预算" '[ $rc = 0 ] && echo "$out" | grep -q "编译内存预算"'
# ⑥ 有一支编不过（审计 P2-208）：退出码非 0、错误行写明失败支数，metal_failed.txt 记下那一支；全好时 ④ 已证退 0
mkdir -p "$T/bad/msl" "$T/badin"; : > "$T/bad/gal.idx"; cp "$T"/out/msl/*.metal "$T/bad/msl/"
printf '#include <metal_stdlib>\nusing namespace metal;\nfragment float4 s000000000000000d() { return undefined_symbol_xyz; }\n' > "$T/bad/msl/000000000000000d.metal"
bo=$(GAL_XC_DONE=1 GAL_UNITY_N=4 GAL_AIR_CACHE="$T/cache" GAL_SHARD_MB=0.001 J=4 timeout 120 python3 "$GO" "$T/badin" "$T/bad" macos 2>&1); brc=$?
ck "⑥ 有一支编不过：退出 ${brc}（非 0）、红行写失败 1 支、metal_failed.txt 记这一支" '[ $brc != 0 ] && echo "$bo" | grep -q "metal 编译失败 1 支" && grep -q "^000000000000000d.metal" "$T/bad/metal_failed.txt"'
# ⑤ 按运行时规则（gal_prog.m：最后一个首键 ≤ 函数键）查每个函数，必须落进真含它的那片（11-01 审计 P1-35：大 MSL 单独成组、键落在别批区间中间，切片后首键乱序 → 找错片）
#   另造一组：把键 …06 垫大（批切点在键 mod 4 == 0，…04 …05 …07 同批、…06 单独编，键落在这批区间正中间）；分片上限极小 → 每组一片
mkdir -p "$T/o5/msl" "$T/c5"; : > "$T/o5/gal.idx"; cp "$T"/out/msl/*.metal "$T/o5/msl/"
python3 -c "import sys; p=sys.argv[1]; t=open(p).read().split('//')[0]; open(p,'w').write(t)" "$T/o5/msl/0000000000000007.metal"
python3 -c "import sys; open(sys.argv[1], 'a').write(''.join('// %s\n' % ('x' * 70) for _ in range(110)))" "$T/o5/msl/0000000000000006.metal"
GAL_XC_DONE=1 GAL_UNITY_N=4 GAL_UNITY_BIG_KB=4 GAL_AIR_CACHE="$T/c5" GAL_SHARD_MB=0.001 J=4 timeout 120 python3 "$GO" "$T/in" "$T/o5" macos > "$T/o5.log" 2>&1
look=$(python3 - "$T/o5" <<'PY'
import bisect, os, re, subprocess, sys
o = sys.argv[1]; rows = [l.split('\t') for l in open(os.path.join(o, 'gal.shards')).read().split('\n') if l]
firsts = [int(k, 16) for k, _ in rows]; bad = []
if firsts != sorted(firsts): bad.append('首键不是升序')
for k, f in rows:
    names = set(re.findall(r's(0{11}0[0-9a-f]{4})', subprocess.run(['strings', os.path.join(o, f.strip())], capture_output=True, text=True).stdout))
    for n in names:
        i = bisect.bisect_right(firsts, int(n, 16)) - 1
        if i < 0 or rows[i][1].strip() != f.strip(): bad.append(f'{n} 在 {f.strip()}，按首键二分查到 {rows[i][1].strip() if i >= 0 else "无"}')
print(f'{len(rows)} 片；' + ('找错 ' + str(len(bad)) + '：' + '；'.join(bad[:3]) if bad else '全部找对'))
PY
)
ck "⑤ 按首键二分查每个函数都落进含它的那片（${look}）" '[[ "$look" == *全部找对 ]]'
echo "t_offline_big：$n 项，失败 $bad"
[ $bad = 0 ]
