# 由 graphics/nvn/gfx/nvn/names.txt 生成安卓的 NVN 名字表（nvn_names[] / nvn_thunk[]）。
# 名字表与 NVN_NFUNC（nvn_count.h，同一份 names.txt 生成）必须逐项对应：hle_nvn.c 按下标配槽，
# 少一项就是空指针（10-29 main 加了 nvnTextureGetNvRmSurfaceNVX，手抄的 536 项表在 vivo 上启动即崩）。
# 不再手抄：构建与探针脚本都调本脚本。
#   cmake -D NAMES=<names.txt> -D OUT=<输出 .c> -P gen_nvn_names.cmake
if(NOT NAMES OR NOT OUT)
    message(FATAL_ERROR "gen_nvn_names.cmake: 需要 -D NAMES=<names.txt> -D OUT=<输出 .c>")
endif()
file(STRINGS "${NAMES}" names)
list(LENGTH names count)
if(count EQUAL 0)
    message(FATAL_ERROR "gen_nvn_names.cmake: ${NAMES} 是空的")
endif()
set(body "// 由 graphics/nvn/gfx/nvn/names.txt 生成（android/native/nvn/gen_nvn_names.cmake），勿手改。\n")
string(APPEND body "#include \"nvn_count.h\"\n")
string(APPEND body "_Static_assert(NVN_NFUNC == ${count}, \"names.txt 与 nvn_count.h 的 NVN_NFUNC 不一致\");\n")
string(APPEND body "void *nvn_thunk[NVN_NFUNC];\nconst char *nvn_names[NVN_NFUNC] = {\n")
foreach(name IN LISTS names)
    # 标识符即可：驱动的按名查找里还有两个不带 nvn 前缀的私有入口（H3ikr9ix / yK1NUEJH，见 nvn_drv_names.txt）
    if(NOT name MATCHES "^[A-Za-z][A-Za-z0-9_]+$")
        message(FATAL_ERROR "gen_nvn_names.cmake: ${NAMES} 里有不是 NVN 函数名的行：'${name}'")
    endif()
    string(APPEND body "    \"${name}\",\n")
endforeach()
string(APPEND body "};\n")
# 内容不变就不改时间戳，避免每次配置都重编
if(EXISTS "${OUT}")
    file(READ "${OUT}" old)
    if(old STREQUAL body)
        return()
    endif()
endif()
file(WRITE "${OUT}" "${body}")
