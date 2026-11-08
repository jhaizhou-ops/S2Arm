// 双补丁岛 brk 兜底单测（只链 runtime/src/traps.c；模块表、module_of 在本文件打桩）。期望值都按改写器块的语义手算，不跑被测实现推：
// ① +0x100 brk #0x8000 = tpidr_r x5：x5 = 线程槽[KTLS 偏移 0x48] = 0x1111，pc +4，命中 1
// ② +0x104 brk #0x8001 = tpidrro_r x30：lr = 线程槽[KTLR 偏移 0x50] = 0x2222
// ③ +0x108 brk #0x8002 = tpidr_w x29：线程槽[0x48] = fp（0x3333）
// ④ +0x10c brk #0x8003 = ctr x0：x0 = 0x8444C004；+0x110 brk #0x8004 = ctr x31（xzr）：寄存器不动、pc +4
// ⑤ 不认领：游戏自己的 brk #0x8000（+0x114，偏移不在表里）、brk #0x8005（序号超表）、非 brk 字、模块外地址 → 0，pc 不动
// ⑦ 远跳（brk #0xA000，按 pc 查 # FAR 表，补丁岛 = 映像尾 +0x6000 起）：代码段 +0x200 → 岛 +0x6000（入口，命中 1）；岛 +0x6010 → 代码段 +0x204；
//    表里没有的 brk #0xA000（代码段 +0x208、岛 +0x6020）不认领、pc 不动
// ⑥ s2a_in_patch：近布局双岛（PATCH_OFF 0x8000 / size 0xc000，PATCH2_OFF −0x24000 / 0x1000）与 FAR 双岛（−0x10000 / 0x4000，0x20000 / 0x800）各边界
#include "../src/native.h"
#include <stdio.h>
#include <string.h>
#include <sys/ucontext.h>

S2A_TEST_MOD_TABLE(64); int g_nmod;
static uint8_t g_img[0x8000] __attribute__((aligned(0x4000)));
module_t *module_of(const void *p) {
    const uint8_t *q = p;
    return g_nmod && q >= g_img && q < g_img + sizeof g_img ? &g_mod[0] : NULL;
}
static uint64_t g_tsd[32];
extern uint64_t (*s2a_trap_test_slot_base)(void);
static uint64_t tsd_base(void) { return (uint64_t)(uintptr_t)g_tsd; }
int s2a_trap_brk(void *ctx);
void s2a_trap_report(const char *when);

static int bad;
#define CK(c, ...) do { if (!(c)) { printf("✗ " __VA_ARGS__); printf("\n"); bad++; } } while (0)
static uint32_t brkw(unsigned imm) { return 0xD4200000u | (imm << 5); }

int main(void) {
    module_t *m = &g_mod[0]; g_nmod = 1;
    m->base = g_img; m->size = sizeof g_img; m->text_end = 0x4000; m->key_page_off = 0x4000;
    m->key_idx[0] = 0; m->key_idx[1] = 1; m->key_idx[2] = 2; m->key_idx[3] = 3;
    uint64_t *page = (uint64_t *)(g_img + 0x4000); page[1] = 0x48; page[2] = 0x50;   // KTLS / KTLR 的槽偏移（字节）
    g_tsd[0x48 / 8] = 0x1111; g_tsd[0x50 / 8] = 0x2222;
    static struct s2a_trap tr[5] = {{.off = 0x100, .kind = S2A_TRAP_TPIDR_R, .reg = 5}, {.off = 0x104, .kind = S2A_TRAP_TPIDRRO_R, .reg = 30},
                                    {.off = 0x108, .kind = S2A_TRAP_TPIDR_W, .reg = 29}, {.off = 0x10c, .kind = S2A_TRAP_CTR, .reg = 0},
                                    {.off = 0x110, .kind = S2A_TRAP_CTR, .reg = 31}};
    m->traps = tr; m->ntrap = 5;
    uint32_t *code = (uint32_t *)g_img;
    for (unsigned i = 0; i < 5; i++) code[0x100 / 4 + i] = brkw(0x8000 + i);
    code[0x114 / 4] = brkw(0x8000); code[0x118 / 4] = brkw(0x8005); code[0x11c / 4] = 0xD503201Fu;
    s2a_trap_test_slot_base = tsd_base;

    ucontext_t uc; _STRUCT_MCONTEXT64 mc; memset(&mc, 0, sizeof mc); uc.uc_mcontext = &mc;
    uint64_t b = (uint64_t)(uintptr_t)g_img;
#define AT(o) (mc.__ss.__pc = b + (o))
    AT(0x100); CK(s2a_trap_brk(&uc) == 1 && mc.__ss.__x[5] == 0x1111 && mc.__ss.__pc == b + 0x104, "① tpidr_r x5：期望 0x1111、pc+4 → %#llx", (unsigned long long)mc.__ss.__x[5]);
    AT(0x104); CK(s2a_trap_brk(&uc) == 1 && mc.__ss.__lr == 0x2222 && mc.__ss.__pc == b + 0x108, "② tpidrro_r x30：期望 lr 0x2222 → %#llx", (unsigned long long)mc.__ss.__lr);
    mc.__ss.__fp = 0x3333;
    AT(0x108); CK(s2a_trap_brk(&uc) == 1 && g_tsd[0x48 / 8] == 0x3333, "③ tpidr_w x29：期望 KTLS 槽 0x3333 → %#llx", (unsigned long long)g_tsd[0x48 / 8]);
    AT(0x10c); CK(s2a_trap_brk(&uc) == 1 && mc.__ss.__x[0] == 0x8444C004u, "④ ctr x0：期望 0x8444c004 → %#llx", (unsigned long long)mc.__ss.__x[0]);
    _STRUCT_MCONTEXT64 before = mc; before.__ss.__pc = b + 0x114;
    AT(0x110); CK(s2a_trap_brk(&uc) == 1 && mc.__ss.__pc == b + 0x114 && !memcmp(&mc, &before, sizeof mc), "④ ctr xzr：期望只动 pc");
    for (unsigned i = 0; i < 5; i++) CK(tr[i].hits == 1, "命中计数 点 %u：期望 1 → %llu", i, (unsigned long long)tr[i].hits);
    const unsigned rej[] = {0x114, 0x118, 0x11c};
    for (unsigned i = 0; i < 3; i++) { AT(rej[i]); CK(s2a_trap_brk(&uc) == 0 && mc.__ss.__pc == b + rej[i], "⑤ +%#x 不该认领", rej[i]); }
    mc.__ss.__pc = 0x1000; CK(s2a_trap_brk(&uc) == 0, "⑤ 模块外地址不该认领");
    m->patch_off = 0x6000;   // ⑦ 远跳
    static struct s2a_far fr[2] = {{.from = 0x200, .to = 0x6000, .entry = 1}, {.from = 0x6010, .to = 0x204}};
    m->fars = fr; m->nfar = 2;
    code[0x200 / 4] = code[0x208 / 4] = code[0x6010 / 4] = code[0x6020 / 4] = brkw(0xA000);
    AT(0x200); CK(s2a_trap_brk(&uc) == 1 && mc.__ss.__pc == b + 0x6000 && fr[0].hits == 1, "⑦ 入口 +0x200：期望 pc → 岛 +0x6000、命中 1 → pc +%#llx 命中 %llu", (unsigned long long)(mc.__ss.__pc - b), (unsigned long long)fr[0].hits);
    AT(0x6010); CK(s2a_trap_brk(&uc) == 1 && mc.__ss.__pc == b + 0x204 && fr[1].hits == 1, "⑦ 出口 岛 +0x6010：期望 pc → +0x204 → +%#llx", (unsigned long long)(mc.__ss.__pc - b));
    AT(0x208); CK(s2a_trap_brk(&uc) == 0 && mc.__ss.__pc == b + 0x208, "⑦ 表里没有的 +0x208 不该认领");
    AT(0x6020); CK(s2a_trap_brk(&uc) == 0 && mc.__ss.__pc == b + 0x6020, "⑦ 表里没有的 岛 +0x6020 不该认领");
    s2a_trap_report("单测");

    module_t n = {0}; n.base = (uint8_t *)0x10000000; n.size = 0xc000; n.patch_off = 0x8000; n.patch2_off = -0x24000; n.patch2_len = 0x1000;
    uint64_t nb = 0x10000000;
    CK(!s2a_in_patch(&n, nb + 0x7ffc) && s2a_in_patch(&n, nb + 0x8000) && s2a_in_patch(&n, nb + 0xbffc) && !s2a_in_patch(&n, nb + 0xc000), "⑥ 近布局后岛边界");
    CK(s2a_in_patch(&n, nb - 0x24000) && s2a_in_patch(&n, nb - 0x23004) && !s2a_in_patch(&n, nb - 0x23000) && !s2a_in_patch(&n, nb - 0x24004), "⑥ 近布局前岛边界");
    module_t f = {0}; f.base = (uint8_t *)0x20000000; f.size = 0x18000; f.image_size = 0x18000; f.patch_off = -0x10000; f.patch_len = 0x4000; f.patch2_off = 0x20000; f.patch2_len = 0x800;
    uint64_t fb = 0x20000000;
    CK(s2a_in_patch(&f, fb - 0x10000) && !s2a_in_patch(&f, fb - 0xc000) && !s2a_in_patch(&f, fb) && !s2a_in_patch(&f, fb + 0x17ffc), "⑥ FAR 前岛 / 映像");
    CK(!s2a_in_patch(&f, fb + 0x1fffc) && s2a_in_patch(&f, fb + 0x20000) && s2a_in_patch(&f, fb + 0x207fc) && !s2a_in_patch(&f, fb + 0x20800), "⑥ FAR 后岛边界");
    printf("%s t_traps：%d 处不符\n", bad ? "✗" : "✓", bad);
    return bad != 0;
}
