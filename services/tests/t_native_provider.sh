#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
DOTNET=${DOTNET:-$HOME/.dotnet/dotnet}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/s2a-provider-test.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
case "$(uname -s)" in
  Darwin) SHARED=-dynamiclib; EXT=dylib ;;
  Linux) SHARED=-shared; EXT=so ;;
  *) echo "不支持该宿主的 provider 动态库测试" >&2; exit 1 ;;
esac
for kind in full half empty; do
  case "$kind" in
    full) clang "$SHARED" -fPIC -DFULL "$ROOT/services/tests/native_provider_fixture.c" -o "$TMP/$kind.$EXT" ;;
    half) clang "$SHARED" -fPIC -DHALF "$ROOT/services/tests/native_provider_fixture.c" -o "$TMP/$kind.$EXT" ;;
    empty) clang "$SHARED" -fPIC "$ROOT/services/tests/native_provider_fixture.c" -o "$TMP/$kind.$EXT" ;;
  esac
done
DLL=${S2A_PROVIDER_DLL:-"$ROOT/services/S2A.Services.Tests/bin/Release/net10.0/S2A.Services.Tests.dll"}
timeout 30 "$DOTNET" "$DLL" --native-provider "$TMP/half.$EXT" "$TMP/full.$EXT" "$TMP/empty.$EXT" full
timeout 30 "$DOTNET" "$DLL" --native-provider "$TMP/half.$EXT" "$TMP/full.$EXT" "$TMP/empty.$EXT" empty
# #1422：同句柄「先兜底、再显式」的升级路径（独立进程，绑定是进程级 latch）
timeout 30 "$DOTNET" "$DLL" --native-provider-upgrade "$TMP/half.$EXT"
# #1422：平台装配登记兜底 owner 后，无参兜底应绑登记句柄（独立进程）
timeout 30 "$DOTNET" "$DLL" --native-provider-registered "$TMP/half.$EXT"

# Set the loader variable in the child after timeout starts: the macOS system
# Perl used by tools/bin/timeout strips inherited DYLD_* variables under SIP.
case "$(uname -s)" in
  Darwin) timeout 30 env DYLD_INSERT_LIBRARIES="$TMP/full.$EXT" "$DOTNET" "$DLL" --native-provider-legacy ;;
  Linux) timeout 30 env LD_PRELOAD="$TMP/full.$EXT" "$DOTNET" "$DLL" --native-provider-legacy ;;
esac
