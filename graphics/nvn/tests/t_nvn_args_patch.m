// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 参数块「只换了统一缓冲」就打补丁、不整块重编（encode_args_ / args_ubo_patchable，照 nxnative adaff735，MIT；11-13 能耗性能线）。直接包含生产 nvn_mtl.m，走生产 state_op / encode_args。
// 期望按构造写死：片元着色器两项绑定 cb0（参数 0）+ 界长表（参数 1，NVN_RB_UBOLEN），池 64 KB：
//   ① cb0 = 池头 4096 字节，整块编：整块 +1；参数 0 = 池头的 GPU 地址 A，界长表 4096 / 16 = 256
//   ② OP_BIND_UBO 把 cb0 换到池头 + 8192、512 字节：打补丁 +1、整块 +0；参数 0 = A + 8192，界长表 512 / 16 = 32（随新绑定重算）
//   ③ 什么都不变再编：复用 +1，参数块就是 ② 那一块
//   ④ 对照：同一状态强制整块重编（args_dirty_all），参数 0 与界长表与 ② 补出来的逐位相同
//   ⑤ 白名单外的着色器（多一项 TEXU：句柄从统一缓冲里读）换 cb0：整块 +1、打补丁 +0
//   ⑥ 换 cb0 的同时换了贴图绑定（g_args_dirty）：整块 +1、打补丁 +0
// 反证：args_ubo_patchable 恒返回 0 → ② 打补丁 +0、整块 +1（红）；补丁不重算界长表 → ② 界长表仍 256（红）
#include "../gfx/nvn/nvn_mtl.m"
#include <sys/mman.h>
static unsigned checks, failures;
#define REQUIRE(c) do { if (!(c)) { fprintf(stderr, "FAIL setup %s:%d: %s\n", __FILE__, __LINE__, #c); exit(1); } } while (0)
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) failures++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
static NvShader *cb_shader(int extra_kind) {
    NvShader *sh = [NvShader new]; sh->stage = 1; sh->arg_len = 24; strcpy(sh->key, "t_args_patch");
    sh->rf.nb = extra_kind ? 3 : 2; sh->rf.b = calloc(3, sizeof *sh->rf.b);
    sh->rf.b[0].kind = NVN_RB_CBUF; sh->rf.b[0].reg = 0; sh->rf.b[0].aid = 0;
    sh->rf.b[1].kind = NVN_RB_UBOLEN; sh->rf.b[1].aid = 1;
    if (extra_kind) { sh->rf.b[2].kind = extra_kind; sh->rf.b[2].reg = 1; sh->rf.b[2].aid = 2; }
    return sh;
}
static uint64_t slot(NvShader *sh, int i) { return ((const uint64_t *)((const uint8_t *)sh->ab_buf.contents + sh->ab_off))[i]; }
static uint32_t table0(NvShader *sh) {
    uint64_t g = slot(sh, 1);
    for (NSArray *list in @[g_sub_arenas, g_arenas]) for (NvArena *a in list) if (g >= a->gpu && g < a->gpu + a->len) return *(const uint32_t *)(a->cpu + (g - a->gpu));
    REQUIRE(!"界长表地址不在任何暂存块里"); return 0;
}
static void bind_cb0(uint64_t addr, uint64_t size) { p_bind_buf b = {1, 0, addr, size}; state_op(OP_BIND_UBO, &b, sizeof b); }
int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IOLBF, 0); alarm(60);
    setenv("DM_NVN_ENC_THREAD", "0", 0); setenv("DM_PRESENT_LINK", "0", 1);
    mtl_init(); arena_begin();
    size_t psz = 65536; uint8_t *pool = mmap(NULL, psz, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); REQUIRE(pool != MAP_FAILED);
    nvn_be_pool_add(pool, psz);
    NvShader *sh = cb_shader(0);
    uint64_t e0 = g_stat_args_enc, p0 = g_stat_args_patch, r0 = g_stat_args_reuse;
    bind_cb0((uint64_t)(uintptr_t)pool, 4096); args_dirty_all(); encode_args(nil, sh, 1, 0);
    uint64_t A = slot(sh, 0);
    VERIFY(g_stat_args_enc == e0 + 1 && table0(sh) == 256, "① 整块编：整块 +%llu（期望 1）、界长表 %u（期望 256）", (unsigned long long)(g_stat_args_enc - e0), table0(sh));
    e0 = g_stat_args_enc; p0 = g_stat_args_patch;
    bind_cb0((uint64_t)(uintptr_t)pool + 8192, 512); encode_args(nil, sh, 1, 0);
    VERIFY(g_stat_args_patch == p0 + 1 && g_stat_args_enc == e0, "② 只换 cb0：打补丁 +%llu、整块 +%llu（期望 1 / 0）", (unsigned long long)(g_stat_args_patch - p0), (unsigned long long)(g_stat_args_enc - e0));
    uint64_t s0 = slot(sh, 0); uint32_t t2 = table0(sh);
    VERIFY(s0 == A + 8192 && t2 == 32, "② 补出来的参数 0 = A + 8192（实差 %lld）、界长表 %u（期望 32）", (long long)(s0 - A), t2);
    r0 = g_stat_args_reuse; id<MTLBuffer> b2 = sh->ab_buf; size_t o2 = sh->ab_off;
    encode_args(nil, sh, 1, 0);
    VERIFY(g_stat_args_reuse == r0 + 1 && sh->ab_buf == b2 && sh->ab_off == o2, "③ 不变再编：复用 +%llu（期望 1）、仍是 ② 那一块", (unsigned long long)(g_stat_args_reuse - r0));
    args_dirty_all(); encode_args(nil, sh, 1, 0);
    VERIFY(slot(sh, 0) == s0 && table0(sh) == t2, "④ 同状态整块重编：参数 0 %s、界长表 %u（与 ② 补出来的 %u 比）", slot(sh, 0) == s0 ? "相同" : "不同", table0(sh), t2);
    NvShader *tu = cb_shader(NVN_RB_TEXU);
    bind_cb0((uint64_t)(uintptr_t)pool, 4096); args_dirty_all(); encode_args(nil, tu, 1, 0);
    e0 = g_stat_args_enc; p0 = g_stat_args_patch;
    bind_cb0((uint64_t)(uintptr_t)pool + 4096, 4096); encode_args(nil, tu, 1, 0);
    VERIFY(g_stat_args_enc == e0 + 1 && g_stat_args_patch == p0, "⑤ 白名单外（带 TEXU）换 cb0：整块 +%llu、打补丁 +%llu（期望 1 / 0）", (unsigned long long)(g_stat_args_enc - e0), (unsigned long long)(g_stat_args_patch - p0));
    encode_args(nil, sh, 1, 0);   // sh 回到当前状态
    e0 = g_stat_args_enc; p0 = g_stat_args_patch;
    bind_cb0((uint64_t)(uintptr_t)pool + 16384, 256); g_args_dirty[1] = 1; encode_args(nil, sh, 1, 0);
    VERIFY(g_stat_args_enc == e0 + 1 && g_stat_args_patch == p0 && slot(sh, 0) == A + 16384, "⑥ 换 cb0 同时别的绑定也变：整块 +%llu、打补丁 +%llu（期望 1 / 0）、参数 0 = A + 16384", (unsigned long long)(g_stat_args_enc - e0), (unsigned long long)(g_stat_args_patch - p0));
    // ⑦ 带 NVN_RB_PUSH / NVN_RB_TEXP 的着色器只换 cb0 走打补丁；同名 push 重复写入不脏 g_args_dirty；改 push 或 g_psnap_gen 前进时退回整块重编
    NvShader *ps = cb_shader(NVN_RB_PUSH); ps->rf.b[2].reg = 0;
    uint32_t pv1[4] = {1, 2, 3, 4}, pv2[4] = {5, 6, 7, 8};
    p_push_const_ptr pp = {.compute = 0, .slot = 0, .offset = 0, .size = sizeof pv1, .data = (uint64_t)(uintptr_t)pv1};
    state_op(OP_PUSH_CONST_PTR, &pp, sizeof pp);
    bind_cb0((uint64_t)(uintptr_t)pool, 4096); args_dirty_all(); encode_args(nil, ps, 1, 0);
    uint64_t push_ptr = slot(ps, 2);
    // 重复写相同 push 字节：不脏 g_args_dirty，再换 cb0 仍走打补丁
    state_op(OP_PUSH_CONST_PTR, &pp, sizeof pp);
    e0 = g_stat_args_enc; p0 = g_stat_args_patch;
    bind_cb0((uint64_t)(uintptr_t)pool + 4096, 512); encode_args(nil, ps, 1, 0);
    VERIFY(g_stat_args_patch == p0 + 1 && g_stat_args_enc == e0 && slot(ps, 2) == push_ptr && slot(ps, 0) == A + 4096,
           "⑦a PUSH 着色器（同值 push + 换 cb0）：打补丁 +%llu、整块 +%llu（期望 1 / 0）、push 槽位保持不变",
           (unsigned long long)(g_stat_args_patch - p0), (unsigned long long)(g_stat_args_enc - e0));
    // 写不同 push 字节：脏 g_args_dirty，退回整块重编并更新 push 槽位
    pp.data = (uint64_t)(uintptr_t)pv2; state_op(OP_PUSH_CONST_PTR, &pp, sizeof pp);
    e0 = g_stat_args_enc; p0 = g_stat_args_patch;
    bind_cb0((uint64_t)(uintptr_t)pool + 8192, 512); encode_args(nil, ps, 1, 0);
    VERIFY(g_stat_args_enc == e0 + 1 && g_stat_args_patch == p0 && slot(ps, 2) != push_ptr,
           "⑦b PUSH 着色器（新值 push + 换 cb0）：整块 +%llu、打补丁 +%llu（期望 1 / 0）、push 槽位更新",
           (unsigned long long)(g_stat_args_enc - e0), (unsigned long long)(g_stat_args_patch - p0));
    // ⑧ 带 NVN_RB_TEXP（贴图池）的着色器：池建表并完成首次 pool_seen_scan 后只换 cb0 走打补丁；g_psnap_gen 或 g_ser_gen 前进时退回整块重编
    NvShader *tp = cb_shader(NVN_RB_TEXP); tp->rf.pool = 1; tp->rf.b[2].dtt = (uint8_t)MTLTextureType2D; tp->rf.b[2].dpf = NVN_DPF_FLOAT;
    bind_cb0((uint64_t)(uintptr_t)pool, 4096); args_dirty_all(); encode_args(nil, tp, 1, 0);   // 建表 0（g_ptab_any 0→1）
    args_dirty_all(); encode_args(nil, tp, 1, 0);   // 同步 pool_seen_scan（g_seen_sub / g_seen_ser）
    uint64_t pool_ptr = slot(tp, 2);
    e0 = g_stat_args_enc; p0 = g_stat_args_patch;
    bind_cb0((uint64_t)(uintptr_t)pool + 4096, 512); encode_args(nil, tp, 1, 0);
    VERIFY(g_stat_args_patch == p0 + 1 && g_stat_args_enc == e0 && slot(tp, 2) == pool_ptr,
           "⑧a TEXP 贴图池着色器只换 cb0：打补丁 +%llu、整块 +%llu（期望 1 / 0）、池地址不变",
           (unsigned long long)(g_stat_args_patch - p0), (unsigned long long)(g_stat_args_enc - e0));
    g_psnap_gen++;
    e0 = g_stat_args_enc; p0 = g_stat_args_patch;
    bind_cb0((uint64_t)(uintptr_t)pool + 8192, 512); encode_args(nil, tp, 1, 0);
    VERIFY(g_stat_args_enc == e0 + 1 && g_stat_args_patch == p0,
           "⑧b TEXP 池快照代号前进后换 cb0：整块 +%llu、打补丁 +%llu（期望 1 / 0）",
           (unsigned long long)(g_stat_args_enc - e0), (unsigned long long)(g_stat_args_patch - p0));
    if (!g_seen_buf) g_seen_buf = [g_dev newBufferWithLength:POOL_SEEN_WORDS * 4 options:MTLResourceStorageModeShared];
    g_seen_sub = g_sub_serial; g_seen_ser = g_ser_gen;
    g_ser_gen++;   // 模拟贴图升级或未写目标刚被渲染遍写入：不能跳过 pool_gpu()
    e0 = g_stat_args_enc; p0 = g_stat_args_patch;
    bind_cb0((uint64_t)(uintptr_t)pool + 12288, 512); encode_args(nil, tp, 1, 0);
    VERIFY(g_stat_args_enc == e0 + 1 && g_stat_args_patch == p0,
           "⑧c TEXP 在 g_ser_gen 前进后换 cb0：不跳过 pool_gpu（整块 +%llu、打补丁 +%llu，期望 1 / 0）",
           (unsigned long long)(g_stat_args_enc - e0), (unsigned long long)(g_stat_args_patch - p0));
  }
    printf("%s t_nvn_args_patch：%u 项，失败 %u\n", failures ? "✗" : "✓", checks, failures); return failures ? 1 : 0;
}
