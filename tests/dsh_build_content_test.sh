#!/bin/bash
# 门禁覆盖：translator/dsh_batch.py graphics/tools/direct/tests/dshfn.py tests/dsh_build_content_test.sh
# dsh_batch 构建按源内容判重编、不信时间戳（约 3 秒，假 dotnet 记参数，不真编）：bash tests/dsh_build_content_test.sh
#   11-02 合入线：mini 时钟被手设慢 16 小时，旧 obj 时间戳落在将来，dotnet 增量把新源码当成旧的不重编，nxgal_fp_test 跑到不认 --lib-fp 的旧 dll。
#   期望（按需求手写）：源内容（工程闭包 + 单列文件 + 属性引用文件）和上次编出产物时不同 → 带 --no-incremental；内容没变、只动时间戳或 bin/obj → 不带（产物在就不调 dotnet build，11-06）；编失败不记戳。
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
R=$T/repo; mkdir -p $R/translator $R/graphics/nvn/gfx/nvn $R/graphics/tools/direct $R/graphics/metal $R/compat/tree/src
cp "$H/translator/dsh_batch.py" "$H/translator/xlock.py" $R/translator/; cp -R "$H/translator/dmsh_xlate" $R/translator/; cp "$H/graphics/nvn/gfx/nvn/dmsh_chain.h" $R/graphics/nvn/gfx/nvn/   # xlock.py：dsh_batch.py 的跨平台文件锁（#1100 W6）
cp -R "$H/graphics/tools/direct/dsh" "$H/graphics/tools/direct/compiler" $R/graphics/tools/direct/; cp -R "$H/graphics/widen" $R/graphics/; cp "$H"/graphics/metal/gal_spvx.* $R/graphics/metal/
cp "$H/compat/tree/Directory.Build.props" $R/compat/tree/; for p in Ryujinx.Graphics.Shader Spv.Generator Ryujinx.Common; do cp -R "$H/compat/tree/src/$p" $R/compat/tree/src/; done
rm -rf $R/graphics/tools/direct/dsh/bin $R/graphics/tools/direct/dsh/obj $R/build
# 假 dotnet：build 记一行参数、按 FAKE_RC 退出并放一个 dll；<dll> --xfp 打 16 位十六进制
cat > $T/dotnet <<'EOF'
#!/bin/bash
if [ "$1" = build ]; then echo "$*" >> "$FAKE_LOG"; o=; while [ $# -gt 0 ]; do [ "$1" = -o ] && o=$2; shift; done; [ -n "$o" ] && : > "$o/dsh_batch.dll"; exit "${FAKE_RC:-0}"; fi
[ "${2:-}" = --xfp ] && echo 0123456789abcdef
EOF
chmod +x $T/dotnet
B() { : > $T/log; DOTNET=$T/dotnet FAKE_LOG=$T/log FAKE_RC=${1:-0} python3 -c "import sys; sys.path.insert(0, '$R/translator'); import dsh_batch; dsh_batch.build()" > /dev/null 2>&1; }
full() { grep -q -- --no-incremental $T/log; }
B; ck "① 首编（没有戳）→ 全量重编、记戳" 'full && [ -s $R/build/dsh_batch/.src_digest ]'
B; ck "② 再编、内容没变、产物在 → 不调 dotnet build（11-06 出包速度线：无改动的增量编也要起 MSBuild 几秒）" '[ ! -s $T/log ]'
rm -f $R/build/dsh_batch/dsh_batch.dll; B; ck "②b 内容没变但产物丢了 → 照常编（增量）、不跳过" '! full && [ -s $T/log ]'
mkdir -p $R/graphics/tools/direct/dsh/obj; touch -t 203001010000 $R/graphics/tools/direct/dsh/obj/x.dll $R/build/dsh_batch/dsh_batch.dll; touch $R/graphics/tools/direct/dsh/batch/Program.cs
B; ck "③ 只动时间戳（产物在将来、源码刚 touch）→ 不全量" '! full'
echo x > $R/graphics/tools/direct/dsh/obj/y.cache; B; ck "④ 只动 obj/ → 不全量" '! full'
echo '// t' >> $R/graphics/tools/direct/dsh/batch/Program.cs; B; ck "⑤ 改 batch/Program.cs → 全量" 'full'
f=$(ls $R/compat/tree/src/Ryujinx.Common/*.cs | head -1); echo '// t' >> "$f"; B; ck "⑥ 改引用闭包深处 Ryujinx.Common → 全量" 'full'
echo '// t' >> $R/graphics/nvn/gfx/nvn/dmsh_chain.h; B; ck "⑦ 改属性引用的 dmsh_chain.h → 全量" 'full'
echo '// t' >> $R/graphics/metal/gal_spvx.c; B; ck "⑧ 改单列的 DshXfpInput gal_spvx.c → 全量" 'full'
echo '// u' >> $R/graphics/tools/direct/dsh/Dsh.cs; B 1; B; ck "⑨ 改源后编失败不记戳 → 下次仍全量" 'full'
# 启动器内置件（S2A_PREBUILT_TOOLS/dsh_batch，bundle_engine.py 发版时编好并写源码摘要，11-06）：摘要相同 → 用内置件、不调 dotnet build；不同 → 照常现编
P=$T/pre; mkdir -p $P/dsh_batch; : > $P/dsh_batch/dsh_batch.dll
python3 -c "import sys; sys.path.insert(0, '$R/translator'); import dsh_batch, os; print(dsh_batch.src_digest(os.path.join(dsh_batch.DSH, 'batch', 'dsh_batch.csproj')))" > $P/dsh_batch/.src_digest
BP() { : > $T/log; S2A_PREBUILT_TOOLS=$P DOTNET=$T/dotnet FAKE_LOG=$T/log python3 -c "import sys; sys.path.insert(0, '$R/translator'); import dsh_batch; print(dsh_batch.build()[0][1])" 2>/dev/null; }
rm -f $R/build/dsh_batch/dsh_batch.dll; o=$(BP); ck "⑩ 内置件摘要相同 → 用内置件（${o}）、不调 dotnet build" '[ "$o" = "$P/dsh_batch/dsh_batch.dll" ] && [ ! -s $T/log ]'
echo '// p' >> $R/graphics/tools/direct/dsh/Dsh.cs; o=$(BP); ck "⑪ 源码改过、摘要不同 → 不用内置件、照常现编（${o}）" '[ "$o" = "$R/build/dsh_batch/dsh_batch.dll" ] && full'
[ $bad = 0 ] && echo "dsh_build_content 单测全过" || { echo "dsh_build_content 单测有不通"; exit 1; }
