#!/usr/bin/env bash
# Build the Android APK natively on the host (Linux x64 or Apple Silicon macOS),
# without the Docker image in docker/.
# Same steps and checks as docker/build.sh: cs/build.sh (NativeAOT probe), openssl/build.sh,
# :app:assembleDebug, :app:lintDebug, verify-apk.py and apksigner. It uses the host's pinned
# SDK packages, JDK 17 and .NET 10 and never installs anything itself: a missing package is
# reported with the exact sdkmanager command, a missing JDK / .NET with the path it looked for.
#
#   bash android/host/build.sh                  # full default build + APK checks
#   bash android/host/build.sh :app:assembleDebug --offline   # only these Gradle tasks
#
# Environment: ANDROID_HOME (or sdk.dir in local.properties, or ~/Android/Sdk,
# ~/Library/Android/sdk on macOS), S2A_JAVAC, S2A_ANDROID_DOTNET (must report the pinned
# cs/build.sh SDK version; unset it to bootstrap a private pinned SDK), S2A_BUILD_CACHE
# (default $HOME/.cache/s2arm-build), NUGET_PACKAGES (default $S2A_BUILD_CACHE/nuget),
# GRADLE_USER_HOME. The repository is only written under build/; Gradle keeps its
# usual host cache (~/.gradle) and the debug signing key stays in ~/.android.
set -euo pipefail
android_dir=$(cd "$(dirname "$0")/.." && pwd -P)
repo_dir=$(cd "$android_dir/.." && pwd -P)
cd "$android_dir"

# SDK 解析 + 固定包核对 + JDK 17 + 缓存目录 + .NET 透传：与 prepare.sh / gate-apk.sh 共用。
. "$android_dir/host/hostenv.sh"
# 只认文件的消费者（Gradle daemon、IDE、sdkmanager）与本次解析一致；写回 sdk.dir
# 只在显式准备 / 出包命令做，门禁路径不写（#1207 复审二条）。
if ! grep -qs '^[[:space:]]*sdk\.dir[[:space:]]*=' "$android_dir/local.properties" 2>/dev/null; then
    printf 'sdk.dir=%s\n' "$ANDROID_HOME" >> "$android_dir/local.properties"
fi
sdk=$ANDROID_HOME

echo "Android SDK: $sdk"
echo "JDK 17:      $JAVAC"
echo ".NET:        ${S2A_ANDROID_DOTNET:-<cs/build.sh 引导私有固定 SDK>}"
echo "构建缓存:    $S2A_BUILD_CACHE"

# --- Build -----------------------------------------------------------------
if [ "${1:-}" = --direct-identity ]; then   # 只出 build/android-direct/identity.json（安卓出包器用）
    exec bash "$android_dir/cs/build.sh" --direct-identity
fi
if [ $# -gt 0 ]; then
    echo "Gradle: $*"
    exec "$android_dir/gradlew" --project-cache-dir "$repo_dir/build/android-gradle-project" "$@"
fi

bash "$android_dir/cs/build.sh"
bash "$android_dir/openssl/build.sh"
"$android_dir/gradlew" --project-cache-dir "$repo_dir/build/android-gradle-project" \
    :app:assembleDebug :app:lintDebug
python3 "$android_dir/verify-apk.py" "$android_dir/app/build/outputs/apk/debug/app-debug.apk"
"$sdk/build-tools/$S2A_ANDROID_BUILD_TOOLS/apksigner" verify "$android_dir/app/build/outputs/apk/debug/app-debug.apk"
echo "APK: $android_dir/app/build/outputs/apk/debug/app-debug.apk"
