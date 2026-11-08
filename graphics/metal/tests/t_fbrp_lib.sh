#!/bin/bash
# t_fbrp 输入（Makefile 调）：用出包那条路造一个离线库——t_fbr 的手写 SPIR-V 按键落盘 → gal_xc --fbr（证明 + 按变体请求改写，改写后的落成 <键>.fbf.spv）
#   → gal_offline.py（gal_xc 主流程带 NXGAL_XC_FBF 翻译 + 编 metallib）。产物 <OUT>/t_fbrp_in/：spv/、lib/（离线库）、fbr.tsv（证明表）、keys.txt（vs vsp fs vsep 四个键）。
# 另有带宽屏外推尾声的 vsep（独立 gl_Position，(w+y)）及其配对与请求（vsep, fs, ydown 1, 128:0）：证明带外推参数条件，尾段与运行时逐字节比。
# 变体请求三条：(vsp, fs, ydown 1, 128:0) 正例；(vsp, fs, ydown 0, 128:0) 映射不在证明里（(w+y) 只在 ydown = 1 时是当前像素）；不在配对表里的程序一条
set -eu
OUT=$1; H=$(cd "$(dirname "$0")/.." && pwd); D=$OUT/t_fbrp_in
rm -rf "$D"; mkdir -p "$D/spv"
key() { python3 -c 'import hashlib,struct,sys;print("%016x"%struct.unpack("<Q",hashlib.sha256(open(sys.argv[1],"rb").read()).digest()[:8])[0])' "$1"; }
for n in vs vsp fs vsep; do k=$(key "$OUT/t_fbr_in/$n.spv"); cp "$OUT/t_fbr_in/$n.spv" "$D/spv/$k.spv"; eval "K_$n=$k"; done
echo "$K_vs $K_vsp $K_fs $K_vsep" > "$D/keys.txt"
printf '# 配对表\n%s %s\n%s %s\n%s %s\n' "$K_vsp" "$K_fs" "$K_vs" "$K_fs" "$K_vsep" "$K_fs" > "$D/pairs.tsv"
{ echo "[gal] 读帧缓冲变体缺 v1 $K_vsp $K_fs 1 128:0"; echo "v1 $K_vsep $K_fs 1 128:0"; echo "v1 $K_vsp $K_fs 0 128:0"; echo "v1 00000000deadbeef $K_fs 1 128:0"; } > "$D/vars.tsv"
"$OUT/gal_xc" --fbr "$D/pairs.tsv" "$D/spv" "$D/fbr.tsv" "$D/vars.tsv" | tee "$D/fbr.log"
GAL_XC="$OUT/gal_xc" GAL_SHARD_MB=0.001 python3 "$H/tools/gal_offline.py" "$D/spv" "$D/lib" macos > "$D/offline.log" 2>&1 || { cat "$D/offline.log"; exit 1; }
# 合并编译等价（10-23）：上面是缺省合编（GAL_UNITY_N=48）出的库，t_fbrp 拿它跑；同一批 SPIR-V 再逐支编一份，逐入口比 AIR（graphics/metal/tools/unity_check.py）须全一致
GAL_XC="$OUT/gal_xc" GAL_UNITY_N=1 GAL_SHARD_MB=0.001 python3 "$H/tools/gal_offline.py" "$D/spv" "$D/lib1" macos > "$D/offline1.log" 2>&1 || { cat "$D/offline1.log"; exit 1; }
grep -q '合编 [1-9][0-9]* 批' "$D/offline.log" || { echo "✗ 缺省没走合编（$D/offline.log）"; exit 1; }
UNITY_CHECK_SDK=macosx python3 "$H/tools/unity_check.py" "$D/lib1/msl" "$D/lib/msl" || { echo "✗ 合编与逐支编 AIR 不一致"; exit 1; }
