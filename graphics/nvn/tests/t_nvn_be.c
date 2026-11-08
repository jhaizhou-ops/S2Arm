// 直连回放层选路（graphics/nvn/gfx/nvn/nvn_be.h，#277 D3-1）：NXGAL_BE / 系统版本 / 设备是否 Metal 4 家族 → 后端与依据。纯 C，不需要 GPU 或游戏。
// nvn_mtl.m 的 mtl_init 把读到的三项原样交给 nvn_be_pick，按返回值建 Metal 4 或 Metal 3 那一套、在 host.log 打「direct backend: Metal N (依据)」
#include <stdio.h>
#include <string.h>
#include "../gfx/nvn/nvn_be.h"

int main(void) {
    static const struct { const char *env; int os26, family4, want; const char *why; } c[] = {
        {NULL, 1, 1, NVN_BE_MTL4, "GPU in the Metal 4 family"},        // 26 起、M1 / A14 起：缺省 Metal 4
        {"mtl3", 1, 1, NVN_BE_MTL3, "forced by NXGAL_BE=mtl3"},         // 26 上强制（A/B）
        {"mtl4", 1, 1, NVN_BE_MTL4, "GPU in the Metal 4 family"},       // 只有 mtl3 才强制，与 gal 同
        {"", 1, 1, NVN_BE_MTL4, "GPU in the Metal 4 family"},
        {"MTL3", 1, 1, NVN_BE_MTL4, "GPU in the Metal 4 family"},       // 大小写不放宽，与 gal 同
        {NULL, 1, 0, NVN_BE_MTL3, "GPU not in the Metal 4 family"},     // 26 上的 A12X / A12Z / A13：没有 Metal 4
        {"mtl4", 1, 0, NVN_BE_MTL3, "GPU not in the Metal 4 family"},   // 设备不支持时开关不能把它推回 Metal 4
        {NULL, 0, 0, NVN_BE_MTL3, "system below macOS / iOS 26"},       // macOS 15 / iOS 18
        {NULL, 0, 1, NVN_BE_MTL3, "system below macOS / iOS 26"},       // 26 以下读不到家族（mtl_init 只在 26 起问），按系统判
        {"mtl3", 0, 0, NVN_BE_MTL3, "forced by NXGAL_BE=mtl3"},
    };
    int n = (int)(sizeof c / sizeof c[0]), bad = 0;
    for (int i = 0; i < n; i++) {
        const char *why = NULL; int be = nvn_be_pick(c[i].env, c[i].os26, c[i].family4, &why);
        int ok = be == c[i].want && why && !strcmp(why, c[i].why);
        printf("%s 选路 %d：NXGAL_BE=%s 系统 26 起=%d Metal 4 家族=%d → Metal %d（%s）\n", ok ? "✓" : "✗", i, c[i].env ? c[i].env : "（不设）", c[i].os26, c[i].family4, be, why ? why : "无依据");
        bad += !ok;
    }
    printf("%s t_nvn_be：%d 种组合，%d 处不符\n", bad ? "✗" : "✓", n, bad);
    return bad != 0;
}
