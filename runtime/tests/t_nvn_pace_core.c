// D7 第七片：nvn_pace.h 的上屏节拍器是纯函数（只依赖 stdint），能在 Linux 上单独编译验证。
// 期望值按「按 vsync 排槽」语义手算：period=0 不等；首帧取当前时间；早到等到槽；晚到不足一拍
// 立即出图并保留原相位；晚到 ≥ 一拍从当前时间重新起拍，不补发。
#include "nvn_pace.h"
#include <stdio.h>

static int fails, checks;

static void eq_u64(const char *what, uint64_t got, uint64_t want) {
    checks++;
    if (got != want) { fails++; printf("FAIL %s：实为 %llu，期望 %llu\n", what, (unsigned long long)got, (unsigned long long)want); }
}

static void eq_pacer(const char *what, const nvn_pacer *p, uint64_t want) {
    eq_u64(what, p->target, want);
}

int main(void) {
    const uint64_t P = 100;

    // period = 0：不等，槽跟当前时间
    nvn_pacer z = {0};
    eq_u64("period 0 不等", nvn_pace(&z, 1000, 0), 0);
    eq_pacer("period 0 槽", &z, 1000);

    // 首帧：没有相位，立即出图并记下当前时间
    nvn_pacer p = {0};
    eq_u64("首帧不等", nvn_pace(&p, 1000, P), 0);
    eq_pacer("首帧槽", &p, 1000);

    // 下一帧早到 90ns：等到槽（1100），相位保留
    eq_u64("早到等待", nvn_pace(&p, 1010, P), 90);
    eq_pacer("早到槽", &p, 1100);

    // 正好踩槽：不等
    eq_u64("正点不等", nvn_pace(&p, 1100, P), 100);

    // 槽已推进到 1200；1250 早到下一槽 1300 的前 50
    eq_u64("再早到", nvn_pace(&p, 1250, P), 50);
    eq_pacer("再早到槽", &p, 1300);

    // 晚到 50（1450 vs 槽 1400，不足一拍）→ 立即出图、保留相位 1400
    eq_u64("晚到不足一拍", nvn_pace(&p, 1450, P), 0);
    eq_pacer("晚到不足一拍槽", &p, 1400);

    // 晚到 ≥ 一拍（1600 vs 槽 1500）：从当前时间重新起拍
    eq_u64("晚到一拍不等", nvn_pace(&p, 1600, P), 0);
    eq_pacer("晚到一拍槽", &p, 1600);

    // 重新起拍后早到 40：等到 1700
    eq_u64("重启后早到", nvn_pace(&p, 1660, P), 40);
    eq_pacer("重启后槽", &p, 1700);

    if (fails) printf("✗ t_nvn_pace_core：%d / %d 项不符\n", fails, checks);
    else printf("✓ t_nvn_pace_core：上屏节拍 %d 项全过（0 处不符）\n", checks);
    return fails ? 1 : 0;
}
