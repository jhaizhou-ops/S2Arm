// P0-0b 生产入口反例：NVN DrawTexture（OP_DRAW_TEX）必须在 Android Vulkan 回放入口被准确拒绝。
//
// 为什么要有：前端 hle_nvn.c 会把 nvnCommandBufferDrawTexture 记成 p_draw_tex（handle + dst/src
// 两个矩形），而本后端此前没有这个 opcode 的分支，落到 switch default 的通用
// "opcode has no Android Vulkan decoder yet"——日志里既没有 DrawTexture 这个名字，也没有句柄和
// 矩形，现场无法判断缺什么。本测试走**生产入口** s2a_record_exec_one（mtl_vk_adapter 的
// exec_guest 就是它），断言：
//   1) 返回 S2A_RECORD_UNSUPPORTED，result.opcode == OP_DRAW_TEX；
//   2) why 带 opcode 名、handle（纹理/采样器 id）、dst/src 两个矩形，以及“未实现”的原因；
//   3) 截断记录准确报 INVALID，不越界读；
//   4) 生产 draw builder 一次都不被调用（不静默跳过、不假装画了）。
//
// 测试替身边界：本路径在拒绝点之前不碰任何 Vulkan 对象，所以不建 device；链接生产 vk_record.c
// 所需的 vk* 符号由宿主 Vulkan loader 解析（不调用、不开 ICD）。Android 系统头由 tests/hostvk 提供。
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

#include "vk_record.h"
#include "nvn_obj.h"

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

static uint8_t g_guest[256];
static int rd(void *o, uint64_t a, void *b, size_t n) {
    (void)o; if (a + n > sizeof g_guest) return -1; memcpy(b, g_guest + a, n); return 0;
}
static int wr(void *o, uint64_t a, const void *b, size_t n) {
    (void)o; if (a + n > sizeof g_guest) return -1; memcpy(g_guest + a, b, n); return 0;
}

static int g_builder_calls;
static int builder(struct s2a_vk_device *d, const struct s2a_record_draw_state *s,
                   struct s2a_record_result *r, void *opaque) {
    (void)d; (void)s; (void)r; (void)opaque;
    g_builder_calls++;
    return 0;
}

static int g_checks, g_failed;
static void check(int cond, const char *what) {
    g_checks++;
    if (!cond) { g_failed++; fprintf(stderr, "FAIL: %s\n", what); }
}

// 生产记录布局：前端 hle_nvn.c 用 REC(c, OP_DRAW_TEX, p_draw_tex)，长度按 8 字节对齐。
static uint32_t put_draw_tex(uint8_t *pkt, size_t cap, const p_draw_tex *t) {
    uint32_t size = (uint32_t)((sizeof(op_hdr) + sizeof *t + 7u) & ~(size_t)7u);
    if (size > cap) return 0;
    memset(pkt, 0, size);
    op_hdr h = { OP_DRAW_TEX, size };
    memcpy(pkt, &h, sizeof h);
    memcpy(pkt + sizeof h, t, sizeof *t);
    return size;
}

int main(void) {
    struct s2a_vk_device dev;
    memset(&dev, 0, sizeof dev);
    dev.device = (VkDevice)(uintptr_t)1;   // 生产回放入口只要求非空句柄；本路径不调用 Vulkan
    struct s2a_record_memory mem = { NULL, rd, wr };
    s2a_record_set_draw_builder(builder, NULL);
    s2a_record_reset_state();

    // 1) 正常 DrawTexture 记录：句柄与矩形必须原样出现在拒绝原因里。
    {
        p_draw_tex t;
        t.handle = (uint64_t)0x2345u | ((uint64_t)0x67u << 20);   // 纹理 id 0x2345，采样器 id 0x67
        t.dst[0] = 10.0f; t.dst[1] = 20.0f; t.dst[2] = 330.0f; t.dst[3] = 260.0f;
        t.src[0] = 4.0f; t.src[1] = 8.0f; t.src[2] = 644.0f; t.src[3] = 488.0f;
        uint8_t pkt[128];
        uint32_t size = put_draw_tex(pkt, sizeof pkt, &t);
        check(size != 0, "draw-texture record fits");
        struct s2a_record_result r;
        memset(&r, 0, sizeof r);
        int rc = s2a_record_exec_one(&dev, pkt, size, &mem, &r);
        check(rc == S2A_RECORD_UNSUPPORTED, "valid DrawTexture returns S2A_RECORD_UNSUPPORTED");
        check(r.code == S2A_RECORD_UNSUPPORTED, "result.code is S2A_RECORD_UNSUPPORTED");
        check(r.opcode == OP_DRAW_TEX, "result.opcode is OP_DRAW_TEX");
        check(strstr(r.why, "OP_DRAW_TEX") != NULL, "why names the opcode");
        check(strstr(r.why, "handle=0x6702345") != NULL, "why carries the raw handle");
        check(strstr(r.why, "tex=9029") != NULL, "why decodes the texture id");
        check(strstr(r.why, "samp=103") != NULL, "why decodes the sampler id");
        check(strstr(r.why, "dst=(10,20)-(330,260)") != NULL, "why carries the destination rectangle");
        check(strstr(r.why, "src=(4,8)-(644,488)") != NULL, "why carries the source rectangle");
        check(strstr(r.why, "unimplemented") != NULL, "why says DrawTexture is unimplemented");
        check(strstr(r.why, "quad pipeline") != NULL, "why names the missing capability");
        printf("valid record: rc=%d opcode=%u why=%s\n", rc, (unsigned)r.opcode, r.why);
    }

    // 2) 截断记录：准确报 INVALID，不能按 p_draw_tex 越界读。
    {
        uint8_t pkt[16];
        memset(pkt, 0, sizeof pkt);
        op_hdr h = { OP_DRAW_TEX, (uint32_t)sizeof pkt };
        memcpy(pkt, &h, sizeof h);
        struct s2a_record_result r;
        memset(&r, 0, sizeof r);
        int rc = s2a_record_exec_one(&dev, pkt, sizeof pkt, &mem, &r);
        check(rc == S2A_RECORD_INVALID, "truncated DrawTexture returns S2A_RECORD_INVALID");
        check(r.opcode == OP_DRAW_TEX, "truncated result.opcode is OP_DRAW_TEX");
        check(strstr(r.why, "draw-texture payload too small") != NULL, "truncated why names the payload problem");
        printf("truncated record: rc=%d opcode=%u why=%s\n", rc, (unsigned)r.opcode, r.why);
    }

    // 3) 生产 draw builder 一次都不该被调用：拒绝不能变成“跳过并继续画”。
    check(g_builder_calls == 0, "draw builder is never reached for a rejected DrawTexture");

    s2a_record_set_draw_builder(NULL, NULL);
    printf("drawtex-reject: %d checks, %d failed\n", g_checks, g_failed);
    return g_failed ? 1 : 0;
}
