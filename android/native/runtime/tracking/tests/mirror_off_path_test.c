// Linux 宿主夹具（#1184 owner r4 第 2 条）：镜像开关关时，tracker 两处写路径必须走 main 的旧路径；
// 开时才走 #1184 D1 的写前页像 + 写者计数 + 拿到别名后的 lastp/act 复核。
// 判据用 track.c 在 S2A_TRACK_TEST 下暴露的两个计数（只在开路径自增）：
//   s2a_track_test_precise_preimages  == 0（关时不取写前页像）
//   s2a_track_test_write_alias_rechecks == 0（关时不做别名事后复核）
// 随后 configure(1) 再跑同样两组，两个计数都必须 > 0，证明计数确实接在开路径上、不是永远不涨。
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "../mirror.h"
#include "../runtime.h"
#include "../../../../../graphics/track/s2a_track.h"
#include "../../../../../graphics/track/track_platform.h"
#include <errno.h>
#include <fcntl.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

static size_t model_page;
static uint8_t *arena;
static size_t arena_bytes;
static int failures;

int s2a_track_test_pagesize(void) { return (int)model_page; }   // track.o 用 -Dgetpagesize=… 编译

extern _Atomic unsigned s2a_track_test_precise_preimages;
extern _Atomic unsigned s2a_track_test_write_alias_rechecks;

static void check(int ok, const char *what) {
    if (ok) fprintf(stderr, "[off-path-fixture] ok: %s\n", what);
    else { fprintf(stderr, "[off-path-fixture] RED: %s\n", what); failures++; }
}

static int setup(void) {
    size_t host_page = (size_t)sysconf(_SC_PAGESIZE);
    if (!model_page) model_page = host_page;
    if (model_page < host_page || model_page % host_page || model_page > 16384) {
        fprintf(stderr, "[off-path-fixture] SKIP model=%zu host=%zu\n", model_page, host_page);
        return 1;   // 宿主内核页模型不支持时不算红
    }
    arena_bytes = 32 * model_page;
    int fd = memfd_create("s2a-mirror-off-path", MFD_CLOEXEC);
    if (fd < 0 || ftruncate(fd, (off_t)arena_bytes)) { perror("memfd"); return 2; }
    void *reserved = mmap(NULL, arena_bytes + model_page, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (reserved == MAP_FAILED) { perror("reserve"); return 2; }
    uintptr_t aligned = ((uintptr_t)reserved + model_page - 1) & ~(uintptr_t)(model_page - 1);
    arena = mmap((void *)aligned, arena_bytes, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_FIXED, fd, 0);
    close(fd);
    if (arena != (void *)aligned) { perror("arena mmap"); return 2; }
    memset(arena, 0x11, arena_bytes);
    s2a_track_prepare();
    s2a_track_set_readflush(1);
    s2a_track_set_walias(1);
    return 0;
}

// restore_precise：真别名 + 哈希记账；关时不应分配/读取写前页像。
static void drive_restore(uint8_t *page) {
    uint8_t value = 0x5a;
    s2a_track_restore_precise((uint64_t)(uintptr_t)page + 16, &value, 1);
    if (page[16] != value) { fprintf(stderr, "[off-path-fixture] restore 未落到页上\n"); failures++; }
}

// write_via_alias：先按 Ryujinx 的 None 意图把页设成不可读，再走回写入口。
static void drive_write(uint8_t *page) {
    s2a_track_reprotect((uintptr_t)page, model_page, S2A_TRACK_NONE);
    uint8_t buffer[64];
    memset(buffer, 0x6d, sizeof buffer);
    s2a_track_write_untracked((uintptr_t)page, buffer, sizeof buffer, 1);
    // 回写别名不改 guest 页保护（仍 PROT_NONE），经 tracker 的读别名核对内容。
    uint8_t readback = 0;
    if (s2a_track_read_untracked((uintptr_t)page, &readback, 1) != 1 || readback != 0x6d) {
        fprintf(stderr, "[off-path-fixture] 回写未落到页上\n"); failures++;
    }
}

int main(int argc, char **argv) {
    model_page = argc > 1 ? (size_t)strtoul(argv[1], NULL, 0) : 0;
    int rc = setup();
    if (rc == 1) return 0;
    if (rc) return rc;

    // ---- 关（缺省，不 configure）：两处都必须走 main 旧路径 ----
    drive_restore(arena);
    drive_write(arena + model_page);
    check(atomic_load(&s2a_track_test_precise_preimages) == 0,
          "关：restore_precise 不取写前页像（main 活别名路径）");
    check(atomic_load(&s2a_track_test_write_alias_rechecks) == 0,
          "关：write_via_alias 不做拿到别名后的 lastp/act 复核（main 原路径）");

    // ---- 开：同样两组必须进新路径（计数证明钩子接在开路径上）----
    check(s2a_android_mirror_configure(1) == 0, "开：宿主创建前 configure 成功");
    s2a_android_mirror_init((uintptr_t)arena, arena_bytes);
    if (!s2a_android_mirror_test_base()) { fprintf(stderr, "[off-path-fixture] mirror_init 未建窗口\n"); return 2; }
    s2a_android_mirror_begin((uintptr_t)arena, arena_bytes);
    s2a_android_mirror_end((uintptr_t)arena, arena_bytes, 1, 1);   // staging 提交，全部位置位
    drive_restore(arena + 2 * model_page);
    drive_write(arena + 3 * model_page);
    check(atomic_load(&s2a_track_test_precise_preimages) > 0, "开：restore_precise 走写前页像路径");
    check(atomic_load(&s2a_track_test_write_alias_rechecks) > 0, "开：write_via_alias 做事后复核");

    if (failures) {
        fprintf(stderr, "[off-path-fixture] FAIL model=%zu failures=%d\n", model_page, failures);
        return 1;
    }
    fprintf(stderr, "[off-path-fixture] GREEN model=%zu（关走 main 旧路径，开走镜像新路径）\n", model_page);
    return 0;
}
