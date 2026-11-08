// 宿主页只读别名单测（alias.c）：期望值都由「源页写了什么」直接给出，不依赖被测实现
#include "../src/native.h"
#include <signal.h>
#include <sys/mman.h>
#include <pthread.h>
#include <fcntl.h>
#include <stdlib.h>
#include <unistd.h>
#define PG 16384
static int bad;
#define CHECK(c, ...) do { if (!(c)) { printf("✗ " __VA_ARGS__); printf("\n"); bad++; } } while (0)
static uint8_t *g_pg; static volatile int g_sig_v = -1;
static void on_segv(int s, siginfo_t *si, void *c) {   // 信号处理里取别名读数（模拟读的真实调用场景），然后放开页让那条读继续
    (void)s; (void)c;
    uint64_t a = (uint64_t)si->si_addr;
    const uint8_t *al = s2a_alias_page(a & ~(uint64_t)(PG - 1));
    g_sig_v = al ? al[a & (PG - 1)] : -2;
    mprotect(g_pg, PG, PROT_READ | PROT_WRITE);
}
static void *other(void *x) { (void)x; return (void *)s2a_alias_page((uint64_t)g_pg); }   // 没 init 的线程
int main(void) {
    uint8_t *p = mmap(NULL, PG * 2, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0); g_pg = p;
    // ⓪ 未 init：返回 NULL（不能把无关内存当槽）
    CHECK(s2a_alias_page((uint64_t)p) == NULL, "⓪ 没 init 就返回了别名");
    s2a_alias_thread_init();
    // ① 源页不可读时，别名读到原值
    p[100] = 0x5a; p[PG - 1] = 0x33; mprotect(p, PG, PROT_NONE);
    const uint8_t *a = s2a_alias_page((uint64_t)p);
    CHECK(a && a[100] == 0x5a && a[PG - 1] == 0x33, "① 别名读到 %#x / %#x，应为 0x5a / 0x33", a ? a[100] : 0, a ? a[PG - 1] : 0);
    // ② 共享不是拷贝：源页再写，已建的别名看到新值
    mprotect(p, PG, PROT_READ | PROT_WRITE); p[100] = 0xa5; mprotect(p, PG, PROT_NONE);
    CHECK(a && a[100] == 0xa5, "② 源页改写后别名读到 %#x，应为 0xa5（共享）", a ? a[100] : 0);
    // ③ 换一页：同一槽改映射到第二页
    p[PG + 7] = 0x77; const uint8_t *b = s2a_alias_page((uint64_t)p + PG);
    CHECK(b && b[7] == 0x77, "③ 第二页别名读到 %#x，应为 0x77", b ? b[7] : 0);
    // ④ 非页对齐 / 没映射的地址：NULL
    CHECK(s2a_alias_page((uint64_t)p + 8) == NULL, "④ 非对齐地址返回了别名");
    uint8_t *gone = mmap(NULL, PG, PROT_READ, MAP_PRIVATE | MAP_ANON, -1, 0); munmap(gone, PG);
    CHECK(s2a_alias_page((uint64_t)gone) == NULL, "④ 已解映射的页返回了别名");
    // ⑤ 信号处理里调（缺页现场）：读被保护页时，处理函数从别名取到正确值
    struct sigaction sa = {0}; sa.sa_sigaction = on_segv; sa.sa_flags = SA_SIGINFO; sigaction(SIGBUS, &sa, NULL); sigaction(SIGSEGV, &sa, NULL);
    mprotect(p, PG, PROT_READ | PROT_WRITE); p[200] = 0x42; mprotect(p, PG, PROT_NONE);
    int v = ((volatile uint8_t *)p)[200];
    CHECK(g_sig_v == 0x42 && v == 0x42, "⑤ 信号里别名读到 %d、读本身得 %d，应为 0x42", g_sig_v, v);
    // ⑥ 别的线程没 init：NULL（槽是每线程的）
    pthread_t t; void *r; pthread_create(&t, NULL, other, NULL); pthread_join(t, &r);
    CHECK(r == NULL, "⑥ 没 init 的线程拿到了别名");
    // ⑧ 可写别名：源页不可读写时经别名写，源页放开后读到写入值；同一槽之后再取只读别名照样可用
    mprotect(p, PG, PROT_READ | PROT_WRITE); p[300] = 0x01; mprotect(p, PG, PROT_NONE);
    uint8_t *w = s2a_alias_page_rw((uint64_t)p); if (w) { w[300] = 0x9d; w[PG - 2] = 0x44; }
    mprotect(p, PG, PROT_READ | PROT_WRITE);
    CHECK(w && p[300] == 0x9d && p[PG - 2] == 0x44, "⑧ 经可写别名写后源页读到 %#x / %#x，应为 0x9d / 0x44", p[300], p[PG - 2]);
    // ⑨ 只读映射的源页（最大权限没有写）：可写别名返回 NULL
    uint8_t *rofile = MAP_FAILED;
    { char tp[] = "/tmp/t_alias_XXXXXX"; int fd = mkstemp(tp);
      if (fd >= 0) { static char z[PG]; write(fd, z, PG); close(fd); fd = open(tp, O_RDONLY); unlink(tp);
        if (fd >= 0) { rofile = mmap(NULL, PG, PROT_READ, MAP_SHARED, fd, 0); close(fd); } } }
    CHECK(rofile != MAP_FAILED && s2a_alias_page_rw((uint64_t)rofile) == NULL, "⑨ 只读打开的文件映射拿到了可写别名");
    // ⑩ 非对齐：NULL
    CHECK(s2a_alias_page_rw((uint64_t)p + 8) == NULL, "⑩ 非对齐地址返回了可写别名");
    // ⑦ 自检没过之后一律 NULL（别名不可信时不能拿来模拟读）
    void s2a_alias_test_mark_bad(void); s2a_alias_test_mark_bad();
    CHECK(s2a_alias_page((uint64_t)p) == NULL, "⑦ 自检判不可用后仍返回了别名");
    CHECK(s2a_alias_page_rw((uint64_t)p) == NULL, "⑦ 自检判不可用后仍返回了可写别名");
    if (!bad) printf("✓ t_alias：0 处不符（共 11 项）\n");
    return bad != 0;
}
