// 缺页处模拟写指令（帧率能耗线 10-24，塞尔达读回假共享）：游戏写到写跟踪拦着的页，写的字节和 GPU 改过、还没回写的字节不重叠时，
// 不整页回写、不等 GPU，在信号处理里替游戏做这次写（写进可写别名）、处理变址回写、pc 前进，页保持拦截。与读模拟（s2a_emul_ld.h）对称，
// 共用 s2a_regs / s2a_emul_ok_fn。只做纯计算（不碰信号上下文、不加锁、不分配），调用方把 mcontext 拷进 / 拷出 s2a_regs。
// 不认识的、独占 / 原子、架构上「不可预测」的组合一律返回 0，调用方走老路（回写后重执行），不会写错。
#pragma once
#include <stdint.h>
#include "s2a_emul_ld.h"

// 只解码不写（判定用）：认得就返回 1，填本条写的有效地址与总字节数；不认得 / 不支持返回 0
int s2a_emul_store_decode(uint32_t insn, const s2a_regs *r, uint64_t *ea_out, uint64_t *len_out);

// 纯寄存器版（单测用）：返回 1 = 已模拟（[ea, ea+len) 已写进 游戏地址 + delta，基址变址已更新，不含 pc）；
// 0 = 不认识 / 不支持 / 越出 [lo, hi) / 回调拒绝，内存与寄存器都不动。ok 可为 NULL。ea_out / len_out 可为 NULL
int s2a_emul_store_regs(uint32_t insn, s2a_regs *r, uint64_t delta, uint64_t lo, uint64_t hi, s2a_emul_ok_fn ok, uint64_t *ea_out, uint64_t *len_out);

// 信号上下文版：uc = 缺页时的 ucontext_t*；dst = fault_addr 对应的可写地址（别名）。只写本 16 KB 宿主页内（越页返回 0）；
// ok 再问一次「这段能直接写」（写跟踪：不碰 GPU 改过的字节），可为 NULL。返回 1 = 已模拟，寄存器与 pc（+4）已写回 uc；0 = 原样不动
// ea_out / len_out 可为 NULL：返回本条写的有效地址与总字节数（调用方据此记「CPU 写过」位图）
int s2a_emul_store(void *uc, uint64_t fault_addr, uint8_t *dst, s2a_emul_ok_fn ok, uint64_t *ea_out, uint64_t *len_out);
