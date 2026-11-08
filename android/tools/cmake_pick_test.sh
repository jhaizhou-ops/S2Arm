#!/usr/bin/env bash
# tools/cmake_pick.sh 的宿主单测（假 cmake 可执行文件，不需要真 CMake，约 1 秒）：bash android/tools/cmake_pick_test.sh
# 期望按 #1568 定的顺序手写：
#   ① 给了 CMAKE 就用它，PATH / SDK 里有也不看；② CMAKE 为空或不可执行 → 报红返回 1，不改用别处；
#   ③ 没给 CMAKE、PATH 上有 cmake → 用 PATH 的；④ PATH 上没有 → SDK cmake/*/bin/cmake 里版本最高的（按数字比：3.10.2 > 3.9.0）；
#   ⑤ ANDROID_SDK_ROOT 没设时用 ANDROID_HOME；⑥ SDK 里没有可执行 bin/cmake 的版本目录不算；⑦ 三处都没有 → 报红返回 1；
#   ⑧ ctest 用同一份 CMake 目录里的（SDK 的 ctest 不在 PATH 上）；同目录没有才用 PATH 上的；两处都没有 → 报红返回 1
#   ⑨ s2a_cmake_shim 只放 cmake / ctest 两个软链：选中的 cmake 和 javac 同目录（像 /usr/bin）时，垫片放到 PATH 前面也不换 javac
set -u
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=/dev/null
source "$here/cmake_pick.sh"
T=$(cd "$(mktemp -d)" && pwd -P); trap 'rm -rf "$T"' EXIT
bad=0
ck() { if eval "$2"; then echo "通 $1"; else echo "不通 $1"; bad=1; fi; }
fake() { mkdir -p "$(dirname "$1")"; printf '#!/bin/sh\necho "cmake version 3.31.6"\n' > "$1"; chmod +x "$1"
          [ "${2:-}" = no-ctest ] || { cp "$1" "$(dirname "$1")/ctest"; chmod +x "$(dirname "$1")/ctest"; }; }
fake "$T/explicit/cmake"; fake "$T/onpath/cmake"
for v in 3.9.0 3.10.2 3.22.1; do fake "$T/sdk/cmake/$v/bin/cmake"; done
mkdir -p "$T/sdk/cmake/9.0.0/bin"; printf 'not executable\n' > "$T/sdk/cmake/9.0.0/bin/cmake"   # ⑥ 版本最高但不可执行
for v in 3.20.0 3.31.6; do fake "$T/home/cmake/$v/bin/cmake"; done
# 基础 PATH 只放挑选 / 垫片 / 断言用到的外部命令，保证宿主机自己装的 cmake、javac 不混进来
mkdir -p "$T/base"; for t in sort tail mkdir ln readlink ls tr; do ln -s "$(command -v $t)" "$T/base/$t"; done
P0=$T/base
pick() { (unset CMAKE ANDROID_SDK_ROOT ANDROID_HOME; export PATH=$P0; for kv in "$@"; do export "${kv?}"; done
          s2a_cmake_pick 2> "$T/err"; echo "$?|$S2A_CMAKE|$S2A_CMAKE_FROM|$S2A_CTEST"); }
ck "前提：基础 PATH 上没有 cmake（${P0}）" '! PATH=$P0 command -v cmake > /dev/null'
r=$(pick "CMAKE=$T/explicit/cmake" "PATH=$T/onpath:$P0" "ANDROID_SDK_ROOT=$T/sdk")
ck "① 给了 CMAKE 就用它，ctest 取同目录（实 ${r}）" '[ "$r" = "0|$T/explicit/cmake|\$CMAKE|$T/explicit/ctest" ]'
r=$(pick "CMAKE=$T/nope/cmake" "PATH=$T/onpath:$P0" "ANDROID_SDK_ROOT=$T/sdk")
ck "② CMAKE 不可执行 → 返回 1、报红、不改用 PATH（实 ${r}）" '[ "$r" = "1|||" ] && grep -q "【红】CMAKE 指定的 CMake 无效" "$T/err"'
r=$(pick "CMAKE=" "PATH=$T/onpath:$P0" "ANDROID_SDK_ROOT=$T/sdk")
ck "② CMAKE 为空 → 返回 1、报红（实 ${r}）" '[ "$r" = "1|||" ] && grep -q "<空值>" "$T/err"'
r=$(pick "PATH=$T/onpath:$P0" "ANDROID_SDK_ROOT=$T/sdk")
ck "③ 没给 CMAKE、PATH 上有 → PATH（实 ${r}）" '[ "$r" = "0|$T/onpath/cmake|PATH|$T/onpath/ctest" ]'
r=$(pick "ANDROID_SDK_ROOT=$T/sdk")
ck "④ PATH 上没有 → SDK 里版本最高的可执行 3.22.1（数字比：3.10.2 > 3.9.0；9.0.0 不可执行不算）（实 ${r}）" '[ "$r" = "0|$T/sdk/cmake/3.22.1/bin/cmake|SDK 3.22.1|$T/sdk/cmake/3.22.1/bin/ctest" ]'
r=$(pick "ANDROID_HOME=$T/home")
ck "⑤ ANDROID_SDK_ROOT 没设 → 用 ANDROID_HOME（实 ${r}）" '[ "$r" = "0|$T/home/cmake/3.31.6/bin/cmake|SDK 3.31.6|$T/home/cmake/3.31.6/bin/ctest" ]'
r=$(pick "ANDROID_SDK_ROOT=$T/sdk" "ANDROID_HOME=$T/home")
ck "⑤ 两个都设 → ANDROID_SDK_ROOT 优先（实 ${r}）" '[ "$r" = "0|$T/sdk/cmake/3.22.1/bin/cmake|SDK 3.22.1|$T/sdk/cmake/3.22.1/bin/ctest" ]'
# ⑧ 同目录没有 ctest：PATH 上有就用 PATH 的；两处都没有 → 报红
fake "$T/lonely/cmake" no-ctest; fake "$T/ctestonly/x"; rm "$T/ctestonly/x"
r=$(pick "CMAKE=$T/lonely/cmake" "PATH=$T/ctestonly:$P0")
ck "⑧ 同目录没 ctest、PATH 上有 → 用 PATH 的（实 ${r}）" '[ "$r" = "0|$T/lonely/cmake|\$CMAKE|$T/ctestonly/ctest" ]'
r=$(pick "CMAKE=$T/lonely/cmake")
ck "⑧ 同目录和 PATH 都没 ctest → 返回 1、报红（实 ${r}）" '[ "${r%%|*}" = 1 ] && grep -q "都没有 ctest" "$T/err"'
rm -rf "$T/sdk/cmake/3.9.0" "$T/sdk/cmake/3.10.2" "$T/sdk/cmake/3.22.1"
r=$(pick "ANDROID_SDK_ROOT=$T/sdk")
ck "⑥⑦ SDK 只剩不可执行的版本目录、PATH 也没有 → 返回 1、报红（实 ${r}）" '[ "$r" = "1|||" ] && grep -q "【红】找不到 CMake" "$T/err"'
r=$(pick)
ck "⑦ 三处都没有 → 返回 1、报红点明都没设（实 ${r}）" '[ "$r" = "1|||" ] && grep -q "都没设" "$T/err"'
# ⑨ 垫片只多出 cmake / ctest 两个名字（#1568 后续复核）：选中的 cmake 和一个 javac 同在一个目录（像 /usr/bin），
#   PATH=<垫片>:<原 PATH> 时 cmake / ctest 指向选中的那份，javac 仍是原 PATH 上排在前面的那个
mkdir -p "$T/sysbin" "$T/jdk17/bin"; fake "$T/sysbin/cmake"; printf '#!/bin/sh\necho javac 21\n' > "$T/sysbin/javac"; chmod +x "$T/sysbin/javac"
printf '#!/bin/sh\necho javac 17\n' > "$T/jdk17/bin/javac"; chmod +x "$T/jdk17/bin/javac"
r=$( (unset ANDROID_SDK_ROOT ANDROID_HOME; export CMAKE="$T/sysbin/cmake" PATH="$T/jdk17/bin:$P0:$T/sysbin"
      s2a_cmake_pick 2> "$T/err" && s2a_cmake_shim "$T/shim" && PATH="$T/shim:$PATH" \
      && echo "$(readlink "$(command -v cmake)")|$(readlink "$(command -v ctest)")|$(command -v javac)|$(ls "$T/shim" | tr '\n' ' ')") )
ck "⑨ 垫片只多 cmake / ctest：cmake、ctest 指向选中的，javac 仍是排在前面的 JDK 17（实 ${r}）" '[ "$r" = "$T/sysbin/cmake|$T/sysbin/ctest|$T/jdk17/bin/javac|cmake ctest " ]'
r=$( (S2A_CMAKE= S2A_CTEST=; s2a_cmake_shim "$T/shim2" 2>&1; echo "rc=$?") )
ck "⑨ 没先挑就建垫片 → 报红、不建目录（实 ${r}）" '[[ "$r" == *"【红】s2a_cmake_shim"*"rc=1" ]] && [ ! -e "$T/shim2" ]'
[ $bad = 0 ] && echo "cmake_pick 单测全过" || { echo "cmake_pick 单测有不通"; exit 1; }
