#!/bin/bash
# 着色器包产出指纹单测（graphics/tools/shbake/out_fp.py，10-24 总指挥「输出不变就不算变」，手造工作目录与仓库，约 2 秒）：bash graphics/tools/shbake/tests/t_out_fp.sh
#   期望按规则手写（不跑被测实现推期望）：只动非内容字节（程序表 ms 列、.toc 第 16–23 字节创建时间戳）、只改运行时 / 翻译器源码（gal_core.m、ShaderBake.cs）、
#   只改并行度 / 远端分流 → 指纹不变；反证：MSL、离线索引、Ryujinx 缓存内容、.toc 时间戳以外的字节、程序表非 ms 列、翻译红数、
#   ③④ 脚本（pso_gen.py）、影响产物的开关（S2A_PSO_P）、首用表内容 → 指纹变
set -u
H=$(cd "$(dirname "$0")/../../../.." && pwd); FP=$H/graphics/tools/shbake/out_fp.py
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; n=0; bad=0
W=$T/w R=$T/r TID=0100000000001234
mkdir -p "$W/lib/msl" "$W/shcache/$TID" "$R/graphics/tools/shbake" "$R/graphics/metal/tools" "$R/tools"
echo 'vertex float4 s1() { return 0; }' > "$W/lib/msl/0000000000000001.metal"; printf 'GALI' > "$W/lib/gal.idx"
printf 'idx\torigin\tstatus\tms\terr\n0\trule\tok\t12.5\t\n' > "$W/programs.tsv"
python3 -c "import sys; open(sys.argv[1],'wb').write(b'TOCS' + bytes(12) + b'\x11' * 8 + b'entries')" "$W/shcache/$TID/shared.toc"; echo data > "$W/shcache/$TID/shared.data"
echo '{"red": {"xlate": 0}, "counts": {"written": 1}, "wall_ms": 100}' > "$W/bake.json"
for f in widen.idx widen_pos.bin guest_keys.tsv fbr.tsv; do echo "$f" > "$W/$f"; done
echo 'print(1)' > "$R/graphics/tools/shbake/pso_gen.py"; echo 'class B {}' > "$R/graphics/tools/shbake/ShaderBake.cs"; echo 'x=1' > "$R/graphics/tools/shader_pack.sh"
echo 'y=1' > "$R/graphics/metal/tools/gal_offline.py"; echo 'IPHONEOS_DEPLOYMENT_TARGET=18.0' > "$R/tools/toolchain.env"; echo 'void f(void) {}' > "$R/graphics/metal/gal_core.m"
echo 'use 1' > "$T/use.tsv"
unset S2A_PSO_P S2A_PSO_J S2A_PSO_REMOTE S2A_PSO_USE S2A_PSO_KEYMAP S2A_SPEC_PIPES
fp() { S2A_PSO_USE=$T/use.tsv python3 "$FP" "$W" "$R" ios "$TID"; }
F0=$(fp)
same() { n=$((n + 1)); local f; f=$(fp); if [ "$f" = "$F0" ]; then echo "✓ 不变：$1"; else echo "✗ 应不变：$1"; bad=$((bad + 1)); fi; }
diff_() { n=$((n + 1)); local f; f=$(fp); if [ "$f" != "$F0" ]; then echo "✓ 变（反证）：$1"; else echo "✗ 应变：$1"; bad=$((bad + 1)); fi; }
bk() { cp -c "$1" "$T/bk" 2>/dev/null || cp "$1" "$T/bk"; }; rs() { cp "$T/bk" "$1"; }   # 改一处、判、复原，下一项仍对 F0
bk "$W/programs.tsv"; sed -i '' 's/12\.5/98.1/' "$W/programs.tsv"; same "程序表只改 ms 列"; rs "$W/programs.tsv"
bk "$W/shcache/$TID/shared.toc"; python3 -c "import sys; b=bytearray(open(sys.argv[1],'rb').read()); b[16:24]=b'\x22'*8; open(sys.argv[1],'wb').write(b)" "$W/shcache/$TID/shared.toc"; same ".toc 只改创建时间戳（第 16–23 字节）"; rs "$W/shcache/$TID/shared.toc"
bk "$W/bake.json"; sed -i '' 's/"wall_ms": 100/"wall_ms": 7/' "$W/bake.json"; same "翻译读数只改耗时"; rs "$W/bake.json"
bk "$R/graphics/metal/gal_core.m"; echo 'void g(void) {}' >> "$R/graphics/metal/gal_core.m"; same "只改运行时源码 gal_core.m（键里 gal_xc 二进制会变）"; rs "$R/graphics/metal/gal_core.m"
bk "$R/graphics/tools/shbake/ShaderBake.cs"; echo '// x' >> "$R/graphics/tools/shbake/ShaderBake.cs"; same "只改翻译器 C# 源码（对产出的影响已在 ② 产出里）"; rs "$R/graphics/tools/shbake/ShaderBake.cs"
S2A_PSO_J=3 S2A_PSO_REMOTE=off same "只改并行度 / 远端分流（S2A_PSO_J、S2A_PSO_REMOTE）"
bk "$W/lib/msl/0000000000000001.metal"; echo '// y' >> "$W/lib/msl/0000000000000001.metal"; diff_ "MSL 改一行"; rs "$W/lib/msl/0000000000000001.metal"
bk "$W/lib/gal.idx"; printf 'GALJ' > "$W/lib/gal.idx"; diff_ "离线索引改一字节"; rs "$W/lib/gal.idx"
bk "$W/shcache/$TID/shared.data"; echo data2 > "$W/shcache/$TID/shared.data"; diff_ "Ryujinx 缓存数据"; rs "$W/shcache/$TID/shared.data"
bk "$W/shcache/$TID/shared.toc"; python3 -c "import sys; b=bytearray(open(sys.argv[1],'rb').read()); b[24]^=1; open(sys.argv[1],'wb').write(b)" "$W/shcache/$TID/shared.toc"; diff_ ".toc 时间戳以外的字节（第 24 字节）"; rs "$W/shcache/$TID/shared.toc"
bk "$W/programs.tsv"; sed -i '' 's/	ok	/	no_rule	/' "$W/programs.tsv"; diff_ "程序表非 ms 列（状态）"; rs "$W/programs.tsv"
bk "$W/bake.json"; sed -i '' 's/"xlate": 0/"xlate": 1/' "$W/bake.json"; diff_ "翻译红数"; rs "$W/bake.json"
bk "$R/graphics/tools/shbake/pso_gen.py"; echo 'print(2)' >> "$R/graphics/tools/shbake/pso_gen.py"; diff_ "③④ 脚本 pso_gen.py"; rs "$R/graphics/tools/shbake/pso_gen.py"
S2A_PSO_P=300 diff_ "影响产物的开关 S2A_PSO_P=300"
bk "$T/use.tsv"; echo 'use 2' > "$T/use.tsv"; diff_ "首用表内容"; rs "$T/use.tsv"
same "全部复原后回到原指纹"
echo "t_out_fp：$n 项，失败 $bad"
[ $bad = 0 ]
