// D7 第三片：nvn_cover.h 的「首绘全覆盖」判定是纯函数（只依赖 math.h），能在 Linux 上单独编译验证。
// 期望值按几何规则手算：viewport / scissor 必须整块；三角形（含 strip 奇偶绕序）要包住四个 NDC 角；
// 每个顶点 w=1、z∈[0,1]；cull 按绕序丢面；未识别图元一律不成立。
#include "nvn_cover.h"
#include <math.h>
#include <stdio.h>
#include <string.h>

static int fails, checks;

static void eq_i(const char *what, int got, int want) {
    checks++;
    if (got != want) { fails++; printf("FAIL %s：实为 %d，期望 %d\n", what, got, want); }
}

// 覆盖整个 NDC 方块的大三角形（CCW）
static const float BIG[3][4] = {{-1, -1, 0, 1}, {3, -1, 0, 1}, {-1, 3, 0, 1}};
// 只盖住左下角的小三角形（CCW）
static const float SMALL[3][4] = {{-1, -1, 0, 1}, {-0.2f, -1, 0, 1}, {-1, -0.2f, 0, 1}};

static int cover(const float (*v)[4], int n, int prim, int cull, int front_ccw) {
    return nvn_cover(v, n, prim, cull, front_ccw, 0, NULL, 0, NULL, 100, 100);
}

int main(void) {
    // 基本：大三角形覆盖整块；小三角形不覆盖
    eq_i("大三角形全覆盖", cover(BIG, 3, NVN_COVER_TRIANGLES, 0, 1), 1);
    eq_i("小三角形不覆盖", cover(SMALL, 3, NVN_COVER_TRIANGLES, 0, 1), 0);
    eq_i("顶点不足", cover(BIG, 2, NVN_COVER_TRIANGLES, 0, 1), 0);
    eq_i("非三角形图元", cover(BIG, 3, 1, 0, 1), 0);
    eq_i("cull 双面", cover(BIG, 3, NVN_COVER_TRIANGLES, NVN_COVER_CULL_BOTH, 1), 0);

    // 顶点约束：w=1、z∈[0,1]、有限坐标
    float bad[3][4];
    memcpy(bad, BIG, sizeof bad); bad[0][3] = 2.0f;
    eq_i("w != 1", cover(bad, 3, NVN_COVER_TRIANGLES, 0, 1), 0);
    memcpy(bad, BIG, sizeof bad); bad[1][2] = -0.1f;
    eq_i("z < 0", cover(bad, 3, NVN_COVER_TRIANGLES, 0, 1), 0);
    memcpy(bad, BIG, sizeof bad); bad[2][2] = 1.1f;
    eq_i("z > 1", cover(bad, 3, NVN_COVER_TRIANGLES, 0, 1), 0);
    memcpy(bad, BIG, sizeof bad); bad[0][0] = NAN;
    eq_i("NaN 坐标", cover(bad, 3, NVN_COVER_TRIANGLES, 0, 1), 0);

    // viewport：必须正好 (0,0,W,H)
    float vp[4] = {0, 0, 100, 100};
    eq_i("viewport 精确", nvn_cover(BIG, 3, NVN_COVER_TRIANGLES, 0, 1, 1, vp, 0, NULL, 100, 100), 1);
    vp[0] = 1;
    eq_i("viewport 偏移", nvn_cover(BIG, 3, NVN_COVER_TRIANGLES, 0, 1, 1, vp, 0, NULL, 100, 100), 0);
    vp[0] = 0; vp[2] = 99;
    eq_i("viewport 尺寸不足", nvn_cover(BIG, 3, NVN_COVER_TRIANGLES, 0, 1, 1, vp, 0, NULL, 100, 100), 0);

    // scissor：覆盖整块即可（允许负起点 / 超出）
    int sc[4] = {0, 0, 100, 100};
    eq_i("scissor 精确", nvn_cover(BIG, 3, NVN_COVER_TRIANGLES, 0, 1, 0, NULL, 1, sc, 100, 100), 1);
    sc[2] = 99;
    eq_i("scissor 不足", nvn_cover(BIG, 3, NVN_COVER_TRIANGLES, 0, 1, 0, NULL, 1, sc, 100, 100), 0);
    sc[0] = -1; sc[1] = -1; sc[2] = 102; sc[3] = 102;
    eq_i("scissor 超出仍覆盖", nvn_cover(BIG, 3, NVN_COVER_TRIANGLES, 0, 1, 0, NULL, 1, sc, 100, 100), 1);
    eq_i("W/H 非正", nvn_cover(BIG, 3, NVN_COVER_TRIANGLES, 0, 1, 0, NULL, 0, NULL, 0, 100), 0);

    // cull：CCW 大三角形在 front_ccw=1 是正面
    eq_i("cull back 保留正面", cover(BIG, 3, NVN_COVER_TRIANGLES, NVN_COVER_CULL_BACK, 1), 1);
    eq_i("cull front 丢掉正面", cover(BIG, 3, NVN_COVER_TRIANGLES, NVN_COVER_CULL_FRONT, 1), 0);
    eq_i("CW 前脸时正面变背面", cover(BIG, 3, NVN_COVER_TRIANGLES, NVN_COVER_CULL_BACK, 0), 0);

    // strip 奇偶绕序：第 0 个三角形被 cull front 丢掉，第 1 个交换 i1/i2 后是背面且覆盖整块
    const float strip[4][4] = {{1, 1, 0, 1}, {-1, 3, 0, 1}, {-1, -1, 0, 1}, {3, -1, 0, 1}};
    eq_i("strip 奇偶绕序", cover(strip, 4, NVN_COVER_TRIANGLE_STRIP, NVN_COVER_CULL_FRONT, 1), 1);

    if (fails) printf("✗ t_nvn_cover_core：%d / %d 项不符\n", fails, checks);
    else printf("✓ t_nvn_cover_core：首绘全覆盖 %d 项全过（0 处不符）\n", checks);
    return fails ? 1 : 0;
}
