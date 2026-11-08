// 缺页处模拟读指令单测（runtime/src/emul_ld.c）：每条编码在真 CPU 上执行一次（JIT 页：清 v0–v3 → 这条指令 → 存 x0–x6 / q0–q3 → ret），
// 再用模拟器对同一份内存、同一组初始寄存器算一次，逐寄存器比。期望值来自真硬件，不来自被测实现。
// 另测：写类 / 独占 / 原子 / 预取必须返回 0；判定回调拒绝时返回 0 且寄存器不动；类别函数对各类编码的归类。
#include "s2a_emul_ld.h"
#include <libkern/OSCacheControl.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/ucontext.h>

static int count, fail;
#define EXPECT(name, want, got) do { long long w_ = (long long)(want), g_ = (long long)(got); count++; if (w_ != g_) { fail++; printf("✗ %s：期望 %lld → 真结果 %lld\n", name, w_, g_); } } while (0)

typedef struct { uint64_t x[7], pad; uint8_t q[4][16]; } out_t;
typedef void (*jit_fn)(uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, out_t *);
static uint32_t *g_code;

static void run_real(uint32_t insn, const uint64_t in[7], out_t *o) {
    uint32_t c[16]; int k = 0;
    for (int v = 0; v < 4; v++) c[k++] = 0x6F00E400u | (uint32_t)v;          // movi vN.2d, #0
    c[k++] = insn;
    c[k++] = 0xA9000000u | (0u << 15) | (1u << 10) | (7u << 5) | 0u;        // stp x0, x1, [x7]
    c[k++] = 0xA9000000u | (2u << 15) | (3u << 10) | (7u << 5) | 2u;        // stp x2, x3, [x7, #16]
    c[k++] = 0xA9000000u | (4u << 15) | (5u << 10) | (7u << 5) | 4u;        // stp x4, x5, [x7, #32]
    c[k++] = 0xF9000000u | (6u << 10) | (7u << 5) | 6u;                      // str x6, [x7, #48]
    c[k++] = 0xAD000000u | (4u << 15) | (1u << 10) | (7u << 5) | 0u;        // stp q0, q1, [x7, #64]
    c[k++] = 0xAD000000u | (6u << 15) | (3u << 10) | (7u << 5) | 2u;        // stp q2, q3, [x7, #96]
    c[k++] = 0xD65F03C0u;                                                    // ret
    pthread_jit_write_protect_np(0); memcpy(g_code, c, (size_t)k * 4); pthread_jit_write_protect_np(1);
    sys_icache_invalidate(g_code, (size_t)k * 4);
    memset(o, 0, sizeof *o);
    ((jit_fn)(void *)g_code)(in[0], in[1], in[2], in[3], in[4], in[5], in[6], o);
}

static uint8_t *g_mem;
static uint64_t g_ok_n;
static int ok_no(uint64_t ea, uint64_t len) { (void)ea; (void)len; g_ok_n++; return 0; }

static void check(const char *name, uint32_t insn, uint64_t base_off, uint64_t x2) {
    uint64_t in[7] = { 0x1111111111111111ull, (uint64_t)(uintptr_t)g_mem + base_off, x2, 0x3333333333333333ull, 0x4444444444444444ull, 0x5555555555555555ull, 0x6666666666666666ull };
    out_t real; run_real(insn, in, &real);
    s2a_regs r; memset(&r, 0, sizeof r); memcpy(r.x, in, sizeof in);
    int h = s2a_emul_load_regs(insn, &r, 0, 0, UINT64_MAX, NULL, NULL, NULL);
    char b[160];
    snprintf(b, sizeof b, "%s（%08x）：模拟器认得", name, insn); EXPECT(b, 1, h);
    if (!h) return;
    for (int k = 0; k < 7; k++) { snprintf(b, sizeof b, "%s：x%d 与真硬件一致", name, k); EXPECT(b, 1, r.x[k] == real.x[k]); }
    for (int v = 0; v < 4; v++) { snprintf(b, sizeof b, "%s：v%d 与真硬件一致", name, v); EXPECT(b, 1, !memcmp(r.v[v], real.q[v], 16)); }
}

static void reject(const char *name, uint32_t insn, int cls) {
    s2a_regs r; memset(&r, 0, sizeof r); r.x[1] = (uint64_t)(uintptr_t)g_mem + 256;
    char b[160]; snprintf(b, sizeof b, "%s（%08x）：不模拟", name, insn); EXPECT(b, 0, s2a_emul_load_regs(insn, &r, 0, 0, UINT64_MAX, NULL, NULL, NULL));
    snprintf(b, sizeof b, "%s：类别", name); EXPECT(b, cls, s2a_emul_class(insn));
}

int main(void) {
    g_code = mmap(NULL, 0x4000, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
    g_mem = mmap(NULL, 0x4000, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (g_code == MAP_FAILED || g_mem == MAP_FAILED) { printf("✗ t_emul_ld：mmap 失败\n"); return 1; }
    for (int k = 0; k < 0x4000; k++) g_mem[k] = (uint8_t)(k * 37 + 0x80);   // 含 ≥ 0x80 的字节：符号扩展可见

    // 单寄存器，无符号立即数
    check("LDR X0,[X1,#16]", 0xF9400000u | (2u << 10) | (1u << 5), 256, 0);
    check("LDR W0,[X1,#8]", 0xB9400000u | (2u << 10) | (1u << 5), 256, 0);
    check("LDRB W0,[X1,#5]", 0x39400000u | (5u << 10) | (1u << 5), 256, 0);
    check("LDRH W0,[X1,#6]", 0x79400000u | (3u << 10) | (1u << 5), 256, 0);
    check("LDRSB X0,[X1,#3]", 0x39800000u | (3u << 10) | (1u << 5), 256, 0);
    check("LDRSB W0,[X1,#3]", 0x39C00000u | (3u << 10) | (1u << 5), 256, 0);
    check("LDRSH X0,[X1,#2]", 0x79800000u | (1u << 10) | (1u << 5), 256, 0);
    check("LDRSH W0,[X1,#2]", 0x79C00000u | (1u << 10) | (1u << 5), 256, 0);
    check("LDRSW X0,[X1,#4]", 0xB9800000u | (1u << 10) | (1u << 5), 256, 0);
    check("LDR X31(XZR),[X1]", 0xF9400000u | (1u << 5) | 31u, 256, 0);
    // 未缩放 / 后变址 / 前变址
    check("LDUR X0,[X1,#-3]", 0xF8400000u | ((uint32_t)(-3 & 0x1ff) << 12) | (1u << 5), 256, 0);
    check("LDURSW X0,[X1,#5]", 0xB8800000u | (5u << 12) | (1u << 5), 256, 0);
    check("LDR X0,[X1],#8", 0xF8400400u | (8u << 12) | (1u << 5), 256, 0);
    check("LDR X0,[X1,#-16]!", 0xF8400C00u | ((uint32_t)(-16 & 0x1ff) << 12) | (1u << 5), 256, 0);
    check("LDRB W0,[X1],#-1", 0x38400400u | ((uint32_t)(-1 & 0x1ff) << 12) | (1u << 5), 256, 0);
    // 寄存器偏移
    check("LDR X0,[X1,X2,LSL #3]", 0xF8607800u | (2u << 16) | (1u << 5), 256, 3);
    check("LDR W0,[X1,W2,SXTW]", 0xB860C800u | (2u << 16) | (1u << 5), 256, 0xFFFFFFFEull);
    check("LDR W0,[X1,W2,UXTW #2]", 0xB8605800u | (2u << 16) | (1u << 5), 256, 0x100000004ull);
    check("LDRB W0,[X1,X2]", 0x38626800u | (1u << 5), 256, 7);
    // 寄存器对
    check("LDP X0,X3,[X1,#16]", 0xA9400000u | (2u << 15) | (3u << 10) | (1u << 5), 256, 0);
    check("LDP W0,W3,[X1,#-8]", 0x29400000u | ((uint32_t)(-2 & 0x7f) << 15) | (3u << 10) | (1u << 5), 256, 0);
    check("LDPSW X0,X3,[X1,#8]", 0x69400000u | (2u << 15) | (3u << 10) | (1u << 5), 256, 0);
    check("LDP X0,X3,[X1],#16", 0xA8C00000u | (2u << 15) | (3u << 10) | (1u << 5), 256, 0);
    check("LDP X0,X3,[X1,#32]!", 0xA9C00000u | (4u << 15) | (3u << 10) | (1u << 5), 256, 0);
    check("LDNP X0,X3,[X1,#8]", 0xA8400000u | (1u << 15) | (3u << 10) | (1u << 5), 256, 0);
    // SIMD 单寄存器 / 对
    check("LDR Q0,[X1,#32]", 0x3DC00000u | (2u << 10) | (1u << 5), 256, 0);
    check("LDR D0,[X1,#8]", 0xFD400000u | (1u << 10) | (1u << 5), 256, 0);
    check("LDR S0,[X1,#4]", 0xBD400000u | (1u << 10) | (1u << 5), 256, 0);
    check("LDR H0,[X1,#2]", 0x7D400000u | (1u << 10) | (1u << 5), 256, 0);
    check("LDR B0,[X1,#1]", 0x3D400000u | (1u << 10) | (1u << 5), 256, 0);
    check("LDUR Q0,[X1,#-16]", 0x3CC00000u | ((uint32_t)(-16 & 0x1ff) << 12) | (1u << 5), 256, 0);
    check("LDR Q0,[X1],#16", 0x3CC00400u | (16u << 12) | (1u << 5), 256, 0);
    check("LDR Q0,[X1,X2,LSL #4]", 0x3CE07800u | (2u << 16) | (1u << 5), 256, 2);
    check("LDP Q0,Q1,[X1,#32]", 0xAD400000u | (2u << 15) | (1u << 10) | (1u << 5), 256, 0);
    check("LDP D0,D1,[X1,#-16]", 0x6D400000u | ((uint32_t)(-2 & 0x7f) << 15) | (1u << 10) | (1u << 5), 256, 0);
    check("LDP S2,S3,[X1,#4]", 0x2D400000u | (1u << 15) | (3u << 10) | (1u << 5) | 2u, 256, 0);
    // 载入获取
    check("LDAR X0,[X1]", 0xC8DFFC20u, 256, 0);
    check("LDAR W0,[X1]", 0x88DFFC20u, 256, 0);
    check("LDARB W0,[X1]", 0x08DFFC20u, 256, 0);
    check("LDAPR X0,[X1]", 0xF8BFC020u, 256, 0);
    check("LDAPRH W0,[X1]", 0x78BFC020u, 256, 0);
    // SIMD 结构
    check("LD1 {V0.16B},[X1]", 0x4C407020u, 256, 0);
    check("LD1 {V0.8B},[X1]", 0x0C407020u, 256, 0);
    check("LD1 {V0.4S,V1.4S},[X1]", 0x4C40A820u, 256, 0);
    check("LD1 {V0.2D-V2.2D},[X1]", 0x4C406C20u, 256, 0);
    check("LD1 {V0.2D-V3.2D},[X1]", 0x4C402C20u, 256, 0);
    check("LD2 {V0.4S,V1.4S},[X1]", 0x4C408820u, 256, 0);
    check("LD3 {V0.8H-V2.8H},[X1]", 0x4C404420u, 256, 0);
    check("LD4 {V0.4S-V3.4S},[X1]", 0x4C400820u, 256, 0);
    check("LD1 {V0.8B},[X1],#8", 0x0CDF7020u, 256, 0);
    check("LD1 {V0.16B},[X1],X2", 0x4CC27020u, 256, 24);
    check("LD1 {V0.S}[1],[X1]", 0x0D409020u, 256, 0);
    check("LD1 {V0.B}[13],[X1]", 0x4D401420u, 256, 0);
    check("LD1 {V0.D}[1],[X1]", 0x4D408420u, 256, 0);
    check("LD1R {V0.4S},[X1]", 0x4D40C820u, 256, 0);
    check("LD2 {V0.H,V1.H}[3],[X1]", 0x0D605820u, 256, 0);
    check("LD4R {V0.8H-V3.8H},[X1],#8", 0x4DFFE420u, 256, 0);

    // 不模拟：写 / 独占 / 原子 / 预取
    reject("STR X0,[X1]", 0xF9000020u, 8);
    reject("STP X0,X1,[X1]", 0xA9000420u, 8);
    reject("LDXR X0,[X1]", 0xC85F7C20u, 6);
    reject("LDAXR X0,[X1]", 0xC85FFC20u, 6);
    reject("LDADD X0,X0,[X1]", 0xF8200020u, 6);
    reject("PRFM PLDL1KEEP,[X1]", 0xF9800020u, 8);
    reject("ST1 {V0.16B},[X1]", 0x4C007020u, 8);
    reject("STLR X0,[X1]", 0xC89FFC20u, 8);
    reject("ADD X0,X0,X0（非访存）", 0x8B000000u, 0);
    // 类别（直方图）
    EXPECT("类别：LDR 立即数", 1, s2a_emul_class(0xF9400020u));
    EXPECT("类别：LDUR", 2, s2a_emul_class(0xF8400020u));
    EXPECT("类别：寄存器偏移", 3, s2a_emul_class(0xF8607820u));
    EXPECT("类别：LDP 偏移", 4, s2a_emul_class(0xA9400C20u));
    EXPECT("类别：LDP 前变址", 4, s2a_emul_class(0xA9C00C20u));
    EXPECT("类别：LDAR", 5, s2a_emul_class(0xC8DFFC20u));
    EXPECT("类别：LDAPR", 5, s2a_emul_class(0xF8BFC020u));
    EXPECT("类别：LD1", 7, s2a_emul_class(0x4C407020u));

    // 判定回调拒绝：返回 0、寄存器不动、回调被问过一次且问的是本条的有效地址与长度
    { s2a_regs r; memset(&r, 0, sizeof r); r.x[1] = (uint64_t)(uintptr_t)g_mem + 256; r.x[0] = 0xABCD; uint64_t ea = 0, len = 0; g_ok_n = 0;
      int h = s2a_emul_load_regs(0xA9400000u | (2u << 15) | (3u << 10) | (1u << 5), &r, 0, 0, UINT64_MAX, ok_no, &ea, &len);
      EXPECT("回调拒绝：不模拟", 0, h); EXPECT("回调拒绝：x0 不动", 0xABCD, r.x[0]); EXPECT("回调拒绝：问过 1 次", 1, g_ok_n);
      EXPECT("回调拒绝：有效地址", (uint64_t)(uintptr_t)g_mem + 272, ea); EXPECT("回调拒绝：长度", 16, len); }
    // 别名偏移：从 游戏地址 + delta 取数
    { s2a_regs r; memset(&r, 0, sizeof r); r.x[1] = (uint64_t)(uintptr_t)g_mem + 256;
      int h = s2a_emul_load_regs(0xF9400020u, &r, 0x1000, 0, UINT64_MAX, NULL, NULL, NULL); uint64_t want; memcpy(&want, g_mem + 256 + 0x1000, 8);
      EXPECT("别名偏移：认得", 1, h); EXPECT("别名偏移：取的是 地址 + delta 的内容", 1, r.x[0] == want); }

    // 信号上下文版：寄存器 / pc 写回 uc；src 是缺页地址对应的可读地址（这里用另一块内存当别名，内容不同于原址，证明从 src 取）；越出 16 KB 宿主页不模拟
    { uint8_t *al = mmap(NULL, 0x8000, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
      uint8_t *pg = (uint8_t *)(((uintptr_t)al + 0x3FFF) & ~(uintptr_t)0x3FFF);   // 16 KB 对齐的「游戏页」
      for (int k = 0; k < 0x4000; k++) g_mem[k] = (uint8_t)(k * 11 + 1);          // g_mem 当别名：内容与 pg 不同
      memset(pg, 0xEE, 0x4000);
      static uint32_t code[2]; code[0] = 0xA9400000u | (2u << 15) | (3u << 10) | (1u << 5);   // LDP X0,X3,[X1,#16]
      _STRUCT_MCONTEXT64 mc; ucontext_t uc; memset(&mc, 0, sizeof mc); memset(&uc, 0, sizeof uc); uc.uc_mcontext = &mc;
      mc.__ss.__pc = (uint64_t)(uintptr_t)code; mc.__ss.__x[1] = (uint64_t)(uintptr_t)pg + 0x100; mc.__ss.__x[0] = 0x77;
      uint64_t fa = (uint64_t)(uintptr_t)pg + 0x110;
      int h = s2a_emul_load(&uc, fa, g_mem + 0x110, NULL);
      uint64_t w0, w3; memcpy(&w0, g_mem + 0x110, 8); memcpy(&w3, g_mem + 0x118, 8);
      EXPECT("上下文版：认得", 1, h); EXPECT("上下文版：x0 取自 src", 1, mc.__ss.__x[0] == w0); EXPECT("上下文版：x3 取自 src", 1, mc.__ss.__x[3] == w3);
      EXPECT("上下文版：pc + 4", (uint64_t)(uintptr_t)code + 4, mc.__ss.__pc);
      // 越页：LDP 读 [页末 - 8, 页末 + 8)
      mc.__ss.__pc = (uint64_t)(uintptr_t)code; mc.__ss.__x[0] = 0x77; mc.__ss.__x[1] = (uint64_t)(uintptr_t)pg + 0x4000 - 8 - 16;
      h = s2a_emul_load(&uc, (uint64_t)(uintptr_t)pg + 0x4000 - 8, g_mem + 0x3FF8 - 0x2000, NULL);
      EXPECT("上下文版·越页：不模拟", 0, h); EXPECT("上下文版·越页：x0 不动", 0x77, mc.__ss.__x[0]); EXPECT("上下文版·越页：pc 不动", (uint64_t)(uintptr_t)code, mc.__ss.__pc);
      // 没有别名（src = NULL）：不模拟
      EXPECT("上下文版·无别名：不模拟", 0, s2a_emul_load(&uc, fa, NULL, NULL));
      // SIMD 目标写回 __ns
      code[0] = 0x3DC00000u | (2u << 10) | (1u << 5) | 5u;   // LDR Q5,[X1,#32]
      mc.__ss.__pc = (uint64_t)(uintptr_t)code; mc.__ss.__x[1] = (uint64_t)(uintptr_t)pg + 0x100;
      h = s2a_emul_load(&uc, (uint64_t)(uintptr_t)pg + 0x120, g_mem + 0x120, NULL);
      EXPECT("上下文版·SIMD：认得", 1, h); EXPECT("上下文版·SIMD：q5 取自 src", 1, !memcmp(&mc.__ns.__v[5], g_mem + 0x120, 16));
      munmap(al, 0x8000); }

    printf("%s t_emul_ld：%d 项，失败 %d\n", fail ? "✗" : "✓", count, fail);
    return fail != 0;
}
