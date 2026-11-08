// 跨队列事件顺序（nvn_mtl.m nvn_xqueue.inc nvn_be_submit）：直接包含生产 nvn_mtl.m，在真 Metal 队列上回放手写的记录流（两条「NVN 队列」用两个不透明指针代表）。
// 期望按 NVN 语义手写，与实现无关：WaitEvent 之后的命令在 GPU 上排在满足它的那笔 SignalEvent 之后执行，不管两条队列谁先提交。
// 数据依赖用池内存上的「填充 / 拷贝」表示（11-07 时之笛：图形队列画半分辨率深度后发信号，计算队列等这个信号再读深度算阴影）：
//   ① 计算队列先提交「等 E=1 → 拷 D→X」，图形队列后提交「填 D=0x22 → 发 E=1」：X = 0x22（改前计算先跑，读到 D 的旧值 0x11）
//   ② 同一条队列在停住期间又提交「拷 X→Z」：排在停住的部分后面，Z = 0x22（不能先跑读到 X 的旧值）
//   ③ 等待在 CALL 进去的子列表里：子列表余下的、调用方 CALL 之后的、这次提交别的句柄，按原顺序接着回放：W = 0x44、V = 0x44
//   ④ 停住期间 QueueFenceSync 拿的栅栏欠着：没发布（SyncWait 看不到完成）；信号回放后发布，等它的栅栏完成时停住的拷贝已落地
//   ⑤ 互等（负对照）：A「等 X → 发 Y」、B「等 Y → 发 X」：B 停住会成环 → B 不停、照旧立即放行并记一次成环（报红），两边都在 2 秒内完成，X = Y = 1，不死锁
//   ⑥ 保险：等一个永远没人发的信号 → 别的队列再提交 256 次后强制放行，停住的拷贝落地
//   ⑦ 停住时的回放状态带到接着回放的那段：等待之前 BindProgram / SetRenderTargets 记下的 S / R 在接着回放时原样恢复（不被中间别的队列的提交改掉）
#include "../gfx/nvn/nvn_mtl.m"
static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "FAIL setup %s:%d: %s\n", __FILE__, __LINE__, #c); exit(1); } } while (0)
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) failures++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
// 记录流拼装：每条记录 {op, size} + 载荷
typedef struct { uint8_t b[4096]; size_t n; } stream;
static void put(stream *s, uint32_t op, const void *pl, uint32_t n) { op_hdr h = {op, 8 + n}; REQUIRE(s->n + h.size + 8 <= sizeof s->b); memcpy(s->b + s->n, &h, 8); if (n) memcpy(s->b + s->n + 8, pl, n); s->n += h.size; }
static void ev(stream *s, volatile uint32_t *val, uint32_t mode, uint32_t v) { struct { volatile uint32_t *val; uint32_t m, v; } p = {val, mode, v}; put(s, OP_SIGNAL_EVENT, &p, 16); }
static void wait_eq(stream *s, volatile uint32_t *val, uint32_t v) { ev(s, val, NVN_EV_WAIT | 0, v); }
static void fill(stream *s, uint8_t *dst, uint64_t n, uint32_t v) { p_clear_buf c = {(uint64_t)(uintptr_t)dst, n, v, 0}; put(s, OP_CLEAR_BUF, &c, sizeof c); }
static void copy(stream *s, const uint8_t *src, uint8_t *dst, uint64_t n) { uint64_t p[3] = {(uint64_t)(uintptr_t)src, (uint64_t)(uintptr_t)dst, n}; put(s, OP_COPY_B2B, p, 24); }
static void call(stream *s, const stream *t) { uint64_t p = (uint64_t)(uintptr_t)t->b; put(s, OP_CALL, &p, 8); }
static void end(stream *s) { put(s, OP_END, NULL, 0); }
static uint64_t submit(void *q, stream *const *v, int n) { uint64_t h[8]; REQUIRE(n <= 8); for (int i = 0; i < n; i++) h[i] = (uint64_t)(uintptr_t)v[i]->b; static uint64_t frame = 1; nvn_be_set_frame(++frame); nvn_be_submit(q, h, n); return nvn_be_last_fence(); }
static int settle(void) { return nvn_be_wait(nvn_be_last_fence(), 5000000000ull); }
int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0); alarm(120);
    setenv("DM_NVN_ENC_THREAD", "0", 0); setenv("DM_PRESENT_LINK", "0", 1);
    mtl_init(); state_reset();
    uint8_t *pool = NULL; REQUIRE(!posix_memalign((void **)&pool, 65536, 1 << 20)); memset(pool, 0, 1 << 20); nvn_be_pool_add(pool, 1 << 20);
    uint8_t *D = pool, *X = pool + 4096, *Z = pool + 8192, *W = pool + 12288, *V = pool + 16384, *P = pool + 20480;
    static queue_t QA, QB;   // 两条队列（全零：没有设备，hle 的每段钩子照常走）
    // ①②
    memset(D, 0x11, 4096); memset(X, 0, 4096); memset(Z, 0, 4096);
    static volatile uint32_t E; E = 0; nvn_be_event_gpu_recorded(&E);   // 录制时知道 E 由 GPU 侧信号写（hle 在录 SignalEvent 时调）
    static stream a1, a2, b1; a1.n = a2.n = b1.n = 0;
    wait_eq(&a1, &E, 1); copy(&a1, D, X, 4096); end(&a1);
    copy(&a2, X, Z, 4096); end(&a2);
    fill(&b1, D, 4096, 0x22222222u); ev(&b1, &E, 0, 1); end(&b1);
    uint64_t p0 = g_xq_parks;
    stream *va[] = {&a1}, *va2[] = {&a2}, *vb[] = {&b1};
    submit(&QA, va, 1); submit(&QA, va2, 1); submit(&QB, vb, 1);
    int ok = settle();
    VERIFY(ok && X[0] == 0x22 && X[4095] == 0x22, "① 计算队列先提交、等图形队列后发的信号：X = %#x（期望 0x22，改前 0x11），停住 %llu 次，完成 %d", X[0], (unsigned long long)(g_xq_parks - p0), ok);
    VERIFY(Z[0] == 0x22 && Z[4095] == 0x22, "② 停住期间同队列再提交：排在后面，Z = %#x（期望 0x22）", Z[0]);
    // ③ 等待在子列表里
    memset(D, 0x33, 4096); memset(W, 0, 4096); memset(V, 0, 4096);
    static volatile uint32_t E3; E3 = 0; nvn_be_event_gpu_recorded(&E3);
    static stream sub, a3, a3b, b3; sub.n = a3.n = a3b.n = b3.n = 0;
    wait_eq(&sub, &E3, 1); copy(&sub, D, W, 4096); end(&sub);
    call(&a3, &sub); copy(&a3, W, V, 2048); end(&a3);
    copy(&a3b, W, V + 2048, 2048); end(&a3b);
    fill(&b3, D, 4096, 0x44444444u); ev(&b3, &E3, 0, 1); end(&b3);
    stream *v3[] = {&a3, &a3b}, *vb3[] = {&b3};
    submit(&QA, v3, 2); submit(&QB, vb3, 1); ok = settle();
    VERIFY(ok && W[0] == 0x44 && V[0] == 0x44 && V[2047] == 0x44 && V[2048] == 0x44 && V[4095] == 0x44,
           "③ 等待在 CALL 的子列表里：子列表余下 W = %#x、调用方 CALL 之后 V[0] = %#x、同次提交下一个句柄 V[2048] = %#x（期望都 0x44）", W[0], V[0], V[2048]);
    // ④ 欠着的栅栏
    memset(D, 0x55, 4096); memset(P, 0, 4096);
    static volatile uint32_t E4; E4 = 0; nvn_be_event_gpu_recorded(&E4);
    static stream a4, b4; a4.n = b4.n = 0; wait_eq(&a4, &E4, 1); copy(&a4, D, P, 4096); end(&a4); fill(&b4, D, 4096, 0x66666666u); ev(&b4, &E4, 0, 1); end(&b4);
    stream *v4[] = {&a4}, *vb4[] = {&b4};
    submit(&QA, v4, 1);
    static sync_t sy; memset(&sy, 0, sizeof sy); sy.magic = MAGIC('S', 'Y', 'N', 'C');
    int owed = nvn_be_xq_fence(&QA, &sy); void *who = NULL; int owed2 = nvn_be_xq_owed(&sy, &who);
    VERIFY(owed && owed2 && who == &QA && !sync_published(&sy, NULL), "④ 停住时拿的栅栏欠着：欠 %d / 查得到 %d、欠在 A %d、没发布 %d", owed, owed2, who == &QA, !sync_published(&sy, NULL));
    submit(&QB, vb4, 1);
    uint64_t sf = 0; int pub = sync_published(&sy, &sf), waited = pub && nvn_be_wait(sf, 5000000000ull);
    VERIFY(pub && waited && P[0] == 0x66 && !nvn_be_xq_owed(&sy, NULL), "④ 信号回放后发布：发布 %d、栅栏完成 %d、那时 P = %#x（期望 0x66）、不再欠 %d", pub, waited, P[0], !nvn_be_xq_owed(&sy, NULL));
    // ⑤ 互等（负对照）
    static volatile uint32_t EX, EY; EX = EY = 0; nvn_be_event_gpu_recorded(&EX); nvn_be_event_gpu_recorded(&EY);
    static stream a5, b5; a5.n = b5.n = 0; wait_eq(&a5, &EX, 1); ev(&a5, &EY, 0, 1); end(&a5); wait_eq(&b5, &EY, 1); ev(&b5, &EX, 0, 1); end(&b5);
    stream *v5[] = {&a5}, *vb5[] = {&b5};
    uint64_t c0 = g_xq_cycles; uint64_t t0 = bp_now();
    submit(&QA, v5, 1); submit(&QB, vb5, 1); ok = settle(); double ms = (bp_now() - t0) / 1e6;
    VERIFY(ok && EX == 1 && EY == 1 && g_xq_cycles == c0 + 1 && ms < 2000 && g_nxq == 0,
           "⑤ 互等：成环 %llu 次（期望 1，报红）、%.0f ms 完成 %d、X = %u Y = %u（期望 1 / 1）、停住的队列剩 %d（期望 0，不死锁）", (unsigned long long)(g_xq_cycles - c0), ms, ok, EX, EY, g_nxq);
    // ⑥ 保险
    memset(D, 0x77, 4096); memset(P, 0, 4096);
    static volatile uint32_t E6; E6 = 0; nvn_be_event_gpu_recorded(&E6);
    static stream a6, nop; a6.n = nop.n = 0; wait_eq(&a6, &E6, 1); copy(&a6, D, P, 4096); end(&a6); end(&nop);
    stream *v6[] = {&a6}, *vn[] = {&nop};
    uint64_t f0 = g_xq_forced; submit(&QA, v6, 1);
    int parked = g_nxq == 1; for (int i = 0; i < 300 && g_nxq; i++) submit(&QB, vn, 1);
    ok = settle();
    VERIFY(parked && ok && P[0] == 0x77 && g_xq_forced == f0 + 1 && g_nxq == 0, "⑥ 永远等不到：停住 %d、强制放行 %llu 次（期望 1）、P = %#x（期望 0x77）", parked, (unsigned long long)(g_xq_forced - f0), P[0]);
    // ⑦ 状态带过停住点
    static volatile uint32_t E7; E7 = 0; nvn_be_event_gpu_recorded(&E7);
    static stream a7, b7; a7.n = b7.n = 0; wait_eq(&a7, &E7, 1); end(&a7); ev(&b7, &E7, 0, 1); end(&b7);
    stream *v7[] = {&a7}, *vb7[] = {&b7};
    state_reset(); S.alpha_ref = 0.25f; S.patch_size = 7; R.has_sc = 1; R.sc.x = 11;
    submit(&QA, v7, 1);   // 停住：存下 alpha_ref 0.25 / patch 7 / 剪裁 x 11
    state_reset(); S.alpha_ref = 0.75f; S.patch_size = 3; R.has_sc = 0;   // 中间别的队列的状态
    static float seen_ref; static int seen_patch, seen_sc;
    // 接着回放的那段在 A 的流末尾（END）读不到状态：用 B 发信号之后、A 接着回放完之后的全局状态看（A 那段是最后回放的）
    submit(&QB, vb7, 1); seen_ref = S.alpha_ref; seen_patch = S.patch_size; seen_sc = R.has_sc ? (int)R.sc.x : -1; settle();
    VERIFY(seen_ref == 0.25f && seen_patch == 7 && seen_sc == 11, "⑦ 接着回放时恢复停住时的状态：alpha_ref %.2f（期望 0.25）、patch %d（期望 7）、剪裁 x %d（期望 11）", seen_ref, seen_patch, seen_sc);
    if (failures) { printf("✗ t_nvn_xqueue：%u 项里 %u 项不符\n", checks, failures); return 1; }
    printf("✓ t_nvn_xqueue：%u 项全过（跨队列事件顺序：等待之后的命令排在满足它的信号之后；同队列后续提交排队；子列表 / 多句柄接着回放；欠着的栅栏；互等报红不死锁；保险放行；状态带过停住点）\n", checks);
    return 0;
} }
