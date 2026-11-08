// 缺页处模拟读指令（帧率能耗线 10-23，塞尔达站立陷地 → 方案 B）：游戏读到写跟踪设成不可读的页（页里有 GPU 改过、还没回写的 4 KB 子页），
// 碰的子页本身不是 GPU 改过的时候，不整页回写，在信号处理里模拟这条读：从可读别名取数、写目标寄存器、处理变址回写、pc 前进，页保持不可读。
// 只做纯计算（不碰信号上下文、不加锁、不分配），调用方把 mcontext 拷进 / 拷出 s2a_regs。
#pragma once
#include <stdint.h>

typedef struct {
    uint64_t x[31];        // x0..x30（x29 = fp，x30 = lr）
    uint64_t sp;
    uint8_t v[32][16];     // SIMD 寄存器（小端，低字节在前）
} s2a_regs;

// 判定回调：模拟要读 [ea, ea+len) 之前问调用方「这段能不能直接从别名读」（写跟踪：所碰子页都不是 GPU 改过的）。返回 0 = 不模拟
typedef int (*s2a_emul_ok_fn)(uint64_t ea, uint64_t len);

// 纯寄存器版（单测用）：返回 1 = 已模拟（寄存器已更新，不含 pc）；0 = 不认识 / 不支持（独占、原子、写、预取…）/ 越出 [lo, hi) / 回调拒绝，调用方走老路。
// delta：取数地址 = 游戏地址 + delta（可读别名）。ok 可为 NULL。ea_out / len_out 可为 NULL，返回本条的有效地址与总字节数（不支持时也尽量填）
int s2a_emul_load_regs(uint32_t insn, s2a_regs *r, uint64_t delta, uint64_t lo, uint64_t hi, s2a_emul_ok_fn ok, uint64_t *ea_out, uint64_t *len_out);

// 信号上下文版（与原生层线 10-23 对齐的接口）：uc = 缺页时的 ucontext_t*；src = fault_addr 对应的可读地址（原生层 s2a_alias_page 给）。
// 只读本 16 KB 宿主页内（越页返回 0）；ok 再问一次「这段所碰子页都能直接读」（写跟踪：都不是 GPU 改过的），可为 NULL。
// 返回 1 = 已模拟，寄存器与 pc（+4）已写回 uc；0 = 原样不动，调用方走老路。不加锁、不分配
int s2a_emul_load(void *uc, uint64_t fault_addr, const uint8_t *src, s2a_emul_ok_fn ok);

// 指令类别（直方图用）：0 不认识 / 1 单寄存器立即数 / 2 单寄存器未缩放或前后变址 / 3 单寄存器寄存器偏移 / 4 寄存器对 / 5 载入获取 / 6 独占 / 7 SIMD 结构（LD1–4）/ 8 写类
int s2a_emul_class(uint32_t insn);
