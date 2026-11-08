// 缺页处模拟写指令单测（runtime/src/emul_st.c）：每条编码在真 CPU 上对内存 A 执行一次（JIT 页：从 out 取 q0–q3 → 这条指令 → 存 x0–x6 → ret），
// 再用模拟器对 A 的副本 B（delta = B − A）、同一组初始寄存器做一次，逐字节比 A 与 B、逐寄存器比 x0–x6。期望值来自真硬件，不来自被测实现。
// 另测：读 / 独占 / 原子 / 带标签 / 不可预测组合必须返回 0 且内存不动；判定回调拒绝时返回 0 且寄存器、内存都不动；信号上下文版写进 dst、pc + 4、越页不模拟。
#include "s2a_emul_st.h"
#include <libkern/OSCacheControl.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/ucontext.h>

static int count, fail;
#define EXPECT(name, want, got) do { long long w_ = (long long)(want), g_ = (long long)(got); count++; if (w_ != g_) { fail++; printf("✗ %s：期望 %lld → 真结果 %lld\n", name, w_, g_); } } while (0)

typedef struct { uint64_t x[7], pad; uint8_t q[4][16]; } io_t;
typedef void (*jit_fn)(uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, uint64_t, io_t *);
static uint32_t *g_code;
static uint8_t *g_a, *g_b;   // 真硬件写 A，模拟器写 B
#define MEM 0x4000

static void run_real(uint32_t insn, const uint64_t in[7], io_t *o) {
    uint32_t c[16]; int k = 0;
    c[k++] = 0xAD400000u | (4u << 15) | (1u << 10) | (7u << 5) | 0u;        // ldp q0, q1, [x7, #64]
    c[k++] = 0xAD400000u | (6u << 15) | (3u << 10) | (7u << 5) | 2u;        // ldp q2, q3, [x7, #96]
    c[k++] = insn;
    c[k++] = 0xA9000000u | (0u << 15) | (1u << 10) | (7u << 5) | 0u;        // stp x0, x1, [x7]
    c[k++] = 0xA9000000u | (2u << 15) | (3u << 10) | (7u << 5) | 2u;        // stp x2, x3, [x7, #16]
    c[k++] = 0xA9000000u | (4u << 15) | (5u << 10) | (7u << 5) | 4u;        // stp x4, x5, [x7, #32]
    c[k++] = 0xF9000000u | (6u << 10) | (7u << 5) | 6u;                      // str x6, [x7, #48]
    c[k++] = 0xD65F03C0u;                                                    // ret
    pthread_jit_write_protect_np(0); memcpy(g_code, c, (size_t)k * 4); pthread_jit_write_protect_np(1);
    sys_icache_invalidate(g_code, (size_t)k * 4);
    ((jit_fn)(void *)g_code)(in[0], in[1], in[2], in[3], in[4], in[5], in[6], o);
}
static void fill(void) { for (int k = 0; k < MEM; k++) g_a[k] = (uint8_t)(k * 37 + 0x80); memcpy(g_b, g_a, MEM); }
static void preset_q(io_t *o) { for (int v = 0; v < 4; v++) for (int b = 0; b < 16; b++) o->q[v][b] = (uint8_t)(0xA0 + v * 16 + b); }

static void check(const char *name, uint32_t insn, uint64_t base_off, uint64_t x2) {
    fill();
    uint64_t in[7] = { 0x0102030405060708ull, (uint64_t)(uintptr_t)g_a + base_off, x2, 0x1112131415161718ull, 0x2122232425262728ull, 0x3132333435363738ull, 0x4142434445464748ull };
    io_t real; memset(&real, 0, sizeof real); preset_q(&real); run_real(insn, in, &real);
    io_t q; preset_q(&q);
    s2a_regs r; memset(&r, 0, sizeof r); memcpy(r.x, in, sizeof in); for (int v = 0; v < 4; v++) memcpy(r.v[v], q.q[v], 16);
    int h = s2a_emul_store_regs(insn, &r, (uint64_t)(uintptr_t)g_b - (uint64_t)(uintptr_t)g_a, 0, UINT64_MAX, NULL, NULL, NULL);
    char b[160];
    snprintf(b, sizeof b, "%s（%08x）：模拟器认得", name, insn); EXPECT(b, 1, h);
    if (!h) return;
    snprintf(b, sizeof b, "%s：内存与真硬件逐字节一致", name); EXPECT(b, 0, memcmp(g_a, g_b, MEM));
    for (int k = 0; k < 7; k++) { snprintf(b, sizeof b, "%s：x%d 与真硬件一致", name, k); EXPECT(b, 1, r.x[k] == real.x[k]); }
}

static void reject(const char *name, uint32_t insn) {
    fill();
    s2a_regs r; memset(&r, 0, sizeof r); r.x[1] = (uint64_t)(uintptr_t)g_a + 256; r.x[0] = 0x5A5A5A5A5A5A5A5Aull;
    char b[160]; snprintf(b, sizeof b, "%s（%08x）：不模拟", name, insn);
    EXPECT(b, 0, s2a_emul_store_regs(insn, &r, (uint64_t)(uintptr_t)g_b - (uint64_t)(uintptr_t)g_a, 0, UINT64_MAX, NULL, NULL, NULL));
    snprintf(b, sizeof b, "%s：内存不动", name); EXPECT(b, 0, memcmp(g_a, g_b, MEM));
}

static uint64_t g_ok_n, g_ok_ea, g_ok_len;
static int ok_no(uint64_t ea, uint64_t len) { g_ok_n++; g_ok_ea = ea; g_ok_len = len; return 0; }

int main(void) {
    g_code = mmap(NULL, 0x4000, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
    g_a = mmap(NULL, MEM, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    g_b = mmap(NULL, MEM, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
    if (g_code == MAP_FAILED || g_a == MAP_FAILED || g_b == MAP_FAILED) { printf("✗ t_emul_st：mmap 失败\n"); return 1; }

    // 单寄存器，无符号立即数
    check("STR X0,[X1,#16]", 0xF9000000u | (2u << 10) | (1u << 5), 256, 0);
    check("STR W0,[X1,#8]", 0xB9000000u | (2u << 10) | (1u << 5), 256, 0);
    check("STRB W0,[X1,#5]", 0x39000000u | (5u << 10) | (1u << 5), 256, 0);
    check("STRH W0,[X1,#6]", 0x79000000u | (3u << 10) | (1u << 5), 256, 0);
    check("STR XZR,[X1]", 0xF9000000u | (1u << 5) | 31u, 256, 0);
    // 未缩放 / 后变址 / 前变址
    check("STUR X0,[X1,#-3]", 0xF8000000u | ((uint32_t)(-3 & 0x1ff) << 12) | (1u << 5), 256, 0);
    check("STURH W3,[X1,#5]", 0x78000000u | (5u << 12) | (1u << 5) | 3u, 256, 0);
    check("STR X0,[X1],#8", 0xF8000400u | (8u << 12) | (1u << 5), 256, 0);
    check("STR X0,[X1,#-16]!", 0xF8000C00u | ((uint32_t)(-16 & 0x1ff) << 12) | (1u << 5), 256, 0);
    check("STRB W0,[X1],#-1", 0x38000400u | ((uint32_t)(-1 & 0x1ff) << 12) | (1u << 5), 256, 0);
    // 寄存器偏移
    check("STR X0,[X1,X2,LSL #3]", 0xF8207800u | (2u << 16) | (1u << 5), 256, 3);
    check("STR W0,[X1,W2,SXTW]", 0xB820C800u | (2u << 16) | (1u << 5), 256, 0xFFFFFFFEull);
    check("STR W0,[X1,W2,UXTW #2]", 0xB8205800u | (2u << 16) | (1u << 5), 256, 0x100000004ull);
    check("STRB W0,[X1,X2]", 0x38226800u | (1u << 5), 256, 7);
    // 寄存器对
    check("STP X0,X3,[X1,#16]", 0xA9000000u | (2u << 15) | (3u << 10) | (1u << 5), 256, 0);
    check("STP W0,W3,[X1,#-8]", 0x29000000u | ((uint32_t)(-2 & 0x7f) << 15) | (3u << 10) | (1u << 5), 256, 0);
    check("STP X0,X3,[X1],#16", 0xA8800000u | (2u << 15) | (3u << 10) | (1u << 5), 256, 0);
    check("STP X0,X3,[X1,#32]!", 0xA9800000u | (4u << 15) | (3u << 10) | (1u << 5), 256, 0);
    check("STNP X0,X3,[X1,#8]", 0xA8000000u | (1u << 15) | (3u << 10) | (1u << 5), 256, 0);
    check("STP X0,X0,[X1]", 0xA9000000u | (0u << 10) | (1u << 5), 256, 0);
    // SIMD 单寄存器 / 对
    check("STR Q0,[X1,#32]", 0x3D800000u | (2u << 10) | (1u << 5), 256, 0);
    check("STR D1,[X1,#8]", 0xFD000000u | (1u << 10) | (1u << 5) | 1u, 256, 0);
    check("STR S2,[X1,#4]", 0xBD000000u | (1u << 10) | (1u << 5) | 2u, 256, 0);
    check("STR H3,[X1,#2]", 0x7D000000u | (1u << 10) | (1u << 5) | 3u, 256, 0);
    check("STR B0,[X1,#1]", 0x3D000000u | (1u << 10) | (1u << 5), 256, 0);
    check("STUR Q1,[X1,#-16]", 0x3C800000u | ((uint32_t)(-16 & 0x1ff) << 12) | (1u << 5) | 1u, 256, 0);
    check("STR Q0,[X1],#16", 0x3C800400u | (16u << 12) | (1u << 5), 256, 0);
    check("STR Q2,[X1,X2,LSL #4]", 0x3CA07800u | (2u << 16) | (1u << 5) | 2u, 256, 2);
    check("STP Q0,Q1,[X1,#32]", 0xAD000000u | (2u << 15) | (1u << 10) | (1u << 5), 256, 0);
    check("STP D2,D3,[X1,#-16]", 0x6D000000u | ((uint32_t)(-2 & 0x7f) << 15) | (3u << 10) | (1u << 5) | 2u, 256, 0);
    check("STP S2,S3,[X1,#4]", 0x2D000000u | (1u << 15) | (3u << 10) | (1u << 5) | 2u, 256, 0);
    check("STP Q0,Q1,[X1,#-32]!", 0xAD800000u | ((uint32_t)(-1 & 0x7f) << 15) | (1u << 10) | (1u << 5), 256, 0);
    // 写释放
    check("STLR X0,[X1]", 0xC89FFC20u, 256, 0);
    check("STLR W0,[X1]", 0x889FFC20u, 256, 0);
    check("STLRB W0,[X1]", 0x089FFC20u, 256, 0);
    check("STLRH W3,[X1]", 0x489FFC23u, 256, 0);
    // SIMD 结构写
    check("ST1 {V0.16B},[X1]", 0x4C007020u, 256, 0);
    check("ST1 {V0.8B},[X1]", 0x0C007020u, 256, 0);
    check("ST1 {V0.4S,V1.4S},[X1]", 0x4C00A820u, 256, 0);
    check("ST1 {V0.2D-V2.2D},[X1]", 0x4C006C20u, 256, 0);
    check("ST1 {V0.2D-V3.2D},[X1]", 0x4C002C20u, 256, 0);
    check("ST2 {V0.4S,V1.4S},[X1]", 0x4C008820u, 256, 0);
    check("ST3 {V0.8H-V2.8H},[X1]", 0x4C004420u, 256, 0);
    check("ST4 {V0.4S-V3.4S},[X1]", 0x4C000820u, 256, 0);
    check("ST1 {V0.8B},[X1],#8", 0x0C9F7020u, 256, 0);
    check("ST1 {V0.16B},[X1],X2", 0x4C827020u, 256, 24);
    check("ST1 {V0.S}[1],[X1]", 0x0D009020u, 256, 0);
    check("ST1 {V0.B}[13],[X1]", 0x4D001420u, 256, 0);
    check("ST1 {V0.D}[1],[X1]", 0x4D008420u, 256, 0);
    check("ST2 {V0.H,V1.H}[3],[X1]", 0x0D205820u, 256, 0);
    check("ST4 {V0.S-V3.S}[2],[X1],#16", 0x4DBFB020u, 256, 0);

    // 不模拟：读 / 独占 / 原子 / 带标签 / 预取 / 不可预测
    reject("LDR X0,[X1]", 0xF9400020u);
    reject("LDP X0,X3,[X1]", 0xA9400C20u);
    reject("LD1 {V0.16B},[X1]", 0x4C407020u);
    reject("STXR W2,X0,[X1]", 0xC8027C20u);
    reject("STLXR W2,X0,[X1]", 0xC802FC20u);
    reject("STADD X0,[X1]", 0xF820003Fu);
    reject("SWP X0,X3,[X1]", 0xF8208023u);
    reject("CASAL X0,X3,[X1]", 0xC8E0FC23u);
    reject("STGP X0,X3,[X1]", 0x69000C20u);
    reject("PRFM PLDL1KEEP,[X1]", 0xF9800020u);
    reject("STR X1,[X1],#8（写回基址 = 源）", 0xF8000400u | (8u << 12) | (1u << 5) | 1u);
    reject("STP X1,X3,[X1,#16]!（写回基址 = 源）", 0xA9800000u | (2u << 15) | (3u << 10) | (1u << 5) | 1u);
    reject("ADD X0,X0,X0（非访存）", 0x8B000000u);

    // 只解码：有效地址与长度
    { s2a_regs r; memset(&r, 0, sizeof r); r.x[1] = 0x1000; uint64_t ea = 0, len = 0;
      EXPECT("解码：STP Q0,Q1,[X1,#32] 认得", 1, s2a_emul_store_decode(0xAD000000u | (2u << 15) | (1u << 10) | (1u << 5), &r, &ea, &len));
      EXPECT("解码：有效地址", 0x1020, ea); EXPECT("解码：长度", 32, len);
      EXPECT("解码：ST4 .4S 长度", 1, s2a_emul_store_decode(0x4C000820u, &r, &ea, &len) && len == 64);
      EXPECT("解码：读类不认", 0, s2a_emul_store_decode(0xF9400020u, &r, &ea, &len)); }
    // 判定回调拒绝：返回 0、内存与寄存器不动、回调被问过一次且问的是本条有效地址与长度
    { fill(); s2a_regs r; memset(&r, 0, sizeof r); r.x[1] = (uint64_t)(uintptr_t)g_a + 256; r.x[0] = 0xABCD; g_ok_n = 0;
      int h = s2a_emul_store_regs(0xA9800000u | (2u << 15) | (3u << 10) | (1u << 5), &r, (uint64_t)(uintptr_t)g_b - (uint64_t)(uintptr_t)g_a, 0, UINT64_MAX, ok_no, NULL, NULL);
      EXPECT("回调拒绝：不模拟", 0, h); EXPECT("回调拒绝：内存不动", 0, memcmp(g_a, g_b, MEM)); EXPECT("回调拒绝：基址不变址", (uint64_t)(uintptr_t)g_a + 256, r.x[1]);
      EXPECT("回调拒绝：问过 1 次", 1, g_ok_n); EXPECT("回调拒绝：有效地址", (uint64_t)(uintptr_t)g_a + 272, g_ok_ea); EXPECT("回调拒绝：长度", 16, g_ok_len); }
    // 越出 [lo, hi)：不模拟
    { fill(); s2a_regs r; memset(&r, 0, sizeof r); r.x[1] = (uint64_t)(uintptr_t)g_a + 256;
      uint64_t lo = (uint64_t)(uintptr_t)g_a, hi = lo + 264;   // STR X0,[X1,#8] 写 [264, 272)，越过 hi
      EXPECT("越界：不模拟", 0, s2a_emul_store_regs(0xF9000020u | (1u << 10), &r, (uint64_t)(uintptr_t)g_b - lo, lo, hi, NULL, NULL, NULL));
      EXPECT("越界：内存不动", 0, memcmp(g_a, g_b, MEM)); }

    // 信号上下文版：写进 dst（另一块内存当别名，证明写的是 dst 不是原址）、pc + 4、变址写回 uc；越出 16 KB 宿主页不模拟
    { uint8_t *raw = mmap(NULL, 0x8000, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0);
      uint8_t *pg = (uint8_t *)(((uintptr_t)raw + 0x3FFF) & ~(uintptr_t)0x3FFF);   // 16 KB 对齐的「游戏页」（内容不该被碰）
      memset(pg, 0xEE, 0x4000); memset(g_b, 0, MEM);
      static uint32_t code[2]; code[0] = 0xA9800000u | (2u << 15) | (3u << 10) | (1u << 5);   // STP X0,X3,[X1,#16]!
      _STRUCT_MCONTEXT64 mc; ucontext_t uc; memset(&mc, 0, sizeof mc); memset(&uc, 0, sizeof uc); uc.uc_mcontext = &mc;
      mc.__ss.__pc = (uint64_t)(uintptr_t)code; mc.__ss.__x[1] = (uint64_t)(uintptr_t)pg + 0x100; mc.__ss.__x[0] = 0x1122334455667788ull; mc.__ss.__x[3] = 0x99AABBCCDDEEFF00ull;
      uint64_t fa = (uint64_t)(uintptr_t)pg + 0x110;
      int h = s2a_emul_store(&uc, fa, g_b + 0x110, NULL, NULL, NULL);
      uint64_t w0, w3; memcpy(&w0, g_b + 0x110, 8); memcpy(&w3, g_b + 0x118, 8);
      EXPECT("上下文版：认得", 1, h); EXPECT("上下文版：x0 写进 dst", 1, w0 == 0x1122334455667788ull); EXPECT("上下文版：x3 写进 dst", 1, w3 == 0x99AABBCCDDEEFF00ull);
      EXPECT("上下文版：游戏页没被碰", 0xEE, pg[0x110]); EXPECT("上下文版：前变址写回 x1", (uint64_t)(uintptr_t)pg + 0x110, mc.__ss.__x[1]);
      EXPECT("上下文版：pc + 4", (uint64_t)(uintptr_t)code + 4, mc.__ss.__pc);
      // 越页：STP 写 [页末 - 8, 页末 + 8)
      code[0] = 0xA9000000u | (2u << 15) | (3u << 10) | (1u << 5);   // STP X0,X3,[X1,#16]
      mc.__ss.__pc = (uint64_t)(uintptr_t)code; mc.__ss.__x[1] = (uint64_t)(uintptr_t)pg + 0x4000 - 8 - 16; memset(g_b, 0, MEM);
      h = s2a_emul_store(&uc, (uint64_t)(uintptr_t)pg + 0x4000 - 8, g_b + 0x2000, NULL, NULL, NULL);
      EXPECT("上下文版·越页：不模拟", 0, h); EXPECT("上下文版·越页：pc 不动", (uint64_t)(uintptr_t)code, mc.__ss.__pc);
      { int z = 1; for (int k = 0; k < MEM; k++) z &= g_b[k] == 0; EXPECT("上下文版·越页：dst 不动", 1, z); }
      EXPECT("上下文版·无别名：不模拟", 0, s2a_emul_store(&uc, fa, NULL, NULL, NULL, NULL));
      // SIMD 源取自 __ns
      code[0] = 0x3D800000u | (2u << 10) | (1u << 5) | 5u;   // STR Q5,[X1,#32]
      mc.__ss.__pc = (uint64_t)(uintptr_t)code; mc.__ss.__x[1] = (uint64_t)(uintptr_t)pg + 0x100;
      for (int b = 0; b < 16; b++) ((uint8_t *)&mc.__ns.__v[5])[b] = (uint8_t)(0x50 + b);
      h = s2a_emul_store(&uc, (uint64_t)(uintptr_t)pg + 0x120, g_b + 0x120, NULL, NULL, NULL);
      EXPECT("上下文版·SIMD：认得", 1, h); EXPECT("上下文版·SIMD：q5 写进 dst", 0, memcmp(&mc.__ns.__v[5], g_b + 0x120, 16));
      munmap(raw, 0x8000); }

    printf("%s t_emul_st：%d 项，失败 %d\n", fail ? "✗" : "✓", count, fail);
    return fail != 0;
}
