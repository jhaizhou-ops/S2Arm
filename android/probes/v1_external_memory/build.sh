#!/usr/bin/env bash
# Cross-compile the WP17 V1 probe inside the pinned Android build image (NDK 29.0.14206865, API 35):
#   build/android-probes/v1_external_memory/v1probe              arm64 executable for adb shell
#   build/android-probes/v1_external_memory/jniLibs/arm64-v8a/libv1probe.so
#   build/android-probes/v1_external_memory/apk/outputs/apk/debug/v1probe-debug.apk   (org.s2arm.probe.v1)
#
#   bash android/probes/v1_external_memory/build.sh          # executable + APK
#   bash android/probes/v1_external_memory/build.sh exe      # executable only
#
# S2A_ANDROID_IMAGE overrides the image; S2A_ANDROID_CACHE names the Docker volume that holds the
# Gradle cache (the APK build runs `gradle --offline`, so the cache must already hold AGP 9.4.1).
set -euo pipefail
probe_dir=$(cd "$(dirname "$0")" && pwd)
repo_dir=$(cd "$probe_dir/../../.." && pwd)
image=${S2A_ANDROID_IMAGE:-sha256:4cbb20d3398c3a28eb95c07bf99352834bb622951426976ca8438a7fb2498321}
cache=${S2A_ANDROID_CACHE:-s2arm-owned-pr-android-cache}
rel=android/probes/v1_external_memory
v0rel=android/probes/v0_external_memory
out_rel=build/android-probes/v1_external_memory
rev=$(git -C "$repo_dir" rev-parse --short=12 HEAD 2> /dev/null || echo unknown)
if [ -n "$(git -C "$repo_dir" status --porcelain -- "$rel" "$v0rel" 2> /dev/null)" ]; then rev="$rev-dirty"; fi
mkdir -p "$repo_dir/$out_rel/jniLibs/arm64-v8a"

docker run --rm --platform linux/amd64 -v "$repo_dir:/src" -w /src "$image" bash -euo pipefail -c "
ndk=/opt/android-sdk/ndk/29.0.14206865
tc=\$ndk/toolchains/llvm/prebuilt/linux-x86_64/bin
\$ndk/shader-tools/linux-x86_64/glslc --target-env=vulkan1.1 -mfmt=c -o $out_rel/xor.comp.inc $v0rel/xor.comp
\$ndk/shader-tools/linux-x86_64/glslc --target-env=vulkan1.1 -o $out_rel/xor.spv $v0rel/xor.comp
\$ndk/shader-tools/linux-x86_64/spirv-val --target-env vulkan1.1 $out_rel/xor.spv
for kind in exe jni; do
    if [ \$kind = exe ]; then out=$out_rel/v1probe; extra='-fPIE -pie'; else out=$out_rel/jniLibs/arm64-v8a/libv1probe.so; extra='-fPIC -shared -DV1_JNI'; fi
    \$tc/aarch64-linux-android35-clang -std=c11 -O2 -Wall -Wextra -Werror \$extra \
        -DPROBE_REV='\"$rev\"' -I$out_rel -o \$out $rel/v1probe.c -lvulkan -landroid
done
\$tc/llvm-strip $out_rel/v1probe $out_rel/jniLibs/arm64-v8a/libv1probe.so
\$tc/llvm-readelf -d $out_rel/v1probe | grep NEEDED
"
shasum -a 256 "$repo_dir/$out_rel/v1probe" "$repo_dir/$out_rel/jniLibs/arm64-v8a/libv1probe.so"
[ "${1:-}" = exe ] && exit 0

docker run --rm --platform linux/amd64 --user "$(id -u):$(id -g)" \
    --mount "type=bind,source=$repo_dir,target=/src" --mount "type=volume,source=$cache,target=/cache" \
    --env HOME=/cache/home --env GRADLE_USER_HOME=/cache/gradle --env ANDROID_USER_HOME=/cache/android-user \
    --workdir "/src/$rel/apk" --entrypoint bash "$image" -euo pipefail -c "
gradle --offline --no-daemon --project-cache-dir /src/$out_rel/gradle-project -Pv1.out=/src/$out_rel assembleDebug
\$ANDROID_HOME/build-tools/36.0.0/apksigner verify --print-certs /src/$out_rel/apk/outputs/apk/debug/v1probe-debug.apk 2>/dev/null | head -3 || true
" | tail -20
apk="$repo_dir/$out_rel/apk/outputs/apk/debug/v1probe-debug.apk"
shasum -a 256 "$apk"
