#!/usr/bin/env bash
# test.sh 原生段用哪个 CMake（#1568 合入线定）：
#   $CMAKE → PATH 上的 cmake → ${ANDROID_SDK_ROOT}（没设用 ${ANDROID_HOME}）/cmake/*/bin/cmake 里版本最高的。
#   官方构建镜像只在 SDK 里有 CMake 3.31.6、PATH 上没有（#107 情形 E：原来退出 127「cmake: command not found」）。
# 用法：source 本文件后调 s2a_cmake_pick（不要在 $(...) 里调）；成功时设 S2A_CMAKE（路径）、S2A_CMAKE_FROM（来源）
#   和 S2A_CTEST（同一份 CMake 目录里的 ctest，没有才用 PATH 上的），返回 0。
#   SDK 的 CMake 目录里 cmake 与 ctest 并排，PATH 上两个都没有：只换 cmake 的话，`cmake -E chdir … ctest` 仍找不到 ctest。
#   显式给了 CMAKE 但为空或不可执行 → 报红返回 1，不悄悄改用 PATH / SDK（同 gate.sh 对 S2A_PY 的口径）；
#   三处都没有 → 报红返回 1。不在这里卡版本下限（3.18+ 由 CMakeLists.txt 的 cmake_minimum_required 报）。
s2a_cmake_pick() {
    S2A_CMAKE= S2A_CMAKE_FROM= S2A_CTEST=
    s2a_cmake_pick_one || return 1
    if [ -x "${S2A_CMAKE%/*}/ctest" ]; then S2A_CTEST=${S2A_CMAKE%/*}/ctest
    elif ! S2A_CTEST=$(command -v ctest 2> /dev/null); then
        S2A_CTEST=
        echo "【红】找到 CMake（${S2A_CMAKE}）但同目录和 PATH 上都没有 ctest" >&2
        return 1
    fi
}

s2a_cmake_pick_one() {
    local found sdk best d v
    if [ "${CMAKE+x}" ]; then
        if [ -z "$CMAKE" ] || ! found=$(command -v -- "$CMAKE" 2> /dev/null) || [ ! -x "$found" ]; then
            echo "【红】CMAKE 指定的 CMake 无效：${CMAKE:-<空值>}（显式给了就不改用 PATH / SDK）" >&2
            return 1
        fi
        S2A_CMAKE=$found S2A_CMAKE_FROM='$CMAKE'
        return 0
    fi
    if found=$(command -v cmake 2> /dev/null) && [ -x "$found" ]; then
        S2A_CMAKE=$found S2A_CMAKE_FROM=PATH
        return 0
    fi
    sdk=${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}
    if [ -n "$sdk" ] && [ -d "$sdk/cmake" ]; then
        # 版本按数字逐段比（3.10.2 比 3.9.0 高），只收真有可执行 bin/cmake 的目录
        best=$(for d in "$sdk"/cmake/*/; do
                   v=${d%/}; v=${v##*/}
                   [ -x "$sdk/cmake/$v/bin/cmake" ] && printf '%s\n' "$v"
               done | sort -t. -k1,1n -k2,2n -k3,3n | tail -n 1)
        if [ -n "$best" ]; then
            S2A_CMAKE=$sdk/cmake/$best/bin/cmake S2A_CMAKE_FROM="SDK $best"
            return 0
        fi
    fi
    echo "【红】找不到 CMake：没设 CMAKE，PATH 上没有 cmake，${sdk:-<ANDROID_SDK_ROOT / ANDROID_HOME 都没设>}/cmake/*/bin/cmake 也没有" >&2
    return 1
}

# s2a_cmake_shim <目录>：在 <目录> 里只放 cmake / ctest 两个指向已选那份的软链（先调 s2a_cmake_pick）。
#   子测试有的自己按 PATH 找 cmake（core-link/test_audit.py）：调用方只给 CMake 那几步用 PATH=<目录>:${PATH}，
#   多出来的只有这两个名字。不能把选中 cmake 所在目录整个放到 PATH 前面：它可能是 /usr/bin，
#   会换掉调用方放在前面的 JDK 17 / Python venv（javac、java、python3 都在那里）。
s2a_cmake_shim() {
    [ -n "${1:-}" ] && [ -n "${S2A_CMAKE:-}" ] && [ -n "${S2A_CTEST:-}" ] || { echo "【红】s2a_cmake_shim：要先 s2a_cmake_pick 并给目录" >&2; return 1; }
    mkdir -p "$1" && ln -sf "$S2A_CMAKE" "$1/cmake" && ln -sf "$S2A_CTEST" "$1/ctest"
}
