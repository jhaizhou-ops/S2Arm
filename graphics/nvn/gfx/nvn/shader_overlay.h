// 着色器包外置（免费签名分发，10-30）：着色器包放进文档目录就能更新，不必重签整个 App（metallib 是 GPU 代码，不走代码签名）。
//   查找顺序：显式环境变量（调用方先判）→ <文档目录>/gal/<程序号 16 位大写>/shaders → App 包内（S2A_GAME_DATA/shaders）。
//   文档目录：runtime/include/s2a_docs.h 的文档根（S2A_DOCS，否则 $HOME/Documents），Mac 局不会误读用户目录。
//   外置包读不进（直连：没有本链号的库目录 b-<链号> 或映射表；通用：离线库打不开）就退回包内，不报红。
//   纯 C、头文件即实现，单测 graphics/nvn/tests/t_shader_overlay.c
#pragma once
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <sys/stat.h>
#include "../../../../runtime/include/s2a_docs.h"

// 外置着色器包根 <文档目录>/gal/<程序号>/shaders 写进 out；返回 snprintf 的长度（截断时 ≥ n）
static inline int s2a_shader_overlay_root(char *out, size_t n, uint64_t pid) {
    return s2a_docs_path(out, n, "gal/%016llX/shaders", (unsigned long long)pid);
}

// 直连：外置包里有本链号的库目录 <根>/direct/b-<链号>/ 和映射表 <根>/direct/shader_map.tsv 才用，库目录（DM_MSL_DIR 口径 = <根>/direct）写进 dir。
//   返回 1 用外置；0 没有外置包；-1 有外置包但链号不符或缺映射表（调用方打一行、退回包内）
static inline int s2a_shader_overlay_direct(char *dir, size_t n, uint64_t pid, const char *chain) {
    char root[1100], t[1300]; struct stat st;
    if ((size_t)s2a_shader_overlay_root(root, sizeof root, pid) >= sizeof root) return 0;
    snprintf(t, sizeof t, "%s/direct", root);
    if (stat(t, &st) != 0 || !S_ISDIR(st.st_mode)) return 0;
    if ((size_t)snprintf(dir, n, "%s", t) >= n) return 0;
    snprintf(t, sizeof t, "%s/b-%s", dir, chain);
    if (stat(t, &st) != 0 || !S_ISDIR(st.st_mode)) return -1;
    snprintf(t, sizeof t, "%s/shader_map.tsv", dir);
    if (stat(t, &st) != 0 || !S_ISREG(st.st_mode)) return -1;
    return 1;
}
