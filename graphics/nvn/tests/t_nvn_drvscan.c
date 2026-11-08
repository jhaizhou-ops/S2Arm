// nvn_drvscan.h：从游戏 sdk 模块里的驱动 nvnDeviceGetInteger 读 API 版本、从驱动 nvnTextureGetNvRmSurfaceNVX 读 RGBA8 的 NvColorFormat。指令按 ARMv8 编码手拼（不抄游戏字节），
// 期望值就是拼进去的立即数；NvColorFormat 换编码的期望值按「颜色空间 + 差、16–31 位左移」手算
#include <stdio.h>
#include <stdlib.h>
#include "nvn_drvscan.h"
static unsigned checks;
#define CHECK(c) do { checks++; if (!(c)) { fprintf(stderr, "t_nvn_drvscan:%d 失败：%s\n", __LINE__, #c); exit(1); } } while (0)
static uint8_t img[0x4000];
static void put(size_t o, uint32_t w) { memcpy(img + o, &w, 4); }
static uint32_t movz_w(int rd, int imm) { return 0x52800000u | (uint32_t)imm << 5 | (uint32_t)rd; }
static uint32_t cmp_w(int rn, int imm) { return 0x7100001fu | (uint32_t)imm << 10 | (uint32_t)rn << 5; }
static uint32_t bhi(int words) { return 0x54000008u | ((uint32_t)words & 0x7ffff) << 5; }
static uint32_t adrp(int rd, size_t pc, size_t target) { int64_t d = ((int64_t)(target & ~0xfffu) - (int64_t)(pc & ~0xfffu)) >> 12; return 0x90000000u | ((uint32_t)d & 3) << 29 | ((uint32_t)(d >> 2) & 0x7ffff) << 5 | (uint32_t)rd; }
static uint32_t add_imm(int rd, int rn, int imm) { return 0x91000000u | (uint32_t)imm << 10 | (uint32_t)rn << 5 | (uint32_t)rd; }
static uint32_t adr(int rd, size_t pc, size_t target) { int64_t d = (int64_t)target - (int64_t)pc; return 0x10000000u | ((uint32_t)d & 3) << 29 | ((uint32_t)(d >> 2) & 0x7ffff) << 5 | (uint32_t)rd; }
static uint32_t br(int rn) { return 0xd61f0000u | (uint32_t)rn << 5; }
static size_t pc;   // 下一条指令的位置
static void emit(uint32_t w) { put(pc, w); pc += 4; }
// 形状一（雷电V，SDK 6.5）：adrp/add 表 ; ldrsw ; add ; movz w0,#major ; br，表项 = 表址 + s32
static void form_ldrsw(size_t f, size_t tbl, int major, int minor) {
    pc = f;
    emit(cmp_w(20, 0x61)); emit(bhi(40)); emit(0x2a1403e8u /* mov w8, w20 */);
    emit(adrp(9, pc, tbl)); emit(add_imm(9, 9, (int)(tbl & 0xfff)));
    emit(0xb8a87928u /* ldrsw x8, [x9, x8, lsl #2] */); emit(0x8b090108u /* add x8, x8, x9 */);
    emit(movz_w(0, major)); emit(br(8));
    size_t ret = pc; emit(0xd65f03c0u /* ret */);   // case 0：用预置的 w0
    size_t c1 = pc; emit(movz_w(0, minor)); emit(0xd65f03c0u);
    int32_t e0 = (int32_t)((int64_t)ret - (int64_t)tbl), e1 = (int32_t)((int64_t)c1 - (int64_t)tbl);
    memcpy(img + tbl, &e0, 4); memcpy(img + tbl + 4, &e1, 4);
}
// 形状二（塞尔达 SDK 20 / 3D 世界 SDK 10.4）：adrp/add 表 ; adr 基准 ; ldrb ; add 基准, u8 lsl 2 ; movz w0,#major ; br
static void form_ldrb(size_t f, size_t tbl, int major, int minor) {
    pc = f;
    emit(cmp_w(20, 0x62)); emit(bhi(40)); emit(0x2a1403e8u);
    emit(adrp(9, pc, tbl)); emit(add_imm(9, 9, (int)(tbl & 0xfff)));
    size_t base = pc + 4 * 5; emit(adr(10, pc, base));
    emit(0x3868692bu /* ldrb w11, [x9, x8] */); emit(0x8b0b094au /* add x10, x10, x11, lsl #2 */);
    emit(movz_w(0, major)); emit(br(10));
    emit(0xd65f03c0u);   // base：case 0 用预置的 w0
    emit(0xd503201fu);   // nop
    emit(movz_w(0, minor)); emit(0xd65f03c0u);   // base + 8：case 1
    img[tbl] = 0; img[tbl + 1] = 2;
}
static int scan(int api[2]) { api[0] = api[1] = -1; return nvn_drv_api_scan(img, 0x2000, sizeof img, api); }
// ---- NvRmSurfaceNVX 的颜色格式编码 ----
static uint32_t movz_x(int rd, int imm, int hw) { return 0xd2800000u | (uint32_t)hw << 21 | (uint32_t)imm << 5 | (uint32_t)rd; }
static uint32_t movk_x(int rd, int imm, int hw) { return 0xf2800000u | (uint32_t)hw << 21 | (uint32_t)imm << 5 | (uint32_t)rd; }
static uint32_t b_to(size_t pc, size_t t) { return 0x14000000u | ((uint32_t)(((int64_t)t - (int64_t)pc) >> 2) & 0x3ffffff); }
static uint32_t cbz_w0(size_t pc, size_t t) { return 0x34000000u | ((uint32_t)(((int64_t)t - (int64_t)pc) >> 2) & 0x7ffff) << 5; }
static uint32_t ldr_x0_slot(size_t slot) { return 0xf9400000u | (uint32_t)((slot & 0xfff) >> 3) << 10; }
#define NAME_AT 0x3100
#define SLOT_AT 0x3808
// 驱动的取名函数一段：adrp/add 名字 ; bl strcmp（这里用 nop 代）; cbz w0, 命中 ; …；命中处按 how 取函数：0 adrp/ldr GOT 槽（槽里放 base + 偏移）、1 adr、2 nop ; adr
static void form_lookup(size_t at, size_t hit, size_t fn, int how, uint64_t base) {
    memcpy(img + NAME_AT, "nvnTextureGetNvRmSurfaceNVX", 28);
    pc = at; emit(adrp(1, pc, NAME_AT)); emit(add_imm(1, 1, NAME_AT & 0xfff)); emit(0xd503201fu); emit(cbz_w0(pc, hit));
    pc = hit;
    if (how == 0) { emit(adrp(0, pc, SLOT_AT)); emit(ldr_x0_slot(SLOT_AT)); uint64_t v = base + fn; memcpy(img + SLOT_AT, &v, 8); }
    else if (how == 1) emit(adr(0, pc, fn));
    else { emit(0xd503201fu); emit(adr(0, pc, fn)); }
    emit(0xd65f03c0u);
}
// 驱动函数：参数对调的跳板 ; 正体里 movz x21,#0x2120 和两条 movk（hi_first：先 lsl 32）
static void form_fn(size_t fn, size_t body, int mid, int hi, int hi_first) {
    pc = fn; emit(0xaa0003e1u /* mov x1, x0 */); emit(0xaa0203e0u /* mov x0, x2 */); emit(b_to(pc, body));
    pc = body; emit(0xd10243ffu /* sub sp, sp, #0x90 */); emit(0xaa0103f4u); emit(movz_x(21, 0x2120, 0));
    if (hi_first) { emit(movk_x(21, hi, 2)); emit(0x910023e1u); emit(movk_x(21, mid, 1)); }
    else { emit(movk_x(21, mid, 1)); emit(0x910023e1u); emit(0xaa1403e0u); emit(movk_x(21, hi, 2)); }
    emit(0xd65f03c0u);
}
static uint64_t rgba8(uint64_t base) { return nvn_drv_nvrm_rgba8_scan(img, 0x2000, sizeof img, base); }
int main(void) {
    int api[2];
    memset(img, 0, sizeof img); form_ldrsw(0x100, 0x3004, 53, 310);
    CHECK(scan(api) == 1 && api[0] == 53 && api[1] == 310);
    memset(img, 0, sizeof img); form_ldrb(0x800, 0x2d82, 55, 15);
    CHECK(scan(api) == 1 && api[0] == 55 && api[1] == 15);
    memset(img, 0, sizeof img); form_ldrb(0x800, 0x2d82, 53, 313); form_ldrb(0x1200, 0x3d82, 53, 313);   // 同一张表出现两处（同形状同值）：照认
    CHECK(scan(api) == 1 && api[0] == 53 && api[1] == 313);
    memset(img, 0, sizeof img); form_ldrb(0x800, 0x2d82, 53, 313); form_ldrsw(0x1200, 0x3104, 53, 313);   // 两处版本同、整张表不同：其余条目不可信，不认
    CHECK(scan(api) == 0);
    {   // 各条目：第 2 项目标 movz w0,#77 → 77；第 3 项目标是 ret（不是立即数）→ −1；第 0 项 = 预置主版本
        memset(img, 0, sizeof img); form_ldrb(0x800, 0x2d82, 55, 16);
        size_t base = 0x800 + 4 * 10; put(base + 16, movz_w(0, 77)); put(base + 20, 0xd65f03c0u); img[0x2d82 + 2] = 4; img[0x2d82 + 3] = 0;
        int32_t it[8]; int n = nvn_drv_items_scan(img, 0x2000, sizeof img, it, 8);
        CHECK(n == 0x63 && it[0] == 55 && it[1] == 16 && it[2] == 77 && it[3] == -1);
    }
    {   // 条目目标是 orr w0, wzr, #位掩码（超级马力欧派对 / GRID 的驱动这样写 GPU 代码版本）：按 ARMv8 逻辑立即数手算
        //   0x320003e0 → 1；0x321c03e0（immr 28）→ 16；0x32001fe0（imms 7）→ 0xff；0x32007fe0（imms 31：32 位元素全 1，保留编码）→ −1
        static const uint32_t w[4] = {0x320003e0u, 0x321c03e0u, 0x32001fe0u, 0x32007fe0u}; static const int32_t want[4] = {1, 16, 255, -1};
        for (int k = 0; k < 4; k++) {
            memset(img, 0, sizeof img); form_ldrb(0x800, 0x2d82, 53, 312);
            size_t base = 0x800 + 4 * 10; put(base + 16, w[k]); put(base + 20, 0xd65f03c0u); img[0x2d82 + 2] = 4;
            int32_t it[4]; nvn_drv_items_scan(img, 0x2000, sizeof img, it, 4);
            CHECK(it[2] == want[k]);
        }
    }
    memset(img, 0, sizeof img); form_ldrb(0x800, 0x2d82, 53, 313); form_ldrsw(0x1200, 0x3104, 53, 310);   // 两处不同值：二义，不认
    CHECK(scan(api) == 0 && api[0] == -1);
    memset(img, 0, sizeof img); form_ldrsw(0x100, 0x3004, 52, 310);   // 主版本不是 53 / 55：不是这个函数
    CHECK(scan(api) == 0);
    memset(img, 0, sizeof img); form_ldrb(0x800, 0x2d82, 55, 15); put(0x800 + 4 * 12, 0x2a1403e0u);   // case 1 不是 movz（读别的）：不认
    CHECK(scan(api) == 0);
    memset(img, 0, sizeof img); form_ldrsw(0x100, 0x3004, 53, 310); put(0x100, 0xd503201fu);   // 没有 cmp / b.hi 守着：不认
    CHECK(scan(api) == 0);
    // RGBA8：三代驱动的取法各一（SDK 8.2 / 13.3：GOT 槽；SDK 16 起：nop ; adr），期望 = 拼进去的 K << 32 | M << 16 | 0x2120
    memset(img, 0, sizeof img); form_lookup(0x400, 0x900, 0x1000, 0, 0x7100000000ull); form_fn(0x1000, 0x1040, 0x53, 1, 0);
    CHECK(rgba8(0x7100000000ull) == 0x100532120ull);
    memset(img, 0, sizeof img); form_lookup(0x400, 0x900, 0x1000, 0, 0); form_fn(0x1000, 0x1040, 0x53, 2, 0);
    CHECK(rgba8(0) == 0x200532120ull);
    memset(img, 0, sizeof img); form_lookup(0x400, 0x900, 0x1000, 2, 0); form_fn(0x1000, 0x1040, 0xa6, 2, 1);   // 先 lsl 32 后 lsl 16
    CHECK(rgba8(0) == 0x200a62120ull);
    memset(img, 0, sizeof img); form_lookup(0x400, 0x900, 0x1000, 1, 0); form_fn(0x1000, 0x1040, 0x53, 2, 0);
    CHECK(rgba8(0) == 0x200532120ull);
    memset(img, 0, sizeof img); form_lookup(0x400, 0x900, 0x1000, 1, 0); form_fn(0x1000, 0x1040, 0x53, 2, 0); put(0x1040 + 4 * 2, movz_x(21, 0x2121, 0));   // 没有 #0x2120：不认
    CHECK(rgba8(0) == 0);
    memset(img, 0, sizeof img); form_lookup(0x400, 0x900, 0x1000, 1, 0); form_fn(0x1000, 0x1040, 0x53, 2, 0); memcpy(img + NAME_AT, "nvnTextureGetNvRmSurfaceNVY", 28);   // 没有这个名字：不认
    CHECK(rgba8(0) == 0);
    memset(img, 0, sizeof img); form_lookup(0x400, 0x900, 0x1000, 1, 0); form_fn(0x1000, 0x1040, 0x53, 2, 0);
    form_lookup(0x600, 0xa00, 0x1200, 1, 0); form_fn(0x1200, 0x1240, 0x53, 1, 0);   // 两处引用指到两种编码：二义，不认
    CHECK(rgba8(0) == 0);
    // 换编码：表里是 6.4–10.9 的值，按驱动的 RGBA8 手算
    CHECK(nvn_drv_nvrm_recode(0x100d12120ull, 0x100532120ull) == 0x100d12120ull);   // 同一代：不变
    CHECK(nvn_drv_nvrm_recode(0x100d12120ull, 0x200532120ull) == 0x200d12120ull);   // BGRA8：颜色空间 1 → 2
    CHECK(nvn_drv_nvrm_recode(0xe09200408ull, 0x200532120ull) == 0xf09200408ull);   // R8：0xE → 0xF
    CHECK(nvn_drv_nvrm_recode(0x100d12120ull, 0x200a62120ull) == 0x201a22120ull);   // BGRA8：再 0x00D1 → 0x01A2
    CHECK(nvn_drv_nvrm_recode(0xe09200408ull, 0x200a62120ull) == 0xf12400408ull);   // R8：0x0920 → 0x1240
    CHECK(nvn_drv_nvrm_recode(0x10a881210ull, 0x200a62120ull) == 0x215101210ull);   // RGB565：0x0A88 → 0x1510
    CHECK(nvn_drv_nvrm_recode(0x100d12120ull, 0) == 0x100d12120ull);   // 没认出驱动：不变
    CHECK(nvn_drv_nvrm_recode(0x100d12120ull, 0x200532121ull) == 0x100d12120ull);   // 驱动值不是 RGBA8 的形状：不变
    CHECK(nvn_drv_nvrm_recode(0, 0x200a62120ull) == 0);   // 表里没有的格式（0）：仍是 0
    printf("✓ t_nvn_drvscan：%u 条断言\n", checks);
    return 0;
}
