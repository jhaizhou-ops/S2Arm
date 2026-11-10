#!/usr/bin/env bash
# 门禁手动：要设备上抓的 NVDEC VP9 作业（游戏数据，只在本机）：S2A_VP9_CAPTURES=<抓取目录>（S2A_NVDEC_VP9_CAPTURE 的 frame_*.bin）
# 原生 VP9（libvpx + S2Arm 补丁，Vp9NativeFrame.cs 写帧头 / 参考槽）与托管解码器逐作业对拍：画面 Y/U/V、MV 回写、计数逐字节相同，且全部作业走原生。
set -euo pipefail
H=$(cd "$(dirname "$0")/.." && pwd -P)
: "${S2A_VP9_CAPTURES:?S2A_VP9_CAPTURES=<capture dir> is required}"
[ "$(uname -s)" = Darwin ] || { echo "t_vp9_native_parity：要苹果配方的 libs2a_vpx.dylib（macOS）" >&2; exit 75; }
export MSBUILDDISABLENODEREUSE=1
lib=$(bash "$H/services/vpx/build.sh" "osx-$( [ "$(uname -m)" = arm64 ] && echo arm64 || echo x64 )" | tail -1)
cd "$H/compat/tree"
dotnet build "$H/tests/vp9_native_parity/Vp9NativeParity.csproj" -c Release -m:1 -p:UseSharedCompilation=false --nologo -v q
exec dotnet "$H/tests/vp9_native_parity/bin/Release/net10.0/Vp9NativeParity.dll" "$S2A_VP9_CAPTURES" "${lib%/*}/libs2a_vpx.dylib"
