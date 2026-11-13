#!/bin/bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# 门禁覆盖：macos/sdl3/build.sh android/tools/fetch_source.sh
# Missing/corrupt prepared sources must fail before CMake or any network tool.
set -euo pipefail
cd "$(dirname "$0")/.."
W=$(mktemp -d "${TMPDIR:-/tmp}/s2arm-sdl-source.XXXXXX")
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin"
for tool in curl gh cmake ninja; do
  cat > "$W/bin/$tool" <<'GUARD'
#!/bin/sh
echo "$0" >> "$S2A_SDL_TEST_CALLS"
exit 99
GUARD
  chmod +x "$W/bin/$tool"
done
export PATH="$W/bin:$PATH" S2A_BUILD_CACHE="$W/cache" S2A_SDL_TEST_CALLS="$W/calls"
check_failure() {
  if bash macos/sdl3/build.sh "$@" > "$W/out" 2> "$W/err"; then
    echo 'FAIL: unprepared SDL source was accepted' >&2; exit 1
  fi
  [ ! -e "$W/calls" ] || { echo 'FAIL: a build/test invoked a preparation tool' >&2; exit 1; }
  grep -q -- '--fetch' "$W/err"
}
check_failure
check_failure --check-source
SHA=d0a8bb138c83c77c0241630159c8bf90d2a9f05ae9bbaca5f19574dac88a8e80
mkdir -p "$S2A_BUILD_CACHE/sources/$SHA"
printf 'corrupt archive\n' > "$S2A_BUILD_CACHE/sources/$SHA/SDL-5403934fd30e3568b1e20f652d4823c796739722.tar.gz"
check_failure
check_failure --check-source
echo 'PASS: SDL source absent/corrupt × normal/check-only (4 cases), no network or compiler invocation'
