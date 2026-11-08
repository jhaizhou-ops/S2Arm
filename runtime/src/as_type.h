// NPDM 地址空间类型（META +0x0C 位 1–3）的位宽，同 Ryujinx ProcessCreationFlags.AddressSpace*：0 = 32 位、1 = 36 位、2 = 32 位无保留区、3 = 39 位。
//   独立头文件：native.h 是解包阶段的输入（pack/stage_inputs/extract.tsv），只给红行措辞用的东西不放那里
#pragma once
#include <stdint.h>
static inline const char *s2a_as_type_bits(uint32_t t) { return t == 0 ? "32 位" : t == 1 ? "36 位" : t == 2 ? "32 位无保留区" : t == 3 ? "39 位" : "未知"; }
// 本类型的地址空间上界（游戏地址必须全在它以下；Ryujinx KPageTableBase.GetAddressSpaceWidth）：布局支持的类型 1（36 位）→ 2^36、3（39 位）→ 2^39，其余 0 = 不支持。
//   宿主窗口按它取空洞（vawin.c）、布局按它核窗口（layout.c）、QueryMemory 按它报地址空间末（svc_mem.c）
static inline uint64_t s2a_as_type_top(uint32_t t) { return t == 1 ? 1ull << 36 : t == 3 ? 1ull << 39 : 0; }
// 跨度为 0 时 vawin.c 读到的本款 NPDM 地址空间类型（0–7；-1 = 读不到 main.npdm 或不是 META，或跨度不为 0 没读）。自检页（selfcheck.c）按它分话术
int s2a_window_astype(void);
