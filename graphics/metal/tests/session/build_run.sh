#!/bin/bash
# 真实 NativeAOT + NxGal：无窗口呈现/读回、超过命令环容量的资源清理、原生 pthread 上创建下一局。
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../../../.." && pwd)
OUT="$ROOT/build/threaded-session"
DN=${DOTNET:-$HOME/.dotnet/dotnet}
[ -x "$DN" ] || { echo "缺少可执行 .NET：$DN" >&2; exit 2; }
mkdir -p "$OUT"
make -s -C "$ROOT/graphics/metal" "$ROOT/build/gal/libnxgal.dylib"
"$DN" publish "$HERE/Session.csproj" -c Release -r osx-arm64 --self-contained -p:PublishAot=true \
    --artifacts-path "$OUT/official-art" -p:OutDir="$OUT/official-bin/" -o "$OUT/official" -v:q -nologo > "$OUT/build.log" 2>&1
export NXGAL_LIB="$ROOT/build/gal/libnxgal.dylib"
timeout 90 "$OUT/official/Session" --native-create > "$OUT/run.log" 2>&1
cat "$OUT/run.log"
# 旧顺序的真实反证：先停编码线程，10032 次 DeleteBuffer 会堵在环形队列，必须失败，不能被底层全局 reset 掩盖。
if timeout 20 "$OUT/official/Session" --stop-backend-before-disposal > "$OUT/old-order.log" 2>&1; then
    echo "旧顺序反证未失败" >&2
    exit 1
else
    rc=$?
    [ "$rc" -eq 1 ] || { cat "$OUT/old-order.log" >&2; exit "$rc"; }
    rg -q '资源释放队列堵住' "$OUT/old-order.log"
fi
echo "PASS: 10 sessions x 120 GPU readbacks/presents; 10032 real buffers released per session; old disposal order rejected"
