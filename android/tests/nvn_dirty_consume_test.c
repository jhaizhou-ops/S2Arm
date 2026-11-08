// 页级写跟踪的消费语义（真机自测）：
//   1) guest 普通写入触发缺页 → 钩子放开页并记脏 → 写成功（重执行）；
//   2) 上传前取的代数之后有写 → 判脏；没有写 → 判干净；
//   3) “读取/上传期间”发生的新写不会被上传结束时吞掉（代数仍更大）。
#include <stdio.h>
#include <stdint.h>
#include <string.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/mman.h>
#include <unistd.h>
#include <ucontext.h>
#include "nvn_dirty.h"

extern int s2a_direct_fault(void *addr, int is_write, void *uctx);
// track 桩：本测试只验证 nvn_dirty 的记账链路
static void (*g_wprep)(uint64_t, uint64_t);
void s2a_track_set_write_prep(void (*fn)(uint64_t, uint64_t)) { g_wprep = fn; }
void s2a_track_write_quiet(uint64_t a, uint64_t n) { if (g_wprep) g_wprep(a, n); }

static volatile int g_handled;
static void on_segv(int sig, siginfo_t *si, void *ctx) {
    (void)sig;
    if (s2a_direct_fault(si->si_addr, 1, ctx)) { g_handled++; return; }
    _exit(90);   // 不是跟踪模块的页：测试失败（说明钩子没接上）
}

int main(void) {
    int ok = 1;
    size_t len = 64 * 1024;
    uint8_t *buf = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (buf == MAP_FAILED) { printf("FAIL mmap\n"); return 1; }
    nvn_dirty_add_range(buf, len);      // 首次调用登记缺页钩子（dm_* → s2a_direct_fault）
    struct sigaction sa;
    memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = on_segv; sa.sa_flags = SA_SIGINFO;
    sigaction(SIGSEGV, &sa, NULL);

    // 1) 页保护 + guest 写 → 钩子放开后重执行
    uint64_t stamp0 = nvn_dirty_now();
    nvn_dirty_protect(buf, len);
    buf[0] = 1;
    ok &= (buf[0] == 1) && (g_handled >= 1);
    ok &= nvn_dirty_since_span(nvn_dirty_span(buf, len), buf, len, stamp0) == 1;

    // 2) 重新保护、取新代数、不写 → 干净
    nvn_dirty_protect(buf, len);
    uint64_t stamp1 = nvn_dirty_now();
    ok &= nvn_dirty_since_span(nvn_dirty_span(buf, len), buf, len, stamp1) == 0;

    // 3) 取代数之后、上传“期间”发生的新写必须仍判脏
    uint64_t stamp2 = nvn_dirty_now();
    nvn_dirty_protect(buf, len);
    buf[4096] = 2;
    ok &= nvn_dirty_since_span(nvn_dirty_span(buf, len), buf, len, stamp2) == 1;

    // 4) 脏页位图：写过的页置位、没写的页保持干净（子资源级重传就靠它）
    {
        uint64_t bits[16] = {0};
        long np = nvn_dirty_written_pages(nvn_dirty_span(buf, len), buf, len, stamp0, bits, 16 * 64);
        size_t pg = nvn_dirty_page_size();
        ok &= (np == (long)(len / pg));
        ok &= (np > 1) && (bits[0] & 1ull) == 1ull;                                  // 第 0 页写过
        ok &= (bits[(np - 1) >> 6] & (1ull << ((np - 1) & 63))) == 0;                // 最后一页没写
    }

    printf("dirty: handled=%d ok=%d\n", g_handled, ok);
    printf("nvn-dirty-consume: %s\n", ok ? "ok" : "FAIL");
    return ok ? 0 : 1;
}
