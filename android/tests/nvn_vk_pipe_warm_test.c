// 管线预热清单的宿主单测：链生产 nvk_vk_pipe_warm.c，假程序来源 + 假 nvn_gpu_pipe_get。
// 覆盖：逐字段往返（每个字段改一点都必须往返后不等）、同配方去重与 uses、散列撞但字节不同必须不命中、
// 上限与淘汰、跨会话落盘/读回（顺序 = uses 降序）、坏文件整份拒绝、stats 转发。
//
// 跨会话的部分用「同一个二进制换参数再跑一次」实现（模块是进程单例，load 只读一次）：
//   父进程建临时目录、按顺序子进程跑各模式；缓存目录经环境变量交给子进程。
// 用法：nvn_vk_pipe_warm_test            （全部模式）
//       nvn_vk_pipe_warm_test <模式名>   （单跑一个模式，交给父进程用）
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <unistd.h>
#include <sys/wait.h>

#include "nvn_vk_pipe_warm.h"
#include "rp_shader.h"

// ---- 平台 / 来源 / 后端替身 ----
static struct rp_prog g_prog;          // 假程序：身份 + 三个阶段句柄
static int g_pipe_get_calls;
static nvn_gpu_pipe_desc g_last_desc;  // 假 nvn_gpu_pipe_get 收到的描述
static int g_pipe_fail;
static uint64_t g_fake_hits = 12345;

int nvn_plat_flag(const char *name, int dflt) {
    if (!strcmp(name, "nvk_warm_max")) { const char *e = getenv("S2A_PW_MAX"); return e && *e ? atoi(e) : dflt; }
    return dflt;
}
void nvn_plat_log(int level, const char *cls, const char *text) { (void)level; (void)cls; (void)text; }
const char *nvk_session_cache_dir(void) { return getenv("S2A_PW_DIR"); }
void nvn_gpu_pipe_warm_scope(int on) { (void)on; }
uint64_t nvn_gpu_pipe_warm_hits(void) { return g_fake_hits; }
uint64_t nvn_gpu_pipe_warm_created(void) { return 0; }

int rp_shader_prog_identity(const struct rp_prog *p, uint8_t out[32]) {
    if (!p) return 0;
    memcpy(out, p->identity, 32);
    return 1;
}
int rp_shader_prog_by_identity(const uint8_t identity[32], const struct rp_prog **out) {
    if (out) *out = NULL;
    if (memcmp(identity, g_prog.identity, 32) != 0) return 0;
    if (out) *out = &g_prog;
    return 1;
}
// 程序借用（rp_shader.h）：管线预热整段使用期间必须持借用，桩里直接转发到上面的假程序表。
static int g_borrow_n;
static int g_borrow_fail;   // 用例：模拟「会话已停 / 借用表满」的拒绝
int rp_shader_prog_borrow(const uint8_t identity[32], const struct rp_prog **out) {
    if (out) *out = NULL;
    if (g_borrow_fail) return -1;
    if (memcmp(identity, g_prog.identity, 32) != 0) return 0;
    if (out) *out = &g_prog;
    g_borrow_n++;
    return 1;
}
void rp_shader_prog_return(const uint8_t identity[32]) { (void)identity; if (g_borrow_n > 0) g_borrow_n--; }
int rp_shader_prog_borrowed(void) { return g_borrow_n; }
nvn_gpu_rc nvn_gpu_pipe_get(const nvn_gpu_pipe_desc *d, int mode, nvn_gpu_pipe *out, nvn_gpu_err *err) {
    (void)mode;
    (void)err;
    if (!d || !out) return (nvn_gpu_rc){NVN_GPU_E_ARG};
    g_pipe_get_calls++;
    g_last_desc = *d;
    if (g_pipe_fail) return (nvn_gpu_rc){NVN_GPU_E_COMPILE};
    *out = (nvn_gpu_pipe)(uintptr_t)0x9001;
    return (nvn_gpu_rc){NVN_GPU_OK};
}

// ---- 断言 ----
static int g_fail;
#define CHECK(cond, ...) do { if (!(cond)) { fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); g_fail = 1; } } while (0)

// ---- 基线描述：每个字段取一个可 +1 的小值；两个阶段有句柄（句柄不进记录） ----
static void base_desc(nvn_gpu_pipe_desc *d) {
    memset(d, 0, sizeof *d);
    d->st[0].sh = (nvn_gpu_shader)(uintptr_t)0x1001;
    d->st[1].sh = (nvn_gpu_shader)(uintptr_t)0x1002;
    d->cfmt[0] = 0x23; d->cfmt[1] = 0x25;
    d->dfmt = 0x2a; d->sfmt = 0; d->samples = 1;
    d->lmap[0] = 0; for (int i = 1; i < 8; i++) d->lmap[i] = 0xff;
    d->prim = 4; d->patch_size = 0; d->prim_restart = 0;
    for (int i = 0; i < 8; i++) {
        d->blend[i].target = 0; d->blend[i].src_rgb = 1; d->blend[i].dst_rgb = 2; d->blend[i].src_a = 3;
        d->blend[i].dst_a = 4; d->blend[i].eq_rgb = 1; d->blend[i].eq_a = 2;
        d->blend[i].adv_mode = 0; d->blend[i].adv_overlap = 0; d->blend[i].adv_premul = 0; d->blend[i].adv_normdst = 0;
    }
    d->color.blend_en = 1; d->color.logic_op = 1; d->color.alpha_func = 1;
    d->chmask.mask = 0x00001111u;
    d->ms.enable = 0; d->ms.samples = 1; d->ms.a2c = 0; d->ms.a2c_dither = 0; d->ms.raster_samples = 1;
    d->ms.cov_mod = 0; d->ms.cov2color_en = 0; d->ms.cov2color_out = 0; d->ms.sl_en = 0; d->ms.sl_grid = 0;
    for (int i = 0; i < 16; i++) { d->attr[i].fmt = 0; d->attr[i].offset = 0; d->attr[i].stream = 0; }
    d->attr[0].fmt = 0x17; d->attr[0].offset = 8;
    for (int i = 0; i < 16; i++) { d->stream[i].stride = 0; d->stream[i].divisor = 0; }
    d->stream[0].stride = 16;
    d->ds.dt = 1; d->ds.dw = 1; d->ds.df = 1; d->ds.st = 0;
    d->ds.sf_f = 1; d->ds.sf_b = 2; d->ds.fail_f = 1; d->ds.zfail_f = 2; d->ds.zpass_f = 3;
    d->ds.fail_b = 4; d->ds.zfail_b = 5; d->ds.zpass_b = 6;
    d->poly.cull = 1; d->poly.front = 0; d->poly.mode = 2; d->poly.offset_en = 1;
    d->rast_discard = 0; d->clip_neg1 = 0; d->origin_ll = 1; d->depth_clamp = 0;
}

static void ident_fill(uint8_t id[32], uint8_t seed) {
    for (int i = 0; i < 32; i++) id[i] = (uint8_t)(seed + i * 7u);
}
static void prog_setup(uint8_t seed) {
    memset(&g_prog, 0, sizeof g_prog);
    ident_fill(g_prog.identity, seed);
    g_prog.sh[0] = (nvn_gpu_shader)(uintptr_t)0x1001;
    g_prog.sh[1] = (nvn_gpu_shader)(uintptr_t)0x1002;
    g_prog.sh[2] = NULL;
}

// ---- 逐字段改动表：kind + 下标，mutate 把该字段改「一点点」 ----
enum {
    K_CFMT, K_LMAP, K_PRIM, K_PATCH, K_PRIM_RESTART, K_DFMT, K_SFMT, K_SAMPLES,
    K_BLEND_TARGET, K_BLEND_SRC_RGB, K_BLEND_DST_RGB, K_BLEND_SRC_A, K_BLEND_DST_A, K_BLEND_EQ_RGB, K_BLEND_EQ_A,
    K_BLEND_ADV_MODE, K_BLEND_ADV_OVERLAP, K_BLEND_ADV_PREMUL, K_BLEND_ADV_NORMDST,
    K_COLOR_BLEND_EN, K_COLOR_LOGIC_OP, K_COLOR_ALPHA_FUNC, K_CHMASK, K_MS_A2C, K_MS_SL_GRID,
    K_ATTR_FMT, K_ATTR_OFFSET, K_ATTR_STREAM, K_STREAM_STRIDE, K_STREAM_DIVISOR,
    K_DS_DT, K_DS_DW, K_DS_DF, K_DS_ST, K_DS_SF_F, K_DS_SF_B, K_DS_FAIL_F, K_DS_ZFAIL_F, K_DS_ZPASS_F,
    K_DS_FAIL_B, K_DS_ZFAIL_B, K_DS_ZPASS_B,
    K_POLY_CULL, K_POLY_FRONT, K_POLY_MODE, K_POLY_OFFSET_EN,
    K_RAST_DISCARD, K_CLIP_NEG1, K_ORIGIN_LL, K_DEPTH_CLAMP
};

static void mutate(nvn_gpu_pipe_desc *d, int kind, int idx) {
    switch (kind) {
    case K_CFMT: d->cfmt[idx] += 1; break;
    case K_LMAP: d->lmap[idx] = d->lmap[idx] == 0xff ? 0 : (uint8_t)(d->lmap[idx] + 1); break;
    case K_PRIM: d->prim += 1; break;
    case K_PATCH: d->patch_size += 1; break;
    case K_PRIM_RESTART: d->prim_restart ^= 1; break;
    case K_DFMT: d->dfmt += 1; break;
    case K_SFMT: d->sfmt += 1; break;
    case K_SAMPLES: d->samples += 1; break;
    case K_BLEND_TARGET: d->blend[idx].target += 1; break;
    case K_BLEND_SRC_RGB: d->blend[idx].src_rgb += 1; break;
    case K_BLEND_DST_RGB: d->blend[idx].dst_rgb += 1; break;
    case K_BLEND_SRC_A: d->blend[idx].src_a += 1; break;
    case K_BLEND_DST_A: d->blend[idx].dst_a += 1; break;
    case K_BLEND_EQ_RGB: d->blend[idx].eq_rgb += 1; break;
    case K_BLEND_EQ_A: d->blend[idx].eq_a += 1; break;
    case K_BLEND_ADV_MODE: d->blend[idx].adv_mode += 1; break;
    case K_BLEND_ADV_OVERLAP: d->blend[idx].adv_overlap += 1; break;
    case K_BLEND_ADV_PREMUL: d->blend[idx].adv_premul ^= 1; break;
    case K_BLEND_ADV_NORMDST: d->blend[idx].adv_normdst ^= 1; break;
    case K_COLOR_BLEND_EN: d->color.blend_en += 1; break;
    case K_COLOR_LOGIC_OP: d->color.logic_op += 1; break;
    case K_COLOR_ALPHA_FUNC: d->color.alpha_func += 1; break;
    case K_CHMASK: d->chmask.mask ^= 1u; break;
    case K_MS_A2C: d->ms.a2c ^= 1; break;
    case K_MS_SL_GRID: d->ms.sl_grid ^= 1; break;
    case K_ATTR_FMT: d->attr[idx].fmt += 1; break;
    case K_ATTR_OFFSET: d->attr[idx].offset += 1; break;
    case K_ATTR_STREAM: d->attr[idx].stream += 1; break;
    case K_STREAM_STRIDE: d->stream[idx].stride += 1; break;
    case K_STREAM_DIVISOR: d->stream[idx].divisor += 1; break;
    case K_DS_DT: d->ds.dt ^= 1; break;
    case K_DS_DW: d->ds.dw ^= 1; break;
    case K_DS_DF: d->ds.df += 1; break;
    case K_DS_ST: d->ds.st ^= 1; break;
    case K_DS_SF_F: d->ds.sf_f += 1; break;
    case K_DS_SF_B: d->ds.sf_b += 1; break;
    case K_DS_FAIL_F: d->ds.fail_f += 1; break;
    case K_DS_ZFAIL_F: d->ds.zfail_f += 1; break;
    case K_DS_ZPASS_F: d->ds.zpass_f += 1; break;
    case K_DS_FAIL_B: d->ds.fail_b += 1; break;
    case K_DS_ZFAIL_B: d->ds.zfail_b += 1; break;
    case K_DS_ZPASS_B: d->ds.zpass_b += 1; break;
    case K_POLY_CULL: d->poly.cull += 1; break;
    case K_POLY_FRONT: d->poly.front ^= 1; break;
    case K_POLY_MODE: d->poly.mode += 1; break;
    case K_POLY_OFFSET_EN: d->poly.offset_en += 1; break;
    case K_RAST_DISCARD: d->rast_discard ^= 1; break;
    case K_CLIP_NEG1: d->clip_neg1 ^= 1; break;
    case K_ORIGIN_LL: d->origin_ll ^= 1; break;
    case K_DEPTH_CLAMP: d->depth_clamp ^= 1; break;
    default: break;
    }
}

struct mut { const char *name; int kind, idx; };
static const struct mut k_muts[] = {
    {"cfmt0", K_CFMT, 0}, {"cfmt1", K_CFMT, 1}, {"cfmt2", K_CFMT, 2}, {"cfmt3", K_CFMT, 3},
    {"cfmt4", K_CFMT, 4}, {"cfmt5", K_CFMT, 5}, {"cfmt6", K_CFMT, 6}, {"cfmt7", K_CFMT, 7},
    {"lmap0", K_LMAP, 0}, {"lmap1", K_LMAP, 1}, {"lmap7", K_LMAP, 7},
    {"prim", K_PRIM, 0}, {"patch_size", K_PATCH, 0}, {"prim_restart", K_PRIM_RESTART, 0},
    {"dfmt", K_DFMT, 0}, {"sfmt", K_SFMT, 0}, {"samples", K_SAMPLES, 0},
    {"color.blend_en", K_COLOR_BLEND_EN, 0}, {"color.logic_op", K_COLOR_LOGIC_OP, 0},
    {"color.alpha_func", K_COLOR_ALPHA_FUNC, 0}, {"chmask", K_CHMASK, 0},
    {"ms.a2c", K_MS_A2C, 0}, {"ms.sl_grid", K_MS_SL_GRID, 0},
    {"ds.dt", K_DS_DT, 0}, {"ds.dw", K_DS_DW, 0}, {"ds.df", K_DS_DF, 0}, {"ds.st", K_DS_ST, 0},
    {"ds.sf_f", K_DS_SF_F, 0}, {"ds.sf_b", K_DS_SF_B, 0}, {"ds.fail_f", K_DS_FAIL_F, 0},
    {"ds.zfail_f", K_DS_ZFAIL_F, 0}, {"ds.zpass_f", K_DS_ZPASS_F, 0}, {"ds.fail_b", K_DS_FAIL_B, 0},
    {"ds.zfail_b", K_DS_ZFAIL_B, 0}, {"ds.zpass_b", K_DS_ZPASS_B, 0},
    {"poly.cull", K_POLY_CULL, 0}, {"poly.front", K_POLY_FRONT, 0}, {"poly.mode", K_POLY_MODE, 0},
    {"poly.offset_en", K_POLY_OFFSET_EN, 0},
    {"rast_discard", K_RAST_DISCARD, 0}, {"clip_neg1", K_CLIP_NEG1, 0},
    {"origin_ll", K_ORIGIN_LL, 0}, {"depth_clamp", K_DEPTH_CLAMP, 0},
    // 数组：每个元素都扫（blend 的 11 个字段扫第 0、第 7 个元素；attr / stream 扫全部 16 个）
    {"blend0.target", K_BLEND_TARGET, 0}, {"blend0.src_rgb", K_BLEND_SRC_RGB, 0},
    {"blend0.dst_rgb", K_BLEND_DST_RGB, 0}, {"blend0.src_a", K_BLEND_SRC_A, 0},
    {"blend0.dst_a", K_BLEND_DST_A, 0}, {"blend0.eq_rgb", K_BLEND_EQ_RGB, 0}, {"blend0.eq_a", K_BLEND_EQ_A, 0},
    {"blend0.adv_mode", K_BLEND_ADV_MODE, 0}, {"blend0.adv_overlap", K_BLEND_ADV_OVERLAP, 0},
    {"blend0.adv_premul", K_BLEND_ADV_PREMUL, 0}, {"blend0.adv_normdst", K_BLEND_ADV_NORMDST, 0},
    {"blend7.target", K_BLEND_TARGET, 7}, {"blend7.src_rgb", K_BLEND_SRC_RGB, 7},
    {"blend7.dst_a", K_BLEND_DST_A, 7}, {"blend7.adv_mode", K_BLEND_ADV_MODE, 7},
    {"attr0.fmt", K_ATTR_FMT, 0}, {"attr0.offset", K_ATTR_OFFSET, 0}, {"attr0.stream", K_ATTR_STREAM, 0},
    {"attr15.fmt", K_ATTR_FMT, 15}, {"attr15.stream", K_ATTR_STREAM, 15},
    {"stream0.stride", K_STREAM_STRIDE, 0}, {"stream0.divisor", K_STREAM_DIVISOR, 0},
    {"stream15.stride", K_STREAM_STRIDE, 15}, {"stream15.divisor", K_STREAM_DIVISOR, 15},
};
#define NMUT ((int)(sizeof k_muts / sizeof k_muts[0]))
#define NFIELDS (NMUT + 1)

// 把反序列化得到的描述里的句柄清掉，好与期望逐字节比（记录里 sh 本来就不存）
static void strip_sh(nvn_gpu_pipe_desc *d) {
    for (int st = 0; st < 5; st++) d->st[st].sh = NULL;
}

// ---- 模式：逐字段往返 ----
static int mode_fields(void) {
    uint8_t id[32];
    ident_fill(id, 0x11);
    prog_setup(0x11);
    nvn_gpu_pipe_desc base;
    base_desc(&base);
    nvk_pipe_warm_note(&base, id);
    static nvn_gpu_pipe_desc exp[NFIELDS];
    exp[0] = base;
    strip_sh(&exp[0]);
    for (int i = 0; i < NMUT; i++) {
        exp[i + 1] = base;
        mutate(&exp[i + 1], k_muts[i].kind, k_muts[i].idx);
        strip_sh(&exp[i + 1]);
        nvn_gpu_pipe_desc send = base;
        mutate(&send, k_muts[i].kind, k_muts[i].idx);
        nvk_pipe_warm_note(&send, id);
    }
    // 本局预热集只来自载入：先落盘再载入，take 才是「这一局要预热的那批」（运行期 note 只影响下一局清单）。
    nvk_pipe_warm_save();
    CHECK(nvk_pipe_warm_load() == NFIELDS, "fields: save+load must bring back %d recipes", NFIELDS);
    int pend = nvk_pipe_warm_pending();
    CHECK(pend == NFIELDS, "expected %d pending recipes, got %d", NFIELDS, pend);

    int seen[NFIELDS];
    memset(seen, 0, sizeof seen);
    int ntake = 0;
    struct nvk_pipe_rec rec;
    while (nvk_pipe_warm_take(&rec)) {
        int rc = nvk_pipe_warm_build(&rec);
        CHECK(rc == 0, "build of a recorded recipe must succeed, rc=%d", rc);
        nvn_gpu_pipe_desc got = g_last_desc;
        strip_sh(&got);
        int matched = -1;
        for (int i = 0; i < NFIELDS && matched < 0; i++)
            if (memcmp(&exp[i], &got, sizeof got) == 0) matched = i;
        CHECK(matched >= 0, "recipe #%d did not round-trip to any expected desc (bytes differ)", ntake);
        if (matched >= 0) seen[matched]++;
        ntake++;
    }
    CHECK(ntake == NFIELDS, "took %d recipes, expected %d", ntake, NFIELDS);
    for (int i = 0; i < NFIELDS; i++) {
        if (seen[i] != 1) {
            CHECK(0, "expected desc %s matched %d times (want exactly 1)", i == 0 ? "base" : k_muts[i - 1].name, seen[i]);
        }
    }
    return g_fail;
}

// ---- 模式：同配方去重 / uses / 跳过条件 ----
static int mode_dedup(void) {
    uint8_t id[32], zero[32];
    ident_fill(id, 0x22);
    memset(zero, 0, sizeof zero);
    prog_setup(0x22);
    nvn_gpu_pipe_desc pd;
    base_desc(&pd);
    for (int i = 0; i < 3; i++) nvk_pipe_warm_note(&pd, id);
    nvk_pipe_warm_note(&pd, zero);            // 没有身份：不记
    nvn_gpu_pipe_desc spec = pd;
    spec.st[0].nspec = 1;                     // 特化常量：不记
    nvk_pipe_warm_note(&spec, id);
    struct nvk_pipe_warm_stats st;
    nvk_pipe_warm_stats(&st);
    CHECK(st.recorded == 1, "three notes of one recipe must record 1 entry, got %llu", (unsigned long long)st.recorded);
    CHECK(st.rejected >= 1, "a recipe with nspec != 0 must be rejected, got %llu", (unsigned long long)st.rejected);
    nvk_pipe_warm_save();
    CHECK(nvk_pipe_warm_load() == 1, "dedup: save+load must bring back the one recipe");
    CHECK(nvk_pipe_warm_pending() == 1, "pending must be 1, got %d", nvk_pipe_warm_pending());
    struct nvk_pipe_rec rec;
    CHECK(nvk_pipe_warm_take(&rec) == 1, "take must return the only entry");
    CHECK(rec.uses == 3, "uses must count every real bind (3), got %u", rec.uses);
    // 再 note 一次：命中去重、uses 继续加
    nvk_pipe_warm_note(&pd, id);
    nvk_pipe_warm_stats(&st);
    CHECK(st.recorded == 1, "repeat note must not add an entry, got %llu", (unsigned long long)st.recorded);
    CHECK(st.draw_hits == g_fake_hits, "draw_hits must forward the backend counter, got %llu", (unsigned long long)st.draw_hits);
    return g_fail;
}

// ---- 模式：散列相同、配方不同必须留两条 ----
// 64 位散列构造不出真碰撞，用模块的用例钩子把散列固定成常数：这时「散列相同的两条不同配方」
// 就是每个配方都同散列。判据若只比散列，B 会被并进 A（pending 1）；判据是整份字节，则两条都在。
static int mode_collide(void) {
    uint8_t id[32];
    ident_fill(id, 0x33);
    prog_setup(0x33);
    nvn_gpu_pipe_desc da, db;
    base_desc(&da);
    db = da;
    db.depth_clamp ^= 1;   // 只改一个语义字节：配方不同
    nvk_pipe_warm_test_hash_const(1);
    struct nvk_pipe_rec ra, rb;
    nvk_pipe_warm_rec_of(&da, id, &ra);
    nvk_pipe_warm_rec_of(&db, id, &rb);
    CHECK(nvk_pipe_warm_hash(&ra) == nvk_pipe_warm_hash(&rb), "hash-const hook must make both hashes equal");
    CHECK(memcmp(ra.desc, rb.desc, NVK_PW_DESC_BYTES) != 0, "the two recipes must differ in bytes");
    nvk_pipe_warm_note(&da, id);
    nvk_pipe_warm_note(&db, id);
    nvk_pipe_warm_save();
    CHECK(nvk_pipe_warm_load() == 2, "collide: save+load must bring back both recipes");
    CHECK(nvk_pipe_warm_pending() == 2,
          "same hash + different bytes must NOT dedup (pending %d, want 2)", nvk_pipe_warm_pending());
    nvk_pipe_warm_note(&da, id);   // 同散列同字节：必须去重、只加 uses
    struct nvk_pipe_warm_stats st;
    nvk_pipe_warm_stats(&st);
    CHECK(st.recorded == 2, "identical recipe must dedup by bytes (recorded %llu)", (unsigned long long)st.recorded);
    nvk_pipe_warm_test_hash_const(0);
    return g_fail;
}

// ---- 模式：上限与淘汰 ----
static int mode_cap(void) {
    uint8_t id[32];
    ident_fill(id, 0x44);
    prog_setup(0x44);
    nvn_gpu_pipe_desc hot, others[5];
    base_desc(&hot);
    hot.prim = 5;                              // 让 hot 与 others 都不同
    for (int i = 0; i < 5; i++) {
        base_desc(&others[i]);
        others[i].prim = 6 + (uint32_t)i;
        for (int k = 0; k <= i + 1; k++) nvk_pipe_warm_note(&others[i], id);   // uses = i+2
    }
    for (int k = 0; k < 20; k++) nvk_pipe_warm_note(&hot, id);                 // uses = 20，必须活下来
    nvk_pipe_warm_save();
    CHECK(nvk_pipe_warm_load() == 4, "cap: save+load must bring back exactly the capped set");
    int pend = nvk_pipe_warm_pending();
    CHECK(pend == 4, "cap=4 must keep 4 entries after 6 distinct recipes, got %d", pend);
    int found_hot = 0, found_cold = 0;
    struct nvk_pipe_rec rec;
    while (nvk_pipe_warm_take(&rec)) {
        CHECK(nvk_pipe_warm_build(&rec) == 0, "build in cap mode");
        strip_sh(&g_last_desc);
        nvn_gpu_pipe_desc h2 = hot;
        strip_sh(&h2);
        if (memcmp(&h2, &g_last_desc, sizeof h2) == 0) found_hot = 1;
        nvn_gpu_pipe_desc c2 = others[0];
        strip_sh(&c2);
        if (memcmp(&c2, &g_last_desc, sizeof c2) == 0) found_cold = 1;
    }
    CHECK(found_hot == 1, "the hottest recipe (uses 20) must survive the cap");
    CHECK(found_cold == 0, "the coldest recipe (uses 2, oldest) must be evicted");
    return g_fail;
}

// ---- 模式：落盘 / 读回 ----
static int file_path(char *out, size_t n) {
    const char *dir = getenv("S2A_PW_DIR");
    if (!dir || !*dir) return -1;
    snprintf(out, n, "%s/pipes-v1-%d.bin", dir, NVK_PW_DESC_BYTES);
    return 0;
}

static int mode_save(void) {
    uint8_t id[32];
    ident_fill(id, 0x55);
    prog_setup(0x55);
    nvn_gpu_pipe_desc d[3];
    for (int i = 0; i < 3; i++) {
        base_desc(&d[i]);
        d[i].prim = 1 + (uint32_t)i;
        for (int k = 0; k <= i * 2; k++) nvk_pipe_warm_note(&d[i], id);   // uses = 1 / 3 / 5
    }
    nvk_pipe_warm_save();
    char path[600];
    if (file_path(path, sizeof path)) return 2;
    FILE *f = fopen(path, "rb");
    if (!f) { CHECK(0, "save must create the manifest file"); return g_fail; }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fclose(f);
    CHECK(sz == 32 + 3 * (32 + NVK_PW_DESC_BYTES + 4), "file size %ld for 3 entries", sz);
    return g_fail;
}

static int mode_load(void) {
    int n = nvk_pipe_warm_load();
    CHECK(n == 3, "load must read 3 entries, got %d", n);
    prog_setup(0x55);
    uint32_t want_uses[3] = {5, 3, 1};
    for (int i = 0; i < 3; i++) {
        struct nvk_pipe_rec rec;
        CHECK(nvk_pipe_warm_take(&rec) == 1, "take #%d after load", i);
        CHECK(rec.uses == want_uses[i], "entry #%d uses %u, want %u (hot first)", i, rec.uses, want_uses[i]);
        CHECK(nvk_pipe_warm_build(&rec) == 0, "build #%d after load", i);
        CHECK(g_last_desc.prim == 3 - (uint32_t)i, "entry #%d prim %u", i, g_last_desc.prim);
    }
    struct nvk_pipe_rec extra;
    CHECK(nvk_pipe_warm_take(&extra) == 0, "take must end after 3");
    return g_fail;
}

// ---- 模式：坏文件整份拒绝 ----
static int mode_badfile(const char *variant) {
    char path[600];
    if (file_path(path, sizeof path)) return 2;
    FILE *f = fopen(path, "rb");
    if (!f) return 2;
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    unsigned char *buf = malloc((size_t)sz);
    if (!buf || fread(buf, 1, (size_t)sz, f) != (size_t)sz) { if (buf) free(buf); fclose(f); return 2; }
    fclose(f);
    long keep = sz;
    const char *v = variant;
    if (!strcmp(v, "magic")) buf[0] ^= 0xff;
    else if (!strcmp(v, "fmt")) buf[8] ^= 0xff;
    else if (!strcmp(v, "descver")) buf[12] ^= 0xff;
    else if (!strcmp(v, "entry")) buf[16] ^= 0xff;
    else if (!strcmp(v, "count")) buf[20] ^= 0xff;
    else if (!strcmp(v, "sum")) buf[24] ^= 0xff;
    else if (!strcmp(v, "trunc")) keep = sz > 20 ? 20 : 1;
    else if (!strcmp(v, "payload")) buf[sz - 1] ^= 0xff;
    else return 2;
    f = fopen(path, "wb");
    if (!f) { free(buf); return 2; }
    fwrite(buf, 1, (size_t)keep, f);
    fclose(f);
    free(buf);
    int n = nvk_pipe_warm_load();
    CHECK(n == 0, "corrupt manifest (%s) must be rejected wholesale, load returned %d", v, n);
    struct nvk_pipe_warm_stats st;
    nvk_pipe_warm_stats(&st);
    CHECK(st.rejected >= 1, "corrupt manifest (%s) must count rejected entries", v);
    CHECK(nvk_pipe_warm_pending() == 0, "corrupt manifest must yield no work");
    return g_fail;
}

// ---- 父进程：子进程跑各模式 ----
// ---- 模式：程序借用（外部复核 P1「管线预热缺少程序寿命保护」的消费侧）----
// 建管线必须持借用、且无论成功失败都要归还；借用被拒（会话已停 / 借用表满）时如实失败，不假装建过。
static int mode_lease(void) {
    uint8_t id[32];
    ident_fill(id, 0x77);
    prog_setup(0x77);
    nvn_gpu_pipe_desc pd;
    base_desc(&pd);
    nvk_pipe_warm_note(&pd, id);
    nvk_pipe_warm_save();
    CHECK(nvk_pipe_warm_load() == 1, "lease: one recipe must load");
    struct nvk_pipe_rec rec;
    CHECK(nvk_pipe_warm_take(&rec) == 1, "lease: take the recipe");
    struct nvk_pipe_warm_stats st0, st1;
    nvk_pipe_warm_stats(&st0);
    g_borrow_fail = 1;
    int rc = nvk_pipe_warm_build(&rec);
    g_borrow_fail = 0;
    nvk_pipe_warm_stats(&st1);
    CHECK(rc == -1, "lease: a refused borrow must fail the build (-1), got %d", rc);
    CHECK(st1.failed == st0.failed + 1, "lease: refused borrow counts as failed, not retried");
    CHECK(rp_shader_prog_borrowed() == 0, "lease: no borrow leaked on the failure path");
    rc = nvk_pipe_warm_build(&rec);
    CHECK(rc == 0, "lease: build with a borrow succeeds, got %d", rc);
    CHECK(rp_shader_prog_borrowed() == 0, "lease: the borrow is returned after the build (no leak)");
    return g_fail;
}

// ---- 模式：并发保存（外部复核 P2「管线清单并发保存会损坏文件」的等价夹具）----
// 4 个线程各自 note + save，然后在同一进程里重新载入：保存必须被串行化，最后发布的文件必须完整可读，
// 且取出的是那条唯一集合（不出现重复、不出现半截条目）。负对照：去掉保存互斥 + 让写盘变慢 → 载入返回 0。
static void *save_thread(void *arg) {
    long k = (long)(intptr_t)arg;
    uint8_t id[32];
    ident_fill(id, (int)(0x70 + k));
    prog_setup((unsigned)(0x70 + k));
    for (int i = 0; i < 40; i++) {
        nvn_gpu_pipe_desc d;
        base_desc(&d);
        d.stream[0].stride = (uint32_t)(100 + i * 7 + k * 1000);
        nvk_pipe_warm_note(&d, id);
        nvk_pipe_warm_save();
    }
    return NULL;
}
static int mode_save_race(void) {
    enum { NTH = 4 };
    pthread_t th[NTH];
    for (long i = 0; i < NTH; i++) pthread_create(&th[i], NULL, save_thread, (void *)(intptr_t)i);
    for (int i = 0; i < NTH; i++) pthread_join(th[i], NULL);
    int n = nvk_pipe_warm_load();
    CHECK(n == 160, "save race: a fresh load of the last published snapshot must return all 160 recipes, got %d", n);
    int seen = 0, dup = 0;
    struct nvk_pipe_rec got, seenr[160];
    while (nvk_pipe_warm_take(&got)) {
        for (int i = 0; i < seen; i++) if (!memcmp(seenr[i].desc, got.desc, NVK_PW_DESC_BYTES) && !memcmp(seenr[i].prog_identity, got.prog_identity, 32)) dup = 1;
        if (seen < 160) seenr[seen] = got;
        seen++;
    }
    CHECK(seen == 160 && !dup, "save race: the published set must be exactly 160 unique recipes (seen=%d dup=%d)", seen, dup);
    return g_fail;
}

// ---- 模式：本局预热集冻结（外部复核 P1「冻结了数量，身份集合仍会变化」的 repro）----
// 载入之后 take 的顺序与集合必须就是文件里那份；运行期的 note、热点重排（order 重建）、淘汰、周期 save
// 都不许影响它——否则同一配方被取两次、另一个配方永远漏掉（复核复现的 A→A）。
static int mode_frozen(void) {
    uint8_t id[32];
    ident_fill(id, 0x66);
    prog_setup(0x66);
    nvn_gpu_pipe_desc a, b, c, d;
    base_desc(&a); b = a; b.prim = 7; c = a; c.prim = 8; d = a; d.prim = 9;
    for (int i = 0; i < 10; i++) nvk_pipe_warm_note(&a, id);   // uses=10，最热
    for (int i = 0; i < 5; i++) nvk_pipe_warm_note(&b, id);    // uses=5
    nvk_pipe_warm_note(&c, id);                                // uses=1
    nvk_pipe_warm_save();
    CHECK(nvk_pipe_warm_load() == 3, "frozen: three recipes load");
    struct nvk_pipe_rec got, ar, br, cr;
    nvk_pipe_warm_rec_of(&a, id, &ar); nvk_pipe_warm_rec_of(&b, id, &br); nvk_pipe_warm_rec_of(&c, id, &cr);
    CHECK(nvk_pipe_warm_take(&got) == 1 && !memcmp(got.desc, ar.desc, NVK_PW_DESC_BYTES), "frozen: first take = hottest A");
    // 运行期搅动：B 变最热、插入新配方 D、立刻落盘（会重排 order）
    for (int i = 0; i < 20; i++) nvk_pipe_warm_note(&b, id);
    nvk_pipe_warm_note(&d, id);
    nvk_pipe_warm_save();
    CHECK(nvk_pipe_warm_take(&got) == 1 && !memcmp(got.desc, br.desc, NVK_PW_DESC_BYTES),
          "frozen: second take must still be B from the loaded plan (not A again, not D)");
    {   // 集合唯一性：剩下必须恰好是 C 一条，且全程没有重复
        int ntake = 0, dup = 0;
        struct nvk_pipe_rec seen[4];
        int ns = 0;
        while (nvk_pipe_warm_take(&got)) {
            for (int i = 0; i < ns; i++) if (!memcmp(seen[i].desc, got.desc, NVK_PW_DESC_BYTES)) dup = 1;
            if (ns < 4) seen[ns++] = got;
            ntake++;
        }
        CHECK(ntake == 1 && !dup && !memcmp(seen[0].desc, cr.desc, NVK_PW_DESC_BYTES),
              "frozen: exactly C left, no duplicates (ntake=%d dup=%d)", ntake, dup);
    }
    return g_fail;
}

static const char *k_modes[] = {"fields", "dedup", "collide", "cap", "frozen", "lease", "save", "load", "save_race"};
static const char *k_bad[] = {"magic", "fmt", "descver", "entry", "count", "sum", "trunc", "payload"};

static int run_child(const char *self, const char *a, const char *b) {
    pid_t pid = fork();
    if (pid == 0) {
        if (b) execl(self, self, a, b, (char *)NULL);
        else execl(self, self, a, (char *)NULL);
        _exit(127);
    }
    if (pid < 0) return -1;
    int status = 0;
    if (waitpid(pid, &status, 0) != pid) return -1;
    return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

int main(int argc, char **argv) {
    if (argc >= 3 && !strcmp(argv[1], "badfile")) return mode_badfile(argv[2]) ? 1 : 0;
    if (argc >= 2) {
        const char *m = argv[1];
        int (*fn)(void) = !strcmp(m, "fields") ? mode_fields : !strcmp(m, "dedup") ? mode_dedup :
                          !strcmp(m, "collide") ? mode_collide : !strcmp(m, "cap") ? mode_cap :
                          !strcmp(m, "frozen") ? mode_frozen : !strcmp(m, "lease") ? mode_lease :
                          !strcmp(m, "save_race") ? mode_save_race :
                          !strcmp(m, "save") ? mode_save : !strcmp(m, "load") ? mode_load : NULL;
        if (!fn) { fprintf(stderr, "unknown mode %s\n", m); return 2; }
        return fn() ? 1 : 0;
    }
    const char *dir = getenv("S2A_PW_DIR");
    char tmp[512];
    if (!dir || !*dir) {
        snprintf(tmp, sizeof tmp, "/tmp/s2a-pw-XXXXXX");
        if (!mkdtemp(tmp)) { perror("mkdtemp"); return 2; }
        setenv("S2A_PW_DIR", tmp, 1);
    }
    int fail = 0;
    for (unsigned i = 0; i < sizeof k_modes / sizeof k_modes[0]; i++) {
        if (!strcmp(k_modes[i], "cap")) setenv("S2A_PW_MAX", "4", 1);   // 上限模式：清单只留 4 条
        int rc = run_child(argv[0], k_modes[i], NULL);
        if (!strcmp(k_modes[i], "cap")) unsetenv("S2A_PW_MAX");
        printf("%-8s %s\n", k_modes[i], rc == 0 ? "ok" : "FAIL");
        if (rc != 0) fail = 1;
    }
    for (unsigned i = 0; i < sizeof k_bad / sizeof k_bad[0]; i++) {
        int rc = run_child(argv[0], "badfile", k_bad[i]);
        printf("bad/%-8s %s\n", k_bad[i], rc == 0 ? "ok" : "FAIL");
        if (rc != 0) fail = 1;
    }
    printf("%s\n", fail ? "FAIL" : "PASS 主机管道：逐字段往返 / 去重 uses / 散列碰撞不去重 / 上限淘汰 / 跨会话清单 / 坏文件整份拒绝 / 本局预热集冻结 / 程序借用不泄漏 / 并发保存不损坏");
    return fail;
}
