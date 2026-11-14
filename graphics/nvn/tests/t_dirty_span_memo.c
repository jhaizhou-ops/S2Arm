// 写跟踪「取范围」线程内备忘（#974 问 3，nvn_dirty.c 的 find_span）单测：
//   ① 答案与线性扫（find_span_scan）逐位一致，含「没有」；重复的 (地址, 长度) 真的命中备忘；
//   ② 表一变（登记 / 注销 / 槽位复用 / 换底 / 重置会话）旧记录必须作废；代际为奇数（有写者在改表）时既不信也不记；
//   ③ 开关 0 = 关、n = 2^n 项、超上限按上限；2 项（必然互相挤占）下答案仍然对；
//   ④ 一个线程不停增删范围时，别的线程读到的答案只能是「改之前」或「改之后」；改完之后（含槽位复用），
//      读者线程上留着的备忘不许再给旧答案。
// 直接包含生产源码（要读 find_span / find_span_scan 两个静态函数，并可换成变异副本跑负对照：dirty_span_memo_mutation_test.py）。
// 登记的范围都落在一块只读不写的真映射里（mprotect 才不会因为地址不存在失败），测试自己从不写它。
#ifndef NVN_DIRTY_SPAN_MEMO_SOURCE
#define NVN_DIRTY_SPAN_MEMO_SOURCE "../gfx/nvn/nvn_dirty.c"
#endif
#include NVN_DIRTY_SPAN_MEMO_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <pthread.h>

void dm_fault_hook_register(int (*fn)(void *addr, int is_write, void *uc)) { (void)fn; }
void dm_guest_write_prep_register(void (*fn)(void *addr, size_t len)) { (void)fn; }
void dm_log(const char *fmt, ...) { (void)fmt; }

static unsigned checks, failures;
#define CK(c, msg) do { checks++; if (!(c)) { failures++; fprintf(stderr, "FAIL %s:%d %s\n", __FILE__, __LINE__, msg); } } while (0)

enum { ARENA_PAGES = 400 };
static uintptr_t PG, ARENA;
static uintptr_t fake(uintptr_t page, uintptr_t byte) { return ARENA + page * PG + byte; }
static uint64_t ep(void) { return atomic_load(&g_table_epoch); }
// 写者纪律：每个写者收工时代际必须是偶数、且比开工前大（旧记录靠它作废，奇偶靠它判「有人正在改表」）。
// 每次都查：一处少加代际，后面所有写者的奇偶会整体反过来、之后的检查跟着失效，所以第一次就要抓住。
static void ck_epoch_step(const char *who, uint64_t before) {
    uint64_t after = ep(); char msg[96]; snprintf(msg, sizeof msg, "写者「%s」收工后代际必须是偶数且比开工前大", who);
    CK(!(after & 1) && after > before, msg);
}
static void add(uintptr_t page, uintptr_t byte, size_t size) { uint64_t e = ep(); nvn_dirty_add_range((const void *)fake(page, byte), size); ck_epoch_step("登记", e); }
static void del(uintptr_t page, uintptr_t byte) { uint64_t e = ep(); nvn_dirty_remove_range((const void *)fake(page, byte)); ck_epoch_step("注销", e); }
static int slot_of(const range_t *r) { int n = atomic_load(&g_nr); for (int i = 0; i < n; i++) if (rg(i) == r) return i; return -1; }
static uint64_t hits(void) { uint64_t h, s; nvn_dirty_span_memo_stats(&h, &s); return h; }
static uint64_t scans(void) { uint64_t h, s; nvn_dirty_span_memo_stats(&h, &s); return s; }
static void reset_world(void) { uint64_t e = ep(); nvn_dirty_reset_session(); ck_epoch_step("重置会话", e); nvn_dirty_set_span_memo(SPAN_MEMO_LOG2); }
static uint32_t rnd_state = 12345;
static uint32_t rnd(void) { rnd_state = rnd_state * 1664525u + 1013904223u; return rnd_state >> 8; }

// ---------- ① 基本：答案与线性扫一致，重复的键命中 ----------
static void t_basic(void) {
    reset_world();
    add(0, 0, 4 * PG);     // 槽 0：页 [0,4)
    add(16, 0, 4 * PG);    // 槽 1：页 [16,20)
    range_t *r0 = find_span_scan(fake(0, 0), 1), *r1 = find_span_scan(fake(16, 0), 1);
    CK(slot_of(r0) == 0 && slot_of(r1) == 1, "前提：两个范围在槽 0 / 1");
    uint64_t h0 = hits(), s0 = scans();
    CK(find_span(fake(1, 5), PG) == r0, "命中槽 0 的跨度");
    CK(scans() == s0 + 1 && hits() == h0, "第一次问：真扫了一次");
    CK(find_span(fake(1, 5), PG) == r0, "同键再问：答案不变");
    CK(hits() == h0 + 1 && scans() == s0 + 1, "同键再问：命中备忘、没再扫");
    CK(find_span(fake(1, 5), 8 * PG) == NULL, "同起点不同长度：装不下槽 0，答案是「没有」（键里必须有长度）");
    CK(find_span(fake(1, 5), PG) == r0, "长度不同的两个键互不串");
    CK(find_span(fake(8, 0), PG) == NULL, "空洞里没有范围");
    uint64_t hb = hits();
    CK(find_span(fake(8, 0), PG) == NULL && hits() == hb + 1, "「没有」也记：同键再问命中");
    CK(find_span(fake(3, 0), 2 * PG) == NULL, "跨出槽 0 末尾的跨度没有范围装得下");
    CK(find_span(fake(16, 7), 3) == r1, "槽 1 内的小跨度");
    CK(find_span(fake(0, 0), 0) == find_span_scan(fake(0, 0), 0), "零长度不走备忘，答案与线性扫一致");
}

// ---------- ① 续：键的每一部分都要比 ----------
// 只留 2 项（= 一组两路）：所有键必然落进同一组，键里少比哪一项（起点 / 长度）都会串；第二个键进第二路，第三个键用来查第二路少比的项。
static void t_keys(void) {
    reset_world();
    nvn_dirty_set_span_memo(1);
    add(0, 0, 4 * PG);     // 槽 0：页 [0,4)
    add(16, 0, 4 * PG);    // 槽 1：页 [16,20)
    range_t *r0 = find_span_scan(fake(0, 0), 1), *r1 = find_span_scan(fake(16, 0), 1);
    CK(find_span(fake(1, 0), PG) == r0, "键 A=(页 1, 一页)：槽 0");
    CK(find_span(fake(17, 0), 8 * PG) == NULL, "键 B=(页 17, 八页)：装不下，没有（进第二路）");
    CK(find_span(fake(1, 0), 8 * PG) == NULL, "与 A 只差长度：不能拿 A 的答案（第一路要比长度）");
    CK(find_span(fake(17, 0), PG) == r1, "与 B 只差长度：不能拿 B 的答案（第二路要比长度）");
    CK(find_span(fake(17, 0), 8 * PG) == NULL, "回到 B：没有");
    CK(find_span(fake(2, 0), 8 * PG) == NULL, "与 B 的长度相同、起点不同（页 2，八页）：槽 0 装不下，没有");
    CK(find_span(fake(2, 0), PG) == r0, "与 A 的长度相同、起点不同（页 2，一页）：槽 0");
    CK(find_span(fake(18, 0), PG) == r1, "（页 18，一页）：槽 1，不能拿到页 2 一页的答案");
    CK(find_span(fake(18, 0), 8 * PG) == NULL, "（页 18，八页）：没有，不能拿到页 18 一页的答案");

    // 两路都要比代际：A 记在它的第一路、与 A 同组的 B 必然记在 B 的第二路（B 的第一路被 A 占着），
    // 表一变（新登记的范围盖住 B）后再问 B，答案必须跟着变；B 的起点按 span_memo_k 挑，让它与 A 同组（不依赖映射地址）
    reset_world();
    nvn_dirty_set_span_memo(1);
    add(0, 0, 4 * PG);
    const uintptr_t ka = fake(1, 0); uintptr_t kb = 0;
    for (uintptr_t by = 0; by < PG && !kb; by += 8) if (span_memo_k(fake(40, by), PG, 1) == span_memo_k(ka, PG, 1)) kb = fake(40, by);
    CK(kb != 0, "前提：找得到与 A 同组的 B");
    CK(find_span(ka, PG) != NULL, "A：槽 0（记在 A 的第一路）");
    CK(find_span(kb, PG) == NULL, "B：没有（记在 B 的第二路）");
    CK(find_span(kb, PG) == NULL && find_span(ka, PG) != NULL, "前提：两个键都已记下");
    add(40, 0, 2 * PG);                  // 槽 1 盖住 B
    CK(slot_of(find_span(kb, PG)) == 1, "表一变，B 的答案跟着变（第二路要比代际）");
    del(0, 0);
    CK(find_span(fake(1, 0), PG) == NULL, "注销之后，A 的答案跟着变（第一路要比代际）");
    nvn_dirty_set_span_memo(SPAN_MEMO_LOG2);
}

// 同组两路互相挤占、表不变：键成「族」（同起点不同长度 / 同长度不同起点），答案各不相同；
// 反复问几万次，键里少比哪一项、哪一路，都会把同族另一个键的旧答案串过来。
static void t_collide(void) {
    reset_world();
    nvn_dirty_set_span_memo(1);
    add(0, 0, 4 * PG); add(16, 0, 4 * PG); add(40, 0, 2 * PG);   // 槽 0 = 页 [0,4)、槽 1 = 页 [16,20)、槽 2 = 页 [40,42)
    const uintptr_t pages[] = {1, 2, 3, 17, 18, 40, 41, 100};
    const size_t lens[] = {1, PG, 2 * PG, 3 * PG, 8 * PG};
    unsigned mism = 0, nonnull = 0, nulls = 0;
    for (int i = 0; i < 40000; i++) {
        uintptr_t a = fake(pages[rnd() % 8], (rnd() % 3) * 8); size_t len = lens[rnd() % 5];
        range_t *want = find_span_scan(a, len), *got = find_span(a, len);
        if (got != want) mism++;
        if (want) nonnull++; else nulls++;
    }
    CK(mism == 0, "同组两路互相挤占时，同族键的答案不能串（键里每一项、每一路都要比）");
    CK(nonnull > 8000 && nulls > 8000, "前提：问到的答案「有」「没有」都足够多（否则串了也看不出）");
    nvn_dirty_set_span_memo(SPAN_MEMO_LOG2);
}

// ---------- ② 作废：登记 / 注销 / 槽位复用 / 换底 / 重置会话 ----------
static void t_invalidate(void) {
    reset_world();
    add(0, 0, 4 * PG);     // 槽 0
    add(16, 0, 4 * PG);    // 槽 1
    CK(find_span(fake(8, 0), PG) == NULL, "前提：页 8 没有范围（记下「没有」）");
    CK(find_span(fake(8, 0), PG) == NULL, "前提：「没有」命中备忘");
    add(8, 0, 2 * PG);     // 槽 2 盖住页 8
    range_t *r2 = find_span_scan(fake(8, 0), PG);
    CK(slot_of(r2) == 2, "前提：新范围在槽 2");
    CK(find_span(fake(8, 0), PG) == r2, "登记之后，旧的「没有」作废，答案是新范围");

    range_t *r1 = find_span_scan(fake(16, 0), 1);
    CK(find_span(fake(17, 0), PG) == r1 && find_span(fake(17, 0), PG) == r1, "前提：槽 1 的答案已记下");
    del(16, 0);
    CK(find_span(fake(17, 0), PG) == NULL, "注销之后，旧的命中作废，答案是「没有」");
    add(32, 0, 2 * PG);    // 复用槽 1
    CK(slot_of(find_span_scan(fake(32, 0), 1)) == 1, "前提：槽 1 被别的池复用");
    CK(find_span(fake(17, 0), PG) == NULL, "槽位被别处复用后，旧键仍然是「没有」，不能拿到复用后的槽");
    CK(slot_of(find_span(fake(32, 0), PG)) == 1, "复用后的新范围查得到");

    // 重叠：两个范围共用一页，先登记的（槽号小的）优先
    reset_world();
    add(64, 0, 2 * PG);                  // 槽 0：页 [64,66)
    add(65, 0, 2 * PG);                  // 槽 1：页 [65,67)，与槽 0 共用页 65
    range_t *a = find_span_scan(fake(64, 0), 1), *b = find_span_scan(fake(66, 0), 1);
    CK(slot_of(a) == 0 && slot_of(b) == 1, "前提：重叠的两个范围在槽 0 / 1");
    CK(find_span(fake(65, 8), 16) == a && find_span(fake(65, 8), 16) == a, "共用页里的小跨度：槽号小的优先（且已记下）");
    del(64, 0);
    CK(find_span(fake(65, 8), 16) == b, "槽 0 注销后，同一个键改由槽 1 回答");
    add(60, 0, 10 * PG);                 // 复用槽 0，盖住页 [60,70)
    CK(slot_of(find_span(fake(65, 8), 16)) == 0, "新范围复用槽 0 后，同一个键又由槽 0 回答");

    // 换底：原地换底改的是页状态，范围的位置不变；换成不同长度会走「删除 + 重新登记」
    reset_world();
    add(0, 0, 4 * PG);
    range_t *q = find_span_scan(fake(0, 0), 1);
    CK(find_span(fake(1, 0), PG) == q && find_span(fake(1, 0), PG) == q, "前提：已记下");
    uint64_t s1 = scans();
    { uint64_t e = ep(); CK(nvn_dirty_replace_range((const void *)fake(0, 0), 4 * PG) == 1, "原地换底成功"); ck_epoch_step("原地换底", e); }
    CK(find_span(fake(1, 0), PG) == q && scans() == s1 + 1, "换底推进代际：下一次问要重扫，答案不变");
    { uint64_t e = ep(); CK(nvn_dirty_replace_range((const void *)fake(0, 0), 2 * PG) == 1, "换成不同长度：走删除 + 重新登记"); ck_epoch_step("换成不同长度", e); }
    CK(find_span(fake(3, 0), PG) == NULL && find_span(fake(1, 0), PG) != NULL, "新长度只盖前 2 页");

    // 重置会话：块被释放，旧记录里的指针不能再被用
    reset_world();
    add(0, 0, 4 * PG);
    CK(find_span(fake(1, 0), PG) != NULL && find_span(fake(1, 0), PG) != NULL, "前提：已记下");
    { uint64_t e = ep(); nvn_dirty_reset_session(); ck_epoch_step("重置会话", e); }
    CK(find_span(fake(1, 0), PG) == NULL, "重置会话之后是「没有」");
    add(0, 0, 4 * PG);
    CK(find_span(fake(1, 0), PG) != NULL, "重置之后重新登记，查得到");
}

// ---------- ② 续：代际为奇数（有写者正在改表）既不信也不记 ----------
static void t_odd_epoch(void) {
    reset_world();
    add(0, 0, 4 * PG);
    range_t *r = find_span_scan(fake(0, 0), 1);
    CK(find_span(fake(1, 0), PG) == r && find_span(fake(1, 0), PG) == r, "前提：已记下");
    atomic_fetch_add(&g_table_epoch, 1);   // 模拟写者开始改表（奇数）
    uint64_t h0 = hits(), s0 = scans();
    for (int i = 0; i < 8; i++) CK(find_span(fake(1, 0), PG) == r, "奇数代际里答案照线性扫");
    CK(hits() == h0 && scans() == s0 + 8, "奇数代际：不信旧记录，每次都真扫");
    atomic_store_explicit(&r->live, 0, memory_order_release);   // 写者在同一个奇数代际里继续改：范围被注销
    for (int i = 0; i < 4; i++) CK(find_span(fake(1, 0), PG) == NULL, "奇数代际里表一变答案马上跟着变（上面几次没有被记下）");
    atomic_store_explicit(&r->live, 1, memory_order_release);
    atomic_fetch_add(&g_table_epoch, 1);   // 写者收工（偶数）
    uint64_t s1 = scans();
    CK(find_span(fake(1, 0), PG) == r && scans() == s1 + 1, "偶数代际回来：旧记录作废，重扫一次");
    CK(find_span(fake(1, 0), PG) == r && scans() == s1 + 1, "之后又命中");
}

// ---------- ③ 开关与容量 ----------

static void t_switch(void) {
    reset_world();
    add(0, 0, 4 * PG);
    nvn_dirty_set_span_memo(0);
    uint64_t h0 = hits(), s0 = scans();
    for (int i = 0; i < 50; i++) CK(find_span(fake(1, 0), PG) == find_span_scan(fake(1, 0), PG), "关着：答案照线性扫");
    CK(hits() == h0 && scans() == s0 + 50, "关着：一次也不命中，次次真扫");
    nvn_dirty_set_span_memo(99);
    CK(atomic_load(&g_span_memo_bits) == SPAN_MEMO_LOG2, "超过上限按上限");
    nvn_dirty_set_span_memo(SPAN_MEMO_LOG2);
    uint64_t h1 = hits();
    find_span(fake(1, 0), PG); find_span(fake(1, 0), PG);
    CK(hits() == h1 + 1, "重新打开：命中");
    // 只有 2 项（一组）：任何两个以上的键都互相挤占，答案仍然要对
    nvn_dirty_set_span_memo(1);
    unsigned mism = 0;
    for (int i = 0; i < 4000; i++) {
        uintptr_t a = fake(rnd() % 8, rnd() % PG); size_t len = 1 + rnd() % (2 * PG);
        if (find_span(a, len) != find_span_scan(a, len)) mism++;
    }
    CK(mism == 0, "2 项备忘互相挤占时答案仍与线性扫一致");
    nvn_dirty_set_span_memo(SPAN_MEMO_LOG2);
}

// ---------- ①+②：随机增删，每步对照线性扫 ----------
static void t_random(unsigned bits) {
    reset_world();
    nvn_dirty_set_span_memo(bits);
    enum { LIVE_MAX = 48, PAGES = 160 };
    struct { uintptr_t page, byte; size_t size; int live; } pools[LIVE_MAX]; memset(pools, 0, sizeof pools);
    unsigned mism = 0, ops = 0;
    uintptr_t ka[8] = {0}, hot_a[12]; size_t kl[8] = {0}, hot_l[12];
    for (int h = 0; h < 12; h++) { hot_a[h] = fake(rnd() % PAGES, rnd() % PG); hot_l[h] = 1 + rnd() % (2 * PG); }   // 热键：整个序列里反复问，跨过表的每次变动
    for (int step = 0; step < 4000; step++) {
        unsigned op = rnd() % 16;
        int i = (int)(rnd() % LIVE_MAX);
        if (op < 7) {                                  // 登记（含与别的范围共用页的位置；起点不与现存的重复，免得注销时对不上号）
            if (!pools[i].live) {
                uintptr_t pg = rnd() % PAGES, by = (rnd() % 2) * (PG / 2);
                int dup = 0; for (int k = 0; k < LIVE_MAX; k++) if (pools[k].live && pools[k].page == pg && pools[k].byte == by) dup = 1;
                if (!dup) {
                    pools[i].page = pg; pools[i].byte = by; pools[i].size = PG / 2 + rnd() % (6 * PG);
                    add(pg, by, pools[i].size); pools[i].live = 1; ops++;
                }
            }
        } else if (op < 12) {                          // 注销
            if (pools[i].live) { del(pools[i].page, pools[i].byte); pools[i].live = 0; ops++; }
        } else if (op < 13) {                          // 原地换底（同位置同长度：只改页状态，范围不动）
            if (pools[i].live) { nvn_dirty_replace_range((const void *)fake(pools[i].page, pools[i].byte), pools[i].size); ops++; }
        }
        for (int q = 0; q < 24; q++) {                 // 问：热键 / 刚问过的键（让备忘有机会命中）/ 新键
            uintptr_t a; size_t len;
            if (q % 6 == 5) { int h = (int)(rnd() % 12); a = hot_a[h]; len = hot_l[h]; }
            else if (q & 1) { a = ka[(q >> 1) & 7]; len = kl[(q >> 1) & 7]; }
            else { a = fake(rnd() % (PAGES + 8), rnd() % PG); len = rnd() % 13 ? 1 + rnd() % (2 * PG) : 0; ka[(q >> 1) & 7] = a; kl[(q >> 1) & 7] = len; }
            if (find_span(a, len) != find_span_scan(a, len)) mism++;
        }
    }
    char msg[120]; snprintf(msg, sizeof msg, "随机增删 %u 次、每步 24 问（备忘 %u 位）：答案与线性扫不一致 %u 次", ops, bits, mism);
    CK(mism == 0, msg);
    CK(ops > 1000, "前提：随机序列里真的有足够多的表变动");
}

// ---------- ④ 并发：写者增删，读者读 ----------
// 写者在槽 1 上不停登记 / 注销 F；P（槽 0）永远在；N 这个地址永远没有范围。
// 读者线程一直在读，读的过程中检查「不可能的答案」；主线程在表稳定下来之后发「请回报」（ack_req 加一），
// 每个读者线程回报它这一刻读到的 F——读者线程上留着的备忘（来自之前的各个代际）不许给出旧答案。
static _Atomic int c_stop, c_ack_req;
static _Atomic unsigned c_bad;
static range_t *c_p, *c_f;
static uintptr_t c_s_addr, c_f_addr, c_n_addr;
static range_t *c_report[3];
static _Atomic int c_acked[3];
static void *c_writer(void *arg) {
    (void)arg;
    for (int i = 0; i < 30000; i++) { nvn_dirty_add_range((const void *)fake(200, 0), 2 * PG); nvn_dirty_remove_range((const void *)fake(200, 0)); }   // 不用带检查的助手：计数器不是原子的
    return NULL;
}
static void *c_reader(void *arg) {
    int id = (int)(uintptr_t)arg, last = 0;
    while (!atomic_load(&c_stop)) {
        range_t *s = find_span(c_s_addr, PG), *n = find_span(c_n_addr, PG), *f = find_span(c_f_addr, PG);
        if (s != c_p) atomic_fetch_add(&c_bad, 1);               // 永远在的 P：答案恒定
        if (n != NULL) atomic_fetch_add(&c_bad, 1);              // 永远没有范围的地址
        if (f != NULL && f != c_f) atomic_fetch_add(&c_bad, 1);  // F 要么没有、要么是 F 自己的槽，不能是别的
        int req = atomic_load(&c_ack_req);
        if (req != last) { last = req; c_report[id] = find_span(c_f_addr, PG); atomic_store(&c_acked[id], req); }
    }
    return NULL;
}
static int wait_acks(int req) {
    for (int t = 0; t < 5000; t++) {
        int all = 1; for (int i = 0; i < 3; i++) if (atomic_load(&c_acked[i]) != req) all = 0;
        if (all) return 1;
        usleep(1000);
    }
    return 0;
}
static void t_concurrent(void) {
    reset_world();
    add(100, 0, 4 * PG);                               // P：槽 0，永远在
    c_p = find_span_scan(fake(100, 0), 1);
    CK(slot_of(c_p) == 0, "前提：P 在槽 0");
    c_s_addr = fake(101, 0); c_f_addr = fake(200, 8); c_n_addr = fake(390, 0);
    add(200, 0, 2 * PG); c_f = find_span_scan(c_f_addr, 1); del(200, 0);
    CK(slot_of(c_f) == 1, "前提：F 范围每次都落在槽 1");
    atomic_store(&c_stop, 0); atomic_store(&c_ack_req, 0); atomic_store(&c_bad, 0);
    for (int i = 0; i < 3; i++) { atomic_store(&c_acked[i], 0); c_report[i] = (range_t *)1; }
    pthread_t w, rd[3];
    for (int i = 0; i < 3; i++) pthread_create(&rd[i], NULL, c_reader, (void *)(uintptr_t)i);
    pthread_create(&w, NULL, c_writer, NULL);
    pthread_join(w, NULL);                             // 写者收工：F 已注销
    atomic_store(&c_ack_req, 1);
    CK(wait_acks(1), "读者线程回报（F 已注销）");
    for (int i = 0; i < 3; i++) CK(c_report[i] == NULL, "F 注销之后每个读者线程读到的必须是「没有」（备忘不能留旧答案）");
    add(200, 0, 2 * PG);                               // F 重新登记
    atomic_store(&c_ack_req, 2);
    CK(wait_acks(2), "读者线程回报（F 已重新登记）");
    for (int i = 0; i < 3; i++) CK(c_report[i] == c_f, "F 重新登记之后每个读者线程读到的必须是 F（旧的「没有」不能留着）");
    del(200, 0);                                       // 再注销，换一个别的范围复用槽 1
    add(300, 0, 2 * PG);
    atomic_store(&c_ack_req, 3);
    CK(wait_acks(3), "读者线程回报（槽 1 被别处复用）");
    for (int i = 0; i < 3; i++) CK(c_report[i] == NULL, "槽 1 被别处复用之后，F 的键仍然是「没有」，不能拿到复用后的槽");
    atomic_store(&c_stop, 1);
    for (int i = 0; i < 3; i++) pthread_join(rd[i], NULL);
    CK(atomic_load(&c_bad) == 0, "增删进行中读者读到过不该有的答案");
}

int main(void) {
    PG = (uintptr_t)getpagesize();
    void *arena = mmap(NULL, (size_t)ARENA_PAGES * PG, PROT_READ | PROT_WRITE, MAP_ANONYMOUS | MAP_PRIVATE, -1, 0);
    if (arena == MAP_FAILED) { perror("mmap"); return 2; }
    ARENA = (uintptr_t)arena;
    t_basic();
    t_keys();
    t_collide();
    t_invalidate();
    t_odd_epoch();
    t_switch();
    t_random(SPAN_MEMO_LOG2);
    t_random(1);    // 2 项：任何两个以上的键都互相挤占
    t_random(3);
    t_concurrent();
    printf("%s t_dirty_span_memo: %u checks, %u failures\n", failures ? "✗" : "✓", checks, failures);
    return failures ? 1 : 0;
}
