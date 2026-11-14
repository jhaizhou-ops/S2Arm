// 管线预热清单的实现，合同见 nvn_vk_pipe_warm.h。
//
// 数据：固定槽位数组（上限 debug.s2a.nvk_warm_max，缺省 4096）+ 每条一个散列桶链。散列只作预筛，
// 命中要 identity + 紧凑配方整份逐字节相等（旧层按 64 位散列直接命中撞过一次：同 hash 不同配方会
// 复用不兼容管线）。note 在提交线程（真机约 130 次/帧），所以先算散列、拿最近 4 条 memo 挡掉重复，
// 只有新配方才整份拷进清单。
#define _GNU_SOURCE 1
#include "nvn_vk_pipe_warm.h"

#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#include "nvn_plat.h"     // nvn_plat_flag / nvn_plat_log
#include "rp_shader.h"    // struct rp_prog / rp_shader_prog_identity

// 会话缓存目录（android/native/gfx_plat/nvk_session.c 定义；会话没开返回 NULL）。声明成弱符号：
// 宿主单测不链会话层，没有它就按「目录还没出来」处理（load 返回 -1 让预热线程稍后重试）。
const char *nvk_session_cache_dir(void) __attribute__((weak));
// 后端协作（backend_vulkan.c）。宿主单测不链后端：缺了就跳过打标 / 计数，其余照做。
void nvn_gpu_pipe_warm_scope(int on) __attribute__((weak));
uint64_t nvn_gpu_pipe_warm_hits(void) __attribute__((weak));
uint64_t nvn_gpu_pipe_warm_created(void) __attribute__((weak));

// ---- 文件格式 ----
// 头 32 字节：magic(8) + 格式版本 + 描述版本（=紧凑配方字节数）+ 条目大小 + 条数 + FNV-1a 整份校验。
// 条目 388 字节：程序身份(32) + 紧凑配方(NVK_PW_DESC_BYTES) + uses(4)。任一项不符整份拒绝。
#define NVK_PW_FORMAT 1u
#define NVK_PW_ENTRY (32 + NVK_PW_DESC_BYTES + 4)
#define NVK_PW_HDR 32
#define NVK_PW_MAX_HARD 8192          // 内存上限：8192 × 400 B ≈ 3.2 MiB
#define NVK_PW_FILE_MAX (NVK_PW_HDR + (size_t)NVK_PW_MAX_HARD * NVK_PW_ENTRY)
#define NVK_PW_DEF_CAP 4096
#define NVK_PW_MEMO 4

static const char k_magic[8] = {'S', '2', 'A', 'P', 'W', '1', 0, 0};

// ---- 逐字段序列化的布局自守恒：改了 NVN 状态记录的字节宽或漏了字段，都要在这一行报错 ----
_Static_assert(sizeof(blend_st) == 8 && sizeof(ds_st) == 8 && sizeof(poly_st) == 4 && sizeof(va_st) == 4 &&
               sizeof(vs_st) == 8 && sizeof(color_st) == 4 && sizeof(chmask_st) == 4 && sizeof(ms_st) == 10,
               "NVN 状态记录字节宽变了：nvk_pw_desc_write / pw_desc_read 与 NVK_PW_DESC_BYTES 要同批改");
#define NVK_PW_DESC_SUM (1u + 8u * 4u + 12u + 8u + 8u + 1u + 8u * 8u + 4u + 4u + 10u + 16u * 4u + 16u * 8u + 8u + 4u + 4u)
_Static_assert(NVK_PW_DESC_SUM == NVK_PW_DESC_BYTES, "紧凑配方的字段长度与 NVK_PW_DESC_BYTES 不一致");

// ---- 状态。全部字段受 g.mu 保护；只有这一把锁 ----
static struct pw_state {
    pthread_mutex_t mu;
    char dir[480];
    char path[520];
    int inited;             // 槽位数组 / 桶已分配
    int loaded;             // load 已经成功走过一次
    uint32_t cap;
    uint32_t nbucket;       // cap 向上取 2 的幂
    uint32_t count;
    uint32_t cursor;        // take 游标（按 order 走）
    struct nvk_pipe_rec *recs;
    uint32_t *uses;         // 与 recs 平行：使用次数（落盘用）
    uint32_t *seen;         // 最近使用序号（同 uses 的淘汰顺序）
    uint64_t *hash;         // 配方散列（桶定位）
    int32_t *next;          // 桶链
    int32_t *bucket;        // 桶头（-1 空）
    uint8_t *used;          // 槽位占用位
    int32_t *order;         // take / 落盘的顺序（uses 降序、同 uses 最近优先）
    uint64_t order_gen, note_gen;
    uint64_t clock;         // 单调使用序号
    uint64_t dirty;
    struct { uint64_t h; int32_t slot; } memo[NVK_PW_MEMO];
    struct nvk_pipe_warm_stats st;
    uint64_t save_ok, save_fail, save_skip;
} g = { .mu = PTHREAD_MUTEX_INITIALIZER };

static void pw_log(int red, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static void pw_log(int red, const char *fmt, ...) {
    char b[512];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(b, sizeof b, fmt, ap);
    va_end(ap);
    nvn_plat_log(red ? NVN_PLAT_LOG_RED : NVN_PLAT_LOG_INFO, "pipe", b);
}

static int pw_id_zero(const uint8_t id[32]) {
    for (int i = 0; i < 32; i++) if (id[i]) return 0;
    return 1;
}

// ---- 逐字段序列化（小端） ----
static void pw_put32(uint8_t *o, size_t *at, uint32_t v) {
    o[(*at)++] = (uint8_t)v; o[(*at)++] = (uint8_t)(v >> 8);
    o[(*at)++] = (uint8_t)(v >> 16); o[(*at)++] = (uint8_t)(v >> 24);
}
static void pw_put64(uint8_t *o, size_t *at, uint64_t v) {
    for (int i = 0; i < 8; i++) o[(*at)++] = (uint8_t)(v >> (8 * i));
}
static uint32_t pw_get32(const uint8_t *b, size_t *at) {
    uint32_t v = (uint32_t)b[*at] | (uint32_t)b[*at + 1] << 8 | (uint32_t)b[*at + 2] << 16 | (uint32_t)b[*at + 3] << 24;
    *at += 4;
    return v;
}
static uint64_t pw_get64(const uint8_t *b, size_t *at) {
    uint64_t v = 0;
    for (int i = 0; i < 8; i++) v |= (uint64_t)b[*at + i] << (8 * i);
    *at += 8;
    return v;
}

// 一条管线描述 → 紧凑字节。st[].sh / nspec / spec / _rsv_prim 不进记录：sh 由程序身份还原，
// nspec 恒 0（note 处已挡），spec 是它的空参数区，_rsv_prim 是保留位。
static void pw_desc_write(const nvn_gpu_pipe_desc *d, uint8_t *o) {
    size_t at = 0;
    uint8_t smask = 0;
    for (int st = 0; st < 5; st++) if (d->st[st].sh) smask |= (uint8_t)(1u << st);
    o[at++] = smask;
    for (int i = 0; i < 8; i++) pw_put32(o, &at, d->cfmt[i]);
    pw_put32(o, &at, d->dfmt);
    pw_put32(o, &at, d->sfmt);
    pw_put32(o, &at, d->samples);
    for (int i = 0; i < 8; i++) o[at++] = d->lmap[i];
    pw_put32(o, &at, d->prim);
    pw_put32(o, &at, d->patch_size);
    o[at++] = d->prim_restart;
    for (int i = 0; i < 8; i++) {
        const blend_st *b = &d->blend[i];
        pw_put64(o, &at, (uint64_t)b->target | (uint64_t)b->src_rgb << 3 | (uint64_t)b->dst_rgb << 10 |
                         (uint64_t)b->src_a << 17 | (uint64_t)b->dst_a << 24 | (uint64_t)b->eq_rgb << 31 |
                         (uint64_t)b->eq_a << 34 | (uint64_t)b->adv_mode << 37 | (uint64_t)b->adv_overlap << 43 |
                         (uint64_t)b->adv_premul << 45 | (uint64_t)b->adv_normdst << 46);
    }
    pw_put32(o, &at, (uint32_t)d->color.blend_en | (uint32_t)d->color.logic_op << 8 | (uint32_t)d->color.alpha_func << 12);
    pw_put32(o, &at, d->chmask.mask);
    { const uint8_t *m = &d->ms.enable; for (int i = 0; i < 10; i++) o[at++] = m[i]; }
    for (int i = 0; i < 16; i++)
        pw_put32(o, &at, (uint32_t)d->attr[i].fmt | (uint32_t)d->attr[i].offset << 8 | (uint32_t)d->attr[i].stream << 27);
    for (int i = 0; i < 16; i++) { pw_put32(o, &at, d->stream[i].stride); pw_put32(o, &at, d->stream[i].divisor); }
    { const ds_st *s = &d->ds;
      pw_put64(o, &at, (uint64_t)s->dt | (uint64_t)s->dw << 1 | (uint64_t)s->df << 2 | (uint64_t)s->st << 6 |
                       (uint64_t)s->sf_f << 7 | (uint64_t)s->sf_b << 11 | (uint64_t)s->fail_f << 15 |
                       (uint64_t)s->zfail_f << 19 | (uint64_t)s->zpass_f << 23 | (uint64_t)s->fail_b << 27 |
                       (uint64_t)s->zfail_b << 31 | (uint64_t)s->zpass_b << 35); }
    pw_put32(o, &at, (uint32_t)d->poly.cull | (uint32_t)d->poly.front << 2 | (uint32_t)d->poly.mode << 3 |
                     (uint32_t)d->poly.offset_en << 5);
    o[at++] = d->rast_discard;
    o[at++] = d->clip_neg1;
    o[at++] = d->origin_ll;
    o[at++] = d->depth_clamp;
}

// 紧凑字节 → 一条 memset 过的管线描述（st[].sh 留空，由 nc 侧用程序身份填）。0 = 字节数不符。
static int pw_desc_read(const uint8_t *b, uint32_t bytes, nvn_gpu_pipe_desc *d) {
    if (bytes != NVK_PW_DESC_BYTES) return 0;
    memset(d, 0, sizeof *d);
    size_t at = 0;
    uint8_t smask = b[at++];
    if (smask & ~0x1fu) return 0;   // 只认 5 个图形阶段
    d->st[0].nspec = 0;             // 记录里不存：恒 0（留一行让人看清这里为什么不读）
    for (int i = 0; i < 8; i++) d->cfmt[i] = pw_get32(b, &at);
    d->dfmt = pw_get32(b, &at);
    d->sfmt = pw_get32(b, &at);
    d->samples = pw_get32(b, &at);
    for (int i = 0; i < 8; i++) d->lmap[i] = b[at++];
    d->prim = pw_get32(b, &at);
    d->patch_size = pw_get32(b, &at);
    d->prim_restart = b[at++];
    for (int i = 0; i < 8; i++) {
        uint64_t v = pw_get64(b, &at);
        blend_st *o = &d->blend[i];
        o->target = v & 0x7u;
        o->src_rgb = (v >> 3) & 0x7fu;
        o->dst_rgb = (v >> 10) & 0x7fu;
        o->src_a = (v >> 17) & 0x7fu;
        o->dst_a = (v >> 24) & 0x7fu;
        o->eq_rgb = (v >> 31) & 0x7u;
        o->eq_a = (v >> 34) & 0x7u;
        o->adv_mode = (v >> 37) & 0x3fu;
        o->adv_overlap = (v >> 43) & 0x3u;
        o->adv_premul = (v >> 45) & 0x1u;
        o->adv_normdst = (v >> 46) & 0x1u;
    }
    { uint32_t v = pw_get32(b, &at);
      d->color.blend_en = v & 0xffu; d->color.logic_op = (v >> 8) & 0xfu; d->color.alpha_func = (v >> 12) & 0xfu; }
    d->chmask.mask = pw_get32(b, &at);
    { uint8_t *m = &d->ms.enable; for (int i = 0; i < 10; i++) m[i] = b[at++]; }
    for (int i = 0; i < 16; i++) {
        uint32_t v = pw_get32(b, &at);
        d->attr[i].fmt = v & 0xffu;
        d->attr[i].offset = (v >> 8) & 0x7ffffu;
        d->attr[i].stream = (v >> 27) & 0x1fu;
    }
    for (int i = 0; i < 16; i++) { d->stream[i].stride = pw_get32(b, &at); d->stream[i].divisor = pw_get32(b, &at); }
    { uint64_t v = pw_get64(b, &at);
      ds_st *o = &d->ds;
      o->dt = v & 0x1u; o->dw = (v >> 1) & 0x1u; o->df = (v >> 2) & 0xfu;
      o->st = (v >> 6) & 0x1u; o->sf_f = (v >> 7) & 0xfu; o->sf_b = (v >> 11) & 0xfu;
      o->fail_f = (v >> 15) & 0xfu; o->zfail_f = (v >> 19) & 0xfu;
      o->zpass_f = (v >> 23) & 0xfu; o->fail_b = (v >> 27) & 0xfu;
      o->zfail_b = (v >> 31) & 0xfu; o->zpass_b = (v >> 35) & 0xfu; }
    { uint32_t v = pw_get32(b, &at);
      d->poly.cull = v & 0x3u; d->poly.front = (v >> 2) & 0x1u; d->poly.mode = (v >> 3) & 0x3u;
      d->poly.offset_en = (v >> 5) & 0x7u; }
    d->rast_discard = b[at++];
    d->clip_neg1 = b[at++];
    d->origin_ll = b[at++];
    d->depth_clamp = b[at++];
    return 1;
}

// ---- 散列 / 判等 ----
// 只需快筛：命中一律再看 identity + 整份字节（pw_same）。
static uint64_t pw_hash(const uint8_t *desc, const uint8_t ident[32]) {
    uint64_t h = 1469598103934665603ull;
    for (uint32_t i = 0; i < NVK_PW_DESC_BYTES; i++) h = (h ^ desc[i]) * 1099511628211ull;
    for (int i = 0; i < 32; i++) h = (h ^ ident[i]) * 1099511628211ull;
    return h;
}

static int pw_same(const struct nvk_pipe_rec *r, const uint8_t *desc, const uint8_t ident[32]) {
    return r->bytes == NVK_PW_DESC_BYTES && memcmp(r->desc, desc, NVK_PW_DESC_BYTES) == 0 &&
           memcmp(r->prog_identity, ident, 32) == 0;
}

// ---- 槽位与桶 ----
static uint32_t pw_cap_from_flag(void) {
    int v = nvn_plat_flag("nvk_warm_max", NVK_PW_DEF_CAP);
    if (v < 1) v = 1;
    if (v > NVK_PW_MAX_HARD) v = NVK_PW_MAX_HARD;
    return (uint32_t)v;
}

static uint32_t pw_bucket_of(uint64_t h, uint32_t nbucket) { return (uint32_t)(h & (nbucket - 1)); }

// 分配槽位数组（幂等）。失败返回 -1：note 只计数，不影响绘制。
static int pw_init_locked(void) {
    if (g.inited) return 0;
    g.cap = pw_cap_from_flag();
    uint32_t nb = 1;
    while (nb < g.cap) nb <<= 1;
    g.nbucket = nb;
    g.recs = calloc(g.cap, sizeof *g.recs);
    g.uses = calloc(g.cap, sizeof *g.uses);
    g.seen = calloc(g.cap, sizeof *g.seen);
    g.hash = calloc(g.cap, sizeof *g.hash);
    g.next = calloc(g.cap, sizeof *g.next);
    g.used = calloc(g.cap, 1);
    g.order = calloc(g.cap, sizeof *g.order);
    g.bucket = malloc((size_t)nb * sizeof *g.bucket);
    if (!g.recs || !g.uses || !g.seen || !g.hash || !g.next || !g.used || !g.order || !g.bucket) {
        free(g.recs); free(g.uses); free(g.seen); free(g.hash); free(g.next); free(g.used); free(g.order); free(g.bucket);
        g.recs = NULL; g.uses = NULL; g.seen = NULL; g.hash = NULL; g.next = NULL; g.used = NULL; g.order = NULL; g.bucket = NULL;
        return -1;
    }
    for (uint32_t i = 0; i < nb; i++) g.bucket[i] = -1;
    for (uint32_t i = 0; i < g.cap; i++) g.next[i] = -1;
    for (int i = 0; i < NVK_PW_MEMO; i++) g.memo[i].slot = -1;
    g.inited = 1;
    return 0;
}

static void pw_unlink_locked(uint32_t slot) {
    uint32_t b = pw_bucket_of(g.hash[slot], g.nbucket);
    int32_t cur = g.bucket[b], prev = -1;
    while (cur >= 0) {
        if ((uint32_t)cur == slot) {
            if (prev < 0) g.bucket[b] = g.next[slot];
            else g.next[prev] = g.next[slot];
            g.next[slot] = -1;
            return;
        }
        prev = cur;
        cur = g.next[cur];
    }
}

static void pw_memo_drop_locked(int32_t slot) {
    for (int i = 0; i < NVK_PW_MEMO; i++) if (g.memo[i].slot == slot) { g.memo[i].slot = -1; g.memo[i].h = 0; }
}

static void pw_memo_touch_locked(uint64_t h, int32_t slot) {
    int at = -1;
    for (int i = 0; i < NVK_PW_MEMO; i++) if (g.memo[i].slot == slot) { at = i; break; }
    if (at > 0) {
        uint64_t mh = g.memo[at].h; int32_t ms = g.memo[at].slot;
        for (int k = at; k > 0; k--) g.memo[k] = g.memo[k - 1];
        g.memo[0].h = mh; g.memo[0].slot = ms;
        return;
    }
    if (at == 0) { g.memo[0].h = h; g.memo[0].slot = slot; return; }
    for (int k = NVK_PW_MEMO - 1; k > 0; k--) g.memo[k] = g.memo[k - 1];
    g.memo[0].h = h; g.memo[0].slot = slot;
}

// 淘汰目标：uses 最小，同 uses 取最久没用的。
static uint32_t pw_victim_locked(void) {
    uint32_t best = 0;
    for (uint32_t i = 0; i < g.cap; i++) {
        if (!g.used[i]) return i;
        if (!g.used[best]) { best = i; continue; }
        if (g.uses[i] < g.uses[best] || (g.uses[i] == g.uses[best] && g.seen[i] < g.seen[best])) best = i;
    }
    return best;
}

static void pw_insert_locked(const uint8_t *desc, const uint8_t ident[32], uint64_t h, uint32_t uses) {
    uint32_t slot = pw_victim_locked();
    if (g.used[slot]) {
        __atomic_fetch_add(&g.st.rejected, 1, __ATOMIC_RELAXED);   // 上限满了淘汰最冷的：不拒绝新配方，代价记在这里
        pw_unlink_locked(slot);
        pw_memo_drop_locked((int32_t)slot);
    } else {
        g.count++;
    }
    struct nvk_pipe_rec *r = &g.recs[slot];
    memcpy(r->desc, desc, NVK_PW_DESC_BYTES);
    memcpy(r->prog_identity, ident, 32);
    r->bytes = NVK_PW_DESC_BYTES;
    r->uses = uses;
    g.uses[slot] = uses;
    g.seen[slot] = (uint32_t)++g.clock;
    g.hash[slot] = h;
    g.used[slot] = 1;
    uint32_t b = pw_bucket_of(h, g.nbucket);
    g.next[slot] = g.bucket[b];
    g.bucket[b] = (int32_t)slot;
    g.note_gen++;
    g.dirty = 1;
    pw_memo_touch_locked(h, (int32_t)slot);
}

static void pw_touch_locked(uint32_t slot) {
    g.uses[slot]++;
    g.seen[slot] = (uint32_t)++g.clock;
    g.recs[slot].uses = g.uses[slot];
    g.dirty = 1;
}

// ---- 用例 / 诊断入口 ----
void nvk_pipe_warm_rec_of(const nvn_gpu_pipe_desc *d, const uint8_t prog_identity[32], struct nvk_pipe_rec *out) {
    if (!out) return;
    memset(out, 0, sizeof *out);
    if (!d || !prog_identity) return;
    for (int st = 0; st < 5; st++) if (d->st[st].nspec) return;   // 特化常量不进记录：bytes 留 0
    pw_desc_write(d, out->desc);
    memcpy(out->prog_identity, prog_identity, 32);
    out->bytes = NVK_PW_DESC_BYTES;
}

static int g_hash_const;   // 用例钩子：见 nvn_vk_pipe_warm.h（读写一律走 __atomic_*）

uint64_t nvk_pipe_warm_hash(const struct nvk_pipe_rec *rec) {
    if (!rec || rec->bytes != NVK_PW_DESC_BYTES) return 0;
    if (__atomic_load_n(&g_hash_const, __ATOMIC_ACQUIRE)) return 0x5a5a5a5a5a5a5a5aull;
    return pw_hash(rec->desc, rec->prog_identity);
}

void nvk_pipe_warm_test_hash_const(int on) { __atomic_store_n(&g_hash_const, on ? 1 : 0, __ATOMIC_RELEASE); }

// ---- note（提交线程，约 130 次/帧） ----
void nvk_pipe_warm_note(const nvn_gpu_pipe_desc *d, const uint8_t prog_identity[32]) {
    if (!d || !prog_identity) return;
    if (pw_id_zero(prog_identity)) return;   // 没有身份的程序不进清单（失败项 / 还没算出来）
    for (int st = 0; st < 5; st++)
        if (d->st[st].nspec) {   // 特化常量不进记录：那类配方本层不产生，宁可不预热也不建错
            __atomic_fetch_add(&g.st.rejected, 1, __ATOMIC_RELAXED);
            return;
        }
    uint8_t desc[NVK_PW_DESC_BYTES];
    pw_desc_write(d, desc);
    uint64_t h = __atomic_load_n(&g_hash_const, __ATOMIC_ACQUIRE) ? 0x5a5a5a5a5a5a5a5aull : pw_hash(desc, prog_identity);
    pthread_mutex_lock(&g.mu);
    if (pw_init_locked() != 0) { pthread_mutex_unlock(&g.mu); return; }
    for (int i = 0; i < NVK_PW_MEMO; i++) {   // 最近 4 条：同散列且整份相等就只 uses ++，不再拷配方
        int32_t slot = g.memo[i].slot;
        if (slot >= 0 && g.memo[i].h == h && pw_same(&g.recs[slot], desc, prog_identity)) {
            pw_touch_locked((uint32_t)slot);
            pw_memo_touch_locked(h, slot);
            pthread_mutex_unlock(&g.mu);
            return;
        }
    }
    {   // 桶链（memo 没挡住时：隔了 4 条以上又回到同一份配方，或第一次见）
        uint32_t b = pw_bucket_of(h, g.nbucket);
        for (int32_t slot = g.bucket[b]; slot >= 0; slot = g.next[slot])
            if (g.hash[slot] == h && pw_same(&g.recs[slot], desc, prog_identity)) {
                pw_touch_locked((uint32_t)slot);
                pw_memo_touch_locked(h, (int32_t)slot);
                pthread_mutex_unlock(&g.mu);
                return;
            }
    }
    __atomic_fetch_add(&g.st.recorded, 1, __ATOMIC_RELAXED);
    pw_insert_locked(desc, prog_identity, h, 1);
    pthread_mutex_unlock(&g.mu);
}

int nvk_pipe_warm_note_prog(const nvn_gpu_pipe_desc *d, const struct rp_prog *p) {
    uint8_t ident[32];
    if (!d || !p) return 0;
    if (!rp_shader_prog_identity(p, ident)) return 0;
    if (pw_id_zero(ident)) return 0;
    nvk_pipe_warm_note(d, ident);
    return 1;
}

// ---- take / pending（预热线程） ----
static int pw_order_cmp(const void *pa, const void *pb) {
    int32_t a = *(const int32_t *)pa, b = *(const int32_t *)pb;
    if (g.uses[a] != g.uses[b]) return g.uses[a] < g.uses[b] ? 1 : -1;   // uses 降序：热点先建
    if (g.seen[a] != g.seen[b]) return g.seen[a] < g.seen[b] ? 1 : -1;   // 同 uses：最近用过的在前
    return a < b ? -1 : 1;
}

static void pw_build_order_locked(void) {
    uint32_t n = 0;
    for (uint32_t i = 0; i < g.cap; i++) if (g.used[i]) g.order[n++] = (int32_t)i;
    qsort(g.order, n, sizeof *g.order, pw_order_cmp);
    g.order_gen = g.note_gen;
}

int nvk_pipe_warm_take(struct nvk_pipe_rec *out) {
    if (!out) return 0;
    memset(out, 0, sizeof *out);
    pthread_mutex_lock(&g.mu);
    if (!g.inited || g.cursor >= g.count) { pthread_mutex_unlock(&g.mu); return 0; }
    if (g.order_gen != g.note_gen) pw_build_order_locked();
    *out = g.recs[g.order[g.cursor++]];
    pthread_mutex_unlock(&g.mu);
    return 1;
}

int nvk_pipe_warm_pending(void) {
    pthread_mutex_lock(&g.mu);
    int n = g.inited && g.count > g.cursor ? (int)(g.count - g.cursor) : 0;
    pthread_mutex_unlock(&g.mu);
    return n;
}

// ---- build（预热线程） ----
int nvk_pipe_warm_build(const struct nvk_pipe_rec *rec) {
    if (!rec || rec->bytes != NVK_PW_DESC_BYTES) return -1;
    const struct rp_prog *prog = NULL;
    if (!rp_shader_prog_by_identity(rec->prog_identity, &prog) || !prog) {
        __atomic_fetch_add(&g.st.retried, 1, __ATOMIC_RELAXED);
        return 1;   // 程序还没发布：预热线程隔几毫秒再试（不是失败）
    }
    nvn_gpu_pipe_desc pd;
    if (!pw_desc_read(rec->desc, rec->bytes, &pd)) {
        __atomic_fetch_add(&g.st.failed, 1, __ATOMIC_RELAXED);
        pw_log(1, "管线预热：记录长度 %u 与描述版本 %u 不符，整条跳过", (unsigned)rec->bytes, (unsigned)NVK_PW_DESC_BYTES);
        return -1;
    }
    // 记录里记着哪些阶段（st[].sh 的存在位），必须和程序实际的阶段一致：对不上就是旧布局 / 别的层的
    // 记录，建出来的就不是这条配方——宁可不建，也不建一条「差不多」的。
    uint8_t want = rec->desc[0];
    for (int st = 0; st < 3; st++) {
        int have = prog->sh[st] != NULL;
        if (((want >> st) & 1) != have) {
            __atomic_fetch_add(&g.st.failed, 1, __ATOMIC_RELAXED);
            pw_log(1, "管线预热：记录的阶段位 %#x 与程序的阶段对不上（阶段 %d），整条跳过", (unsigned)want, st);
            return -1;
        }
    }
    if ((want & ~0x7u) != 0) {   // GS 以外的阶段（TCS / TES）本层不产生：有就是坏记录
        __atomic_fetch_add(&g.st.failed, 1, __ATOMIC_RELAXED);
        return -1;
    }
    for (int st = 0; st < 3; st++) pd.st[st].sh = prog->sh[st];
    if (nvn_gpu_pipe_warm_scope) nvn_gpu_pipe_warm_scope(1);
    nvn_gpu_pipe pipe = NULL;
    nvn_gpu_err err = {0};
    nvn_gpu_rc r = nvn_gpu_pipe_get(&pd, NVN_GPU_PIPE_SYNC, &pipe, &err);
    if (nvn_gpu_pipe_warm_scope) nvn_gpu_pipe_warm_scope(0);
    if (!nvn_gpu_ok(r)) {
        __atomic_fetch_add(&g.st.failed, 1, __ATOMIC_RELAXED);
        pw_log(1, "管线预热：nvn_gpu_pipe_get 失败（%d）：%s", (int)r.code, err.why);
        return -1;
    }
    __atomic_fetch_add(&g.st.built, 1, __ATOMIC_RELAXED);
    return 0;
}

// ---- 盘上文件：<缓存目录>/pipes-v<格式>-<描述版本>.bin ----
static void pw_w32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); p[2] = (uint8_t)(v >> 16); p[3] = (uint8_t)(v >> 24);
}
static uint32_t pw_r32(const uint8_t *p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}
static void pw_w64(uint8_t *p, uint64_t v) { for (int i = 0; i < 8; i++) p[i] = (uint8_t)(v >> (8 * i)); }
static uint64_t pw_r64(const uint8_t *p) {
    uint64_t v = 0;
    for (int i = 0; i < 8; i++) v |= (uint64_t)p[i] << (8 * i);
    return v;
}

// 目录 / 文件名（幂等）。返回 1 = 有目录可用；0 = 目录还没出来（会话还没开 / 平台没给缓存目录）。
static int pw_ensure_dir_locked(void) {
    if (!g.dir[0]) {
        const char *dir = nvk_session_cache_dir ? nvk_session_cache_dir() : NULL;
        if (!dir || !*dir) return 0;
        snprintf(g.dir, sizeof g.dir, "%s", dir);
    }
    snprintf(g.path, sizeof g.path, "%s/pipes-v%u-%u.bin", g.dir, (unsigned)NVK_PW_FORMAT, (unsigned)NVK_PW_DESC_BYTES);
    return 1;
}

// 原子写：临时文件 + 内容 fsync + rename + 目录 fsync。掉电后不会留半个文件。
static int pw_write_atomic(const char *path, const uint8_t *buf, size_t bytes) {
    char tmp[600];
    snprintf(tmp, sizeof tmp, "%s.tmp", path);
    int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0644);
    if (fd < 0) return -1;
    size_t off = 0;
    while (off < bytes) {
        ssize_t w = write(fd, buf + off, bytes - off);
        if (w <= 0) { close(fd); unlink(tmp); return -1; }
        off += (size_t)w;
    }
    if (fsync(fd) != 0) { close(fd); unlink(tmp); return -1; }
    if (close(fd) != 0) { unlink(tmp); return -1; }
    if (rename(tmp, path) != 0) { unlink(tmp); return -1; }
    {   // 目录项也要落盘：rename 之后文件才算真的在那儿
        char dir[600];
        snprintf(dir, sizeof dir, "%s", path);
        char *slash = strrchr(dir, '/');
        if (slash) {
            *slash = 0;
            int dfd = open(dir, O_RDONLY | O_CLOEXEC);
            if (dfd >= 0) { fsync(dfd); close(dfd); }
        }
    }
    return 0;
}

// 整份读（有界）。*enoent = 1 表示目录里还没有旧文件（不是错误）。
static int pw_read_file(const char *path, uint8_t **out, size_t *bytes, int *enoent) {
    *out = NULL; *bytes = 0; *enoent = 0;
    int fd = open(path, O_RDONLY | O_CLOEXEC);
    if (fd < 0) { if (errno == ENOENT) { *enoent = 1; return 0; } return -1; }
    struct stat st;
    if (fstat(fd, &st) != 0 || st.st_size < 0 || (uint64_t)st.st_size > (uint64_t)NVK_PW_FILE_MAX) { close(fd); return -1; }
    size_t n = (size_t)st.st_size;
    uint8_t *b = malloc(n ? n : 1);
    if (!b) { close(fd); return -1; }
    size_t got = 0;
    while (got < n) {
        ssize_t r = read(fd, b + got, n - got);
        if (r <= 0) { free(b); close(fd); return -1; }
        got += (size_t)r;
    }
    close(fd);
    *out = b; *bytes = n;
    return 0;
}

int nvk_pipe_warm_load(void) {
    pthread_mutex_lock(&g.mu);
    if (g.loaded) { int n = (int)g.count; pthread_mutex_unlock(&g.mu); return n; }
    if (pw_init_locked() != 0) { pthread_mutex_unlock(&g.mu); return -1; }
    if (!pw_ensure_dir_locked()) { pthread_mutex_unlock(&g.mu); return -1; }   // 目录还没出来：预热线程稍后重试
    char path[sizeof g.path];
    snprintf(path, sizeof path, "%s", g.path);
    uint32_t cap = g.cap;
    pthread_mutex_unlock(&g.mu);

    uint8_t *buf = NULL;
    size_t bytes = 0;
    int enoent = 0;
    if (pw_read_file(path, &buf, &bytes, &enoent) != 0) {
        pw_log(1, "管线预热清单读失败：%s", path);
        return -1;   // 读不动：让预热线程稍后重试，不把「读失败」当「清单是空的」
    }
    if (enoent) {
        pthread_mutex_lock(&g.mu); g.loaded = 1; pthread_mutex_unlock(&g.mu);
        pw_log(0, "管线预热清单：目录里还没有旧文件（%s），本局只记不预热", path);
        return 0;
    }
    // 头 + 整份校验：magic / 格式版本 / 描述版本 / 条目大小 / 条数 / 文件长度 / FNV，任一不符整份拒绝。
    uint32_t cnt = 0;
    const char *why = NULL;
    if (bytes < NVK_PW_HDR || memcmp(buf, k_magic, 8) != 0) why = "magic 不符";
    else if ((cnt = pw_r32(buf + 20)) > cap) why = "条数超过本局上限";
    else if (pw_r32(buf + 8) != NVK_PW_FORMAT) why = "格式版本不符";
    else if (pw_r32(buf + 12) != NVK_PW_DESC_BYTES) why = "描述版本不符（配方布局变了）";
    else if (pw_r32(buf + 16) != NVK_PW_ENTRY) why = "条目大小不符";
    else if (bytes != NVK_PW_HDR + (size_t)cnt * NVK_PW_ENTRY) why = "文件长度与条数不符";
    else {
        uint64_t h = 1469598103934665603ull;
        for (size_t i = NVK_PW_HDR; i < bytes; i++) h = (h ^ buf[i]) * 1099511628211ull;
        if (h != pw_r64(buf + 24)) why = "整份校验和不符";
    }
    if (why) {
        pthread_mutex_lock(&g.mu);
        g.loaded = 1;
        __atomic_fetch_add(&g.st.rejected, cnt ? cnt : 1, __ATOMIC_RELAXED);
        pthread_mutex_unlock(&g.mu);
        pw_log(1, "管线预热清单整份拒绝（%s）：%s，本局不预热", why, path);
        free(buf);
        return 0;
    }
    pthread_mutex_lock(&g.mu);
    for (uint32_t i = 0; i < cnt; i++) {
        const uint8_t *e = buf + NVK_PW_HDR + (size_t)i * NVK_PW_ENTRY;
        struct nvk_pipe_rec *r = &g.recs[i];
        memcpy(r->prog_identity, e, 32);
        memcpy(r->desc, e + 32, NVK_PW_DESC_BYTES);
        r->bytes = NVK_PW_DESC_BYTES;
        r->uses = pw_r32(e + 32 + NVK_PW_DESC_BYTES);
        g.uses[i] = r->uses;
        g.seen[i] = cnt - i;   // 文件按热点降序写：前面 = 更近
        g.hash[i] = pw_hash(r->desc, r->prog_identity);
        g.used[i] = 1;
        uint32_t b = pw_bucket_of(g.hash[i], g.nbucket);
        g.next[i] = g.bucket[b];
        g.bucket[b] = (int32_t)i;
    }
    g.count = cnt;
    g.cursor = 0;
    g.clock = cnt;
    g.loaded = 1;
    g.dirty = 0;
    g.note_gen = 1;
    g.order_gen = 0;
    g.st.loaded = cnt;
    pthread_mutex_unlock(&g.mu);
    free(buf);
    pw_log(0, "管线预热清单：%u 条（%s，%zu 字节）", (unsigned)cnt, path, bytes);
    return (int)cnt;
}

void nvk_pipe_warm_save(void) {
    char path[sizeof g.path];
    uint8_t *buf = NULL;
    size_t bytes = 0;
    uint32_t cnt = 0;
    pthread_mutex_lock(&g.mu);
    if (!g.inited || !g.dirty || !pw_ensure_dir_locked() || g.count == 0) {
        g.save_skip++;   // 内容没变 / 没有目录 / 一条都没有：不写盘
        pthread_mutex_unlock(&g.mu);
        return;
    }
    if (g.order_gen != g.note_gen) pw_build_order_locked();
    cnt = g.count;
    bytes = NVK_PW_HDR + (size_t)cnt * NVK_PW_ENTRY;
    buf = malloc(bytes);
    if (!buf) {
        g.save_fail++;
        pthread_mutex_unlock(&g.mu);
        return;
    }
    memset(buf, 0, NVK_PW_HDR);
    memcpy(buf, k_magic, 8);
    pw_w32(buf + 8, NVK_PW_FORMAT);
    pw_w32(buf + 12, NVK_PW_DESC_BYTES);
    pw_w32(buf + 16, NVK_PW_ENTRY);
    pw_w32(buf + 20, cnt);
    {   // 落盘顺序 = uses 降序、同 uses 最近优先（与 take 的顺序同一份）
        size_t o = NVK_PW_HDR;
        for (uint32_t k = 0; k < cnt; k++) {
            const struct nvk_pipe_rec *r = &g.recs[g.order[k]];
            memcpy(buf + o, r->prog_identity, 32); o += 32;
            memcpy(buf + o, r->desc, NVK_PW_DESC_BYTES); o += NVK_PW_DESC_BYTES;
            pw_w32(buf + o, g.uses[g.order[k]]); o += 4;
        }
        uint64_t h = 1469598103934665603ull;
        for (size_t i = NVK_PW_HDR; i < bytes; i++) h = (h ^ buf[i]) * 1099511628211ull;
        pw_w64(buf + 24, h);
    }
    memcpy(path, g.path, sizeof path);
    g.dirty = 0;
    pthread_mutex_unlock(&g.mu);

    int rc = pw_write_atomic(path, buf, bytes);
    free(buf);
    pthread_mutex_lock(&g.mu);
    if (rc == 0) g.save_ok++;
    else { g.save_fail++; g.dirty = 1; }   // 写失败：留着脏位，下一次 save 再试（失败只计数）
    pthread_mutex_unlock(&g.mu);
    if (rc != 0) pw_log(1, "管线预热清单写盘失败（%u 条，%zu 字节）：%s", (unsigned)cnt, bytes, path);
}

void nvk_pipe_warm_stats(struct nvk_pipe_warm_stats *out) {
    if (!out) return;
    memset(out, 0, sizeof *out);
    pthread_mutex_lock(&g.mu);
    *out = g.st;
    out->pending = g.inited && g.count > g.cursor ? g.count - g.cursor : 0;
    out->rejected = g.st.rejected + g.save_fail;
    pthread_mutex_unlock(&g.mu);
    out->draw_hits = nvn_gpu_pipe_warm_hits ? nvn_gpu_pipe_warm_hits() : 0;   // 转发后端：真实 draw 命中预建对象
}

