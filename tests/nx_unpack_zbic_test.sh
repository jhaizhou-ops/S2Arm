#!/bin/bash
# 门禁覆盖：pack/nx_unpack/* tests/nx_unpack_zbic/* compat/packages/*
# nx_unpack 的 ZBIC 单测（#769：22.0.0 起 NSO 标志 0x80，段是 ZBIC）：编 tests/nx_unpack_zbic（直接编 pack/nx_unpack/ZbicDecoder.cs、NsoZbic.cs）并跑。
#   期望：测试帧（BIC 表头各 4 处）解出与合成原文逐字节相同、校验和帧对上；改坏 / 截断 / 标准 zstd / 不认识的魔数报错；NSO 规整同前（0x40 保留）。产物在 <仓库根>/build/nx_unpack_zbic_test。退出 0 = 全过
# 子命令端到端：编真 nx_unpack 跑 --nso-normalize <in> <out>（不要密钥）——真 ZBIC 样本解出与 Normalize 期望逐字节相同（0xBF → 0x38、0xFF → 0x78）、
#   非 NSO 原样写出、输入缺位 / ZBIC 数据损坏退出非 0。样本由 ZbicTest --emit 合成落盘（合成、不进仓库）。
set -u
H=$(cd "$(dirname "$0")" && pwd); ROOT=$(cd "$H/.." && pwd); OUT=$ROOT/build/nx_unpack_zbic_test; mkdir -p "$OUT"
timeout 500 dotnet build "$H/nx_unpack_zbic/ZbicTest.csproj" -c Release --artifacts-path "$OUT/art" -v quiet -nologo > "$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; echo "不通 编译（期望编过）"; exit 1; }
B=$(find "$OUT/art/bin" -name ZbicTest.dll | head -1); [ -n "$B" ] || { echo "不通 没找到 ZbicTest.dll"; exit 1; }
timeout 120 dotnet "$B" || exit 1

# --nso-normalize 子命令（真 nx_unpack + ZbicTest --emit 合成的真 ZBIC 样本）
timeout 500 dotnet build "$ROOT/pack/nx_unpack/nx_unpack.csproj" -c Release --artifacts-path "$OUT/artx" -v quiet -nologo >> "$OUT/build.log" 2>&1 || { tail -30 "$OUT/build.log"; echo "不通 nx_unpack 编译（期望编过）"; exit 1; }
NXD=$(find "$OUT/artx/bin" -name nx_unpack.dll | head -1); [ -n "$NXD" ] || { echo "不通 没找到 nx_unpack.dll"; exit 1; }
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
dotnet "$B" --emit "$W/z.nso" "$W/z-exp.nso" > /dev/null || { echo "不通 --emit 0xBF 样本"; exit 1; }
dotnet "$B" --emit "$W/zff.nso" "$W/zff-exp.nso" FF > /dev/null || { echo "不通 --emit 0xFF 样本"; exit 1; }
bad=0; flg() { xxd -p -l 4 -s 12 "$1"; }
timeout 120 dotnet "$NXD" --nso-normalize "$W/z.nso" "$W/z-out.nso" > "$W/o1" 2>&1 || bad=1
cmp -s "$W/z-out.nso" "$W/z-exp.nso" && [ "$(flg "$W/z-out.nso")" = 38000000 ] || bad=1
[ $bad = 0 ] && echo "通 子命令 0xBF 样本退出 0、产物与期望逐字节相同、标志 0x38" || { echo "不通 子命令 0xBF 样本（$(cat "$W/o1" | tail -1)）"; }
timeout 120 dotnet "$NXD" --nso-normalize "$W/zff.nso" "$W/zff-out.nso" > "$W/o2" 2>&1 && cmp -s "$W/zff-out.nso" "$W/zff-exp.nso" && [ "$(flg "$W/zff-out.nso")" = 78000000 ] \
  && echo "通 子命令 0xFF 样本（ZBIC + 0x40，塞尔达 main 的值）退出 0、逐字节相同、标志 0x78" || { echo "不通 子命令 0xFF 样本（$(cat "$W/o2" | tail -1)）"; bad=1; }
printf 'this is not an NSO file at all' > "$W/blob"
timeout 120 dotnet "$NXD" --nso-normalize "$W/blob" "$W/blob.out" > "$W/o3" 2>&1 && cmp -s "$W/blob" "$W/blob.out" \
  && echo "通 子命令非 NSO 原样写出" || { echo "不通 子命令非 NSO 原样写出（$(cat "$W/o3" | tail -1)）"; bad=1; }
timeout 120 dotnet "$NXD" --nso-normalize "$W/no-such.nso" "$W/x.nso" > "$W/o4" 2>&1; rc=$?
[ $rc != 0 ] && [ ! -f "$W/x.nso" ] && echo "通 子命令输入缺位退出非 0、不留下产物" || { echo "不通 子命令输入缺位（rc=$rc: $(cat "$W/o4" | tail -1)）"; bad=1; }
cp "$W/z.nso" "$W/zbad.nso"; printf '\xAA' | dd of="$W/zbad.nso" bs=1 seek=$((0x100 + 8)) conv=notrunc 2> /dev/null
timeout 120 dotnet "$NXD" --nso-normalize "$W/zbad.nso" "$W/x2.nso" > "$W/o5" 2>&1; rc=$?
[ $rc != 0 ] && [ ! -f "$W/x2.nso" ] && echo "通 子命令 ZBIC 数据损坏退出非 0、不留下产物" || { echo "不通 子命令 ZBIC 数据损坏（rc=$rc: $(cat "$W/o5" | tail -1)）"; bad=1; }
exit $bad
