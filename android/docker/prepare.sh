#!/usr/bin/env bash
# Explicit online setup, separate from the network-disabled APK gate.
# Apple Silicon: enable Rosetta for amd64 containers (OrbStack Settings;
# Colima --vm-type vz --vz-rosetta; Docker Desktop Apple Virtualization +
# Use Rosetta). Some QEMU configurations fail .NET MSBuild evaluation.
# Linux arm64: use a verified binfmt/QEMU setup or a native amd64 builder.
# The fixed Dockerfile base digest and SHA-checked SDK/tool downloads populate
# the image; .NET/NuGet, Gradle, Opus, VP8 and OpenSSL populate the volume.
# 2026-10-28 commit eb66111f9, M2 Max / OrbStack, amd64 emulation: absent
# image + empty volume, --no-cache layers, existing base/host caches: 1197 s;
# image logical size
# 4,031,284,086 bytes, volume 2,689,736 KiB. An older script at 4fe0b7a4f
# measured 970 s. Neither measurement is of the current head; results vary.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
image=${S2ARM_ANDROID_IMAGE:-s2arm-android-build:1}
cache=${S2ARM_ANDROID_CACHE:-s2arm-android-build-cache}
for tool in docker python3; do command -v "$tool" >/dev/null || { echo "【红】准备需要 ${tool}" >&2; exit 1; }; done
start=$SECONDS
scratch=$(mktemp -d "${HOME}/s2a-apk-prepare.XXXXXXXX")
trap 'rc=$?; rm -rf "$scratch"; echo "安卓 APK 依赖准备墙钟：$((SECONDS - start)) 秒（rc=${rc}）"' EXIT
mkdir -p "$scratch/src"
python3 - "$root" "$scratch/src" <<'PY'
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
recipe=$(python3 - "$root/android/docker/Dockerfile" <<'PY'
import hashlib, pathlib, sys
print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())
PY
)
label=org.s2arm.android.dockerfile-sha256
installed=$(docker image inspect "$image" --format "{{index .Config.Labels \"$label\"}}" 2>/dev/null || true)
if [ "$installed" != "$recipe" ]; then
    if [ "${S2ARM_ANDROID_PREPARE_NO_CACHE:-0}" = 1 ]; then
        docker build --platform linux/amd64 --no-cache --label "$label=$recipe" -t "$image" "$root/android/docker"
    else
        docker build --platform linux/amd64 --label "$label=$recipe" -t "$image" "$root/android/docker"
    fi
fi
docker volume create "$cache" >/dev/null
image_id=$(docker image inspect "$image" --format '{{.Id}}')
expected=$(python3 "$root/android/docker/cache-identity.py" \
  --repo "$root" --source "$scratch/src" --image-id "$image_id" --recipe "$recipe")
slot=/cache/$(printf '%s\n' "$expected" | python3 "$root/android/docker/cache-identity.py" --slot) \
  || { echo '【红】准备无法确定凭据槽' >&2; exit 1; }
# Revoke any old success for this identity before touching the cache. Other
# identities' slots stay intact; the legacy single slot is retired here.
# A failed or interrupted preparation must not leave a receipt that lets an
# incomplete cache pass.
docker run --rm --network none --user "$(id -u):$(id -g)" \
  --mount "type=volume,source=$cache,target=/cache" --env "S2A_APK_RECEIPT_PATH=$slot" \
  --entrypoint sh "$image" \
  -c 'rm -f "$S2A_APK_RECEIPT_PATH" /cache/s2a-apk-gate-receipt.json'
# Bootstrap the same pinned SDK used by cs/build.sh, then test both startup and
# the target-framework property evaluation that failed under Colima/QEMU.
# Bootstrap errors (network/checksum) remain separate from emulation failures.
if ! docker run --rm --platform linux/amd64 --user "$(id -u):$(id -g)" \
  --mount "type=bind,source=$scratch/src,target=/src,readonly" \
  --mount "type=volume,source=$cache,target=/cache" \
  --env HOME=/cache/home --env S2A_BUILD_CACHE=/cache \
  --workdir /src/platforms/android --entrypoint bash "$image" cs/build.sh --prepare-sdk; then
    echo '【红】.NET SDK 准备失败；检查上方下载、SHA 校验或容器错误' >&2
    exit 1
fi
if ! docker run --rm --platform linux/amd64 --network none --user "$(id -u):$(id -g)" \
  --mount "type=bind,source=$scratch/src,target=/src,readonly" \
  --mount "type=volume,source=$cache,target=/cache" \
  --env HOME=/cache/home --env S2A_BUILD_CACHE=/cache \
  --workdir /src/platforms/android --entrypoint bash "$image" cs/build.sh --check-host \
  > "$scratch/dotnet-probe.log" 2>&1; then
    echo '【红】amd64 容器 .NET 启动或 MSBuild 求值失败；Apple Silicon 请启用 Rosetta，其他宿主请检查 amd64 运行环境（详见 README）' >&2
    exit 1
fi
# 固定版本源码包先在宿主按 SHA 取进本机共享缓存（tools/fetch_source.sh：命中不联网，下载按进展判挂死），
# 再把宿主的 sources/ 挂成容器的 /cache/sources：容器里 codecs/build.sh、openssl/build.sh 走同一个函数、命中同一份。
# 其余下载（SDK/NuGet、Gradle、libavc）照旧在容器里由各自的客户端与固定校验负责。
. "$root/android/tools/fetch_source.sh"
pin() { sed -n "$2" "$root/$1" | head -1; }
vpx_ver=$(pin services/vpx/build.sh 's/^VER=\([0-9.]*\); SHA=.*/\1/p')
vpx_sha=$(pin services/vpx/build.sh 's/^VER=[0-9.]*; SHA=\([0-9a-f]*\)$/\1/p')
opus_ver=$(pin services/opus/build.sh 's/^VER=\([0-9.]*\); SHA=.*/\1/p')
opus_sha=$(pin services/opus/build.sh 's/^VER=[0-9.]*; SHA=\([0-9a-f]*\)$/\1/p')
ssl_ver=$(pin android/openssl/build.sh 's/^version=\([0-9.]*\).*/\1/p')
ssl_sha=$(pin android/openssl/build.sh 's/^sha256=\([0-9a-f]*\)$/\1/p')
[ -n "$vpx_ver" ] && [ -n "$vpx_sha" ] && [ -n "$opus_ver" ] && [ -n "$opus_sha" ] && [ -n "$ssl_ver" ] && [ -n "$ssl_sha" ] \
  || { echo '【红】准备无法读取固定版本与 sha256' >&2; exit 1; }
s2a_source_fetch "libvpx-${vpx_ver}.tar.gz" "https://github.com/webmproject/libvpx/archive/refs/tags/v${vpx_ver}.tar.gz" "$vpx_sha" >/dev/null \
  && s2a_source_fetch "opus-${opus_ver}.tar.gz" "https://downloads.xiph.org/releases/opus/opus-${opus_ver}.tar.gz" "$opus_sha" >/dev/null \
  && s2a_source_fetch "openssl-${ssl_ver}.tar.gz" "https://github.com/openssl/openssl/releases/download/openssl-${ssl_ver}/openssl-${ssl_ver}.tar.gz" "$ssl_sha" >/dev/null \
  || { echo '【红】源码包准备失败；原因见上方【红】行' >&2; exit 1; }
sources=$(s2a_source_cache_dir)
docker run --rm --user "$(id -u):$(id -g)" \
  --mount "type=bind,source=$scratch/src,target=/src" \
  --mount "type=volume,source=$cache,target=/cache" \
  --mount "type=bind,source=$sources,target=/cache/sources" \
  --env S2A_BUILD_CACHE=/cache --env HOME=/cache/home --env GRADLE_USER_HOME=/cache/gradle \
  --env ANDROID_USER_HOME=/cache/android-user \
  --env S2ARM_ANDROID_CS_SERVICES=static --env S2ARM_ANDROID_GAME_DIR= --env RyuGpu= \
  --workdir /src/platforms/android --entrypoint bash "$image" -c '
    set -euo pipefail
    mkdir -p "$HOME" "$GRADLE_USER_HOME" "$ANDROID_USER_HOME"
    # Newer codec recipes require an explicit online source-preparation step;
    # older recipes download their pinned inputs during the following build.
    if grep -q "^--prepare-sources)" codecs/build.sh; then
        bash codecs/build.sh --prepare-sources
    fi
    bash cs/build.sh
    bash openssl/build.sh
    gradle --no-daemon --project-cache-dir /src/build/android-gradle-project :app:assembleDebug
    python3 docker/gate-audit.py
    python3 verify-apk.py app/build/outputs/apk/debug/app-debug.apk
  '
printf '镜像大小（字节）：'; docker image inspect "$image" --format '{{.Size}}'
printf '缓存卷占用（KiB）：'; docker run --rm --network none --mount "type=volume,source=$cache,target=/cache,readonly" --entrypoint du "$image" -sk /cache
# The build used a snapshot. Refuse to certify it if any dependency input
# changed during preparation; write the completed identity atomically last.
current=$(python3 "$root/android/docker/cache-identity.py" \
  --repo "$root" --source "$root" --image-id "$image_id" --recipe "$recipe")
[ "$current" = "$expected" ] || { echo '【红】准备期间依赖清单变化；未写完成标记' >&2; exit 1; }
docker run --rm --network none --user "$(id -u):$(id -g)" \
  --mount "type=volume,source=$cache,target=/cache" --env "S2A_APK_RECEIPT=$expected" \
  --env "S2A_APK_RECEIPT_PATH=$slot" \
  --mount "type=bind,source=$root/android/docker/cache-identity.py,target=/s2a-cache-identity.py,readonly" \
  --entrypoint python3 "$image" -c '
import os, subprocess, sys, tempfile
cache = "/cache"
path = os.environ["S2A_APK_RECEIPT_PATH"]
fd, temp = tempfile.mkstemp(prefix=".s2a-apk-receipt-", dir=cache)
try:
    with os.fdopen(fd, "w", encoding="utf-8") as output:
        output.write(os.environ["S2A_APK_RECEIPT"] + "\n")
        output.flush()
        os.fsync(output.fileno())
    os.replace(temp, path)
except BaseException:
    if os.path.exists(temp):
        os.unlink(temp)
    raise
# Keep the four most recently used identity slots (a successful gate run touches
# its own slot). Pruning only removes receipt files; dependency payloads in the
# volume are never touched.
subprocess.run([sys.executable, "/s2a-cache-identity.py", "--prune", cache], check=True)
'
