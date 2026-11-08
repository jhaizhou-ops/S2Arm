#!/bin/bash
# Host-only run of the capprobe contract unit tests (no device, no
# Android SDK; plain JDK 17 javac/java + a C toolchain). Covers the
# verdict contract (CapProbeVerdictTest), the cache/orchestration layer
# (CapProbeStoreTest) with a stub NativeBridge for host compilation,
# and the arm runner's process model (capprobe_spawn_test: a sibling
# thread holds a lock through the probe window — the posix_spawn'd
# helper still answers, while a forked child under the same scenario
# wedges, which is the reported failure).
set -eu
cd "$(dirname "$0")"
repo=../../..
app_java="$repo/android/app/src/main/java"
tests="$repo/android/tests"
out=${OUT:-build}
mkdir -p "$out/java" "$out/bin"
javac -encoding UTF-8 -d "$out/java" \
    "$tests/stubs/org/s2arm/android/NativeBridge.java" \
    "$app_java/org/s2arm/android/CapProbeVerdict.java" \
    "$app_java/org/s2arm/android/CapProbe.java" \
    "$tests/CapProbeVerdictTest.java" \
    "$tests/CapProbeStoreTest.java"
java -cp "$out/java" org.s2arm.android.CapProbeVerdictTest
java -cp "$out/java" org.s2arm.android.CapProbeStoreTest
"${CC:-cc}" -std=gnu11 -Wall -Wextra -Werror \
    "$tests/capprobe_fake_helper.c" -o "$out/bin/capprobe-fake-helper"
"${CC:-cc}" -std=gnu11 -Wall -Wextra -Werror \
    "$tests/capprobe_fake_linker.c" -o "$out/bin/capprobe-fake-linker"
# The spawn test's directory standing in for the APK: the runner launches
# <apk>!/lib/arm64-v8a/libs2a_capprobe.so through the fake linker.
mkdir -p "$out/fakeapk/lib/arm64-v8a"
cp "$out/bin/capprobe-fake-helper" "$out/fakeapk/lib/arm64-v8a/libs2a_capprobe.so"
"${CC:-cc}" -std=gnu11 -Wall -Wextra -Werror -I . \
    "$tests/capprobe_spawn_test.c" capprobe_host.c \
    -o "$out/bin/capprobe-spawn-test" -lpthread
CAPPROBE_FAKE_APK="$out/fakeapk" CAPPROBE_FAKE_LINKER="$out/bin/capprobe-fake-linker" \
    "$out/bin/capprobe-spawn-test"
# GS-path decision + debug.s2a.gs_path force switch (#1482): built twice —
# "debug" keeps S2A_ANDROID_DEBUG_ENV so both gates live, "release" drops it
# so the compile-time gate is dead and the switch must stay inert.
gs_flags="-std=gnu11 -Wall -Wextra -Werror -D__ANDROID__ -I $tests/hostvk"
"${CC:-cc}" $gs_flags -DS2A_ANDROID_DEBUG_ENV -I ../.. \
    "$tests/gs_path_test.c" ../direct/gs_path.c capprobe_host.c \
    -o "$out/bin/gs-path-test-debug" -lpthread
"${CC:-cc}" $gs_flags -I ../.. \
    "$tests/gs_path_test.c" ../direct/gs_path.c capprobe_host.c \
    -o "$out/bin/gs-path-test-release" -lpthread
"$out/bin/gs-path-test-debug"
"$out/bin/gs-path-test-release"
echo "capprobe host tests: ok"
