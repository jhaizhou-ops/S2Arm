#!/bin/bash
# 门禁覆盖：graphics/tools/direct/vklib/dsh_vklib.py android/cs/build.sh tests/dsh_vklib_launcher_test.sh
# 出包 Vulkan 库启动器找 dotnet 的单测（graphics/tools/direct/vklib/dsh_vklib.py，#783 合入线 11-03 答 ③：复用安卓构建同一份解析 / 引导，不另抄查找顺序；假仓库 + 假 dotnet，约 1 秒）：
#   bash tests/dsh_vklib_launcher_test.sh。启动器与 android/cs/build.sh（及它引的 ndk_toolchain.sh / versions.sh、versions.sh 读的 docker/Dockerfile）原样拷进假仓库。期望按 build.sh 的口径手写：
#   ① 给了 S2A_ANDROID_DOTNET（固定版本 10.0.403）→ 用它，不用 PATH 上的另一个 dotnet；调 dotnet 时带 DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1（同 build.sh）
#   ② S2A_ANDROID_DOTNET 版本不对 → 启动器退非 0、[RED]，带 build.sh 的「要求固定」原话
#   ③ 没给 S2A_ANDROID_DOTNET、私有固定 SDK 已在 S2A_BUILD_CACHE/dotnet/10.0.403 → 用它、不下载（PATH 上的 curl 是会记账的桩）
set -u; H=$(cd "$(dirname "$0")/.." && pwd); T=$(mktemp -d); bad=0; trap 'rm -rf "$T"' EXIT
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
P=$T/repo; mkdir -p $P/graphics/tools/direct/vklib $P/android/cs $P/android/tools $P/android/docker $T/bin
cp "$H/graphics/tools/direct/vklib/dsh_vklib.py" $P/graphics/tools/direct/vklib/; cp "$H/android/cs/build.sh" $P/android/cs/
cp "$H/android/tools/ndk_toolchain.sh" "$H/android/tools/versions.sh" $P/android/tools/; cp "$H/android/docker/Dockerfile" $P/android/docker/
fake() {   # fake <路径> <版本> <VkFpPrint 打的指纹>：--version 回版本；msbuild 回「VKFP=<指纹>」并记下 DOTNET_SYSTEM_GLOBALIZATION_INVARIANT
  mkdir -p "$(dirname "$1")"; printf '#!/bin/sh\ncase "$1" in --version) echo %s;; msbuild) echo "  VKFP=%s"; echo "${DOTNET_SYSTEM_GLOBALIZATION_INVARIANT:-无}" > "%s.env";; esac\n' "$2" "$3" "$1" > "$1"; chmod +x "$1"; }
fake $T/a/dotnet 10.0.403 00000000000000aa; fake $T/bin/dotnet 10.0.403 00000000000000bb; fake $T/old/dotnet 9.0.100 00000000000000dd
fake $T/cache/dotnet/10.0.403/dotnet 10.0.403 00000000000000cc
printf '#!/bin/sh\necho curl >> %s/curl.calls; exit 1\n' "$T" > $T/bin/curl; chmod +x $T/bin/curl
F() { env -u DOTNET_SYSTEM_GLOBALIZATION_INVARIANT PATH="$T/bin:$PATH" S2A_BUILD_CACHE=$T/cache "$@" python3 $P/graphics/tools/direct/vklib/dsh_vklib.py fp 2>&1; }
o=$(F S2A_ANDROID_DOTNET=$T/a/dotnet); r=$?
ck "① 给了 S2A_ANDROID_DOTNET → 用它（rc=${r}，实 ${o}；PATH 上那个会打 …bb），调用时全球化设 invariant（实 $(cat $T/a/dotnet.env 2> /dev/null)）" '[ $r = 0 ] && [ "$o" = 00000000000000aa ] && [ "$(cat $T/a/dotnet.env)" = 1 ]'
o=$(F S2A_ANDROID_DOTNET=$T/old/dotnet); r=$?
ck "② S2A_ANDROID_DOTNET 版本不对 → 退非 0、[RED]、带 build.sh 原话（rc=${r}）" '[ $r != 0 ] && [[ "$o" == *"[RED]"* ]] && [[ "$o" == *"要求固定 10.0.403"* ]]'
o=$(env -u S2A_ANDROID_DOTNET bash -c "$(declare -f F); T=$T P=$P; F"); r=$?
ck "③ 没给 S2A_ANDROID_DOTNET → 用私有固定 SDK（rc=${r}，实 ${o}）、不下载（curl 调了 $(cat $T/curl.calls 2> /dev/null | wc -l | tr -d ' ') 次）" '[ $r = 0 ] && [ "$o" = 00000000000000cc ] && [ ! -e $T/curl.calls ]'
[ $bad = 0 ] && echo "dsh_vklib 启动器单测：全通" || echo "dsh_vklib 启动器单测：有不通"
exit $bad
