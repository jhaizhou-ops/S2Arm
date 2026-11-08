// 视频按片源帧率出图的判定（graphics/nvn/gfx/nvn/nvn_vpace.h，hle_nvn.c video_cap 用的同一份）。
// 期望值全部手算（不跑被测实现）：
//   进入要 1 秒内 12–32 帧且最早一帧距今 ≥ 0.9 秒：30 帧片源第 k 帧距首帧 33333333 ns ×(k−1) ≥ 9e8 ns ⇒ k−1 ≥ 27.0000003 ⇒ k = 29（27 个周期 899.99999 ms 差一点）；24 帧片源 41.67(k−1) ≥ 900 ⇒ k = 23；
//   60 帧片源 1 秒内 60 帧，从不进入；
//   起播突发（100 ms 内 20 帧）超过 32 不进入，之后按 30 帧平稳，突发移出 1 秒窗口后进入；
//   放完：最后一帧后 0.5 秒内仍在、超过 0.5 秒退出；在放时片源跳到 60 帧：1 秒内超过 40 帧退出。
//   封顶（nvn_vpace_cap）另要每帧绘制数 ≤ 200：12 / 200 封顶，201 / 4000 / 未量出（−1）不封顶。
#include "../gfx/nvn/nvn_vpace.h"
#include <stdio.h>
#include <string.h>

static int g_bad, g_n;
#define CHECK(c, ...) do { g_n++; if (!(c)) { g_bad++; printf("✗ "); printf(__VA_ARGS__); printf("\n"); } } while (0)
#define MS 1000000ull

// 按 period_us 喂 frames 帧（从 t0 起），返回第一次判为在放的帧序号（1 起），从没进入返回 0；*tend 给最后一帧时刻
static int feed(nvn_vpace *v, uint64_t t0, uint64_t period_ns, int frames, uint64_t *tend) {
    int first = 0;
    for (int k = 0; k < frames; k++) {
        uint64_t t = t0 + (uint64_t)k * period_ns;
        nvn_vpace_frame(v, t);
        if (nvn_vpace_on(v, t) && !first) first = k + 1;
        if (tend) *tend = t;
    }
    return first;
}

int main(void) {
    nvn_vpace v;
    uint64_t end;

    memset(&v, 0, sizeof v);
    CHECK(!nvn_vpace_on(&v, 5 * MS), "没有帧：不在放");

    memset(&v, 0, sizeof v);
    CHECK(feed(&v, 1000 * MS, 33333333ull, 90, &end) == 29, "30 帧片源：第 29 帧进入");
    CHECK(nvn_vpace_on(&v, end + 499 * MS), "30 帧片源放完 0.499 秒：仍在放");
    CHECK(!nvn_vpace_on(&v, end + 501 * MS), "30 帧片源放完 0.501 秒：退出");

    memset(&v, 0, sizeof v);
    CHECK(feed(&v, 1000 * MS, 41666667ull, 48, &end) == 23, "24 帧片源：第 23 帧进入");

    memset(&v, 0, sizeof v);
    CHECK(feed(&v, 1000 * MS, 16666667ull, 180, &end) == 0, "60 帧片源：从不进入");

    // 起播突发：0–95 ms 每 5 ms 一帧共 20 帧，之后每 33.3 ms 一帧。
    // 第 k 个平稳帧（k 从 1 起）时刻 95 + 33.33k ms；窗口 1 秒内的突发帧数：突发帧 j（5j ms）在窗口内 ⇔ 5j ≥ 95 + 33.33k − 1000。
    // k = 27：时刻 995 ms，窗口起点 −5 → 20 个突发 + 27 = 47 > 32 不进入；
    // k = 28：1028.3 ms，起点 28.3 → 突发帧 j ≥ 6（30 ms）共 14 个 + 28 = 42；k = 30：1095 ms，起点 95 → j = 19 共 1 个 + 30 = 31 进入。
    //   k = 29：1061.7 ms，起点 61.7 → j ≥ 13（65 ms）共 7 个 + 29 = 36 > 32 不进入。所以第 30 个平稳帧进入
    memset(&v, 0, sizeof v);
    int first = 0;
    for (int j = 0; j < 20; j++) { nvn_vpace_frame(&v, 1000 * MS + (uint64_t)j * 5 * MS); CHECK(!nvn_vpace_on(&v, 1000 * MS + (uint64_t)j * 5 * MS), "突发第 %d 帧不进入", j + 1); }
    for (int k = 1; k <= 40; k++) {
        uint64_t t = 1000 * MS + 95 * MS + (uint64_t)k * 33333333ull;
        nvn_vpace_frame(&v, t);
        if (nvn_vpace_on(&v, t) && !first) first = k;
    }
    CHECK(first == 30, "起播突发后：第 30 个平稳帧进入（实得 %d）", first);

    // 在放时片源变 60 帧：每 16.67 ms 一帧，1 秒窗口内帧数逐帧上升，超过 40 退出
    memset(&v, 0, sizeof v);
    feed(&v, 1000 * MS, 33333333ull, 60, &end);   // 2 秒 30 帧，在放
    CHECK(nvn_vpace_on(&v, end), "60 帧前：在放");
    int off = 0;
    for (int k = 1; k <= 60 && !off; k++) {
        uint64_t t = end + (uint64_t)k * 16666667ull;
        nvn_vpace_frame(&v, t);
        if (!nvn_vpace_on(&v, t)) off = k;
    }
    // 第 k 个 60 帧帧时刻 end + 16.67k ms，窗口起点 end + 16.67k − 1000 ms。30 帧段帧 end − 33.33j 在窗口内 ⇔ j ≤ 30 − k/2，共 floor(30 − k/2) + 1 帧，
    //   再加 60 帧段 k 帧：k = 19 → 20 + 1 + 19 = 40 保持；k = 20 → 20 + 1 + 20 = 41 > 40 退出（j = 20 那帧正好距今 1 秒，按 ≤ 1 秒计入）
    CHECK(off == 20, "片源变 60 帧：第 20 帧退出（实得 %d）", off);

    // 时钟回退（now 早于最后一帧）：不在放
    memset(&v, 0, sizeof v);
    feed(&v, 1000 * MS, 33333333ull, 30, &end);
    CHECK(!nvn_vpace_on(&v, end - MS), "时刻早于最后一帧：不在放");

    // 封顶还要游戏每帧绘制数 ≤ VP_DRAW_MAX（200）：30 帧片源在放（第 29 帧起）时，每帧 12 个绘制 → 封顶；200 → 封顶（含边界）；201 / 4000（奥德赛局内）→ 不封顶；
    //   还没量出（−1）→ 不封顶；视频停了（最后一帧后 0.501 秒）即使绘制少也不封顶
    memset(&v, 0, sizeof v);
    feed(&v, 1000 * MS, 33333333ull, 60, &end);
    CHECK(nvn_vpace_cap(&v, end, 12) && nvn_vpace_cap(&v, end, 200), "在放 + 每帧 12 / 200 个绘制：封顶");
    CHECK(!nvn_vpace_cap(&v, end, 201) && !nvn_vpace_cap(&v, end, 4000), "在放 + 每帧 201 / 4000 个绘制（视频是画面里一块）：不封顶");
    CHECK(!nvn_vpace_cap(&v, end, -1), "在放 + 绘制数还没量出：不封顶");
    CHECK(!nvn_vpace_cap(&v, end + 501 * MS, 12), "放完 0.501 秒 + 绘制少：不封顶");

    printf("t_vpace：%d 项，%d 项失败\n", g_n, g_bad);
    return g_bad != 0;
}
