#include <sys/wait.h>
#include <spawn.h>
#include <time.h>
// 第 2 块单测：缓冲建 / 读写往返 / 按命令顺序（SetData 夹在拷贝之间）/ 32 位清 / 重叠拷贝 / 宿主映射（整段与分窗）/ GPU 地址 / 安全阀 / 桩。
// 期望值全部按命令顺序手算（字节图样由下标公式给出），不跑被测实现。
#include "../gal_abi.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <execinfo.h>
#include <signal.h>
#include <unistd.h>
#include <sys/mman.h>
// 内部接口（gal_internal.h 缓冲一节；本测试直接连源码编）
uint64_t gal_buf_gpu(uint32_t buf, int32_t offset);
uint64_t gal_buf_gpu_range(uint32_t buf, int32_t offset, int32_t len);
int32_t gal_buf_size(uint32_t buf);

static void on_sig(int s) { void *b[32]; int n = backtrace(b, 32); backtrace_symbols_fd(b, n, 2); _exit(128 + s); }
static int g_fail, g_checks;
#define CHECK(cond, ...) do { g_checks++; if (!(cond)) { g_fail++; printf("  ✗ " __VA_ARGS__); printf("\n"); } } while (0)
// 逐字节比对，最多报 3 处
static void cmp(const char *what, const uint8_t *got, const uint8_t *exp, size_t n) {
    int bad = 0;
    for (size_t k = 0; k < n; k++) if (got[k] != exp[k] && bad++ < 3) printf("  ✗ %s：字节 %zu 期望 %#x 实得 %#x\n", what, k, exp[k], got[k]);
    g_checks++; if (bad) { g_fail++; printf("  ✗ %s：共 %d / %zu 字节不符\n", what, bad, n); }
}
static uint64_t g_sync = 100;
static void gpu_wait(void) { nxgal_create_sync(g_sync, 1); nxgal_wait_sync(g_sync); g_sync++; }
static uint32_t mk(int size, uint8_t (*f)(int)) {   // 建缓冲并整段写入 f(下标)
    uint32_t b = nxgal_buf_create(size, 0);
    uint8_t *d = malloc(size); for (int k = 0; k < size; k++) d[k] = f(k);
    nxgal_buf_set_data(b, 0, d, size); free(d); return b;
}
static uint8_t f_i(int k) { return (uint8_t)k; }
static uint8_t f_hi(int k) { return (uint8_t)(0x80 + k); }
static uint8_t f_11(int k) { (void)k; return 0x11; }
static uint8_t f_z(int k) { (void)k; return 0; }
static uint8_t f_p(int k) { return (uint8_t)(k * 7 + 3); }

// 1：新建缓冲（没被 GPU 碰过：CPU 直写路）写 → 读一段
static void t_roundtrip(void) {
    printf("· 建 256 字节 → 整段写 k*7+3 → 读 [16,48)\n");
    uint32_t b = mk(256, f_p); CHECK(b, "建缓冲失败");
    CHECK(gal_buf_size(b) == 256, "大小 期望 256 实得 %d", gal_buf_size(b));
    uint8_t got[32], exp[32]; for (int k = 0; k < 32; k++) exp[k] = (uint8_t)((16 + k) * 7 + 3);
    CHECK(nxgal_buf_get_data(b, 16, 32, got) == 0, "读回返回非 0");
    cmp("往返", got, exp, 32);
    CHECK(nxgal_buf_get_data(b, 250, 8, got) != 0, "越界读 期望返回非 0");
    nxgal_buf_delete(b);
}

// 2：SetData 夹在两次 CopyBuffer 之间（GPU 碰过：暂存拷贝路）
static void t_order(void) {
    printf("· A=k → 拷 A→B → 写 A=0x80+k → 拷 A→C：B 应是旧值、C 应是新值\n");
    uint32_t A = mk(64, f_i), B = mk(64, f_z), C = mk(64, f_z);
    nxgal_buf_copy(A, B, 0, 0, 64);
    uint8_t nv[64]; for (int k = 0; k < 64; k++) nv[k] = f_hi(k);
    nxgal_buf_set_data(A, 0, nv, 64);
    nxgal_buf_copy(A, C, 0, 0, 64);
    uint8_t got[64], exp[64];
    for (int k = 0; k < 64; k++) exp[k] = (uint8_t)k;
    nxgal_buf_get_data(B, 0, 64, got); cmp("B（写之前拷的）", got, exp, 64);
    for (int k = 0; k < 64; k++) exp[k] = (uint8_t)(0x80 + k);
    nxgal_buf_get_data(C, 0, 64, got); cmp("C（写之后拷的）", got, exp, 64);

    printf("· D=k → 拷 D[0,16)→E → 写 E[8,12)=9 → 拷 E[0,16)→F[4,20) → 写 E[0,4)=0xEE（拷之后，不影响 F）\n");
    uint32_t D = mk(32, f_i), E = mk(32, f_z), F = mk(32, f_z);
    nxgal_buf_copy(D, E, 0, 0, 16);
    uint8_t nine[4] = {9, 9, 9, 9}, ee[4] = {0xEE, 0xEE, 0xEE, 0xEE};
    nxgal_buf_set_data(E, 8, nine, 4);
    nxgal_buf_copy(E, F, 0, 4, 16);
    nxgal_buf_set_data(E, 0, ee, 4);
    uint8_t ef[32] = {0}; for (int k = 0; k < 16; k++) ef[4 + k] = (uint8_t)(k >= 8 && k < 12 ? 9 : k);
    nxgal_buf_get_data(F, 0, 32, got); cmp("F", got, ef, 32);
    uint8_t ee_exp[16]; for (int k = 0; k < 16; k++) ee_exp[k] = (uint8_t)(k < 4 ? 0xEE : k >= 8 && k < 12 ? 9 : k);
    nxgal_buf_get_data(E, 0, 16, got); cmp("E", got, ee_exp, 16);

    printf("· 非对齐暂存写：E 偏移 3 长 5 写 0x51..0x55（GPU 碰过）\n");
    uint8_t five[5] = {0x51, 0x52, 0x53, 0x54, 0x55}; nxgal_buf_set_data(E, 3, five, 5);
    for (int k = 0; k < 5; k++) ee_exp[3 + k] = five[k];
    nxgal_buf_get_data(E, 0, 16, got); cmp("E 非对齐写", got, ee_exp, 16);

    printf("· 越尾写截断：E 偏移 30 写 4 字节 → 只写 [30,32)\n");
    uint8_t four[4] = {0xA1, 0xA2, 0xA3, 0xA4}; nxgal_buf_set_data(E, 30, four, 4);
    nxgal_buf_get_data(E, 28, 4, got); uint8_t tail[4] = {0, 0, 0xA1, 0xA2}; cmp("E 尾", got, tail, 4);
    nxgal_buf_delete(A); nxgal_buf_delete(B); nxgal_buf_delete(C); nxgal_buf_delete(D); nxgal_buf_delete(E); nxgal_buf_delete(F);
}

// 3：暂存块回收：GPU 碰过的 1 MB 缓冲连写 12 次（共 12 MB，超过 4 MB 暂存块），中间穿插提交；最后读回 = 最后一次写
static void t_staging(void) {
    printf("· 暂存回收：1 MB 缓冲（GPU 碰过）连写 12 次、每 3 次提交一次 → 读回 = 第 12 次的值\n");
    int n = 1 << 20; uint32_t b = mk(n, f_z), z = mk(16, f_z);
    nxgal_buf_copy(z, b, 0, 0, 16);   // 让 b 成为「GPU 碰过」
    uint8_t *d = malloc(n), *got = malloc(n);
    for (int r = 1; r <= 12; r++) { memset(d, r, n); nxgal_buf_set_data(b, 0, d, n); if (r % 3 == 0) gpu_wait(); }
    nxgal_buf_get_data(b, 0, n, got); memset(d, 12, n); cmp("1 MB 第 12 次", got, d, n);
    free(d); free(got); nxgal_buf_delete(b); nxgal_buf_delete(z);
}

// 3b：影子 malloc 失败（注入 gal_sh_test_fail；10-21 巫师3 iPhone 低区地址耗尽时 sh_try_build 往 NULL memcpy 崩溃）：
//   同 t_order 第一段（A 被拷贝用过后命中已用区间写 → 要建影子）：不崩，B 是写前值 k、C 是写后值 0x80+k（期望按命令顺序手算）
extern int gal_sh_test_fail;
static void t_shfail(void) {
    printf("· 影子建不出：A=k → 拷 A→B → 写 A=0x80+k（命中已用区间、影子 malloc 失败）→ 拷 A→C：不崩，B 旧值、C 新值\n");
    uint32_t A = mk(64, f_i), B = mk(64, f_z), C = mk(64, f_z);
    nxgal_buf_copy(A, B, 0, 0, 64);
    uint8_t nv[64]; for (int k = 0; k < 64; k++) nv[k] = f_hi(k);
    gal_sh_test_fail = 1; nxgal_buf_set_data(A, 0, nv, 64); gal_sh_test_fail = 0;
    nxgal_buf_copy(A, C, 0, 0, 64);
    uint8_t got[64], exp[64];
    for (int k = 0; k < 64; k++) exp[k] = (uint8_t)k;
    nxgal_buf_get_data(B, 0, 64, got); cmp("影子失败 B（写之前拷的）", got, exp, 64);
    for (int k = 0; k < 64; k++) exp[k] = (uint8_t)(0x80 + k);
    nxgal_buf_get_data(C, 0, 64, got); cmp("影子失败 C（写之后拷的）", got, exp, 64);
    nxgal_buf_get_data(A, 0, 64, got); cmp("影子失败 A", got, exp, 64);
    nxgal_buf_delete(A); nxgal_buf_delete(B); nxgal_buf_delete(C);
}

// 4：ClearBuffer 32 位值
static void t_clear(void) {
    printf("· 清：200000 字节底 0x11，[8, 8+196612) 填 0xAABBCCDD（多段图样拷贝）；[0,8) 填 0x7F7F7F7F（单字节快路）\n");
    int n = 200000; uint32_t b = mk(n, f_11);
    nxgal_buf_clear(b, 8, 196612, 0xAABBCCDDu);
    nxgal_buf_clear(b, 0, 8, 0x7F7F7F7Fu);
    uint8_t *got = malloc(n), *exp = malloc(n); static const uint8_t le[4] = {0xDD, 0xCC, 0xBB, 0xAA};
    for (int k = 0; k < n; k++) exp[k] = k < 8 ? 0x7F : k < 8 + 196612 ? le[(k - 8) & 3] : 0x11;
    nxgal_buf_get_data(b, 0, n, got); cmp("200000 字节清", got, exp, n);
    free(got); free(exp); nxgal_buf_delete(b);

    printf("· 清：长度 10（非 4 倍数）偏移 4 值 0x01020304 → 写 [4,12)，[12,14) 不动（Vulkan VK_WHOLE_SIZE 取整语义）\n");
    uint32_t c = mk(16, f_11);
    nxgal_buf_clear(c, 4, 10, 0x01020304u);
    uint8_t g16[16], e16[16] = {0x11, 0x11, 0x11, 0x11, 4, 3, 2, 1, 4, 3, 2, 1, 0x11, 0x11, 0x11, 0x11};
    nxgal_buf_get_data(c, 0, 16, g16); cmp("非 4 倍数清", g16, e16, 16);

    printf("· 清在两次拷贝之间：拷 c→d，清 c=0，拷 c→e：d 是清之前、e 全 0\n");
    uint32_t d = mk(16, f_z), e = mk(16, f_hi);
    nxgal_buf_copy(c, d, 0, 0, 16); nxgal_buf_clear(c, 0, 16, 0); nxgal_buf_copy(c, e, 0, 0, 16);
    nxgal_buf_get_data(d, 0, 16, g16); cmp("d", g16, e16, 16);
    uint8_t z16[16] = {0}; nxgal_buf_get_data(e, 0, 16, g16); cmp("e", g16, z16, 16);
    nxgal_buf_delete(c); nxgal_buf_delete(d); nxgal_buf_delete(e);
}

// 5：同一缓冲重叠区拷贝（memmove 语义）
static void t_overlap(void) {
    printf("· 重叠拷：buf=k，[0,32)→[8,40)；另一 buf=k，[8,40)→[0,32)\n");
    uint32_t a = mk(64, f_i), b = mk(64, f_i);
    nxgal_buf_copy(a, a, 0, 8, 32);
    nxgal_buf_copy(b, b, 8, 0, 32);
    uint8_t got[64], exp[64];
    for (int k = 0; k < 64; k++) exp[k] = (uint8_t)(k >= 8 && k < 40 ? k - 8 : k);
    nxgal_buf_get_data(a, 0, 64, got); cmp("前移重叠", got, exp, 64);
    for (int k = 0; k < 64; k++) exp[k] = (uint8_t)(k < 32 ? k + 8 : k);
    nxgal_buf_get_data(b, 0, 64, got); cmp("后移重叠", got, exp, 64);
    nxgal_buf_delete(a); nxgal_buf_delete(b);
}

// 6：宿主映射（零拷贝）：小（整段）与大（分窗）
static void t_host(void) {
    long pg = getpagesize();
    printf("· 宿主映射（小）：页对齐区 +100 起 1000 字节；直写（未碰过）→ 宿主内存可见；GPU 拷 N[0,200)→H[50,250) → CPU 直接读宿主内存\n");
    size_t rn = 4 * pg; uint8_t *mem = mmap(NULL, rn, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    memset(mem, 0x33, rn);
    uint32_t h = nxgal_buf_create_host(mem + 100, 1000); CHECK(h, "建宿主映射失败");
    uint8_t w4[4] = {1, 2, 3, 4}; nxgal_buf_set_data(h, 0, w4, 4);
    CHECK(!memcmp(mem + 100, w4, 4) && mem[99] == 0x33 && mem[104] == 0x33, "直写 期望宿主 [100,104)=1 2 3 4 实得 %u %u %u %u", mem[100], mem[101], mem[102], mem[103]);
    uint32_t nb = mk(200, f_p);
    nxgal_buf_copy(nb, h, 0, 50, 200); gpu_wait();
    uint8_t exp[1000]; memset(exp, 0x33, sizeof exp); memcpy(exp, w4, 4); for (int k = 0; k < 200; k++) exp[50 + k] = f_p(k);
    cmp("宿主内存（小）", mem + 100, exp, 1000);
    CHECK(mem[99] == 0x33 && mem[1100] == 0x33, "映射区外被改 [99]=%#x [1100]=%#x", mem[99], mem[1100]);
    uint64_t g0 = gal_buf_gpu(h, 0), g10 = gal_buf_gpu(h, 10);
    CHECK(g0 && g10 == g0 + 10, "宿主小映射 GPU 地址 期望 非零且 +10 一致 实得 %#llx / %#llx", (unsigned long long)g0, (unsigned long long)g10);
    // GPU 碰过之后的写走暂存拷贝，读回经提交等待后从宿主内存读
    uint8_t w2[2] = {0xC1, 0xC2}; nxgal_buf_set_data(h, 998, w2, 2);
    uint8_t got2[2]; nxgal_buf_get_data(h, 998, 2, got2); cmp("宿主（小）暂存写读回", got2, w2, 2);
    CHECK(mem[1098] == 0xC1 && mem[1099] == 0xC2, "暂存写后宿主内存 期望 c1 c2 实得 %#x %#x", mem[1098], mem[1099]);
    nxgal_buf_delete(h); nxgal_buf_delete(nb); gpu_wait(); munmap(mem, rn);

    // 宿主映射建在被保护的页上（10-23 帧率能耗线，缓冲零拷贝）：写跟踪常把游戏内存页设成不可访问 / 只读。
    // 期望按「GPU 写的就是这批物理页」直接定：放开保护后宿主内存 = GPU 写进去的图样。旧实现直接在原地址建：不可访问页建不出来，只读页 GPU 写无声丢失（读到 0x55）
    for (int pr = 0; pr < 2; pr++) {
        const char *nm = pr ? "只读" : "不可访问";
        printf("· 宿主映射建在%s页上：GPU 拷 512 字节进去 → 放开保护后宿主内存是图样\n", nm);
        uint8_t *pm = mmap(NULL, 4 * pg, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); memset(pm, 0x55, 4 * pg);
        mprotect(pm, 4 * pg, pr ? PROT_READ : PROT_NONE);
        uint32_t hp2 = nxgal_buf_create_host(pm + 64, 2048); CHECK(hp2, "%s页上建宿主映射 期望成功", nm);
        uint32_t sp = mk(512, f_p); nxgal_buf_copy(sp, hp2, 0, 0, 512); gpu_wait();
        mprotect(pm, 4 * pg, PROT_READ | PROT_WRITE);
        uint8_t e512[512]; for (int k = 0; k < 512; k++) e512[k] = f_p(k);
        cmp(pr ? "只读页上的宿主映射" : "不可访问页上的宿主映射", pm + 64, e512, 512);
        CHECK(pm[63] == 0x55 && pm[64 + 512] == 0x55, "%s页：映射段外被改", nm);
        nxgal_buf_delete(hp2); nxgal_buf_delete(sp); gpu_wait(); munmap(pm, 4 * pg);
    }
    // 反方向：建好宿主映射后 CPU 直接写原地址 → GPU 从（别名上的）缓冲读出来，偏移跨 16 KB 页边界、跨 4 MB 窗口边界（期望 = CPU 写的图样）
    {
        printf("· 宿主映射 CPU 写原地址 → GPU 读：跨 16 KB 页、跨窗口边界\n");
        size_t cn = 12u << 20; uint8_t *cm = mmap(NULL, cn, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); memset(cm, 0x11, cn);
        int csz = (int)(cn - 8192); uint8_t *cp = cm + 4096 + 24;
        uint32_t hc = nxgal_buf_create_host(cp, csz);
        int offs[3] = { 0x4000 - 40, (4 << 20) - 100, (6 << 20) + 12345 }, ln = 5000;
        for (int q = 0; q < 3; q++) {
            for (int k = 0; k < ln; k++) cp[offs[q] + k] = f_hi(k + q);
            uint32_t ob = nxgal_buf_create(ln, 0);
            nxgal_buf_copy(hc, ob, offs[q], 0, ln); gpu_wait();
            uint8_t *got = malloc(ln); nxgal_buf_get_data(ob, 0, ln, got);
            uint8_t *ex = malloc(ln); for (int k = 0; k < ln; k++) ex[k] = f_hi(k + q);
            cmp(q == 0 ? "CPU 写跨 16 KB 页 → GPU 读" : q == 1 ? "CPU 写跨 4 MB 窗口 → GPU 读" : "CPU 写 6 MB 处 → GPU 读", got, ex, ln);
            free(got); free(ex); nxgal_buf_delete(ob);
        }
        nxgal_buf_delete(hc); gpu_wait(); munmap(cm, cn);
    }
    // 释放延后到栅栏：GPU 拷贝在途时就删宿主映射，GPU 做完后宿主内存仍是图样（别名 / 窗口提前放掉 = GPU 写进已释放的地址：缺页或内容没到）
    {
        printf("· 宿主映射在 GPU 写在途时删除：等 GPU 做完后宿主内存仍是图样\n");
        size_t dn = 8u << 20; uint8_t *dm = mmap(NULL, dn, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); memset(dm, 0x66, dn);
        int dsz = 6 << 20; uint32_t hd = nxgal_buf_create_host(dm, dsz), sd = mk(dsz, f_p);
        nxgal_buf_copy(sd, hd, 0, 0, dsz); nxgal_flush();   // 已提交、多半还没做完
        nxgal_buf_delete(hd); gpu_wait();
        uint8_t *ed = malloc(dsz); for (int k = 0; k < dsz; k++) ed[k] = f_p(k);
        cmp("在途删除后的宿主内存（6 MB 分窗）", dm, ed, dsz);
        free(ed); nxgal_buf_delete(sd); gpu_wait(); munmap(dm, dn);
    }

    // 游戏重映射（共享内存映射 / 解除：同一地址换成另一批物理页）后：通知（nxgal_host_remapped）→ GPU 写进新页、原地址读得到；
    // 不通知 → GPU 仍写旧页（别名指着旧页），原地址读到的是换页后 CPU 填的 0x99——证明作废是必须的。小映射（整段）与大映射（分窗）各一遍
    for (int big = 0; big < 2; big++) for (int notify = 1; notify >= 0; notify--) {
        size_t rn2 = big ? 8u << 20 : 4 * pg; int len = big ? 6 << 20 : 2048;
        printf("· 宿主映射换页（%s，%s）\n", big ? "大·分窗" : "小·整段", notify ? "通知重建" : "不通知");
        uint8_t *rm = mmap(NULL, rn2, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); memset(rm, 0x55, rn2);
        uint32_t hr = nxgal_buf_create_host(rm, len), sa = mk(len, f_p), sbb = mk(len, f_hi);
        nxgal_buf_copy(sa, hr, 0, 0, len); gpu_wait();                     // 旧页上已有 GPU 写过（大映射：窗口已建）
        CHECK(rm[0] == f_p(0), "换页前 GPU 写 期望 %#x 实得 %#x", f_p(0), rm[0]);
        CHECK(mmap(rm, rn2, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE | MAP_FIXED, -1, 0) == rm, "换页 mmap 失败");
        memset(rm, 0x99, rn2);
        if (notify) nxgal_host_remapped((uint64_t)(uintptr_t)rm, rn2);
        nxgal_buf_copy(sbb, hr, 0, 0, len); gpu_wait();
        if (notify) { uint8_t *eh = malloc(len); for (int k = 0; k < len; k++) eh[k] = f_hi(k); cmp(big ? "换页通知后（大）" : "换页通知后（小）", rm, eh, len); free(eh); }
        else CHECK(rm[0] == 0x99 && rm[len - 1] == 0x99, "不通知时 GPU 写旧页、新页不变 期望 0x99 实得 %#x / %#x", rm[0], rm[len - 1]);
        nxgal_buf_delete(hr); nxgal_buf_delete(sa); nxgal_buf_delete(sbb); gpu_wait(); munmap(rm, rn2);
    }

    printf("· 宿主映射（大，分窗）：12 MB 区 +4104 起 12 MB-8192；拷 3 MB 到偏移 1 MB+12345（跨步长边界）、64 KB 到偏移 6 MB-100（跨窗口边界）\n");
    size_t bn = 12u << 20; mem = mmap(NULL, bn, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); memset(mem, 0x44, bn);
    int hs = (int)(bn - 8192); uint8_t *hp = mem + 4096 + 8;
    h = nxgal_buf_create_host(hp, hs); CHECK(h, "建大宿主映射失败");
    int n3 = 3 << 20, o3 = (1 << 20) + 12345, n64 = 64 << 10, o64 = (6 << 20) - 100;
    uint32_t s3 = mk(n3, f_p), s64 = mk(n64, f_hi);
    nxgal_buf_copy(s3, h, 0, o3, n3);
    nxgal_buf_copy(s64, h, 0, o64, n64);
    gpu_wait();
    uint8_t *e3 = malloc(n3); for (int k = 0; k < n3; k++) e3[k] = f_p(k);
    cmp("大映射 3 MB 段", hp + o3, e3, n3);
    uint8_t *e64 = malloc(n64); for (int k = 0; k < n64; k++) e64[k] = f_hi(k);
    cmp("大映射 64 KB 段", hp + o64, e64, n64);
    CHECK(hp[o3 - 1] == 0x44 && hp[o3 + n3] == 0x44 && hp[o64 - 1] == 0x44 && hp[o64 + n64] == 0x44, "大映射段外被改");
    uint64_t ga = gal_buf_gpu_range(h, o64, 64), gb = gal_buf_gpu_range(h, o64 + 16, 16);
    CHECK(ga && gb == ga + 16, "分窗 GPU 地址 期望 非零且 +16 一致 实得 %#llx / %#llx", (unsigned long long)ga, (unsigned long long)gb);
    uint8_t got[16]; nxgal_buf_get_data(h, o64, 16, got); cmp("大映射 GetData", got, e64, 16);
    free(e3); free(e64); nxgal_buf_delete(h); nxgal_buf_delete(s3); nxgal_buf_delete(s64); gpu_wait(); munmap(mem, bn);
}

// 6b：上传租约（方案 B）：GPU 没碰过（直写）与碰过之后（进暂存、录拷贝）两种情况，租约路（nxgal_upload_rent 写入 → nxgal_buf_set_data_lease）
//     与旧路（nxgal_buf_set_data）读回逐字节相同；交过的租约再交报红不改数据
static void t_lease(void) {
    printf("· 上传租约：未碰过 / 碰过之后两种，租约路与旧路读回逐字节相同；交过的租约再交不改数据\n");
    int n = 3000; uint8_t *d = malloc(n); for (int k = 0; k < n; k++) d[k] = (uint8_t)(k * 13 + 5);
    for (int touched = 0; touched < 2; touched++) {
        uint32_t a = nxgal_buf_create(4096, 0), b = nxgal_buf_create(4096, 0);
        if (touched) { uint32_t z = mk(4096, f_p); nxgal_buf_copy(z, a, 0, 0, 4096); nxgal_buf_copy(z, b, 0, 0, 4096); gpu_wait(); nxgal_buf_delete(z); }
        nxgal_buf_set_data(a, 100, d, n);
        void *cpu = NULL; uint32_t l = nxgal_upload_rent((uint64_t)n, &cpu); CHECK(l && cpu, "租约：租不到");
        if (cpu) memcpy(cpu, d, n);
        nxgal_buf_set_data_lease(b, 100, l, n);
        uint8_t ra[4096], rb[4096]; nxgal_buf_get_data(a, 0, 4096, ra); nxgal_buf_get_data(b, 0, 4096, rb);
        CHECK(!memcmp(ra, rb, 4096) && !memcmp(ra + 100, d, n), "租约（%s）：读回不同", touched ? "碰过之后" : "未碰过");
        nxgal_buf_set_data_lease(b, 0, l, n); nxgal_upload_drop(l);
        nxgal_buf_get_data(b, 0, 4096, rb); CHECK(!memcmp(ra, rb, 4096), "租约（%s）：交过的租约再交改了数据", touched ? "碰过之后" : "未碰过");
        nxgal_buf_delete(a); nxgal_buf_delete(b);
    }
    gpu_wait(); free(d);
}

// 7：普通缓冲 GPU 地址 / 安全阀 / 桩 / 编号回收
static void t_misc(void) {
    printf("· GPU 地址：普通缓冲 +256 一致；安全阀 NX_RES_CAP_GB=0.0001 时宿主映射建不了 / 分窗取址为 0；稀疏桩与宿主映射预备返回 0；删后编号复用\n");
    uint32_t b = nxgal_buf_create(1024, 0);
    uint64_t g0 = gal_buf_gpu(b, 0), g256 = gal_buf_gpu(b, 256);
    CHECK(g0 && g256 == g0 + 256, "普通缓冲 GPU 地址 期望 非零且 +256 一致 实得 %#llx / %#llx", (unsigned long long)g0, (unsigned long long)g256);
    CHECK(gal_buf_gpu(0, 0) == 0 && gal_buf_gpu(99999, 0) == 0, "无效编号 GPU 地址 期望 0");
    size_t bn = 8u << 20; uint8_t *mem = mmap(NULL, bn, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    setenv("NX_RES_CAP_GB", "0.0001", 1);
    uint32_t hs = nxgal_buf_create_host(mem, 4096);
    CHECK(hs == 0, "安全阀下小映射 期望建不了 实得编号 %u", hs);
    uint32_t hl = nxgal_buf_create_host(mem, (int)bn);
    CHECK(hl != 0, "大映射登记 期望成功（窗口懒建）");
    CHECK(gal_buf_gpu_range(hl, 0, 16) == 0, "安全阀下分窗取址 期望 0");
    unsetenv("NX_RES_CAP_GB");
    CHECK(gal_buf_gpu_range(hl, 0, 16) != 0, "解除后分窗取址 期望非零");
    nxgal_buf_delete(hl); gpu_wait(); munmap(mem, bn);
    nxgal_buf_range r = {b, 0, 16, 0};
    CHECK(nxgal_buf_create_sparse(&r, 1) == 0, "稀疏桩 期望 0");
    CHECK(nxgal_prepare_host_mapping((void *)0x10000, 4096) == 0, "宿主映射预备 期望 0");
    nxgal_buf_delete(b);
    uint32_t b2 = nxgal_buf_create(16, 0);
    CHECK(b2 == b, "删后新建 期望复用编号 %u 实得 %u", b, b2);
    nxgal_buf_delete(b2);
}

// 11：不等 GPU 的读（nxgal_buf_peek_cpu）在途上传登记溢出后能恢复（10-23 画幅线：巫师3 10 MB 流式顶点缓冲，一个命令缓冲里上传超过 8 次 → 登记溢出；
// 旧逻辑溢出标记只在建影子时清，大于 4 MB 的缓冲从不建影子，此后只要又有在途上传（wfence 前移）整块都读不到，宽屏几何判定逐帧在外推 / 拉伸之间跳）。
// 期望手算：5 MB 缓冲图样 f_p；同一命令缓冲里往 [0, 10×64) 传 10 段 0xA0+i（第 9、10 段溢出）→ 等完成 → 再往 [4096, 4160) 传一段（在途）
// → 读 [8192, 8256)（没被任何上传碰过）期望读得到、等于 f_p；读 [4096, 4160) 期望读得到、等于在途那段 0x55。旧逻辑第一项读不到（返回 0）
int32_t nxgal_buf_peek_cpu(uint32_t bid, int32_t offset, int32_t size, void *out);
static void t_peek_ov(void) {
    printf("· 不等 GPU 的读：在途上传登记溢出、溢出那批完成后，别处的在途上传不再连累整块\n");
    int n = 5 << 20; uint32_t b = mk(n, f_p), c = nxgal_buf_create(64, 0);
    nxgal_buf_copy(b, c, 0, 0, 64); gpu_wait();   // 让 b 被 GPU 碰过：之后的上传走暂存 + 在途登记
    uint8_t d[64];
    for (int i = 0; i < 10; i++) { memset(d, 0xA0 + i, 64); nxgal_buf_set_data(b, i * 64, d, 64); }
    gpu_wait();
    memset(d, 0x55, 64); nxgal_buf_set_data(b, 4096, d, 64);
    uint8_t got[64], exp[64]; for (int k = 0; k < 64; k++) exp[k] = f_p(8192 + k);
    int r1 = nxgal_buf_peek_cpu(b, 8192, 64, got);
    CHECK(r1 == 1, "溢出那批完成后、另有在途上传：读没碰过的 [8192, 8256) 期望读得到（1）实得 %d", r1);
    if (r1 == 1) cmp("没碰过的区间内容", got, exp, 64);
    int r2 = nxgal_buf_peek_cpu(b, 4096, 64, got); memset(exp, 0x55, 64);
    CHECK(r2 == 1, "读在途那段 [4096, 4160) 期望读得到（1）实得 %d", r2);
    if (r2 == 1) cmp("在途那段内容", got, exp, 64);
    gpu_wait(); nxgal_buf_delete(b); nxgal_buf_delete(c);
}

// 12：同一命令缓冲里上传很多次，不等完成读其中靠后的一段（10-23 巫师3 露台真机静置：一个命令缓冲往 10 MB 顶点环传几十次，固定 8 条在途表把全屏遍的
// 四边形顶点那段丢进溢出区间 → 几何判定读不读得到看 GPU 完成时机，同一遍逐帧在外推 / 拉伸间跳）。期望手算：第 30 段 [30×64, 31×64) = 0x40+30，
// 读得到（1）且内容逐字节相等；旧 8 条表下第 9 段起都在溢出区间里，返回 0
static void t_peek_many(void) {
    printf("· 不等 GPU 的读：同一命令缓冲上传 40 段，读第 30 段\n");
    int n = 5 << 20; uint32_t b = mk(n, f_p), c = nxgal_buf_create(64, 0);
    nxgal_buf_copy(b, c, 0, 0, 64); gpu_wait();
    uint8_t d[64];
    for (int i = 0; i < 40; i++) { memset(d, 0x40 + i, 64); nxgal_buf_set_data(b, i * 64, d, 64); }
    uint8_t got[64], exp[64]; memset(exp, 0x40 + 30, 64);
    int r = nxgal_buf_peek_cpu(b, 30 * 64, 64, got);
    CHECK(r == 1, "40 段在途、读第 30 段 期望读得到（1）实得 %d", r);
    if (r == 1) cmp("第 30 段内容", got, exp, 64);
    gpu_wait(); nxgal_buf_delete(b); nxgal_buf_delete(c);
}

// 9：后台闸门（10-20 测试机1 塞尔达切后台 GPU 拒收后台提交）。关闸后别的线程的提交被挡住、开闸后接着做完且数据对；关闸返回时已提交的都已在 GPU 上做完
void nxgal_gpu_hold(int on, const char *why); uint64_t gal_done(void); uint64_t gal_committed_fence(void);
#include <pthread.h>
static _Atomic int g_hold_done;
static uint32_t g_hold_src, g_hold_dst;
static void *hold_worker(void *a) {   // GPU 拷贝（一定进命令缓冲）+ 提交并等：关闸时应卡在提交口
    (void)a; nxgal_buf_copy(g_hold_src, g_hold_dst, 0, 0, 64); gpu_wait(); g_hold_done = 1; return NULL;
}
static void t_hold(void) {
    printf("· 后台闸门：关闸挡住提交、开闸后做完；关闸返回时在途已做完\n");
    uint32_t b = mk(256, f_z); gpu_wait();
    uint32_t c = mk(64, f_11); nxgal_flush();   // 留一笔刚提交的在途工作
    uint64_t f0 = gal_committed_fence();
    nxgal_gpu_hold(1, "单测");
    CHECK(gal_done() >= f0, "关闸返回时 已完成栅栏 期望 ≥ %llu 实得 %llu", (unsigned long long)f0, (unsigned long long)gal_done());
    g_hold_src = c; g_hold_dst = b; pthread_t th; pthread_create(&th, NULL, hold_worker, NULL);
    usleep(300000);
    CHECK(!g_hold_done, "关闸 300 ms 内 工作线程 期望 卡在提交口 实得 已做完");
    CHECK(gal_committed_fence() == f0, "关闸期间 已提交栅栏 期望 不变 %llu 实得 %llu", (unsigned long long)f0, (unsigned long long)gal_committed_fence());
    nxgal_gpu_hold(0, "单测"); pthread_join(th, NULL);
    CHECK(g_hold_done, "开闸后 工作线程 期望 做完");
    uint8_t got[256], exp[256]; for (int k = 0; k < 256; k++) exp[k] = k < 64 ? 0x11 : 0;   // 前 64 字节拷自全 0x11 的源，其余仍是 0
    nxgal_buf_get_data(b, 0, 256, got); cmp("开闸后缓冲内容", got, exp, 256);
    nxgal_buf_delete(b); nxgal_buf_delete(c);
}

// 7 / 8：GPU 卡死与命令缓冲出错都判红退出（10-19 本机内核恐慌；10-19 总指挥撤掉「出错后重建队列照常跑」）：
// 子进程等一个永不完成的栅栏 / 走命令缓冲报错路径，期望 ≤ 4 秒退出、退出码 86，不「继续等」也不「重建后照常跑」
void nxgal_test_fence_stall(void); void nxgal_test_cb_error(void); void nxgal_test_cb_victim(int second);
static const char *g_argv0;
// 用时从「子进程触发出错 / 卡死」那一刻量起（子进程触发前把单调时钟写进 T_T0_FILE；macOS 的 CLOCK_MONOTONIC 跨进程同源）：
//   原先量整个子进程寿命，含起进程与 Metal 设备初始化，整机负载 45 时「命令缓冲出错 ≤ 4 秒」实得 5.68 秒偶发红（10-21 画面·着色器线报）
static void mark_trigger(void) { const char *p = getenv("T_T0_FILE"); struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    FILE *f = p ? fopen(p, "w") : NULL; if (f) { fprintf(f, "%lld %ld\n", (long long)t.tv_sec, t.tv_nsec); fclose(f); } }
static double since_trigger(const char *path, const struct timespec *t1, const struct timespec *t0_spawn) {
    long long sec = 0; long ns = 0; FILE *f = fopen(path, "r"); int ok = f && fscanf(f, "%lld %ld", &sec, &ns) == 2; if (f) fclose(f); unlink(path);
    if (!ok) { sec = t0_spawn->tv_sec; ns = t0_spawn->tv_nsec; }   // 子进程没走到触发（初始化失败等）：退回整段，退出码那条会报
    return (t1->tv_sec - sec) + (t1->tv_nsec - ns) / 1e9;
}
static void t0_file(char *buf) { strcpy(buf, "/tmp/t_buf_t0_XXXXXX"); int fd = mkstemp(buf); if (fd >= 0) close(fd); unlink(buf); setenv("T_T0_FILE", buf, 1); }
static void t_exit86(const char *mode, const char *what) {
    printf("· %s：子进程 → 期望触发后 ≤ 4 秒退出、退出码 86\n", what); char t0f[64]; t0_file(t0f);
    char mark[] = "/tmp/t_buf_dump_XXXXXX"; int mfd = mkstemp(mark); if (mfd >= 0) close(mfd); unlink(mark); setenv("T_DUMP_MARK", mark, 1);
    pid_t pid; char *av[] = {(char *)g_argv0, (char *)mode, NULL}; extern char **environ;
    struct timespec t0, t1; clock_gettime(CLOCK_MONOTONIC, &t0);
    if (posix_spawn(&pid, g_argv0, NULL, NULL, av, environ)) { CHECK(0, "起子进程失败"); return; }
    int st = 0; waitpid(pid, &st, 0); clock_gettime(CLOCK_MONOTONIC, &t1);
    double s = since_trigger(t0f, &t1, &t0);
    CHECK(WIFEXITED(st) && WEXITSTATUS(st) == 86, "%s 退出码 期望 86 实得 %s %d", what, WIFEXITED(st) ? "exit" : "signal", WIFEXITED(st) ? WEXITSTATUS(st) : WTERMSIG(st));
    CHECK(s <= 4.0, "%s 用时（触发起）期望 ≤ 4 秒 实得 %.2f 秒", what, s);
    FILE *mf = fopen(mark, "r"); char got[256] = ""; if (mf) { if (!fgets(got, sizeof got, mf)) got[0] = 0; fclose(mf); } unlink(mark);
    CHECK(mf && got[0], "%s 退出前取了全线程现场（s2a_dump_threads 被调到）：期望 标记文件有内容 实得 %s", what, mf ? got : "没有标记文件");
}

// 9 / 10：连坐丢弃（10-21 巫师3 真机只留下主队列一条 InnocentVictim 就退了）：子进程报连坐后 → 期望等别的回执（收到就带队列名照打）再退码 86；
// 没有第二条时等满 1 秒、报「肇事者不在本进程」再退。用时下限按等待设计：有第二条 0.2 秒到、至多再等 0.05 秒；没有就 1 秒
static void t_victim(const char *mode, const char *what, const char *want, double smin, double smax) {
    printf("· %s：子进程 → 期望触发后 %.1f–%.1f 秒退出、退出码 86、日志含「%s」\n", what, smin, smax, want); char t0f[64]; t0_file(t0f);
    char log[] = "/tmp/t_buf_victim_XXXXXX"; int lfd = mkstemp(log); if (lfd < 0) { CHECK(0, "建日志文件失败"); return; }
    posix_spawn_file_actions_t fa; posix_spawn_file_actions_init(&fa); posix_spawn_file_actions_adddup2(&fa, lfd, 2);
    pid_t pid; char *av[] = {(char *)g_argv0, (char *)mode, NULL}; extern char **environ;
    struct timespec t0, t1; clock_gettime(CLOCK_MONOTONIC, &t0);
    int rc = posix_spawn(&pid, g_argv0, &fa, NULL, av, environ); posix_spawn_file_actions_destroy(&fa); close(lfd);
    if (rc) { CHECK(0, "起子进程失败"); unlink(log); return; }
    int st = 0; waitpid(pid, &st, 0); clock_gettime(CLOCK_MONOTONIC, &t1);
    double s = since_trigger(t0f, &t1, &t0);
    CHECK(WIFEXITED(st) && WEXITSTATUS(st) == 86, "%s 退出码 期望 86 实得 %s %d", what, WIFEXITED(st) ? "exit" : "signal", WIFEXITED(st) ? WEXITSTATUS(st) : WTERMSIG(st));
    CHECK(s >= smin && s <= smax, "%s 用时（触发起）期望 %.1f–%.1f 秒 实得 %.2f 秒", what, smin, smax, s);
    static char buf[1 << 16]; FILE *f = fopen(log, "r"); size_t n = f ? fread(buf, 1, sizeof buf - 1, f) : 0; buf[n] = 0; if (f) fclose(f); unlink(log);
    CHECK(strstr(buf, want) != NULL, "%s 日志 期望 含「%s」 实得 %zu 字节里没有", what, want, n);
}

int main(int argc, char **argv) {
    g_argv0 = argv[0];
    if (argc > 1 && !strcmp(argv[1], "--stall")) { if (nxgal_init(0)) return 2; mark_trigger(); nxgal_test_fence_stall(); printf("✗ 没退出\n"); return 0; }
    if (argc > 1 && !strcmp(argv[1], "--cberr")) { if (nxgal_init(0)) return 2; mark_trigger(); nxgal_test_cb_error(); printf("✗ 没退出\n"); return 0; }
    if (argc > 1 && !strcmp(argv[1], "--victim1")) { if (nxgal_init(0)) return 2; mark_trigger(); nxgal_test_cb_victim(0); return 0; }
    if (argc > 1 && !strcmp(argv[1], "--victim2")) { if (nxgal_init(0)) return 2; mark_trigger(); nxgal_test_cb_victim(1); return 0; }
    setvbuf(stdout, NULL, _IONBF, 0); signal(SIGSEGV, on_sig); signal(SIGBUS, on_sig);
    if (nxgal_init(0)) { printf("初始化失败\n"); return 2; }
    t_roundtrip(); t_order(); t_shfail(); t_staging(); t_clear(); t_overlap(); t_host(); t_lease(); t_misc(); t_peek_ov(); t_peek_many(); t_hold(); t_exit86("--stall", "卡死保护（等永不完成的栅栏）"); t_exit86("--cberr", "命令缓冲出错");
    t_victim("--victim2", "连坐丢弃 + 上屏队列肇事", "上屏命令缓冲执行出错（第 2 条回执", 0.15, 1.0); t_victim("--victim1", "连坐丢弃、本进程无肇事者", "肇事者不在主队列", 0.95, 3.0);
    nxgal_shutdown();
    printf("%s：%d / %d 项通过\n", g_fail ? "失败" : "通过", g_checks - g_fail, g_checks);
    return g_fail ? 1 : 0;
}
