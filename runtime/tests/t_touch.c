// 改道回写单测（只链 runtime/src/touch.c，其余设施在本文件打桩）。
// ① s2a_touch_body 回写前放开虚拟核、回写后取回（修干净清单 #12）：期望调用顺序 = 放核 → 回写（地址原样）→ 取核，各 1 次。
//    回写要经 C# 让 Ryujinx 读回 GPU 数据（几～几十 ms），期间持核会让同核游戏线程干等（S2A_CORES=1）。
#include "../src/native.h"
#include <stdio.h>
#include <string.h>

uint64_t g_xs_key;
void sw_touch_tramp(void) {}
const uint32_t sw_touch_brk[1];

static char g_seq[64]; static int g_n; static uint64_t g_addr;
void s2a_core_leave(void) { g_seq[g_n++] = 'L'; }
void s2a_core_enter(void) { g_seq[g_n++] = 'E'; }
void s2a_track_touch(uint64_t addr) { g_seq[g_n++] = 'T'; g_addr = addr; }
void s2a_touch_body(uint64_t addr);

int main(void) {
    int bad = 0;
    s2a_touch_body(0x7012345000ull);
    g_seq[g_n] = 0;
    if (strcmp(g_seq, "LTE")) { printf("✗ 调用顺序：期望 LTE（放核 → 回写 → 取核）→ %s\n", g_seq); bad++; }
    if (g_addr != 0x7012345000ull) { printf("✗ 回写地址：期望 0x7012345000 → %#llx\n", (unsigned long long)g_addr); bad++; }
    printf("%s t_touch：%d 处不符\n", bad ? "✗" : "✓", bad);
    return bad != 0;
}
