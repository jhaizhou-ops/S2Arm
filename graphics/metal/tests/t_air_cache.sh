#!/bin/bash
# .air 缓存命中单测（graphics/metal/tools/gal_offline.py 的 hit_cache）：真工具链编 3 支极小 MSL，逐支（GAL_UNITY_N=1）与合编（缺省）两条路径各跑。退出 0 = 全过，约 10 秒
# 期望（不跑被测脚本算：3 支源码由本单测生成，逐支 = 3 个条目、合编 = 1 批 1 个条目）：
#   ① 首次：命中 0、现编 3
#   ② 条目修改时间先设成 2023-01-01 再跑：命中 3、现编 0，条目时间都被刷新到今天（克隆不刷新访问时间，gc 按最近使用删要靠这个）
#   ④ 只改编译旗 MATH（脚本副本去掉 -fpreserve-invariance）、同一份缓存：命中 0、现编 3（11-01 审计 P2-41）
#   ③ 条目设成不可读（模拟 gc 在「判存在」和「克隆」之间删了条目 → 克隆失败）：不抛异常、退出 0，命中 0、现编 3
set -u; R=$(cd "$(dirname "$0")/../../.." && pwd); T=$(mktemp -d "${TMPDIR:-/tmp}/t_air_cache.XXXXXX"); bad=0
trap 'chmod -R u+rw "$T" 2> /dev/null; rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "✓ $1"; else echo "✗ $1"; bad=1; fi; }
mkdir -p "$T/o/msl"; : > "$T/o/gal.idx"
for i in 1 2 3; do printf '#include <metal_stdlib>\nusing namespace metal;\nkernel void s%016d(device float4* b [[buffer(0)]], uint i [[thread_position_in_grid]]) { b[i] += %d.0; }\n' $i $i > "$T/o/msl/$(printf %016d $i).metal"; done
run() { GAL_UNITY_N=$1 GAL_XC_DONE=1 GAL_AIR_CACHE=$T/c$1 python3 "$R/graphics/metal/tools/gal_offline.py" "$T/src" "$T/o" ios > "$T/log" 2>&1; echo $? > "$T/rc"; }
hit() { grep -oE '缓存命中 [0-9]+，现编 [0-9]+' "$T/log"; }
ents() { find "$T/c$1" -name '*.air' -type f; }
for n in 1 48; do want=$([ $n = 1 ] && echo 3 || echo 1); tag=$([ $n = 1 ] && echo 逐支 || echo 合编)
  run $n; ck "$tag ① 首次：命中 0、现编 3、退出 0（$(hit)）" '[ "$(cat $T/rc)" = 0 ] && [ "$(hit)" = "缓存命中 0，现编 3" ]'
  ck "$tag ① 缓存条目 $want 个（$(ents $n | wc -l | tr -d " ")）" '[ "$(ents $n | wc -l | tr -d " ")" = $want ]'
  ents $n | while read -r f; do touch -t 202301010000 "$f"; done
  run $n; ck "$tag ② 再跑：命中 3、现编 0（$(hit)）" '[ "$(cat $T/rc)" = 0 ] && [ "$(hit)" = "缓存命中 3，现编 0" ]'
  ck "$tag ② 命中后 $want 个条目修改时间都刷新（还是 2023 的：$(find "$T/c$n" -name "*.air" ! -newermt 2023-06-01 | wc -l | tr -d " ")）" '[ "$(find "$T/c$n" -name "*.air" -newermt 2023-06-01 | wc -l | tr -d " ")" = $want ]'
  ents $n | while read -r f; do chmod 000 "$f"; done
  run $n; ck "$tag ③ 条目克隆不了：不崩、退出 0、命中 0、现编 3（$(hit)；$(grep -m1 -E 'Error|Traceback' "$T/log")）" '[ "$(cat $T/rc)" = 0 ] && [ "$(hit)" = "缓存命中 0，现编 3" ]'
  ents $n | while read -r f; do chmod 644 "$f"; done
  # ④ 只改编译旗（MATH，如去掉 -fpreserve-invariance），同一份缓存：必须全部重编（11-01 审计 P2-41：旗不在键里，旧 .air 照样命中，改旗要等清缓存才生效）
  F=$T/fake$n; mkdir -p "$F/graphics/metal/tools" "$F/tools"; cp "$R"/graphics/metal/tools/*.py "$F/graphics/metal/tools/"; cp "$R/tools/toolchain.env" "$R"/tools/*.py "$F/tools/"
  python3 -c "import sys; p=sys.argv[1]; t=open(p).read(); a=\"MATH = ['-fmetal-math-mode=relaxed', '-fpreserve-invariance']\"; assert t.count(a)==1; open(p,'w').write(t.replace(a, \"MATH = ['-fmetal-math-mode=relaxed']\"))" "$F/graphics/metal/tools/gal_offline.py"
  run $n; GAL_UNITY_N=$n GAL_XC_DONE=1 GAL_AIR_CACHE=$T/c$n python3 "$F/graphics/metal/tools/gal_offline.py" "$T/src" "$T/o" ios > "$T/log" 2>&1; echo $? > "$T/rc"
  ck "$tag ④ 只改编译旗：命中 0、现编 3（$(hit)）" '[ "$(cat $T/rc)" = 0 ] && [ "$(hit)" = "缓存命中 0，现编 3" ]'
done
echo ".air 缓存命中：$([ $bad = 0 ] && echo 全过 || echo 有失败)"; exit $bad
