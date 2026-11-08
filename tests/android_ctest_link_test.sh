#!/usr/bin/env bash
# 门禁覆盖：android/ctest-link/* android/core-link/link_symbols.py
# 门禁本机：要 cmake + ninja + NDK 29 真编真链假工程；mini 的 /opt/homebrew/bin 没有 cmake / ninja（10-30 实测）
# 安卓 Linux CTest 链接符号核对（android/ctest-link/ctest_link.py）的单测：手写假 CMake 工程，期望按规则手算——
#   Linux 配置：if(ANDROID) 分支不进、Linux 专属目标要进；缺定义的外部符号报【红】（符号、文件:行、目标）；
#   替身文件提供定义 = 绿；--gc-sections 下死函数里的引用不算缺；目标自己 -D__ANDROID__ 才走安卓分支；
#   -lpthread / -Werror 不误红；编译不过报【红】；路由自检漏一个读入文件报一行【红】、全覆盖退 0。
set -u
root=$(cd "$(dirname "$0")/.." && pwd)
tool="$root/android/ctest-link/ctest_link.py"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
bad=0
ok() { echo "  ✓ $*"; }
no() { echo "  ✗ $*"; bad=1; }

p="$T/fake"; mkdir -p "$p"
cat > "$p/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.16)
project(fake C)
if(ANDROID)
    add_executable(android_only_test ok.c)
else()
    add_executable(ok_test ok.c lib.c)
    add_executable(miss_test miss.c)
    add_executable(stub_test uses.c stub.c)
    add_executable(gc_test gc.c)
    target_compile_options(gc_test PRIVATE -ffunction-sections)
    target_link_options(gc_test PRIVATE -Wl,--gc-sections)
    add_executable(cfg_test cfg.c)
    add_executable(cfg2_test cfg.c)
    target_compile_definitions(cfg2_test PRIVATE __ANDROID__)
    add_executable(thr_test thr.c)
    target_link_libraries(thr_test PRIVATE pthread)
    add_executable(werr_test werr.c)
    target_compile_options(werr_test PRIVATE -Wall -Werror)
    add_executable(broken_test broken.c)
    if(CMAKE_SYSTEM_NAME STREQUAL "Linux")
        add_executable(linux_only_test linux_only.c)
    endif()
endif()
EOF
printf 'int lib_fn(void);\nint main(void) { return lib_fn(); }\n' > "$p/ok.c"
printf 'int lib_fn(void) { return 0; }\n' > "$p/lib.c"
printf 'int missing_fn(void);\nint main(void) {\n    return missing_fn();\n}\n' > "$p/miss.c"
printf 'int stubbed(void);\nint main(void) { return stubbed(); }\n' > "$p/uses.c"
printf 'int stubbed(void) { return 0; }\n' > "$p/stub.c"
printf 'int gone_fn(void);\nint dead(void) {\n    return gone_fn();\n}\nint main(void) { return 0; }\n' > "$p/gc.c"
printf '#ifdef __ANDROID__\nint android_only_fn(void);\n#endif\nint main(void) {\n#ifdef __ANDROID__\n    return android_only_fn();\n#else\n    return 0;\n#endif\n}\n' > "$p/cfg.c"
printf '#include <pthread.h>\nstatic void *f(void *a) { return a; }\nint main(void) { pthread_t t; pthread_create(&t, 0, f, 0); return pthread_join(t, 0); }\n' > "$p/thr.c"
printf 'int main(void) { int unused = 1; return 0; }\n' > "$p/werr.c"
printf 'int main(void) { return }\n' > "$p/broken.c"
printf 'int linux_missing(void);\nint main(void) {\n    return linux_missing();\n}\n' > "$p/linux_only.c"

echo "假工程（10 个 Linux 目标，期望链过 6、红 4）："
out=$(python3 "$tool" --root "$p" --project "$p" 2>&1); rc=$?
[ $rc = 1 ] && ok "退出码 1" || no "退出码期望 1 → 真 $rc"
got=$(printf '%s\n' "$out" | grep '^【红】' | sed 's/（broken\.c[^）]*）.*$/（broken.c）/' | LC_ALL=C sort)
want=$(LC_ALL=C sort <<'EOF'
【红】未定义符号 missing_fn：miss.c:3 引用，目标 miss_test 的链接源里没有定义 / 替身
【红】未定义符号 android_only_fn：cfg.c:6 引用，目标 cfg2_test 的链接源里没有定义 / 替身
【红】未定义符号 linux_missing：linux_only.c:3 引用，目标 linux_only_test 的链接源里没有定义 / 替身
EOF
)
got_undef=$(printf '%s\n' "$got" | grep '未定义符号' || true)
[ "$got_undef" = "$want" ] && ok "未定义符号三行（符号 / 文件:行 / 目标）与手算一致" || { no "未定义符号行不符"; diff <(echo "$want") <(echo "$got_undef"); }
printf '%s\n' "$got" | grep -q '^【红】目标 broken_test 编译不过' && ok "broken_test 编译不过报红" || no "broken_test 没报编译红"
[ "$(printf '%s\n' "$got" | grep -c .)" = 4 ] && ok "【红】共 4 行（gc / 替身 / 无 __ANDROID__ / -lpthread / -Werror 都没误红）" || { no "【红】行数期望 4"; printf '%s\n' "$got"; }
printf '%s\n' "$out" | grep -q '^链接目标 10 个（CMake Linux aarch64 配置.*：链过 6、红 4' && ok "射程：10 个目标、链过 6、红 4（android_only_test 不在、linux_only_test 在）" || { no "射程行不符"; printf '%s\n' "$out" | tail -1; }
printf '%s\n' "$out" | grep -q 'android_only_test' && no "进了 if(ANDROID) 分支" || ok "没进 if(ANDROID) 分支"

echo "路由自检："
g="$T/good"; mkdir -p "$g"
printf 'cmake_minimum_required(VERSION 3.16)\nproject(good C)\nadd_executable(a_test a.c)\n' > "$g/CMakeLists.txt"
printf '#include "b.h"\nint main(void) { return B; }\n' > "$g/a.c"
printf '#define B 0\n' > "$g/b.h"
printf '#!/bin/bash\n# 门禁路由：CMakeLists.txt a.c\n' > "$g/hook.sh"
out=$(python3 "$tool" --root "$g" --project "$g" --route-hook "$g/hook.sh" 2>&1); rc=$?
red=$(printf '%s\n' "$out" | grep '^【红】')
[ $rc = 1 ] && [ "$red" = "【红】路由漏项：b.h 被安卓链接目标编译 / 配置读到，hook.sh 文件头「# 门禁路由：」没覆盖它" ] && ok "漏 b.h 恰报一行、退 1" || { no "漏项期望一行 b.h、退 1 → rc=$rc"; printf '%s\n' "$out"; }
printf '#!/bin/bash\n# 门禁路由：CMakeLists.txt\n# 门禁路由：a.c b.h\n' > "$g/hook.sh"
out=$(python3 "$tool" --root "$g" --project "$g" --route-hook "$g/hook.sh" 2>&1); rc=$?
[ $rc = 0 ] && printf '%s\n' "$out" | grep -q '链过 1、红 0，路由覆盖核 3 个读入文件' && ok "多行路由取并集、全覆盖退 0（核 3 个读入文件）" || { no "全覆盖期望退 0、核 3 个 → rc=$rc"; printf '%s\n' "$out"; }

[ $bad = 0 ] && echo "安卓 CTest 链接核对单测：期望 全过 → 真结果 全过" || { echo "安卓 CTest 链接核对单测：期望 全过 → 真结果 有不符（见上）"; exit 1; }
