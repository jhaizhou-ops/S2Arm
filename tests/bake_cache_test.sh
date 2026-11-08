#!/bin/bash
# 翻译缓存单测（graphics/tools/shader_pack.sh ②，假翻译器 / 假抽取，临时目录，约 5 秒）：bash tests/bake_cache_test.sh
#   期望按缓存规则手算：同输入第二次不跑翻译器、产物逐字节相同；并行度 J 不同仍命中；
#   翻译器源码里读的环境变量变了 / 抽取内容变了 / 程序表变了 → 重翻；翻译 rc≠0 不进缓存；S2A_BAKE_CACHE=off 不缓存
set -u
R=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d "${TMPDIR:-/tmp}/bake_cache_test.XXXXXX"); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "✓ $1"; else echo "✗ $1"; bad=1; fi; }
P=$T/repo; mkdir -p "$P/graphics/tools/shbake" "$P/graphics/metal/tools" "$P/tools" "$P/cs" "$T/data/romfs" "$T/data/exefs" "$T/pre/gal" "$T/pre/shbake"
# romfs_list.py：input_fp 的 RomFS 文件清单经它（仓库里唯一的 RomFS 遍历）
mkdir -p "$P/graphics/nvn/tools"; cp "$R/graphics/nvn/tools/romfs_list.py" "$P/graphics/nvn/tools/"
cp "$R/graphics/tools/shader_pack.sh" "$R/graphics/tools/timeout_snap.sh" "$P/graphics/tools/"; cp "$R/graphics/tools/shbake/out_fp.py" "$P/graphics/tools/shbake/"; cp "$R/tools/safe_killpg.sh" "$P/tools/"
printf 'export IPHONEOS_DEPLOYMENT_TARGET=18.0 MACOSX_DEPLOYMENT_TARGET=15.0\n' > "$P/tools/toolchain.sh"
# 翻译器源码里读的环境变量（缓存键从源码现扫）：哨兵两个 + 一个假开关
printf 'class A { void f() { System.Environment.GetEnvironmentVariable("S2A_PROG_TABLE"); System.Environment.GetEnvironmentVariable("S2A_FAKE_KNOB"); } }\n' > "$P/cs/A.cs"
printf 'int main(void) { return getenv("NXGAL_VPULL") != 0; }\n' > "$P/graphics/metal/tools/gal_xc.c"; printf 'void g(void) { getenv("NXGAL_FAKE_XC"); }\n' > "$P/graphics/metal/a.m"
# 假抽取：rows.tsv 内容 = ${FAKE_ROWS}；其余读取器出空
printf 'import os, sys\nos.makedirs(sys.argv[1], exist_ok=True)\nopen(sys.argv[1] + "/rows.tsv", "w").write(os.environ.get("FAKE_ROWS", "r1") + "\\n")\nopen(os.environ["CALLS"] + ".x", "a").write(" ".join(sys.argv[2:]) + "\\n")\n' > "$P/graphics/tools/shbake/nxsh_extract.py"   # 每次调用记参数（$CALLS.x）
printf 'import sys\nopen(sys.argv[2], "w").write("")\n' > "$P/graphics/tools/shbake/file_pairs.py"
printf 'print("{}")\n' > "$P/graphics/tools/shbake/nvn_uses.py"
printf 'import sys\nsys.exit(1)\n' > "$P/graphics/metal/tools/gal_offline.py"
# 假翻译器：记一次调用；产物 = 抽取内容 + 假开关取值（翻译确实依赖的输入）；FAKE_BAKE_RC 控退出码
cat > "$T/pre/shbake/S2A.ShBake" <<'EOF'
#!/bin/bash
echo x >> "$CALLS"; W=$3; mkdir -p "$W/spv" "$W/lib" "$W/shcache/t"; echo v > "$W/spv/a.spv"
{ cat "$2/rows.tsv"; echo "knob=${S2A_FAKE_KNOB:-}"; } > "$W/lib/a.msl"; echo s > "$W/shcache/t/guest"; echo '{}' > "$W/bake.json"; exit "${FAKE_BAKE_RC:-0}"
EOF
for f in gal/gal_xc shbake/gpu_arch; do printf '#!/bin/sh\nexit 0\n' > "$T/pre/$f"; done; chmod +x "$T/pre"/*/*; printf '{}' > "$T/pre/prepare.json"
printf code > "$T/data/exefs/main"; printf data > "$T/data/romfs/f"
python3 -c "import struct,sys;b=bytearray(0x100);struct.pack_into('<I',b,0x70,0x80);b[0x80:0x84]=b'ACI0';struct.pack_into('<Q',b,0x90,0x0100000000001234);open(sys.argv[1],'wb').write(b)" "$T/data/main.npdm"
export CALLS=$T/calls S2A_PREBUILT_TOOLS=$T/pre S2A_PYTHON=python3 S2A_BAKE_CACHE=$T/bc J=4
unset S2A_FAKE_KNOB NXGAL_FAKE_XC FAKE_ROWS FAKE_BAKE_RC S2A_FBR_VARS
n=0; run() { n=$((n + 1)); S2A_SHX_CACHE=$T/shx$n bash "$P/graphics/tools/shader_pack.sh" "$T/data" "$T/o$n" > "$T/log$n" 2>&1; }
calls() { wc -l < "$CALLS" | tr -d ' '; }
: > "$CALLS"
run; ck "首次：跑翻译器 1 次、存进缓存" '[ "$(calls)" = 1 ] && [ "$(ls "$T/bc"/*/ok 2>/dev/null | wc -l | tr -d " ")" = 1 ]'
run; ck "同输入：不跑翻译器、日志写命中" '[ "$(calls)" = 1 ] && grep -q 翻译：缓存命中 "$T/log2"'
ck "命中的产物与首次逐字节相同" 'diff -r "$T/o1/work/lib" "$T/o2/work/lib" > /dev/null && diff -r "$T/o1/work/shcache" "$T/o2/work/shcache" > /dev/null && cmp -s "$T/o1/work/bake.json" "$T/o2/work/bake.json"'
J=11 run; ck "并行度不同仍命中" '[ "$(calls)" = 1 ]'
S2A_FAKE_KNOB=1 run; ck "翻译器读的环境变量变了：重翻" '[ "$(calls)" = 2 ] && grep -q knob=1 "$T/o$n/work/lib/a.msl"'
NXGAL_FAKE_XC=1 run; ck "gal_xc 读的环境变量变了：重翻" '[ "$(calls)" = 3 ]'
FAKE_ROWS=r2 run; ck "抽取内容变了：重翻" '[ "$(calls)" = 4 ] && grep -q r2 "$T/o$n/work/lib/a.msl"'
S2A_FAKE_KNOB=2 FAKE_BAKE_RC=1 run; S2A_FAKE_KNOB=2 FAKE_BAKE_RC=1 run; ck "翻译 rc≠0 不进缓存（同输入两次都跑）" '[ "$(calls)" = 6 ]'
S2A_BAKE_CACHE=off run; ck "S2A_BAKE_CACHE=off：不查缓存" '[ "$(calls)" = 7 ]'
ck "缓存只存翻译新出的条目（不含抽取、不含 spv/），命中时留空 spv/" '! ls -d "$T/bc"/*/extract "$T/bc"/*/spv > /dev/null 2>&1 && [ -d "$T/o2/work/spv" ]'
# ②½ 产出指纹（10-24，graphics/tools/shbake/out_fp.py）：现行记下的指纹（S2A_SHADERS_PREV/output.fp）= 本次的 → 不编库、退出 3；
#   键变而产出不变（gal_xc 读的开关变了 → 重翻，但假翻译器的产出不依赖它）→ 仍退出 3；并行度变了 → 退出 3；反证：抽取内容变了（MSL 变）/ 片长 S2A_PSO_P 变了 → 照常编（到假 ③ 退出 1）
mkdir -p "$T/prev"; cp "$T/o2/work/output.fp" "$T/prev/"; export S2A_SHADERS_PREV=$T/prev; c0=$(calls)
run; r=$?; ck "指纹同现行 → 退出 ${r}（期望 3）、日志写「沿用现行」" '[ $r = 3 ] && grep -q "沿用现行" "$T/log$n"'
NXGAL_FAKE_XC=1 run; r=$?; ck "键变（重翻 $(( $(calls) - c0 )) 次）而产出不变 → 退出 ${r}（期望 3）" '[ $r = 3 ] && [ $(( $(calls) - c0 )) -ge 1 ]'
S2A_PSO_J=3 J=2 run; r=$?; ck "并行度变了 → 退出 ${r}（期望 3）" '[ $r = 3 ]'
FAKE_ROWS=r9 run; r=$?; ck "反证：MSL 变了 → 照常编（退出 ${r}，期望到假 ③ 的 1）、日志写「照常编」" '[ $r = 1 ] && grep -q "照常编" "$T/log$n"'
S2A_PSO_P=300 run; r=$?; ck "反证：片长 S2A_PSO_P 变了 → 照常编（退出 ${r}）" '[ $r = 1 ] && grep -q "照常编" "$T/log$n"'
unset S2A_SHADERS_PREV
# 抽着色器只做一次（10-25）：产物根有追加内容 → 自己抽时 aoc/<序号> 一起扫；有抽取阶段的结果（extract/ok + s2x/）→ 克隆它、不跑抽取器
mkdir -p "$T/data/aoc/1"; printf dlc > "$T/data/aoc/1/f"; x0=$(wc -l < "$CALLS.x" | tr -d ' ')
FAKE_ROWS=r10 run; ck "有追加内容：自己抽时一起扫 aoc/1（实 $(tail -1 "$CALLS.x" | tr ' ' '\n' | grep -c aoc/1) 处）" '[ "$(wc -l < "$CALLS.x" | tr -d " ")" = $((x0 + 1)) ] && tail -1 "$CALLS.x" | grep -q "/aoc/1 "'
mkdir -p "$T/data/extract/s2x"; echo shared > "$T/data/extract/s2x/rows.tsv"; echo log > "$T/data/extract/s2x.log"; printf 'split\t1\n' > "$T/data/extract/ok"
x1=$(wc -l < "$CALLS.x" | tr -d ' '); run
ck "有抽取阶段的结果：不跑抽取器（$x1 → $(wc -l < "$CALLS.x" | tr -d ' ') 次）、翻译读到它（shared）" '[ "$(wc -l < "$CALLS.x" | tr -d " ")" = "$x1" ] && grep -q shared "$T/o$n/work/lib/a.msl"'
rm -rf "$T/data/extract" "$T/data/aoc"
echo "翻译缓存单测：$([ $bad = 0 ] && echo 全过 || echo 有失败)"; exit $bad
