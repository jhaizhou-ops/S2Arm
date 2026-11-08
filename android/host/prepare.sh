#!/usr/bin/env bash
# Explicit online setup for the native-host Android APK build (#1131), separate
# from the offline host/gate-apk.sh — same contract as docker/prepare.sh:
# download the pinned .NET SDK, NuGet/Gradle dependencies and codec/OpenSSL
# sources; run the same static-service build the gate runs offline; write the
# dependency-identity receipt into S2A_BUILD_CACHE atomically, last.
set -euo pipefail
android_dir=$(cd "$(dirname "$0")/.." && pwd -P)
repo_dir=$(cd "$android_dir/.." && pwd -P)
cd "$android_dir"
. "$android_dir/tools/ndk_toolchain.sh"
. "$android_dir/host/hostenv.sh"
# 只认文件的消费者（Gradle daemon、IDE、sdkmanager）与本次解析一致；写回 sdk.dir
# 只在显式准备 / 出包命令做，门禁路径不写（#1207 复审二条）。
if ! grep -qs '^[[:space:]]*sdk\.dir[[:space:]]*=' "$android_dir/local.properties" 2>/dev/null; then
    printf 'sdk.dir=%s\n' "$ANDROID_HOME" >> "$android_dir/local.properties"
fi
command -v git >/dev/null || { echo '【红】准备需要 git' >&2; exit 1; }
command -v python3 >/dev/null || { echo '【红】准备需要 python3' >&2; exit 1; }
start=$SECONDS
scratch=$(mktemp -d "${HOME}/s2a-apk-host-prepare.XXXXXXXX")
trap 'rc=$?; rm -rf "$scratch"; echo "安卓宿主 APK 准备墙钟：$((SECONDS - start)) 秒（rc=${rc}）"' EXIT
ndk=$(s2a_ndk_resolve) || { echo '【红】找不到固定 NDK（ANDROID_NDK_HOME 或 ANDROID_HOME/ndk/${S2A_ANDROID_NDK}）' >&2; exit 1; }
sdk_version=$(sed -n 's/^sdk_version=\([0-9.]*\).*/\1/p' "$android_dir/cs/build.sh" | head -1)
[ -n "$sdk_version" ] || { echo '【红】准备无法读取 cs/build.sh 的 sdk_version' >&2; exit 1; }
dotnet=${S2A_ANDROID_DOTNET:-$S2A_BUILD_CACHE/dotnet/$sdk_version/dotnet}

# The build runs in a tracked-file snapshot so the working tree stays clean and
# the dependency set under test is exactly what git tracks.
python3 - "$repo_dir" "$scratch/src" <<'PY'
import os, pathlib, shutil, subprocess, sys
root, target = map(pathlib.Path, sys.argv[1:])
for raw in subprocess.check_output(['git', '-C', str(root), 'ls-files', '-z']).split(b'\0'):
    if not raw:
        continue
    rel = os.fsdecode(raw)
    src, dst = root / rel, target / rel
    dst.parent.mkdir(parents=True, exist_ok=True)
    if src.is_symlink():
        dst.symlink_to(os.readlink(src))
    else:
        shutil.copy2(src, dst)
PY
expected=$(python3 "$android_dir/docker/cache-identity.py" --backend host \
    --repo "$repo_dir" --source "$scratch/src" --sdk "$ANDROID_HOME" --ndk "$ndk" \
    --dotnet "$dotnet" --javac "$JAVAC") || { echo '【红】依赖清单不可核实' >&2; exit 1; }
receipt_path=$S2A_BUILD_CACHE/$(printf '%s\n' "$expected" \
    | python3 "$android_dir/docker/cache-identity.py" --slot) \
    || { echo '【红】准备无法确定凭据槽' >&2; exit 1; }
# Revoke any old success for this identity before touching the cache, and retire
# the legacy single slot shared by every tree. Other identities' slots stay
# intact; a failed or interrupted preparation must not leave a receipt that lets
# an incomplete cache pass.
rm -f "$receipt_path" "$S2A_BUILD_CACHE/s2a-apk-gate-receipt.json"

# Online dependency acquisition. Every download stays behind the build scripts'
# own pinned-version + SHA checks; nothing here bypasses them.
(cd "$scratch/src/platforms/android" && bash codecs/build.sh --prepare-sources) || {
    echo '【红】codec 源码准备失败；检查上方下载或 SHA 校验' >&2; exit 1; }
(cd "$scratch/src/platforms/android" && S2ARM_ANDROID_CS_SERVICES=static bash host/build.sh) || {
    echo '【红】宿主构建失败；检查上方 .NET/NDK/Gradle/OpenSSL 输出' >&2; exit 1; }
python3 "$android_dir/docker/gate-audit.py" --root "$scratch/src" \
    --ndk-bin "$(s2a_ndk_host_bin "$ndk")" || {
    echo '【红】core-link 审计失败' >&2; exit 1; }

# The build used a snapshot. Refuse to certify it if any dependency input
# changed during preparation; write the completed identity atomically last.
current=$(python3 "$android_dir/docker/cache-identity.py" --backend host \
    --repo "$repo_dir" --source "$repo_dir" --sdk "$ANDROID_HOME" --ndk "$ndk" \
    --dotnet "$dotnet" --javac "$JAVAC")
[ "$current" = "$expected" ] || { echo '【红】准备期间依赖清单变化；未写完成标记' >&2; exit 1; }
S2A_APK_RECEIPT=$expected python3 - "$receipt_path" <<'PY'
import os, sys, tempfile
fd, path = tempfile.mkstemp(prefix='.s2a-apk-receipt-', dir=os.path.dirname(sys.argv[1]))
try:
    with os.fdopen(fd, 'w', encoding='utf-8') as output:
        output.write(os.environ['S2A_APK_RECEIPT'] + '\n')
        output.flush()
        os.fsync(output.fileno())
    os.replace(path, sys.argv[1])
except BaseException:
    if os.path.exists(path):
        os.unlink(path)
    raise
PY
# Keep the four most recently used identity slots (a successful gate run touches
# its own slot). Pruning only removes receipt files, never dependency payloads.
python3 "$android_dir/docker/cache-identity.py" --prune "$S2A_BUILD_CACHE"
echo "宿主准备完成标记：$receipt_path"
