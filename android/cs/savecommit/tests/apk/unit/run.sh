#!/usr/bin/env bash
# 门禁手动：只能 Linux（runtime/runner.c 要 sys/vfs.h，macOS 编不过），本机跑不了，门禁 Linux 路径本轮没实跑验证
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
# Manual host-only fake-JNI cleanup proof; not an Android/device gate.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d)
trap 'rm -f "$TMP/positive" "$TMP/negative" "$TMP/runner-negative.c" "$TMP/negative.log"; rmdir "$TMP"' EXIT
FLAGS=(-std=c11 -O1 -g -Wall -Wextra -Werror -Wpedantic -I "$HERE" -I "$HERE/../native")
"${CC:-cc}" "${FLAGS[@]}" "$HERE/cleanup_test.c" -o "$TMP/positive"
"$TMP/positive"
# Effective negative control: restore just the original path-overflow early return.
sed 's/{rc=-104;goto cleanup;}/{return -104;}/' "$HERE/../native/runner.c" > "$TMP/runner-negative.c"
"${CC:-cc}" "${FLAGS[@]}" -DRUNNER_SOURCE=\""$TMP/runner-negative.c"\" "$HERE/cleanup_test.c" -o "$TMP/negative"
set +e
"$TMP/negative" > "$TMP/negative.log" 2>&1
rc=$?
set -e
cat "$TMP/negative.log"
# The negative control stops at its empty owned fixture. Never recursively clean anything.
while IFS= read -r line; do
    case "$line" in fixture=/tmp/s2arm-cleanup-unit-*)
        path=${line#fixture=}; if [ -d "$path" ]; then rmdir "$path"; fi;;
    esac
done < "$TMP/negative.log"
if [ "$rc" != 1 ] || ! grep -q 'FAIL case=path .*leases==releases' "$TMP/negative.log"; then
    echo 'Negative control did not detect the original missing UTF release' >&2; exit 1
fi
echo 'Host cleanup positive and effective negative control passed; not Android evidence.'
