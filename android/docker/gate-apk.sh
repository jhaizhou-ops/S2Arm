#!/usr/bin/env bash
# Build a diagnostic static-service APK in a disposable source tree, offline.
set -euo pipefail
root=$(cd "$(dirname "$0")/../.." && pwd)
image=${S2ARM_ANDROID_IMAGE:-s2arm-android-build:1}
cache=${S2ARM_ANDROID_CACHE:-s2arm-android-build-cache}
# 只核准备标记（S2A_APK_RECEIPT_CHECK=1，合入后钩子 tools/post_android_prepare.sh 用）：标记与当前依赖清单相符退 0、缺 / 不匹配（重跑 prepare 能修）退 42，不往下出包
need() { [ "${S2A_APK_RECEIPT_CHECK:-}" != 1 ] || { printf '需备料：%s\n' "$1"; exit 42; }; }
skip() { printf '未跑：%s；运行 bash android/docker/prepare.sh\n待宿主证\t安卓宿主\tapk\n' "$1"; exit 0; }
red() { printf '【红】安卓 APK 门禁：%s\n' "$1" >&2; exit 1; }
command -v docker >/dev/null || skip '缺 Docker'
if inspection=$(docker image inspect "$image" 2>&1); then :; else
  case "$inspection" in
    *'No such image:'*|*'No such object:'*) need "缺镜像 ${image}"; skip "缺镜像 ${image}" ;;
    *) red "无法检查镜像 ${image}：${inspection}" ;;
  esac
fi
recipe=$(python3 - "$root/android/docker/Dockerfile" <<'PY_RECIPE'
import hashlib, pathlib, sys
print(hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest())
PY_RECIPE
) || red '镜像配方不可读'
label=org.s2arm.android.dockerfile-sha256
installed=$(docker image inspect "$image" --format "{{index .Config.Labels \"$label\"}}") || red '无法读取镜像配方标签'
[ "$installed" = "$recipe" ] || { need '镜像配方不匹配'; red '镜像配方不匹配；运行 bash android/docker/prepare.sh'; }
image_id=$(docker image inspect "$image" --format '{{.Id}}') || red '无法识别镜像'
[ -n "$image_id" ] || red '镜像身份为空'
if inspection=$(docker volume inspect "$cache" 2>&1); then :; else
  case "$inspection" in
    *'No such volume:'*|*'No such object:'*) need "缺缓存卷 ${cache}"; skip "缺缓存卷 ${cache}" ;;
    *) red "无法检查缓存卷 ${cache}：${inspection}" ;;
  esac
fi
expected=$(python3 "$root/android/docker/cache-identity.py" --repo "$root" --source "$root" --image-id "$image_id" --recipe "$recipe") || red '依赖清单不可核实'
slot=/cache/$(printf '%s\n' "$expected" | python3 "$root/android/docker/cache-identity.py" --slot) || red '依赖清单不可核实'
# Distinguish an absent receipt from a broken cache or a Docker execution error.
# Only this dependency identity's slot is consulted; other identities' slots are
# left alone so concurrent trees do not invalidate each other.
if receipt=$(docker run --rm --network none --mount "type=volume,source=$cache,target=/cache,readonly" \
  --env "S2A_APK_RECEIPT_PATH=$slot" --entrypoint sh "$image" -c '
  p=$S2A_APK_RECEIPT_PATH
  [ ! -L "$p" ] || exit 43
  [ -e "$p" ] || exit 42
  [ -f "$p" ] || exit 43
  cat "$p"
'); then :; else
  rc=$?
  [ "$rc" -ne 42 ] || { need '缺准备完成标记'; skip '缺准备完成标记'; }
  red "无法读取准备完成标记（rc=${rc}）"
fi
[ "$receipt" = "$expected" ] || { need '准备标记与镜像或依赖不匹配'; red '准备标记与镜像或依赖不匹配；运行 bash android/docker/prepare.sh'; }
[ "${S2A_APK_RECEIPT_CHECK:-}" != 1 ] || { echo '准备标记与当前依赖清单相符'; exit 0; }
# Record that this identity actually used the gate. prepare.sh keeps the four
# most recently used slots, so a rarely prepared but frequently used identity
# (main) is not evicted by branches that prepare one after another. The receipt
# read above stays read-only; this one-shot container gets a writable mount and
# a fixed command that only touches the slot just verified, leaving the build
# command and its cache mounts unchanged. The slot stays in the cache volume
# rather than a separate receipt volume: deleting the dependency volume then
# cannot leave a receipt that claims dependencies which no longer exist.
if docker run --rm --network none --user "$(id -u):$(id -g)" \
  --mount "type=volume,source=$cache,target=/cache" \
  --env "S2A_APK_RECEIPT_PATH=$slot" --entrypoint sh "$image" -c '
  p=$S2A_APK_RECEIPT_PATH
  [ ! -L "$p" ] && [ -f "$p" ] && touch "$p"
'; then :; else
  rc=$?
  red "无法登记准备凭据使用时间（rc=${rc}）"
fi
start=$SECONDS
scratch=$(mktemp -d "${HOME}/s2a-apk-gate.XXXXXXXX")
trap 'rc=$?; rm -rf "$scratch"; echo "安卓 APK 门禁墙钟：$((SECONDS - start)) 秒（rc=${rc}）"' EXIT
# The working-tree bytes, including tracked local edits, are the inputs under test.
# Never copy ignored outputs or an untracked game tree.
python3 - "$root" "$scratch" <<'PY'
import os, pathlib, shutil, subprocess, sys
root, target = map(pathlib.Path, sys.argv[1:])
paths = subprocess.check_output(['git', '-C', str(root), 'ls-files', '-z']).split(b'\0')
for raw in paths:
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
# Build dependencies must already exist in the selected volume. No network access
# is granted to restore missing SDKs, NuGet packages or Gradle dependencies.
rc=0
docker run --rm --network none --user "$(id -u):$(id -g)" \
  --mount "type=bind,source=$scratch,target=/src" \
  --mount "type=volume,source=$cache,target=/cache" \
  --env S2A_BUILD_CACHE=/cache --env HOME=/cache/home --env GRADLE_USER_HOME=/cache/gradle \
  --env ANDROID_USER_HOME=/cache/android-user \
  --env S2ARM_ANDROID_CS_SERVICES=static --env S2ARM_ANDROID_GAME_DIR= --env RyuGpu= \
  --workdir /src/platforms/android --entrypoint bash "$image" -c '
    set -euo pipefail
    mkdir -p "$HOME" "$GRADLE_USER_HOME" "$ANDROID_USER_HOME"
    source docker/gate-step.sh
    s2a_apk_step bash cs/build.sh
    s2a_apk_step bash openssl/build.sh
    s2a_apk_step gradle --offline --no-daemon --project-cache-dir /src/build/android-gradle-project :app:assembleDebug
    s2a_apk_step python3 docker/gate-audit.py
    s2a_apk_step python3 verify-apk.py app/build/outputs/apk/debug/app-debug.apk
  ' > "$scratch/docker.log" 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
  reason=$(grep -m1 '^【红】APK ' "$scratch/docker.log" || true)
  # gradle：真正的报错在「* What went wrong:」下面；gate-step 取到的第一条「> 」行只是阶段名（如 > Configure project :app）
  #   （放在这里不放 gate-step.sh：后者在离线依赖身份清单里，改它会让各机准备标记失效）
  www=$(awk '/^\* What went wrong:/ {f = 1; next} f && NF {print; exit}' "$scratch/docker.log")
  [ -z "$www" ] || [ -z "$reason" ] || reason="${reason%%：*}：$www"
  if [ -z "$reason" ]; then
    reason=$(grep -v '^[[:space:]]*$' "$scratch/docker.log" | tail -1 || true)
    reason="【红】APK 容器失败（rc=${rc}）：${reason:-无诊断输出}"
  fi
  printf '%s\n' "$reason" >&2
fi
cat "$scratch/docker.log"
if [ "$rc" -eq 0 ] && [ -n "${S2A_APK_OUT:-}" ]; then
  cp "$scratch/platforms/android/app/build/outputs/apk/debug/app-debug.apk" "$S2A_APK_OUT"
fi
# 失败时把 gradle 的「What went wrong」整段在末尾再打一遍：门禁红项只留日志末 30 行，这段在中间会被 * Try: 与弃用提示挤掉
#   （11-01 合入后层 APK 红只看得到「> Configure project :app」）
if [ "$rc" -ne 0 ] && grep -q '^\* What went wrong:' "$scratch/docker.log"; then
  printf '【红】APK 失败原因段落：\n'
  awk '/^\* What went wrong:/ {f = 1} /^\* Try:/ {f = 0} f' "$scratch/docker.log" | head -25
fi
if [ "$rc" -eq 0 ]; then
  printf '已证宿主项\t安卓宿主\tapk\n'
fi
exit "$rc"
