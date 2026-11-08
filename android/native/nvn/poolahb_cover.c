#include "poolahb_cover.h"

#include <string.h>
#include <stdio.h>

static int parse_line(char *line, unsigned long *lo, unsigned long *hi, char *perms,
                      unsigned long *off, char *dev, unsigned long *inode, const char **path) {
    char pathbuf[256] = {0};
    int n = sscanf(line, "%lx-%lx %7s %lx %15s %lu %255[^\n]", lo, hi, perms, off, dev, inode, pathbuf);
    if (n < 6) return 0;
    if (path) *path = "";
    if (path) {
        char *p = pathbuf[0] ? strstr(line, pathbuf) : NULL;
        if (p) *path = p;
    }
    return 1;
}

// 是否是我们允许“替页”的 guest 内存：普通匿名映射，或 kgsl 设备映射（本机 guest RAM 就是
// /dev/kgsl-3d0 的共享映射，`rw-s`/`r--s`）。文件后备（apk/.so/memfd/ashmem）与其它设备映射一律不碰。
static int acceptable_backing(const char *path) {
    if (!path || !path[0]) return 1;                       // 匿名
    // guest RAM 在本机可能是普通匿名、/dev/kgsl-3d0 或 /dev/ashmem（ashmem 的旧名字是 /dev/ashmem）。
    // 这些都不是“另一个外部所有者”的后备，可以替页；别名由受控登记表单独判定。
    // 本机 guest RAM 是 "/dev/zero (deleted)" 的共享映射（emulator 用 /dev/zero + mmap 共享分配），
    // 另有 kgsl / ashmem 两种历史形态；这些都属于 guest RAM，可以替页。
    if (strstr(path, "kgsl") || strstr(path, "ashmem") || strstr(path, "/dev/zero")) return 1;
    // main 7ff542ea2 起 guest RAM 换成本进程 memfd_create("s2a-guest") 的注入式背板，maps 里是
    // "/memfd:s2a-guest (deleted)"：匿名共享内存、没有外部文件所有者，属于可替页的 guest RAM。
    // 其它 /memfd:<name> 仍拒绝（可能是别的组件/进程共享的后备）。
    if (strstr(path, "/memfd:s2a-guest")) return 1;
    if (strstr(path, "base.apk") || strstr(path, ".so") || strstr(path, "/memfd:")) return 0;
    if (strstr(path, "/dev/")) return 0;                    // dma-heap / ion 等其它设备后备
    return 1;
}

int s2a_poolahb_cover_check_stream(FILE *f, uint64_t base, uint64_t len) {
    if (!f || !len) return 0;
    // 注意：必须**流式**扫完整个 maps（本机进程有上千条映射，池往往在很后面；只读前 N 行会直接判失败）。
    char line[512];
    uint64_t want = base;
    const uint64_t end = base + len;
    while (fgets(line, sizeof line, f)) {
        unsigned long lo = 0, hi = 0, off = 0, inode = 0;
        char perms[8] = {0}, dev[16] = {0};
        const char *path = "";
        if (!parse_line(line, &lo, &hi, perms, &off, dev, &inode, &path)) continue;
        if ((uint64_t)hi <= want) continue;
        if ((uint64_t)lo > want) return 0;                  // 出现空洞
        if (!acceptable_backing(path)) return 0;
        if ((uint64_t)hi >= end) return 1;
        want = (uint64_t)hi;
    }
    return 0;
}

int s2a_poolahb_cover_check_path(const char *path, uint64_t base, uint64_t len) {
    if (!path || !len) return 0;
    FILE *f = fopen(path, "r");
    if (!f) return 0;
    int ok = s2a_poolahb_cover_check_stream(f, base, len);
    fclose(f);
    return ok;
}
