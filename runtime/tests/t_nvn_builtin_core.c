// D7 第八片：nvn_builtin.h 的曲面细分辅助是纯 C（C 编译下不含 NSString 分支），能在 Linux 上单独编译验证。
// 期望值按「索引绘制的控制点规划」手算：map[i] = 索引[i] - lo；unique 排序去重后是捕获遍顶点表。
#include "nvn_builtin.h"
#include <stdio.h>
#include <string.h>

static int fails, checks;

static void eq_i(const char *what, int got, int want) {
    checks++;
    if (got != want) { fails++; printf("FAIL %s：实为 %d，期望 %d\n", what, got, want); }
}

static void eq_u32(const char *what, uint32_t got, uint32_t want) {
    checks++;
    if (got != want) { fails++; printf("FAIL %s：实为 %u，期望 %u\n", what, got, want); }
}

static void eq_bytes(const char *what, const void *got, const void *want, size_t n) {
    checks++;
    if (memcmp(got, want, n) != 0) { fails++; printf("FAIL %s：内容不符\n", what); }
}

int main(void) {
    // 域名与曲面因子步长
    eq_i("域 0 名", strcmp(nvn_tess_dom_name(0), "isolines"), 0);
    eq_i("域 1 名", strcmp(nvn_tess_dom_name(1), "triangles"), 0);
    eq_i("域 2 名", strcmp(nvn_tess_dom_name(2), "quads"), 0);
    eq_i("域未知按四边形", strcmp(nvn_tess_dom_name(3), "quads"), 0);
    eq_u32("等值线因子步长", nvn_tess_fstride(0), 12);   // 等值线翻译成四边形，TCS 按 12 字节一片写（审计 1101 P0-4）
    eq_u32("三角因子步长", nvn_tess_fstride(1), 8);
    eq_u32("四边形因子步长", nvn_tess_fstride(2), 12);

    // 排序比较器
    uint32_t a = 3, b = 7, c = 3;
    eq_i("cmp 小于", nvn_tess_cmp_u32(&a, &b), -1);
    eq_i("cmp 等于", nvn_tess_cmp_u32(&a, &c), 0);
    eq_i("cmp 大于", nvn_tess_cmp_u32(&b, &a), 1);

    // 16 位索引 {5,3,5,9}：lo=3、hi=9，map = 索引-3，unique = {3,5,9}
    uint16_t ib16[4] = {5, 3, 5, 9};
    uint32_t map[4], uniq[4], nu = 0, lo = 0, hi = 0;
    memset(map, 0, sizeof map); memset(uniq, 0, sizeof uniq);
    eq_i("16 位索引规划", nvn_tess_index_plan((const uint8_t *)ib16, 2, 4, map, uniq, &nu, &lo, &hi), 1);
    eq_u32("16 位 lo", lo, 3);
    eq_u32("16 位 hi", hi, 9);
    eq_u32("16 位 nu", nu, 3);
    uint32_t map16_want[4] = {2, 0, 2, 6};
    uint32_t uniq16_want[3] = {3, 5, 9};
    eq_bytes("16 位 map", map, map16_want, sizeof map16_want);
    eq_bytes("16 位 unique", uniq, uniq16_want, sizeof uniq16_want);

    // 8 位索引 {255,0,255}：lo=0、hi=255，unique = {0,255}
    uint8_t ib8[3] = {255, 0, 255};
    memset(map, 0, sizeof map); memset(uniq, 0, sizeof uniq);
    eq_i("8 位索引规划", nvn_tess_index_plan(ib8, 1, 3, map, uniq, &nu, &lo, &hi), 1);
    eq_u32("8 位 lo", lo, 0);
    eq_u32("8 位 hi", hi, 255);
    eq_u32("8 位 nu", nu, 2);
    uint32_t map8_want[3] = {255, 0, 255};
    uint32_t uniq8_want[2] = {0, 255};
    eq_bytes("8 位 map", map, map8_want, sizeof map8_want);
    eq_bytes("8 位 unique", uniq, uniq8_want, sizeof uniq8_want);

    // 32 位索引、指针故意不对齐 4 字节：按 memcpy 读，结果与对齐无关
    uint8_t raw[1 + 3 * 4];
    uint32_t vals[3] = {10, 3, 7};
    memcpy(raw + 1, vals, sizeof vals);
    memset(map, 0, sizeof map); memset(uniq, 0, sizeof uniq);
    eq_i("32 位未对齐索引规划", nvn_tess_index_plan(raw + 1, 4, 3, map, uniq, &nu, &lo, &hi), 1);
    eq_u32("32 位 lo", lo, 3);
    eq_u32("32 位 hi", hi, 10);
    eq_u32("32 位 nu", nu, 3);
    uint32_t map32_want[3] = {7, 0, 4};
    uint32_t uniq32_want[3] = {3, 7, 10};
    eq_bytes("32 位 map", map, map32_want, sizeof map32_want);
    eq_bytes("32 位 unique", uniq, uniq32_want, sizeof uniq32_want);

    // 单个控制点：map = {0}，lo = hi = 7
    uint8_t one = 7;
    memset(map, 0, sizeof map); memset(uniq, 0, sizeof uniq);
    eq_i("单点规划", nvn_tess_index_plan(&one, 1, 1, map, uniq, &nu, &lo, &hi), 1);
    eq_u32("单点 map", map[0], 0);
    eq_u32("单点 lo", lo, 7);
    eq_u32("单点 hi", hi, 7);
    eq_u32("单点 nu", nu, 1);

    // 非法索引宽度 / 空索引：返回 0，不写输出
    eq_i("索引宽度 3", nvn_tess_index_plan(ib8, 3, 3, map, uniq, &nu, &lo, &hi), 0);
    eq_i("count 0", nvn_tess_index_plan(ib8, 1, 0, map, uniq, &nu, &lo, &hi), 0);

    if (fails) printf("✗ t_nvn_builtin_core：%d / %d 项不符\n", fails, checks);
    else printf("✓ t_nvn_builtin_core：曲面细分规划 %d 项全过（0 处不符）\n", checks);
    return fails ? 1 : 0;
}
