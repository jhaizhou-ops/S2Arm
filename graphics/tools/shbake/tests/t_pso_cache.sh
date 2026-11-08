#!/bin/bash
# 管线分片缓存反证单测（graphics/tools/shbake/pso_chunk.sh + pso_gen.py 分片键）。退出 0 = 全过
# 一、缓存机制（假编译器：拷输入、记调用次数）：同输入第二次 = 命中且不编；分片键 / 工具链版本 / 架构 / 平台大版本 / SDK 版本 / 生成器签名 / 编译线程数 PSO_NTJ 任一项变 = 不命中、重编
# 二、分片键对不对（真工具链 + 本机 GPU：小 MSL 编库 → pso_gen 出键 → applegpu-nt 编归档 → 探针按运行时描述查）：
#   判据 = 「键不变 ⇔ 旧归档对新库全命中」——键不变却查不中 = 缓存会发出查不中的旧归档（10-20 PSO_LIBH 要防的事）；键变了却全命中 = 白重编
#   库 = V(顶点) F(片元) C(计算) X(未引用)，按键序链接（同 gal_offline）；管线 = V+F、C
#   ① 未引用的 X 改了（排在后面）          → 键不变、旧归档全中
#   ② 引用的 F 改了                        → 键变、旧归档不全中
#   ③ 前面插一支未引用的 P（同名结构体不同布局）：V / C 的 .air 没变，但链接时类型改名改了它们的库内位码 → 键变、旧归档不全中
#   ④ 同一份库换目录                        → 键不变、旧归档全中
#   ⑤ 端到端：① 走 pso_chunk.sh 缓存命中拷出的归档，对 ① 的库全中
set -u
D=$(mktemp -d "${TMPDIR:-/tmp}/t_pso_cache.XXXXXX"); trap 'rm -rf "$D"' EXIT
H=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd); C=$H/pso_chunk.sh
cat > "$D/fake_nt" <<'EOF'
#!/bin/bash
o=; while [ $# -gt 0 ]; do [ "$1" = -o ] && o=$2; [ "$1" = -N ] && i=$2; shift; done
cp "$i" "$o"; echo x >> "$(dirname "$o")/../calls"
EOF
chmod +x "$D/fake_nt"; mkdir -p "$D/w" "$D/o" "$D/pc"
echo '{"a":1}' > "$D/w/pso.0.mtl4-json"; echo k1 > "$D/w/pso.0.key"
export PSO_NT=$D/fake_nt PSO_A=g18p PSO_PLAT=ios PSO_M=27 PSO_SV=27.0 PSO_SP=/x PSO_NTV=v1 PSO_SIG=s1 PSO_PC=$D/pc PSO_O=$D/o PSO_W=$D/w
calls() { [ -f "$D/calls" ] && wc -l < "$D/calls" | tr -d ' ' || echo 0; }
run() { rm -f "$D/w"/*.hit; bash "$C" "$D/w/pso.0.mtl4-json"; }
fail=0; n=0
check() {   # 期望 <命中 1/0> <说明>
  n=$((n + 1)); local before after hit; before=$(calls); run; after=$(calls); hit=$(ls "$D/w"/*.hit 2>/dev/null | wc -l | tr -d ' ')
  if [ "$1" = 1 ] && [ "$hit" = 1 ] && [ "$after" = "$before" ]; then echo "✓ $2：命中、没编"
  elif [ "$1" = 0 ] && [ "$hit" = 0 ] && [ "$after" = $((before + 1)) ]; then echo "✓ $2：不命中、重编"
  else echo "✗ $2：期望 命中=$1，实际 命中=${hit}、编 $((after - before)) 次"; fail=$((fail + 1)); fi
}
check 0 "首次"
check 1 "同输入第二次"
echo k2 > "$D/w/pso.0.key"; check 0 "分片键变"; check 1 "分片键变后再来一次"
PSO_NTV=v2 check 0 "工具链版本变"
PSO_A=g17s check 0 "架构变"
PSO_M=26 check 0 "平台大版本变"
PSO_SV=27.1 check 0 "SDK 版本变"
PSO_SIG=s2 check 0 "生成器签名变（pso_gen / pso_chunk / CodeGenVersion）"
PSO_NTJ=1 check 0 "编译线程数 PSO_NTJ 从不设变 1"; PSO_NTJ=1 check 1 "PSO_NTJ=1 再来一次"
PSO_NTJ=3 check 0 "PSO_NTJ 从 1 变 3"; check 1 "PSO_NTJ 回到不设：仍命中最早的缺省版"
n=$((n + 1)); rm -f "$D/args"; printf '#!/bin/bash\necho "$*" > "%s/args"; "%s/fake_nt" "$@"\n' "$D" "$D" > "$D/nt_args"; chmod +x "$D/nt_args"
echo k9 > "$D/w/pso.0.key"; PSO_NT=$D/nt_args PSO_NTJ=2 run; grep -q -- ' -j 2 ' "$D/args" 2>/dev/null && echo "✓ PSO_NTJ=2 编译器拿到 -j 2" || { echo "✗ PSO_NTJ=2 编译器参数：$(cat "$D/args" 2>/dev/null)"; fail=$((fail + 1)); }
n=$((n + 1)); cmp -s "$D/o/gal_pso.g18p.ios27.0.bin" "$D/w/pso.0.mtl4-json" && echo "✓ 命中拷出的产物与编出的相同" || { echo "✗ 命中产物不同"; fail=$((fail + 1)); }
# 命中刷新条目修改时间（克隆不刷新访问时间，gc 按最近使用删、1 小时内用过不动都靠它）：全部条目设成 2023-01-01，命中一次 → 恰好 1 条刷新
n=$((n + 1)); find "$D/pc" -name '*.bin' -exec touch -t 202301010000 {} +; PSO_NTJ=2 run
nn=$(find "$D/pc" -name '*.bin' -newermt 2023-06-01 | wc -l | tr -d ' '); [ "$nn" = 1 ] && [ -n "$(ls "$D/w"/*.hit 2>/dev/null)" ] && echo "✓ 命中后该条目修改时间刷新、别的不动" || { echo "✗ 命中后刷新的条目数 ${nn}（期望 1）"; fail=$((fail + 1)); }

# ---------- 二、分片键 vs 运行时命中（真工具链）----------
R=$D/k; mkdir -p "$R/src"
NT=$(dirname "$(xcrun -f metal-tt 2>/dev/null)")/../metal/current/bin/applegpu-nt
if ! xcrun -sdk macosx metal --version > /dev/null 2>&1 || [ ! -x "$NT" ]; then echo "✗ 本机没有 Metal 工具链（xcrun metal / applegpu-nt），分片键反证没跑"; echo "管线分片缓存反证：$n 项，失败 $((fail + 1))（缺工具链）"; exit 1; fi
clang -fobjc-arc -O1 -o "$R/archprobe" "$H/tests/archprobe.m" -framework Metal -framework Foundation && clang -fobjc-arc -O1 -o "$R/gpu_arch" "$H/gpu_arch.m" -framework Metal -framework Foundation \
  || { echo "✗ 编探针失败"; exit 1; }
msl() { printf '#include <metal_stdlib>\nusing namespace metal;\n%s\n' "$2" > "$R/src/$1.metal" && xcrun -sdk macosx metal -mmacosx-version-min=15.0 -c "$R/src/$1.metal" -o "$R/src/$1.air"; }
msl P 'struct Buf { float4 a; float4 b; uint c; }; kernel void s0800000000000000(device Buf* b [[buffer(0)]], uint i [[thread_position_in_grid]]) { b[i].a = b[i].b * float(b[i].c); }'
msl V 'struct Buf { float4 a; }; struct VOut { float4 pos [[position]]; }; vertex VOut s1000000000000000(const device Buf* b [[buffer(0)]], uint vid [[vertex_id]]) { VOut o; o.pos = b[vid].a; return o; }'
msl F 'fragment float4 s2000000000000000(float4 p [[position]]) { return float4(p.xy * 0.5, 0.0, 1.0); }'
msl F2 'fragment float4 s2000000000000000(float4 p [[position]]) { return float4(p.xy * 0.25, 0.0, 1.0); }'
msl C 'struct Buf { float4 a; }; kernel void s3000000000000000(device Buf* b [[buffer(0)]], uint i [[thread_position_in_grid]]) { b[i].a += 1.0; }'
msl X 'struct Buf { float2 a; }; kernel void s4000000000000000(device Buf* b [[buffer(0)]], uint i [[thread_position_in_grid]]) { b[i].a *= 2.0; }'
msl X2 'struct Buf { float2 a; }; kernel void s4000000000000000(device Buf* b [[buffer(0)]], uint i [[thread_position_in_grid]]) { b[i].a *= 3.0; }'
# 程序表（V+F 图形、C 计算）+ 离线索引（V 记录位 4 = 顶点自取）
printf 'idx\torigin\tstatus\tkind\tsource\tstages\tspv\tms\terr\n0\tt\tok\tgraphics\tt\tt\t1000000000000000,2000000000000000\t0\t\n1\tt\tok\tcompute\tt\tt\t3000000000000000\t0\t\n' > "$R/programs.tsv"
python3 - "$R/gal.idx" <<'EOF'
import struct, sys
ks = [(0x1000000000000000, 4), (0x2000000000000000, 0)]; base = 24 + 16 * len(ks); hd = bytearray(24); hd[:4] = b'GALI'; struct.pack_into('<I', hd, 16, len(ks)); ent = recs = b''
for k, fl in ks: r = bytearray(100); struct.pack_into('<I', r, 96, fl); ent += struct.pack('<QII', k, base + len(recs), 100); recs += bytes(r)
open(sys.argv[1], 'wb').write(bytes(hd) + ent + recs)
EOF
mk() {   # mk <情形> <按链接序的 .air 名…>：建库 + pso_gen 出分片键
  local s=$1; shift; mkdir -p "$R/$s"; local a=(); for x in "$@"; do a+=("$R/src/$x.air"); done
  xcrun -sdk macosx metallib "${a[@]}" -o "$R/$s/gal.0.metallib" && printf '0000000000000000\tgal.0.metallib\n' > "$R/$s/gal.shards" && cp "$R/gal.idx" "$R/$s/" \
    && python3 "$H/pso_gen.py" "$R/programs.tsv" "$R/$s/gal.idx" "$R/$s/gal.shards" "$R/$s/pso" 300 > "$R/$s/pso_gen.log" || echo "✗ 情形 $s 建库 / pso_gen 失败"
}
mk base V F C X; mk x2 V F C X2; mk f2 V F2 C X; mk ins P V F C X
mkdir -p "$R/moved/sub"; cp "$R/base/gal.0.metallib" "$R/base/gal.shards" "$R/base/gal.idx" "$R/moved/sub/"
python3 "$H/pso_gen.py" "$R/programs.tsv" "$R/moved/sub/gal.idx" "$R/moved/sub/gal.shards" "$R/moved/pso" 300 > "$R/moved/pso_gen.log"
# 旧归档 = 按 base 编（真 pso_chunk.sh + applegpu-nt，缓存目录私有）
export PSO_NT=$NT PSO_A=$("$R/gpu_arch") PSO_PLAT=macos PSO_M=$(sw_vers -productVersion | cut -d. -f1) PSO_SV=$(xcrun --sdk macosx --show-sdk-version) PSO_SP=$(xcrun --sdk macosx --show-sdk-path) PSO_SIG=t PSO_PC=$R/pc
export PSO_NTV=$("$NT" --version 2>&1 | head -1)
chunk() { PSO_O=$R/$1 PSO_W=$R/$1 bash "$C" "$R/$1/pso.0.mtl4-json"; }
probe() { "$R/archprobe" "$1" "$R/$2/gal.0.metallib" R s1000000000000000 s2000000000000000 C s3000000000000000 | tail -1; }
TAG=$PSO_A.macos$PSO_M.0; OLD=$R/base/gal_pso.$TAG.bin
chunk base; n=$((n + 1))
if [ -s "$OLD" ] && [ "$(probe "$OLD" base)" = "命中 2/2" ]; then echo "✓ 正对照：旧归档查原库 命中 2/2"; else echo "✗ 正对照：旧归档查原库 $(probe "$OLD" base 2>&1)（$R/base/pso_$TAG.log：$(tail -1 "$R/base/pso_$TAG.log" 2>/dev/null)）"; fail=$((fail + 1)); fi
kcase() {   # kcase <情形> <期望 同/变> <说明>：键与 base 同 ⇔ 旧归档对该情形的库全中
  n=$((n + 1)); local k0 k1 eq p; k0=$(cat "$R/base/pso.0.key" 2>/dev/null); k1=$(cat "$R/$1/pso.0.key" 2>/dev/null); [ -n "$k0" ] && [ "$k0" = "$k1" ] && eq=同 || eq=变
  local lib=$1; [ "$1" = moved ] && lib=moved/sub; p=$(probe "$OLD" "$lib")
  if [ -z "$k1" ]; then echo "✗ $3：没出分片键（$(tail -1 "$R/$1/pso_gen.log")）"; fail=$((fail + 1))
  elif [ "$eq" = "$2" ] && { { [ $eq = 同 ] && [ "$p" = "命中 2/2" ]; } || { [ $eq = 变 ] && [ "$p" != "命中 2/2" ]; }; }; then echo "✓ $3：键${eq}，旧归档$p"
  else echo "✗ $3：期望 键$2 且旧归档$([ "$2" = 同 ] && echo 全中 || echo 不全中)，实际 键${eq}、旧归档$p"; fail=$((fail + 1)); fi
}
kcase x2 同 "① 未引用的 X 改了"
kcase f2 变 "② 引用的 F 改了"
kcase ins 变 "③ 前面插入 P（V / C 的 .air 没变、库内位码变了）"
kcase moved 同 "④ 同一份库换目录"
chunk x2; n=$((n + 1))
if [ -f "$R/x2/pso_$TAG.hit" ] && [ "$(probe "$R/x2/gal_pso.$TAG.bin" x2)" = "命中 2/2" ]; then echo "✓ ⑤ 端到端：① 走缓存命中，拷出的归档查新库 命中 2/2"
else echo "✗ ⑤ 端到端：缓存命中 $([ -f "$R/x2/pso_$TAG.hit" ] && echo 是 || echo 否)，查新库 $(probe "$R/x2/gal_pso.$TAG.bin" x2 2>&1)"; fail=$((fail + 1)); fi
# ---------- 三、只有顶点阶段的程序（10-21 首局根治 ③：怪猎首局 39 条「片元 -」现建）----------
# pso_gen 给它出只带顶点函数的基础管线 → applegpu-nt 编归档 → 探针按运行时描述（片元为空、颜色留空）查，期望命中 1/1（旧 pso_gen 跳过「阶段数不是 2」，归档里没有它）
mkdir -p "$R/vo"; printf 'idx\torigin\tstatus\tkind\tsource\tstages\tspv\tms\terr\n0\tt\tok\tgraphics\tt\tvs:t\t1000000000000000\t0\t\n' > "$R/vo/programs.tsv"
xcrun -sdk macosx metallib "$R/src/V.air" -o "$R/vo/gal.0.metallib" && printf '0000000000000000\tgal.0.metallib\n' > "$R/vo/gal.shards" && cp "$R/gal.idx" "$R/vo/" \
  && python3 "$H/pso_gen.py" "$R/vo/programs.tsv" "$R/vo/gal.idx" "$R/vo/gal.shards" "$R/vo/pso" 300 > "$R/vo/pso_gen.log" || echo "✗ 只顶点：建库 / pso_gen 失败"
chunk vo; n=$((n + 1)); pv=$("$R/archprobe" "$R/vo/gal_pso.$TAG.bin" "$R/vo/gal.0.metallib" V s1000000000000000 2>&1 | tail -1)
[ "$pv" = "命中 1/1" ] && echo "✓ ⑥ 只有顶点阶段的程序：出包归档按运行时描述（片元为空、颜色留空）命中 1/1" || { echo "✗ ⑥ 只有顶点阶段的程序：期望命中 1/1，实得 ${pv:-无归档}（$(tail -1 "$R/vo/pso_gen.log")）"; fail=$((fail + 1)); }
# ---------- 四、特化管线表（10-22：iPhone 上特化与程序不无关，出包按「程序 × 组合」预编完整管线）----------
# 表一行（附件 0 RGB10A2 写 R|A 开混合、附件 1 RGBA16F、拓扑三角形）→ pso_gen 第 8 个参数 → 归档：探针按运行时完整描述 S 命中 1/1、换格式的对照 N 0/1、基础管线 R 照中 1/1
mkdir -p "$R/sp"; cp "$R/base/gal.0.metallib" "$R/base/gal.shards" "$R/gal.idx" "$R/sp/"
printf '# 表\nv2 s1000000000000000 s2000000000000000 3 1 0 0 1 0:90:9:1:0:4:5:4:1:1 1:115:15:0:0:1:0:0:1:0\n' > "$R/sp/spec_pipes.tsv"
python3 "$H/pso_gen.py" "$R/programs.tsv" "$R/sp/gal.idx" "$R/sp/gal.shards" "$R/sp/pso" 300 /nonexistent /nonexistent "$R/sp/spec_pipes.tsv" > "$R/sp/pso_gen.log" || echo "✗ 特化管线：pso_gen 失败"
chunk sp; n=$((n + 1)); SB=$R/sp/gal_pso.$TAG.bin
ps_=$("$R/archprobe" "$SB" "$R/sp/gal.0.metallib" S s1000000000000000 s2000000000000000 2>&1 | tail -1); pn_=$("$R/archprobe" "$SB" "$R/sp/gal.0.metallib" N s1000000000000000 s2000000000000000 2>&1 | tail -1)
pr_=$("$R/archprobe" "$SB" "$R/sp/gal.0.metallib" R s1000000000000000 s2000000000000000 2>&1 | tail -1)
if [ "$ps_" = "命中 1/1" ] && [ "$pn_" = "命中 0/1" ] && [ "$pr_" = "命中 1/1" ] && grep -q '"spec_pipes": 1' "$R/sp/pso_gen.log"; then echo "✓ ⑦ 特化管线表：完整描述命中 1/1、换格式对照 0/1、基础管线 1/1"
else echo "✗ ⑦ 特化管线表：期望 S 1/1、N 0/1、R 1/1，实得 S ${ps_:-无}、N ${pn_:-无}、R ${pr_:-无}（$(tail -1 "$R/sp/pso_gen.log")）"; fail=$((fail + 1)); fi
# ⑧ 运行时才出现的程序配对（程序表里没有 V+F 这一对，只有计算）：表里一行 b2（颜色留空的基础管线）→ 归档按运行时基础描述 R 命中 1/1（没有这行 0/1，对照）
mkdir -p "$R/sb"; cp "$R/base/gal.0.metallib" "$R/base/gal.shards" "$R/gal.idx" "$R/sb/"
printf 'idx\torigin\tstatus\tkind\tsource\tstages\tspv\tms\terr\n1\tt\tok\tcompute\tt\tt\t3000000000000000\t0\t\n' > "$R/sb/programs.tsv"
printf 'b2 s1000000000000000 s2000000000000000 0 1 0 0 1\n' > "$R/sb/spec_pipes.tsv"
python3 "$H/pso_gen.py" "$R/sb/programs.tsv" "$R/sb/gal.idx" "$R/sb/gal.shards" "$R/sb/pso" 300 /nonexistent /nonexistent "$R/sb/spec_pipes.tsv" > "$R/sb/pso_gen.log" || echo "✗ 基础管线行：pso_gen 失败"
chunk sb; n=$((n + 1)); pb_=$("$R/archprobe" "$R/sb/gal_pso.$TAG.bin" "$R/sb/gal.0.metallib" R s1000000000000000 s2000000000000000 2>&1 | tail -1)
mkdir -p "$R/sb0"; cp "$R/sb/gal.0.metallib" "$R/sb/gal.shards" "$R/gal.idx" "$R/sb/programs.tsv" "$R/sb0/"
python3 "$H/pso_gen.py" "$R/sb0/programs.tsv" "$R/sb0/gal.idx" "$R/sb0/gal.shards" "$R/sb0/pso" 300 > "$R/sb0/pso_gen.log"; chunk sb0
pb0=$("$R/archprobe" "$R/sb0/gal_pso.$TAG.bin" "$R/sb0/gal.0.metallib" R s1000000000000000 s2000000000000000 2>&1 | tail -1)
[ "$pb_" = "命中 1/1" ] && [ "$pb0" = "命中 0/1" ] && grep -q '"spec_bases": 1' "$R/sb/pso_gen.log" && echo "✓ ⑧ 运行时才出现的配对（b2 行）：基础管线命中 1/1（没有这行的对照 0/1）" || { echo "✗ ⑧ b2 行：期望 1/1、对照 0/1，实得 ${pb_:-无}、对照 ${pb0:-无}（$(tail -1 "$R/sb/pso_gen.log")）"; fail=$((fail + 1)); }
# ---------- 三、Metal 3（PSO_M3）：片号解析与缓存键（假编译器，不编真归档）----------
# ⑨ 3 片各自产物文件名不同：旧代码 ${S%.mtl4-json} 对 pso.2.mtlp-json 得到 n=mtlp-json，三片 TAG 相同、后编的覆盖先编的
# ⑩ 同一个 .key（同一片）在 Metal 3 与 Metal 4 之间不能命中对方的缓存产物
M3=$D/m3; mkdir -p "$M3/o" "$M3/w" "$M3/pc" "$M3/shim"
cat > "$M3/shim/xcrun" <<'XEOF'
#!/bin/bash
if [ "${4:-}" = "-version" ]; then echo "metal-tt fixture"; exit 0; fi
if [ "${3:-}" = "-f" ]; then echo /nonexistent/MetalToolchain-v1.0.0/usr/bin/metal-tt; exit 0; fi   # pso_chunk 取查询缓存后缀要 metal-tt 路径（tools/tt_env.sh），不计调用次数
prev=; out=
for a in "$@"; do [ "$prev" = "-o" ] && out=$a; prev=$a; done
echo x >> "$SHIM_LOG"
[ -n "$out" ] && printf 'm3' > "$out"
exit 0
XEOF
chmod +x "$M3/shim/xcrun"
for i in 0 1 2; do printf '{"libraries":{"paths":[]},"pipelines":{}}' > "$M3/w/pso.$i.mtlp-json"; echo "k$i" > "$M3/w/pso.$i.key"; done
export PSO_A=g16g PSO_PLAT=macos PSO_M=27 PSO_SV=27.0 PSO_SP=/x PSO_NTV=v1 PSO_SIG=s1
export PSO_O=$M3/o PSO_W=$M3/w PSO_PC=$M3/pc SHIM_LOG=$M3/shim_calls
n=$((n + 1))
for i in 0 1 2; do PATH="$M3/shim:$PATH" PSO_M3=1 PSO_M3VER=27.0 PSO_O=$M3/o PSO_W=$M3/w PSO_PC=$M3/pc bash "$C" "$M3/w/pso.$i.mtlp-json" > /dev/null 2>&1; done
cnt=$(ls "$M3/o"/gal_pso.*.bin 2>/dev/null | wc -l | tr -d ' ')
if [ "$cnt" = 3 ]; then echo "✓ ⑨ Metal 3 片号解析：3 片 → 3 个不同产物（$(ls "$M3/o" | tr '\n' ' ')）"
else echo "✗ ⑨ Metal 3 片号解析：期望 3 个不同产物，实得 ${cnt:-0}（$(ls "$M3/o" 2>/dev/null | tr '\n' ' ')）；旧代码对 pso.2.mtlp-json 算 n=mtlp-json，三片同名互相覆盖"; fail=$((fail + 1)); fi
n=$((n + 1))
echo '{"a":1}' > "$M3/w/pso.0.mtl4-json"   # 与 pso.0.mtlp-json 共用 pso.0.key（同一片，仅格式不同）
b4=$( [ -f "$M3/calls" ] && wc -l < "$M3/calls" | tr -d ' ' || echo 0 )
PSO_M3= PSO_NT=$D/fake_nt PSO_O=$M3/o PSO_W=$M3/w PSO_PC=$M3/pc bash "$C" "$M3/w/pso.0.mtl4-json" > /dev/null 2>&1
a4=$( [ -f "$M3/calls" ] && wc -l < "$M3/calls" | tr -d ' ' || echo 0 )
if [ "$a4" -gt "$b4" ]; then echo "✓ ⑩ 同一片切 Metal 4 不命中 Metal 3 的缓存（重编，调用 ${b4} → ${a4}）"
else echo "✗ ⑩ 同一片切 Metal 4 命中了 Metal 3 的缓存（调用次数未增）；缓存键缺 Metal 3 维度"; fail=$((fail + 1)); fi
n=$((n + 1))
b5=$( [ -f "$M3/shim_calls" ] && wc -l < "$M3/shim_calls" | tr -d ' ' || echo 0 )
PATH="$M3/shim:$PATH" PSO_M3=1 PSO_M3VER=26.0 PSO_O=$M3/o PSO_W=$M3/w PSO_PC=$M3/pc bash "$C" "$M3/w/pso.0.mtlp-json" > /dev/null 2>&1
a5=$( [ -f "$M3/shim_calls" ] && wc -l < "$M3/shim_calls" | tr -d ' ' || echo 0 )
if [ "$a5" -gt "$b5" ]; then echo "✓ ⑪ 同一片换 PSO_M3VER（27.0 → 26.0）不命中（重编，调用 ${b5} → ${a5}）"
else echo "✗ ⑪ 同一片换 PSO_M3VER 命中了旧缓存；缓存键缺最低系统版本维度"; fail=$((fail + 1)); fi
echo "管线分片缓存反证：$n 项，失败 $fail"
[ $fail = 0 ]
