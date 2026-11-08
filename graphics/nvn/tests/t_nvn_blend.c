// 高级混合状态位的布局与语义边界（#270 N12，BlendState 高级混合组）：blend_st 长在游戏给的 NVNblendState（8 字节）里，
// 又被 PSO 键按 8 个 blend_st 原样收进去（nvn_pso_skey.h），所以只许在同一个 uint64_t 内加位：
//   · sizeof(blend_st) 必须还是 8（否则越界写游戏对象 / PSO 键布局漂移）；
//   · adv_mode 要装得下 NVN 的最大值 0x32（50），adv_overlap 要装下 0..2；
//   · adv_* 与既有的 target / src_rgb / … 互不别名。
// 纯 C，不需要 GPU、不需要起局。
#include <stdio.h>
#include <string.h>
#include "../gfx/nvn/nvn_obj.h"

int main(void) {
    int bad = 0;
#define CHECK(c, ...) do { if (!(c)) { printf("✗ "); printf(__VA_ARGS__); printf("\n"); bad++; } } while (0)

    CHECK(sizeof(blend_st) == 8, "blend_st 应为 8 字节（实际 %zu）", sizeof(blend_st));
    CHECK(sizeof(blend_st) <= sizeof(NVNblendState), "blend_st 不得大于 NVNblendState（%zu > %zu）",
          sizeof(blend_st), sizeof(NVNblendState));

    blend_st s;
    memset(&s, 0, sizeof s);
    CHECK(s.adv_mode == 0 && s.adv_overlap == 0 && s.adv_premul == 0 && s.adv_normdst == 0, "零初始化后 adv_* 应为 0");

    // adv_mode：装得下规范最大值 0x32（50），并原样读回
    s.adv_mode = 0x32;
    CHECK(s.adv_mode == 0x32, "adv_mode 存不下 0x32（读到 %u）", (unsigned)s.adv_mode);
    // adv_overlap：0..2 三个合法值
    for (unsigned v = 0; v <= 2; v++) {
        s.adv_overlap = v;
        CHECK(s.adv_overlap == v, "adv_overlap 存不下 %u（读到 %u）", v, (unsigned)s.adv_overlap);
    }

    // 互不别名：写满既有字段 + adv_*，逐项读回
    memset(&s, 0, sizeof s);
    s.target = 7; s.src_rgb = 0x12; s.dst_rgb = 0x34; s.src_a = 0x56; s.dst_a = 0x78;
    s.eq_rgb = 5; s.eq_a = 6;
    s.adv_mode = 0x2E; s.adv_overlap = 2; s.adv_premul = 1; s.adv_normdst = 1;
    CHECK(s.target == 7 && s.src_rgb == 0x12 && s.dst_rgb == 0x34 && s.src_a == 0x56 && s.dst_a == 0x78 &&
          s.eq_rgb == 5 && s.eq_a == 6, "写 adv_* 后既有 blend 字段被改（别名）");
    CHECK(s.adv_mode == 0x2E && s.adv_overlap == 2 && s.adv_premul == 1 && s.adv_normdst == 1,
          "adv_* 读回不一致（mode=%u overlap=%u premul=%u norm=%u）",
          (unsigned)s.adv_mode, (unsigned)s.adv_overlap, (unsigned)s.adv_premul, (unsigned)s.adv_normdst);

    // 反向：改既有字段不能动 adv_*
    s.src_rgb = 0x7F; s.eq_a = 1; s.target = 0;
    CHECK(s.adv_mode == 0x2E && s.adv_overlap == 2 && s.adv_premul == 1 && s.adv_normdst == 1,
          "改既有字段后 adv_* 变了");

    printf("%s t_nvn_blend：blend_st %zu 字节，adv_* 与既有字段不别名、范围可容纳\n",
           bad ? "✗" : "✓", sizeof(blend_st));
    return bad != 0;
}
