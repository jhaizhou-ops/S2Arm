// Linux 宿主夹具（#1184 / owner #1285）：镜像写跟踪的生产开关 s2arm.mirror（缺省关）。
//   关（argv[2]=off，不 configure，缺省）：调用 init / begin / end / 别名入口不得建窗口、不得映射、
//       不得分配、不得改世代号；窗内地址走旧别名路（mremap），镜像命中/错过/窗外计数全 0。
//       关态 init 同样冻结开关：之后 configure(1) 返回 EBUSY，configure(0) 仍返回 0。
//       红（开关实现前）：init 直接建第二窗口，base != 0、VMA 增加、begin/end 把世代号翻到 2。
//   开（argv[2]=on，configure(1)）：行为与旧实现一致——init 建窗、begin/end 翻世代、窗内别名命中镜像；
//       建窗后 configure 同值返回 0、不同值返回 EBUSY（开关只在首次 init 前生效一次）。
// 结构：memfd + MAP_SHARED guest 区（平台别名路要真实共享 backing）；窗口取 64 MiB，模型页 4K/16K。
// 关/开分开进程跑：冻结位一旦在 init 置上就不复位，同一进程无法再验证另一条路径。
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "../mirror.h"
#include "../../../../../graphics/track/track_platform.h"
#include <errno.h>
#include <fcntl.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

static size_t model_page;
static void *arena;
static size_t arena_bytes;
static int failures;

int s2a_track_test_pagesize(void) { return (int)model_page; }   // track.o 用 -Dgetpagesize=… 编译

static void check(int ok, const char *what) {
    if (ok) fprintf(stderr, "[switch-fixture] ok: %s\n", what);
    else { fprintf(stderr, "[switch-fixture] RED: %s\n", what); failures++; }
}

// /proc/self/maps 的段数与总字节：镜像建窗必然新增一段保留 + 一段 mprotect 后的映射。
static int maps_snapshot(unsigned long *count, unsigned long long *bytes) {
    FILE *maps = fopen("/proc/self/maps", "r");
    if (!maps) return errno;
    char *line = NULL;
    size_t capacity = 0;
    *count = 0; *bytes = 0;
    while (getline(&line, &capacity, maps) >= 0) {
        unsigned long lo, hi;
        if (sscanf(line, "%lx-%lx", &lo, &hi) != 2) { free(line); fclose(maps); return EINVAL; }
        (*count)++; *bytes += (unsigned long long)(hi - lo);
    }
    free(line);
    fclose(maps);
    return 0;
}

static int setup(void) {
    arena_bytes = 32 * model_page;
    int fd = memfd_create("s2a-mirror-switch", MFD_CLOEXEC);
    if (fd < 0 || ftruncate(fd, (off_t)arena_bytes)) { perror("memfd"); return 2; }
    arena = mmap(NULL, arena_bytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (arena == MAP_FAILED) { perror("arena mmap"); return 2; }
    memset(arena, 0x11, 4096);
    return 0;
}

// 关（缺省，不 configure）：init 仍必须零副作用，但要在入口置冻结位。
static int run_off(void) {
    unsigned long vmas0, vmas1;
    unsigned long long bytes0, bytes1;
    if (maps_snapshot(&vmas0, &bytes0)) return 2;
    s2a_android_mirror_init((uintptr_t)arena, arena_bytes);
    s2a_android_mirror_begin((uintptr_t)arena, arena_bytes);
    s2a_android_mirror_end((uintptr_t)arena, arena_bytes, 1, 1);
    if (maps_snapshot(&vmas1, &bytes1)) return 2;
    check(s2a_android_mirror_test_base() == 0, "关：init 不建第二窗口（base == 0）");
    check(s2a_android_mirror_test_initialized() == 0, "关：init 不发布镜像状态（initialized == 0）");
    check(s2a_android_mirror_sequence() == 0, "关：begin/end 不改世代号（seq == 0）");
    check(vmas1 == vmas0, "关：init/begin/end 不新增 VMA 段");
    check(bytes1 == bytes0, "关：init/begin/end 不改变已映射字节数");
    uint64_t hits = 1, misses = 1, outside = 1, init_failures = 1;
    s2a_android_mirror_test_stats(&hits, &misses, &outside, &init_failures);
    check(hits == 0 && misses == 0 && outside == 0 && init_failures == 0,
        "关：镜像命中/错过/窗外/init 失败计数全 0（不分配、不记账）");
    void *legacy = NULL;
    int alias_error = s2a_track_platform_alias((uintptr_t)arena, model_page, PROT_READ | PROT_WRITE, &legacy);
    check(alias_error == 0 && legacy && legacy != arena, "关：窗内地址仍走旧别名路（真实共享别名）");
    check(s2a_track_platform_unalias(legacy, model_page) == 0, "关：旧别名释放成功");
    s2a_android_mirror_test_stats(&hits, &misses, &outside, NULL);
    check(hits == 0 && misses == 0 && outside == 0, "关：别名路不进镜像计数");
    // 关态 init 也冻结：不同值 EBUSY，同值仍成功，且开关状态不变。
    check(s2a_android_mirror_configure(1) == EBUSY, "关：初始化后 configure(1) 返回 EBUSY（冻结）");
    check(s2a_android_mirror_enabled() == 0, "关：拒绝 configure(1) 后开关仍为关");
    check(s2a_android_mirror_configure(0) == 0, "关：初始化后 configure(0) 同值返回 0");
    s2a_android_mirror_report("switch-off");   // 只报一行开关状态
    return 0;
}

// 开（configure(1)）：行为与旧实现一致，但首次 init 后冻结。
static int run_on(void) {
    check(s2a_android_mirror_configure(1) == 0, "开：宿主创建前 configure 成功");
    s2a_android_mirror_init((uintptr_t)arena, arena_bytes);
    uintptr_t base = s2a_android_mirror_test_base();
    check(base != 0, "开：init 建第二窗口");
    check(s2a_android_mirror_test_initialized() == 1, "开：镜像状态已发布");
    s2a_android_mirror_begin((uintptr_t)arena, arena_bytes);
    s2a_android_mirror_end((uintptr_t)arena, arena_bytes, 1, 1);
    check(s2a_android_mirror_sequence() == 2, "开：begin/end 成对翻世代（seq == 2）");
    void *probe = NULL;
    int alias_error = s2a_track_platform_alias((uintptr_t)arena, model_page, PROT_READ | PROT_WRITE, &probe);
    check(alias_error == 0 && (uintptr_t)probe == base, "开：窗内首个别名命中镜像窗口");
    uint64_t hits = 0;
    s2a_android_mirror_test_stats(&hits, NULL, NULL, NULL);
    check(hits == 1, "开：镜像命中计数 = 1");
    check(s2a_track_platform_unalias(probe, model_page) == 0, "开：镜像别名释放成功");
    check(s2a_android_mirror_configure(1) == 0, "开：初始化后 configure(1) 同值返回 0");
    check(s2a_android_mirror_configure(0) == EBUSY, "开：初始化后 configure(0) 返回 EBUSY（开关只生效一次）");
    check(s2a_android_mirror_enabled() == 1, "开：拒绝 configure(0) 后开关仍为开");
    s2a_android_mirror_report("switch-on");
    return 0;
}

int main(int argc, char **argv) {
    size_t host_page = (size_t)sysconf(_SC_PAGESIZE);
    if (argc != 3 || (strcmp(argv[2], "off") && strcmp(argv[2], "on"))) {
        fprintf(stderr, "用法: %s <模型页> off|on\n", argv[0]);
        return 2;
    }
    model_page = (size_t)strtoul(argv[1], NULL, 0);
    if (!model_page) model_page = host_page;
    if (model_page < host_page || model_page % host_page || model_page > 16384) {
        fprintf(stderr, "[switch-fixture] SKIP model=%zu host=%zu\n", model_page, host_page);
        return 0;   // 宿主内核页模型不支持时不算红
    }
    if (setup()) return 2;

    int rc = !strcmp(argv[2], "off") ? run_off() : run_on();
    if (rc) return rc;

    if (failures) {
        fprintf(stderr, "[switch-fixture] FAIL model=%zu mode=%s failures=%d\n", model_page, argv[2], failures);
        return 1;
    }
    fprintf(stderr, "[switch-fixture] GREEN model=%zu mode=%s（关零副作用/冻结，开与旧行为一致/冻结）\n",
            model_page, argv[2]);
    return 0;
}
