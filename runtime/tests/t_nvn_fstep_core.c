// D7 第四片：nvn_fstep.h 的帧步进状态机是纯函数（只依赖 stdint / math），能在 Linux 上单独编译验证。
// 期望值按头文件语义手算：首帧取 kmin；fixed 原样保持；连续 3 个晚帧升一档；升档后连续
// FSTEP_RUN 个「装得下 k-1」的按时帧降档并进入 trial；长停顿债务封顶；kmin 抬升立即生效。
#include "nvn_fstep.h"
#include <math.h>
#include <stdio.h>

static int fails, checks;

static void eq_i(const char *what, int got, int want) {
    checks++;
    if (got != want) { fails++; printf("FAIL %s：实为 %d，期望 %d\n", what, got, want); }
}

static void eq_d(const char *what, double got, double want) {
    checks++;
    if (fabs(got - want) > 1e-9) { fails++; printf("FAIL %s：实为 %.6f，期望 %.6f\n", what, got, want); }
}

int main(void) {
    // 首帧：没有历史，k / step 都取 kmin
    nvn_fstep s = {0};
    int r = nvn_fstep_next(&s, 1.0, 0.5, 1, FSTEP_MAX, 0, 0);
    eq_i("首帧 step", r, 1);
    eq_i("首帧 k", s.k, 1);

    // fixed：游戏自己定步长，原样保持，债务清零
    nvn_fstep f = {0};
    r = nvn_fstep_next(&f, 1.0, 5.0, 1, FSTEP_MAX, 3, 0);
    eq_i("fixed step", r, 3);
    eq_i("fixed k", f.k, 3);
    eq_d("fixed debt", f.debt, 0.0);

    // 稳在 kmin：最近 120 帧里迟到超过 24 帧（20%）才升档（11-02 三局真机：降频前的降档全是 0.6–9.5% 的零星尖刺、最长连续 3–5 帧）。
    //   持续迟到（shown / cost 都比 held 多 1）：第 3 帧不升（旧规则在这里升），第 25 个迟到帧升一档，那一步返回 k+1（含债务补帧）
    nvn_fstep a = {0};
    nvn_fstep_next(&a, 1.0, 0.5, 1, FSTEP_MAX, 0, 0);
    for (int i = 0; i < 3; i++) r = nvn_fstep_next(&a, 2.0, 2.0, 1, FSTEP_MAX, 0, 0);
    eq_i("持续迟到第 3 帧不升（旧规则在这里升）", a.k, 1);
    for (int i = 3; i < 24; i++) r = nvn_fstep_next(&a, 2.0, 2.0, 1, FSTEP_MAX, 0, 0);
    eq_i("第 24 个迟到帧仍不升", a.k, 1);
    r = nvn_fstep_next(&a, 2.0, 2.0, 1, FSTEP_MAX, 0, 0);
    eq_i("第 25 个迟到帧升到 k 2", a.k, 2);
    eq_i("升档 ups", (int)a.ups, 1);
    eq_i("升档那步 step 含补帧", r, 3);
    eq_i("升档后窗口清空", a.wn + a.wlate, 0);

    // 升到 k=2 后连续 30 个按时帧（shown=2、cost 装得下 k-1）：降回 k=1 并进入 trial
    for (int i = 0; i < FSTEP_RUN; i++) r = nvn_fstep_next(&a, 2.0, 0.2, 1, FSTEP_MAX, 0, 0);
    eq_i("30 个合适帧后 k", a.k, 1);
    eq_i("30 个合适帧后 downs", (int)a.downs, 1);
    eq_i("降档返回 step", r, 1);

    // trial 期间给按时帧（shown=1）：trial 走完，保持 k=1，不再反复升
    for (int i = 0; i < FSTEP_RUN; i++) r = nvn_fstep_next(&a, 1.0, 0.2, 1, FSTEP_MAX, 0, 0);
    eq_i("trial 走完后 k", a.k, 1);
    eq_i("trial 走完后 trial", a.trial, 0);
    eq_i("trial 走完后 ups 仍为 1", (int)a.ups, 1);

    // 长停顿：债务封顶 FSTEP_DEBT_MAX，超出部分丢弃；这一步按债务补一帧
    nvn_fstep d = {0};
    nvn_fstep_next(&d, 1.0, 0.5, 1, FSTEP_MAX, 0, 0);
    r = nvn_fstep_next(&d, 100.0, 100.0, 1, FSTEP_MAX, 0, 0);
    eq_d("长停顿 debt", d.debt, FSTEP_DEBT_MAX);
    checks++;
    if (!(d.dropped > 0)) { fails++; printf("FAIL 长停顿 dropped 应 > 0，实为 %.3f\n", d.dropped); }
    eq_i("长停顿 step", r, 2);

    // kmin 抬升立即生效（30 → 60 帧上限解除）
    nvn_fstep m = {0};
    nvn_fstep_next(&m, 1.0, 0.5, 1, FSTEP_MAX, 0, 0);
    r = nvn_fstep_next(&m, 1.0, 0.5, 2, FSTEP_MAX, 0, 0);
    eq_i("kmin 抬升后 k", m.k, 2);
    eq_i("kmin 抬升后 step", r, 2);

    // kmax < kmin 时按 kmin 收口，不能给出比 kmin 更小的步长
    nvn_fstep c = {0};
    r = nvn_fstep_next(&c, 1.0, 0.2, 3, 2, 0, 0);
    eq_i("kmax 低于 kmin 时 k", c.k, 3);
    eq_i("kmax 低于 kmin 时 step", r, 3);

    // GPU 慢：在 kmin 记参考（不更新 probe 的参考），高于 kmin 连续 30 帧且超过 1.3 倍 / 不装得下 k-1 才算慢
    nvn_fgpu g = {0};
    eq_i("kmin 帧不算 GPU 慢", nvn_fstep_gpu_slowed(&g, 1.0, 1, 1, 0), 0);
    eq_d("kmin 参考", g.ref, 1.0);
    nvn_fstep_gpu_slowed(&g, 1.4, 1, 1, 1);   // probe 的 kmin 帧不更新参考
    eq_d("probe 不更新参考", g.ref, 1.0);
    for (int i = 0; i < FSTEP_GPU_N; i++) nvn_fstep_gpu_slowed(&g, 1.4, 2, 1, 0);
    eq_i("30 帧 1.4 倍判 GPU 慢", nvn_fgpu_slow(&g), 1);
    nvn_fgpu ok = {0};
    nvn_fstep_gpu_slowed(&ok, 1.0, 1, 1, 0);
    for (int i = 0; i < FSTEP_GPU_N; i++) nvn_fstep_gpu_slowed(&ok, 1.2, 2, 1, 0);
    eq_i("1.2 倍不算慢", nvn_fgpu_slow(&ok), 0);
    eq_i("gpu=0 沿用当前判定", nvn_fstep_gpu_slowed(&ok, 0, 2, 1, 0), 0);

    // 尖刺型（三局降频前段落的形状）：每 40 帧里连续 4 帧迟到（10%）、跑 1200 帧（20 秒）→ 一直留在 kmin；
    //   9.5% 那种最密的：每 21 帧 2 帧迟到也不升；超过 20%：每 4 帧 1 帧迟到（25%）→ 窗口满时（迟到 30 > 24）升档
    { nvn_fstep sp = {0}; nvn_fstep_next(&sp, 1.0, 0.5, 1, FSTEP_MAX, 0, 0);
      for (int i = 0; i < 1200; i++) { int lt = i % 40 < 4; nvn_fstep_next(&sp, lt ? 1.6 : 1.0, lt ? 1.3 : 0.6, 1, FSTEP_MAX, 0, 0); }
      eq_i("尖刺 10%（每 40 帧连续 4 帧）20 秒：留在 k 1", sp.k * 10 + (int)sp.ups, 10);
      nvn_fstep d9 = {0}; nvn_fstep_next(&d9, 1.0, 0.5, 1, FSTEP_MAX, 0, 0);
      for (int i = 0; i < 1200; i++) { int lt = i % 21 < 2; nvn_fstep_next(&d9, lt ? 1.6 : 1.0, lt ? 1.3 : 0.6, 1, FSTEP_MAX, 0, 0); }
      eq_i("尖刺 9.5%（每 21 帧 2 帧）20 秒：留在 k 1", d9.k * 10 + (int)d9.ups, 10);
      nvn_fstep hv = {0}; nvn_fstep_next(&hv, 1.0, 0.5, 1, FSTEP_MAX, 0, 0); int at = -1;
      for (int i = 0; i < 400 && at < 0; i++) { int lt = i % 4 == 0; nvn_fstep_next(&hv, lt ? 1.6 : 1.0, lt ? 1.3 : 0.6, 1, FSTEP_MAX, 0, 0); if (hv.k == 2) at = i; }
      eq_i("25% 迟到：第 100 帧升（第 25 个迟到帧在 i = 96，窗口内 25 > 24）", at, 96);
      // 试档 / 探测照旧连续 3 帧：k 2 时 30 个装得下的帧 → 试 k 1，试档中连续 3 帧迟到 → 回 k 2
      nvn_fstep tr = {0}; nvn_fstep_next(&tr, 1.0, 0.5, 1, FSTEP_MAX, 0, 0);
      for (int i = 0; i < 25; i++) nvn_fstep_next(&tr, 2.0, 2.0, 1, FSTEP_MAX, 0, 0);
      for (int i = 0; i < 60 && tr.k != 1; i++) nvn_fstep_next(&tr, 2.0, 0.2, 1, FSTEP_MAX, 0, 0);
      eq_i("降回 k 1 进入试档", tr.k * 10 + (tr.trial > 0), 11);
      for (int i = 0; i < 3; i++) nvn_fstep_next(&tr, 2.0, 2.0, 1, FSTEP_MAX, 0, 0);
      eq_i("试档中连续 3 帧迟到 → 回 k 2", tr.k, 2);
      // 稳在 kmin：开销超节拍但出图按时（shown 1.0、cost 1.3 > 1.1）不进窗口——200 帧仍留 k 1（期望手算：出图迟到 0 帧 ≤ 24）；同样开销且出图也迟到（shown 1.3）第 25 帧升
      nvn_fstep ct = {0}; nvn_fstep_next(&ct, 1.0, 0.5, 1, FSTEP_MAX, 0, 0);
      for (int i = 0; i < 200; i++) nvn_fstep_next(&ct, 1.0, 1.3, 1, FSTEP_MAX, 0, 0);
      eq_i("开销超节拍、出图按时 200 帧：留在 k 1", ct.k * 10 + (int)ct.ups, 10);
      nvn_fstep cs = {0}; nvn_fstep_next(&cs, 1.0, 0.5, 1, FSTEP_MAX, 0, 0); int at2 = -1;
      for (int i = 0; i < 60 && at2 < 0; i++) { nvn_fstep_next(&cs, 1.3, 1.3, 1, FSTEP_MAX, 0, 0); if (cs.k == 2) at2 = i; }
      eq_i("出图也迟到：第 25 个迟到帧（i = 24）升", at2, 24);
      // 11-06 窗口优先看真正上屏（onscreen：0 未知 / 1 准时 / 2 晚）：同上 25% 开始间隔迟到（i % 4 == 0 时 shown 1.6、cost 1.3）
      //   期望手算：上屏全准时 → 窗口 0 帧晚 ≤ 24，400 帧留 k 1；那 25% 上屏也晚 → 与不给判定同为 i = 96 升（窗口 25 > 24）
      nvn_fstep os1 = {0}; nvn_fstep_next(&os1, 1.0, 0.5, 1, FSTEP_MAX, 0, 0);
      for (int i = 0; i < 400; i++) { int lt = i % 4 == 0; os1.onscreen = 1; nvn_fstep_next(&os1, lt ? 1.6 : 1.0, lt ? 1.3 : 0.6, 1, FSTEP_MAX, 0, 0); }
      eq_i("开始间隔 25% 迟到、上屏全准时 400 帧：留在 k 1", os1.k * 10 + (int)os1.ups, 10);
      nvn_fstep os2 = {0}; nvn_fstep_next(&os2, 1.0, 0.5, 1, FSTEP_MAX, 0, 0); int at3 = -1;
      for (int i = 0; i < 400 && at3 < 0; i++) { int lt = i % 4 == 0; os2.onscreen = lt ? 2 : 1; nvn_fstep_next(&os2, lt ? 1.6 : 1.0, lt ? 1.3 : 0.6, 1, FSTEP_MAX, 0, 0); if (os2.k == 2) at3 = i; }
      eq_i("上屏也 25% 晚：i = 96 升", at3, 96);
      eq_i("判定用过即清", os2.onscreen, 0); }

    if (fails) printf("✗ t_nvn_fstep_core：%d / %d 项不符\n", fails, checks);
    else printf("✓ t_nvn_fstep_core：帧步进 %d 项全过（0 处不符）\n", checks);
    return fails ? 1 : 0;
}
