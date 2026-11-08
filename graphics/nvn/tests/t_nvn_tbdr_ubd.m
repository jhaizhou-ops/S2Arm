// TBDR 与遍内常量更新延后 / 惰性清除不互斥（11-04 能耗线 41c55e71a；审计 #1508 测试 T7：把互斥加回去旧单测照样绿）。直接包含生产 nvn_mtl.m，调 tbdr_on / ubd_on / lc_on。
// 期望按开关语义手写：`t_nvn_tbdr_ubd on`（环境 DM_NVN_TBDR=1）→ tbdr_on = 1、ubd_on = 1、lc_on = 1；
//   `t_nvn_tbdr_ubd off`（再加 DM_NVN_UB_DEFER=0 DM_NVN_LAZY_CLEAR=0）→ tbdr_on = 1、ubd_on = 0、lc_on = 0（证明读的是这两个开关本身）。
// 反证：把 ubd_on / lc_on 改回 `return v && !tbdr_on();`（10-24 上游原样）编同一单测，on 那一遍 ubd_on / lc_on 为 0，红
#include "../gfx/nvn/nvn_mtl.m"
#include <string.h>
int main(int argc, char **argv) { @autoreleasepool {
    int want = argc > 1 && !strcmp(argv[1], "off") ? 0 : 1, t = tbdr_on(), u = ubd_on(), l = lc_on();
    int ok = t == 1 && u == want && l == want;
    printf("%s t_nvn_tbdr_ubd（%s）：tbdr_on=%d ubd_on=%d lc_on=%d（期望 1 / %d / %d）\n", ok ? "✓" : "✗", want ? "TBDR 开、延后与惰性清除缺省" : "TBDR 开、两者显式关", t, u, l, want, want);
    return ok ? 0 : 1;
} }
