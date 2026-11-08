// P0-0b' 生产入口反例：Deferred 纹理/采样器绑定必须在回放时读游戏内存，不能绑到 id 0。
//
// 为什么要有：前端 hle_nvn.c 的 BindTexturesDeferred / Bind*Deferred 把“游戏句柄数组的地址”
// 记进 p_bind_handles（defer=1、src=指针，h[n] 之后追加录制时的池基址 p_bind_pool_bases），
// 语义是 GPU 执行到这条命令时才读那块内存（录制后游戏还会改写句柄）。回放此前不看 defer/src，
// 直接用记录里被清零的 h[]，于是所有 Deferred 纹理/采样器都绑到 id 0（静默绑错纹理，比拒绝危险）。
// Metal 侧对应 nvn_mtl.m 的 bh_fresh（读 src、再把 id 平移到池基址）。
//
// 本测试走**生产入口** s2a_record_exec_one（mtl_vk_adapter 的 exec_guest 就是它），并通过生产
// 接缝 s2a_record_set_draw_builder 读 draw 快照里的 tex_handle/samp_handle（后端真正消费的那份）：
//   1) Deferred 记录与“已经平移到池基址的普通绑定”得到同一快照（等价对照）；
//   2) 记录构造后改写游戏内存，回放必须用改写后的值（证明是执行时读，不是录制备份）；
//   3) 源地址不可读 / 记录缺池基址 / 缺源地址：准确拒绝，且 draw builder 不被调用；
//   4) 普通（非 Deferred）绑定行为不变。
//   5) replay 自己的命令缓冲分支（无 draw builder）上 RESET_COUNTER + DRAW：查询页必须在取命令缓冲
//      之前准备好，不得报 “query page full inside one render pass”（生产 nvn_vk_query prepare 契约）。
//
// 测试替身边界：第 1–7 节的 opcode 只改 CPU 记录状态，不碰 Vulkan 对象（链接所需的 vk* 由宿主
// Vulkan loader 解析，不建 device、不开 ICD）；第 8 节显式走 replay 的 draw 分支，用文件内替身
// 提供它实际调用的 Vulkan 入口（不建真 device、不仿真驱动语义）。Android 系统头由 tests/hostvk 提供。
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "vk_record.h"
#include "nvn_obj.h"
#include "nvn_vk_query.h"   // 第 8 节：replay 的查询页顺序回归要读 query 统计（slots/segments）

// ---- 宿主替身：Android 日志 / 系统属性 / 显存类型选择（本路径不调用，只有链接需要）----
int __android_log_print(int prio, const char *tag, const char *fmt, ...) {
    (void)prio; (void)tag;
    va_list ap; va_start(ap, fmt); vfprintf(stderr, fmt, ap); va_end(ap); fputc('\n', stderr);
    return 0;
}
int __system_property_get(const char *name, char *value) { (void)name; if (value) value[0] = 0; return 0; }
uint32_t s2a_vk_memory_type(const struct s2a_vk_device *d, uint32_t bits,
                            VkMemoryPropertyFlags req, VkMemoryPropertyFlags *actual) {
    (void)d; (void)bits; (void)req; if (actual) *actual = 0; return 0;
}

// 程序绑定的最小快照（生产 compact 记录经 nvn_prog_snap_get 还原；这里只给 draw 闸门要的 stage 0）。
const prog_t *nvn_prog_snap_get(uint64_t serial, uint8_t keys[6][8], uint8_t *ok, uint8_t stage[6]) {
    static prog_t p;
    memset(&p, 0, sizeof p);
    p.serial = serial;
    memset(stage, 0xff, 6); stage[0] = 0;
    *ok = 1;
    memset(keys, 0xAB, 48);
    return &p;
}

static uint8_t g_guest[4096];
static int rd(void *o, uint64_t a, void *b, size_t n) {
    (void)o; if (a + n > sizeof g_guest) return -1; memcpy(b, g_guest + a, n); return 0;
}
static int wr(void *o, uint64_t a, const void *b, size_t n) {
    (void)o; if (a + n > sizeof g_guest) return -1; memcpy(g_guest + a, b, n); return 0;
}

static struct s2a_record_draw_state g_cap;
static int g_builder_calls;
static int builder(struct s2a_vk_device *d, const struct s2a_record_draw_state *s,
                   struct s2a_record_result *r, void *opaque) {
    (void)d; (void)r; (void)opaque;
    g_builder_calls++;
    g_cap = *s;
    return 0;
}

static int g_checks, g_failed;
static void check(int cond, const char *what) {
    g_checks++;
    if (!cond) { g_failed++; fprintf(stderr, "FAIL: %s\n", what); }
}

// 生产记录布局（与 hle_nvn.c 的 bind_handles / bind_handles_deferred 逐字节一致）：
//   普通：{stage,first,n,defer=0,src=0,h[n]}；Deferred：多 8 字节池基址，src 指向游戏里的句柄数组。
static size_t put_bind(uint8_t *pkt, size_t cap, uint32_t op, int32_t stage, int32_t first, int32_t n,
                       const uint64_t *h, int defer, uint64_t src, int32_t tbase, int32_t sbase) {
    size_t payload = offsetof(p_bind_handles, h) + 8u * (size_t)n +
                     (defer ? sizeof(p_bind_pool_bases) : 0);
    size_t size = (sizeof(op_hdr) + payload + 7u) & ~(size_t)7u;
    if (size > cap) return 0;
    memset(pkt, 0, size);
    op_hdr hd = { op, (uint32_t)size };
    memcpy(pkt, &hd, sizeof hd);
    p_bind_handles r;
    memset(&r, 0, sizeof r);
    r.stage = stage; r.first = first; r.n = n; r.defer = defer; r.src = src;
    if (h && !defer) memcpy(r.h, h, 8u * (size_t)n);
    memcpy(pkt + sizeof hd, &r, offsetof(p_bind_handles, h) + 8u * (size_t)n);
    if (defer) {
        p_bind_pool_bases bases = { tbase, sbase };
        memcpy(pkt + sizeof hd + offsetof(p_bind_handles, h) + 8u * (size_t)n, &bases, sizeof bases);
    }
    return size;
}

static struct s2a_vk_device g_dev;
static struct s2a_record_memory g_mem = { NULL, rd, wr };

static int bind_program(void) {
    uint8_t pkt[64];
    size_t size = sizeof(op_hdr) + sizeof(p_bind_program_id);
    memset(pkt, 0, sizeof pkt);
    op_hdr hd = { OP_BIND_PROGRAM, (uint32_t)size };
    memcpy(pkt, &hd, sizeof hd);
    p_bind_program_id id = { (const prog_t *)(uintptr_t)0x1000, 7, 1, 0 };
    memcpy(pkt + sizeof hd, &id, sizeof id);
    struct s2a_record_result r;
    memset(&r, 0, sizeof r);
    return s2a_record_exec_one(&g_dev, pkt, size, &g_mem, &r);
}

// 一笔最小普通绘制：走生产 draw builder 分支，把当前绑定状态交给 builder（后端消费的就是它）。
static int draw_and_capture(void) {
    uint8_t pkt[64];
    size_t size = sizeof(op_hdr) + offsetof(p_draw, ind);
    memset(pkt, 0, sizeof pkt);
    op_hdr hd = { OP_DRAW, (uint32_t)size };
    memcpy(pkt, &hd, sizeof hd);
    p_draw d;
    memset(&d, 0, sizeof d);
    d.prim = 4; d.count = 3; d.instances = 1;
    memcpy(pkt + sizeof hd, &d, offsetof(p_draw, ind));
    struct s2a_record_result r;
    memset(&r, 0, sizeof r);
    int rc = s2a_record_exec_one(&g_dev, pkt, size, &g_mem, &r);
    if (rc) fprintf(stderr, "draw_and_capture: rc=%d why=%s\n", rc, r.why);
    return rc;
}

static void reset(void) {
    s2a_record_reset_state();
    memset(&g_cap, 0, sizeof g_cap);
    g_builder_calls = 0;
    memset(g_guest, 0, sizeof g_guest);
    check(bind_program() == 0, "bind program succeeds");
}

// ---- 第 8 节（replay 的查询页顺序）用的 Vulkan 替身 ----
// 背景：没有注册 draw builder 时，OP_DRAW 走 replay 自己的命令缓冲分支（通用回放路径）。该分支在
// “RESET_COUNTER 之后的第一笔 DRAW”上必须与直连 first_draw.c:2924→2958 同一顺序：
//   nvn_vk_query_prepare（页选择/回收；页耗尽回收可能在提交边界 flush）
//   → 取得命令缓冲并 vkBeginCommandBuffer → nvn_vk_query_cb_begin（只在缓冲开头录 vkCmdResetQueryPool）。
// 修前 replay 取完缓冲后才调 cb_begin，页从未建立，draw_begin 命中 p->used >= p->cap，报
// “query page full inside one render pass”。下面只仿真该分支实际调用的 Vulkan 入口（不建 device、
// 不仿真驱动语义）；其余 vk* 仍由宿主 loader 解析（本用例不调用它们）。
static int g_vk_seq, g_cmd_alloc_seq, g_reset_seq, g_pool_create_seq, g_query_begins, g_replay_draws;
static uintptr_t g_cmd_handle, g_query_pool_handle;
VKAPI_ATTR VkResult VKAPI_CALL vkAllocateCommandBuffers(VkDevice d, const VkCommandBufferAllocateInfo *i, VkCommandBuffer *p) {
    (void)d; (void)i; g_cmd_alloc_seq = ++g_vk_seq; g_cmd_handle++; *p = (VkCommandBuffer)g_cmd_handle; return VK_SUCCESS;
}
VKAPI_ATTR VkResult VKAPI_CALL vkBeginCommandBuffer(VkCommandBuffer c, const VkCommandBufferBeginInfo *i) { (void)c; (void)i; return VK_SUCCESS; }
VKAPI_ATTR VkResult VKAPI_CALL vkEndCommandBuffer(VkCommandBuffer c) { (void)c; return VK_SUCCESS; }
VKAPI_ATTR void VKAPI_CALL vkFreeCommandBuffers(VkDevice d, VkCommandPool p, uint32_t n, const VkCommandBuffer *c) {
    (void)d; (void)p; (void)n; (void)c;
}
VKAPI_ATTR VkResult VKAPI_CALL vkCreateFence(VkDevice d, const VkFenceCreateInfo *i, const VkAllocationCallbacks *a, VkFence *f) {
    (void)d; (void)i; (void)a; *f = (VkFence)(uintptr_t)0xF0; return VK_SUCCESS;
}
VKAPI_ATTR void VKAPI_CALL vkDestroyFence(VkDevice d, VkFence f, const VkAllocationCallbacks *a) { (void)d; (void)f; (void)a; }
VKAPI_ATTR VkResult VKAPI_CALL vkQueueSubmit(VkQueue q, uint32_t n, const VkSubmitInfo *s, VkFence f) {
    (void)q; (void)n; (void)s; (void)f; return VK_SUCCESS;
}
VKAPI_ATTR VkResult VKAPI_CALL vkWaitForFences(VkDevice d, uint32_t n, const VkFence *f, VkBool32 w, uint64_t t) {
    (void)d; (void)n; (void)f; (void)w; (void)t; return VK_SUCCESS;
}
VKAPI_ATTR VkResult VKAPI_CALL vkCreateQueryPool(VkDevice d, const VkQueryPoolCreateInfo *i, const VkAllocationCallbacks *a, VkQueryPool *p) {
    (void)d; (void)i; (void)a; g_pool_create_seq = ++g_vk_seq;
    ++g_query_pool_handle; *p = (VkQueryPool)g_query_pool_handle; return VK_SUCCESS;
}
VKAPI_ATTR void VKAPI_CALL vkCmdResetQueryPool(VkCommandBuffer c, VkQueryPool p, uint32_t a, uint32_t n) {
    (void)c; (void)p; (void)a; (void)n; g_reset_seq = ++g_vk_seq;
}
VKAPI_ATTR void VKAPI_CALL vkCmdBeginQuery(VkCommandBuffer c, VkQueryPool p, uint32_t q, VkQueryControlFlags f) {
    (void)c; (void)p; (void)q; (void)f; g_query_begins++;
}
VKAPI_ATTR void VKAPI_CALL vkCmdEndQuery(VkCommandBuffer c, VkQueryPool p, uint32_t q) { (void)c; (void)p; (void)q; }
VKAPI_ATTR void VKAPI_CALL vkCmdBeginRenderPass(VkCommandBuffer c, const VkRenderPassBeginInfo *i, VkSubpassContents s) { (void)c; (void)i; (void)s; }
VKAPI_ATTR void VKAPI_CALL vkCmdEndRenderPass(VkCommandBuffer c) { (void)c; }
VKAPI_ATTR void VKAPI_CALL vkCmdBindPipeline(VkCommandBuffer c, VkPipelineBindPoint b, VkPipeline p) { (void)c; (void)b; (void)p; }
VKAPI_ATTR void VKAPI_CALL vkCmdDraw(VkCommandBuffer c, uint32_t v, uint32_t i, uint32_t f, uint32_t fi) {
    (void)c; (void)v; (void)i; (void)f; (void)fi; g_replay_draws++;
}

// T2T replay: fake Vulkan records arguments; no real driver or pixels are claimed.
static int g_t2t_copies, g_t2t_blits, g_t2t_written, g_t2t_bad_layout;
static VkImageCopy g_t2t_region;
VKAPI_ATTR void VKAPI_CALL vkCmdPipelineBarrier(VkCommandBuffer c, VkPipelineStageFlags a, VkPipelineStageFlags b,
        VkDependencyFlags f, uint32_t mc, const VkMemoryBarrier *m, uint32_t bc, const VkBufferMemoryBarrier *bb,
        uint32_t ic, const VkImageMemoryBarrier *ib) {
    (void)c; (void)a; (void)b; (void)f; (void)mc; (void)m; (void)bc; (void)bb;
    for (uint32_t i = 0; i < ic; i++) if (ib[i].oldLayout != VK_IMAGE_LAYOUT_GENERAL) g_t2t_bad_layout++;
}
VKAPI_ATTR void VKAPI_CALL vkCmdCopyImage(VkCommandBuffer c, VkImage src, VkImageLayout sl,
        VkImage dst, VkImageLayout dl, uint32_t n, const VkImageCopy *r) {
    (void)c; (void)src; (void)sl; (void)dst; (void)dl;
    if (n == 1) { g_t2t_copies++; g_t2t_region = *r; }
}
VKAPI_ATTR void VKAPI_CALL vkCmdBlitImage(VkCommandBuffer c, VkImage src, VkImageLayout sl,
        VkImage dst, VkImageLayout dl, uint32_t n, const VkImageBlit *r, VkFilter f) {
    (void)c; (void)src; (void)sl; (void)dst; (void)dl; (void)r; (void)f;
    if (n == 1) g_t2t_blits++;
}
VKAPI_ATTR void VKAPI_CALL vkCmdResolveImage(VkCommandBuffer c, VkImage src, VkImageLayout sl,
        VkImage dst, VkImageLayout dl, uint32_t n, const VkImageResolve *r) {
    (void)c; (void)src; (void)sl; (void)dst; (void)dl; (void)n; (void)r;
}
VKAPI_ATTR void VKAPI_CALL vkGetPhysicalDeviceFormatProperties(VkPhysicalDevice d, VkFormat f, VkFormatProperties *p) {
    (void)d; (void)f; memset(p, 0, sizeof *p);
    p->optimalTilingFeatures = VK_FORMAT_FEATURE_BLIT_SRC_BIT | VK_FORMAT_FEATURE_BLIT_DST_BIT |
                               VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT;
}
void s2a_vk_adapter_mark_written(VkImage image) { if (image == (VkImage)(uintptr_t)0x22) g_t2t_written++; }

// 一条“SetRT → BindProgram → ResetCounter → Draw”的最小记录流（与 hle_nvn.c 的记录布局一致）。
// 返回记录总字节数；0 = 缓冲区不够。SET_RT 只带 1 个颜色目标、无视图/深度（快照区留零，读端按指针还原）。
static size_t build_query_replay_stream(uint8_t *buf, size_t cap, const tex_t *rt) {
    size_t at = 0;
    {
        p_set_rt sr;
        memset(&sr, 0, sizeof sr);
        sr.n = 1; sr.color[0] = rt;
        size_t payload = set_rt_size(&sr);
        size_t size = (sizeof(op_hdr) + payload + 7u) & ~(size_t)7u;
        if (size > cap) return 0;
        memset(buf + at, 0, size);
        op_hdr h = { OP_SET_RT, (uint32_t)size };
        memcpy(buf + at, &h, sizeof h);
        set_rt_put(buf + at + sizeof h, &sr);
        at += size;
    }
    {
        size_t size = sizeof(op_hdr) + sizeof(p_bind_program_id);
        if (at + size > cap) return 0;
        op_hdr h = { OP_BIND_PROGRAM, (uint32_t)size };
        p_bind_program_id id = { (const prog_t *)(uintptr_t)0x1000, 7, 1, 0 };
        memcpy(buf + at, &h, sizeof h);
        memcpy(buf + at + sizeof h, &id, sizeof id);
        at += size;
    }
    {
        // OP_RESET_COUNTER(SAMPLES_PASSED)：payload 8 字节，记录长 16（同生产 put_counter）。
        size_t size = 16;
        if (at + size > cap) return 0;
        op_hdr h = { OP_RESET_COUNTER, (uint32_t)size };
        uint64_t type = 1;   // NVN_COUNTER_TYPE_SAMPLES_PASSED
        memcpy(buf + at, &h, sizeof h);
        memcpy(buf + at + sizeof h, &type, sizeof type);
        at += size;
    }
    {
        size_t payload = (sizeof(p_draw) + 7u) & ~(size_t)7u;
        size_t size = sizeof(op_hdr) + payload;
        if (at + size > cap) return 0;
        memset(buf + at, 0, size);
        op_hdr h = { OP_DRAW, (uint32_t)size };
        p_draw d;
        memset(&d, 0, sizeof d);
        d.prim = 4; d.count = 3; d.instances = 1;
        memcpy(buf + at, &h, sizeof h);
        memcpy(buf + at + sizeof h, &d, sizeof d);
        at += size;
    }
    {
        op_hdr h = { OP_END, sizeof h };
        if (at + sizeof h > cap) return 0;
        memcpy(buf + at, &h, sizeof h);
        at += sizeof h;
    }
    return at;
}

int main(void) {
    memset(&g_dev, 0, sizeof g_dev);
    g_dev.device = (VkDevice)(uintptr_t)1;   // 生产回放入口只要求非空句柄；这些 opcode 不调用 Vulkan
    s2a_record_set_draw_builder(builder, NULL);

    // 1) Deferred 纹理绑定 == 已平移的普通绑定（等价对照）。池基址 {0x100, 0x200}。
    //    句柄: h0 = tid 5 / 无采样器；h1 = tid 7 / sampler 3。
    const uint64_t expect_tex0 = 5u + 0x100u;
    const uint64_t expect_tex1 = (7u + 0x100u) | ((uint64_t)(3u + 0x200u) << 20);
    uint64_t cap_deferred[2] = {0, 0}, cap_plain[2] = {0, 0};
    {
        reset();
        uint64_t handles[2] = { 5u, 7u | ((uint64_t)3u << 20) };
        memcpy(g_guest + 0x200, handles, sizeof handles);
        uint8_t pkt[128];
        size_t size = put_bind(pkt, sizeof pkt, OP_BIND_TEX, 0, 0, 2, NULL, 1, 0x200, 0x100, 0x200);
        check(size != 0, "deferred texture record fits");
        struct s2a_record_result r;
        memset(&r, 0, sizeof r);
        int rc = s2a_record_exec_one(&g_dev, pkt, size, &g_mem, &r);
        check(rc == 0, "deferred texture bind replays");
        check(draw_and_capture() == 0, "draw after deferred texture bind");
        cap_deferred[0] = g_cap.tex_handle[0][0];
        cap_deferred[1] = g_cap.tex_handle[0][1];
        check(g_cap.tex_present[0][0] == 1 && g_cap.tex_present[0][1] == 1,
              "deferred texture slots are present");
        printf("deferred tex: [0]=0x%llx [1]=0x%llx (expect 0x%llx / 0x%llx)\n",
               (unsigned long long)cap_deferred[0], (unsigned long long)cap_deferred[1],
               (unsigned long long)expect_tex0, (unsigned long long)expect_tex1);
        check(cap_deferred[0] == expect_tex0, "deferred texture 0 gets texture-pool base, not id 0");
        check(cap_deferred[1] == expect_tex1, "deferred texture 1 gets texture+sampler pool bases");
    }
    {
        reset();
        uint64_t handles[2] = { expect_tex0, expect_tex1 };
        uint8_t pkt[128];
        size_t size = put_bind(pkt, sizeof pkt, OP_BIND_TEX, 0, 0, 2, handles, 0, 0, 0, 0);
        check(size != 0, "plain texture record fits");
        struct s2a_record_result r;
        memset(&r, 0, sizeof r);
        check(s2a_record_exec_one(&g_dev, pkt, size, &g_mem, &r) == 0, "plain texture bind replays");
        check(draw_and_capture() == 0, "draw after plain texture bind");
        cap_plain[0] = g_cap.tex_handle[0][0];
        cap_plain[1] = g_cap.tex_handle[0][1];
        printf("plain tex:    [0]=0x%llx [1]=0x%llx\n",
               (unsigned long long)cap_plain[0], (unsigned long long)cap_plain[1]);
        check(cap_plain[0] == cap_deferred[0] && cap_plain[1] == cap_deferred[1],
              "deferred binding equals the pre-offset plain binding");
    }

    // 2) 执行时读：记录构造后把游戏内存改成另一组句柄，回放必须用新值。
    {
        reset();
        uint64_t before[1] = { 5u }, after[1] = { 9u };
        memcpy(g_guest + 0x300, before, sizeof before);
        uint8_t pkt[128];
        size_t size = put_bind(pkt, sizeof pkt, OP_BIND_TEX, 0, 0, 1, NULL, 1, 0x300, 0x40, 0);
        check(size != 0, "deferred read-at-exec record fits");
        memcpy(g_guest + 0x300, after, sizeof after);   // 录制后改写（NVN 的 Deferred 语义）
        struct s2a_record_result r;
        memset(&r, 0, sizeof r);
        check(s2a_record_exec_one(&g_dev, pkt, size, &g_mem, &r) == 0, "deferred read-at-exec bind replays");
        check(draw_and_capture() == 0, "draw after read-at-exec bind");
        printf("read-at-exec: [0]=0x%llx (expect 0x%x)\n",
               (unsigned long long)g_cap.tex_handle[0][0], 9 + 0x40);
        check(g_cap.tex_handle[0][0] == (9u + 0x40u), "deferred handles are read when the command executes");
    }

    // 3) Deferred 独立采样器：句柄只带 sampler id，只加采样器池基址。
    {
        reset();
        uint64_t handles[1] = { (uint64_t)5u << 20 };
        memcpy(g_guest + 0x400, handles, sizeof handles);
        uint8_t pkt[128];
        size_t size = put_bind(pkt, sizeof pkt, OP_BIND_SAMP, 0, 0, 1, NULL, 1, 0x400, 0, 0x30);
        check(size != 0, "deferred sampler record fits");
        struct s2a_record_result r;
        memset(&r, 0, sizeof r);
        check(s2a_record_exec_one(&g_dev, pkt, size, &g_mem, &r) == 0, "deferred sampler bind replays");
        check(draw_and_capture() == 0, "draw after deferred sampler bind");
        printf("deferred samp: [0]=0x%llx (expect 0x%llx)\n",
               (unsigned long long)g_cap.samp_handle[0][0],
               (unsigned long long)((5u + 0x30u) << 20));
        check(g_cap.samp_present[0][0] == 1, "deferred sampler slot is present");
        check(g_cap.samp_handle[0][0] == ((5u + 0x30u) << 20), "deferred sampler gets sampler-pool base");
    }

    // 4) 源地址不可读：准确拒绝，draw builder 不被调用。
    {
        reset();
        uint8_t pkt[128];
        size_t size = put_bind(pkt, sizeof pkt, OP_BIND_TEX, 0, 0, 1, NULL, 1, 0xFFFFFFF0u, 0x100, 0);
        check(size != 0, "unreadable-source record fits");
        struct s2a_record_result r;
        memset(&r, 0, sizeof r);
        int rc = s2a_record_exec_one(&g_dev, pkt, size, &g_mem, &r);
        printf("unreadable: rc=%d why=%s\n", rc, r.why);
        check(rc == S2A_RECORD_MEMORY, "unreadable deferred source returns S2A_RECORD_MEMORY");
        check(strstr(r.why, "unreadable") != NULL, "unreadable why names the problem");
        check(g_builder_calls == 0, "unreadable deferred bind does not reach the draw builder");
    }

    // 5) 记录缺池基址：准确拒绝（不能按 0 基址继续）。
    {
        reset();
        uint8_t pkt[128];
        size_t full = put_bind(pkt, sizeof pkt, OP_BIND_TEX, 0, 0, 1, NULL, 1, 0x200, 0x100, 0x200);
        check(full != 0, "deferred record fits for missing-bases case");
        size_t short_size = sizeof(op_hdr) + offsetof(p_bind_handles, h) + 8u;   // 丢掉末尾 8 字节基址
        check(short_size < full, "short record is shorter than the full one");
        op_hdr hd = { OP_BIND_TEX, (uint32_t)short_size };
        memcpy(pkt, &hd, sizeof hd);
        memset(pkt + sizeof hd + offsetof(p_bind_handles, h), 0, 8);   // 句柄字段清零，避免读旧内容
        struct s2a_record_result r;
        memset(&r, 0, sizeof r);
        int rc = s2a_record_exec_one(&g_dev, pkt, short_size, &g_mem, &r);
        printf("missing bases: rc=%d why=%s\n", rc, r.why);
        check(rc == S2A_RECORD_INVALID, "deferred record without pool bases returns S2A_RECORD_INVALID");
        check(strstr(r.why, "pool bases") != NULL, "missing-bases why names the missing field");
    }

    // 6) 缺源地址：准确拒绝。
    {
        reset();
        uint8_t pkt[128];
        size_t size = put_bind(pkt, sizeof pkt, OP_BIND_TEX, 0, 0, 1, NULL, 1, 0, 0x100, 0x200);
        check(size != 0, "null-source record fits");
        struct s2a_record_result r;
        memset(&r, 0, sizeof r);
        int rc = s2a_record_exec_one(&g_dev, pkt, size, &g_mem, &r);
        printf("null source: rc=%d why=%s\n", rc, r.why);
        check(rc == S2A_RECORD_INVALID, "deferred bind without source returns S2A_RECORD_INVALID");
        check(strstr(r.why, "source address") != NULL, "null-source why names the missing field");
    }

    // 7) 普通绑定回归：非 Deferred 记录行为不变。
    {
        reset();
        uint64_t handles[1] = { (uint64_t)0x1234u | ((uint64_t)0x7u << 20) };
        uint8_t pkt[128];
        size_t size = put_bind(pkt, sizeof pkt, OP_BIND_TEX, 0, 0, 1, handles, 0, 0, 0, 0);
        check(size != 0, "plain record fits");
        struct s2a_record_result r;
        memset(&r, 0, sizeof r);
        check(s2a_record_exec_one(&g_dev, pkt, size, &g_mem, &r) == 0, "plain bind still replays");
        check(draw_and_capture() == 0, "draw after plain bind");
        check(g_cap.tex_handle[0][0] == handles[0], "plain binding keeps its handles unchanged");
    }

    // 8) replay 的查询页顺序回归（通用回放路径）：RESET_COUNTER 之后的 DRAW 必须先把查询页准备好
    //    （prepare 在取命令缓冲之前）才能 cb_begin/draw_begin。修前 replay 取完缓冲才 cb_begin，
    //    页从未建立，draw_begin 命中 p->used >= p->cap，报 “query page full inside one render pass”。
    //    门禁 nvn_vk_query_edges.sh 只覆盖 query 模块本身；这里才真正走生产 s2a_record_replay 的 draw 分支。
    s2a_record_set_draw_builder(NULL, NULL);   // 走 replay 自己的命令缓冲分支（不带 draw builder）
    {
        struct s2a_vk_device qdev;
        memset(&qdev, 0, sizeof qdev);
        qdev.device = (VkDevice)(uintptr_t)1;
        qdev.queue = (VkQueue)(uintptr_t)2;
        qdev.command_pool = (VkCommandPool)(uintptr_t)3;
        qdev.core_features.occlusionQueryPrecise = VK_TRUE;   // prepare 的前置门：精确遮挡查询
        static tex_t rt_tex;
        memset(&rt_tex, 0, sizeof rt_tex);
        _Alignas(8) uint8_t stream[512];
        size_t len = build_query_replay_stream(stream, sizeof stream, &rt_tex);
        check(len != 0, "query replay stream fits");
        struct s2a_replay_draw draws[1];
        memset(draws, 0, sizeof draws);
        draws[0].program_key = (const void *)(uintptr_t)0x1000;   // 与 BIND_PROGRAM 记录的 prog 身份一致
        draws[0].rt_key = &rt_tex;                                // 与 SET_RT 记录的颜色目标一致
        draws[0].pipeline = (VkPipeline)(uintptr_t)0x10;
        draws[0].render_pass = (VkRenderPass)(uintptr_t)0x20;
        draws[0].framebuffer = (VkFramebuffer)(uintptr_t)0x30;
        draws[0].extent.width = 64; draws[0].extent.height = 64;
        g_vk_seq = g_cmd_alloc_seq = g_reset_seq = g_pool_create_seq = 0;
        g_query_begins = g_replay_draws = 0;
        struct s2a_record_result r;
        memset(&r, 0, sizeof r);
        int rc = s2a_record_replay(&qdev, stream, stream + len, &g_mem, NULL, 0, draws, 1, NULL, 0, &r);
        struct nvn_vk_query_stats qst;
        memset(&qst, 0, sizeof qst);
        nvn_vk_query_stats(&qst);
        printf("query replay: rc=%d why=%s slots=%llu segments=%llu begins=%d draws=%d "
               "seq(pool_create/cmd_alloc/reset)=%d/%d/%d\n",
               rc, r.why, (unsigned long long)qst.slots, (unsigned long long)qst.segments,
               g_query_begins, g_replay_draws, g_pool_create_seq, g_cmd_alloc_seq, g_reset_seq);
        check(rc == 0, "replay RESET_COUNTER+DRAW succeeds (query page prepared before the command buffer)");
        check(strstr(r.why, "query page full") == NULL,
              "replay no longer reports 'query page full inside one render pass'");
        check(qst.slots == 1 && qst.segments == 1, "exactly one occlusion query segment was recorded");
        check(g_query_begins == 1 && g_replay_draws == 1, "one begin-query and one draw reached Vulkan");
        // prepare 里建立查询页（vkCreateQueryPool）必须在取命令缓冲（vkAllocateCommandBuffers）之前：
        // replay 的页选择/回收可以 flush 帧队列，命令缓冲一旦 vkBeginCommandBuffer 就不能再被提交/续录。
        check(g_pool_create_seq > 0 && g_pool_create_seq < g_cmd_alloc_seq,
              "query page was created before the command buffer was acquired (prepare before begin_command)");
        check(g_cmd_alloc_seq > 0 && g_reset_seq > g_cmd_alloc_seq,
              "vkCmdResetQueryPool is recorded after the command buffer started (cb_begin order)");
    }

    // Real production replay entry, with view + engine hint and a partial region.
    // The Vulkan calls above are test doubles; neither pixels nor a device are verified.
    {
        struct s2a_vk_device d = {0};
        d.device = (VkDevice)(uintptr_t)1; d.queue = (VkQueue)(uintptr_t)2;
        d.command_pool = (VkCommandPool)(uintptr_t)3; d.physical = (VkPhysicalDevice)(uintptr_t)4;
        tex_t src_tex = {0}, dst_tex = {0};
        struct s2a_replay_texture tex[2] = {
            {.key=&src_tex, .image=(VkImage)(uintptr_t)0x11,
             .format=VK_FORMAT_R8G8B8A8_UNORM, .width=8, .height=8, .depth=1, .levels=1, .layers=1},
            {.key=&dst_tex, .image=(VkImage)(uintptr_t)0x22,
             .format=VK_FORMAT_R8G8B8A8_UNORM, .width=8, .height=8, .depth=1, .levels=1, .layers=1}
        };
        p_copy_t2t copy = {0};
        copy.src = tex[0].key; copy.dst = tex[1].key; copy.flags = 2; copy.has_sv = 1;
        copy.sr = (NVNcopyRegion){1, 2, 0, 4, 3, 1}; copy.dr = (NVNcopyRegion){2, 1, 0, 4, 3, 1};
        _Alignas(8) uint8_t pkt[sizeof(op_hdr) + ((sizeof(p_copy_t2t) + 7) & ~(size_t)7) + sizeof(op_hdr)] = {0};
        const size_t size = sizeof pkt - sizeof(op_hdr);
        op_hdr h = {OP_COPY_T2T, (uint32_t)size}, end = {OP_END, sizeof(op_hdr)};
        memcpy(pkt, &h, sizeof h); memcpy(pkt + sizeof h, &copy, sizeof copy); memcpy(pkt + size, &end, sizeof end);
        struct s2a_record_result r = {0};
        g_t2t_copies = g_t2t_written = g_t2t_bad_layout = 0;
        int rc = s2a_record_replay(&d, pkt, pkt + sizeof pkt, &g_mem, tex, 2, NULL, 0, NULL, 0, &r);
        printf("T2T view+flag replay rc=%d why=%s copies=%d written=%d\n", rc, r.why, g_t2t_copies, g_t2t_written);
        check(rc == 0, "T2T view+flag reaches supported copy");
        check(g_t2t_copies == 1 && g_t2t_written == 1, "one copy and destination GPU-write registration");
        check(g_t2t_region.srcOffset.x == 1 && g_t2t_region.srcOffset.y == 2 &&
              g_t2t_region.dstOffset.x == 2 && g_t2t_region.dstOffset.y == 1 &&
              g_t2t_region.extent.width == 4 && g_t2t_region.extent.height == 3,
              "T2T recorded subregion passed to Vulkan");
        check(g_t2t_bad_layout == 0, "T2T barriers preserve existing image contents");
        copy.flags = 0x80; memcpy(pkt + sizeof h, &copy, sizeof copy);
        g_t2t_copies = g_t2t_written = 0;
        rc = s2a_record_replay(&d, pkt, pkt + sizeof pkt, &g_mem, tex, 2, NULL, 0, NULL, 0, &r);
        check(rc == S2A_RECORD_UNSUPPORTED && g_t2t_copies == 0 && g_t2t_written == 0,
              "unknown T2T flag is rejected without executing or marking writes");
    }

    s2a_record_set_draw_builder(NULL, NULL);
    printf("deferred-bind: %d checks, %d failed\n", g_checks, g_failed);
    return g_failed ? 1 : 0;
}
