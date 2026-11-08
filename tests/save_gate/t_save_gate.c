// iOS 存档页状态（ios/save_gate.h）单测：期望按审计 P0-1 的要求手推，不跑被测实现得出
#include <stdio.h>
#include "save_gate.h"
static int fails;
#define CK(c, what) do { if (c) printf("过 %s\n", what); else { printf("红 %s\n", what); fails++; } } while (0)
int main(void) {
    struct s2a_save_buttons b; enum s2a_save_phase p;
    // ① 无事务：打开即可开始、导入；有存档才可导出；没有「仍要开始」
    p = s2a_save_next(S2A_SAVE_CHECKING, S2A_SAVE_EV_OPEN_NO_TX); b = s2a_save_buttons(p, 0, 1, 1, 0);
    CK(b.start && b.import && b.export_ && !b.override, "无事务：开始 / 导入 / 导出可点，无仍要开始");
    b = s2a_save_buttons(p, 0, 1, 0, 0); CK(b.start && !b.export_, "无事务无存档：可开始、不可导出");
    b = s2a_save_buttons(p, 0, 1, 1, 1); CK(!b.start && !b.import, "处理中：全灰");
    // ② 有事务、恢复成功：恢复中全灰，成功后放开
    p = s2a_save_next(S2A_SAVE_CHECKING, S2A_SAVE_EV_OPEN_TX); b = s2a_save_buttons(p, 0, 1, 1, 0);
    CK(!b.start && !b.import && !b.override, "恢复中：开始 / 导入灰，无仍要开始");
    p = s2a_save_next(p, S2A_SAVE_EV_RECOVER_OK); b = s2a_save_buttons(p, 0, 1, 1, 0);
    CK(b.start && b.export_ && !b.override, "恢复成功：开始 / 导出可点");
    // ③ 有事务、恢复失败：不能直接开始，但给「仍要开始」；确认后开始可点（旧逻辑停在恢复中，这两条红）
    p = s2a_save_next(s2a_save_next(S2A_SAVE_CHECKING, S2A_SAVE_EV_OPEN_TX), S2A_SAVE_EV_RECOVER_FAIL); b = s2a_save_buttons(p, 0, 1, 1, 0);
    CK(!b.start && b.override, "恢复失败：开始灰、出现仍要开始");
    b = s2a_save_buttons(p, 1, 1, 1, 0); CK(b.start && b.export_ && !b.override, "恢复失败后确认仍要开始：开始 / 导出可点");
    // ④ 缺存档服务：有事务 → 同恢复失败；没事务 → 照常开始、不能导入导出
    p = s2a_save_next(s2a_save_next(S2A_SAVE_CHECKING, S2A_SAVE_EV_OPEN_TX), S2A_SAVE_EV_NO_SERVICE); b = s2a_save_buttons(p, 0, 0, 1, 0);
    CK(!b.start && b.override, "缺服务有事务：开始灰、出现仍要开始");
    b = s2a_save_buttons(p, 1, 0, 1, 0); CK(b.start && !b.import && !b.export_, "缺服务有事务确认后：可开始、不可导入导出");
    p = s2a_save_next(s2a_save_next(S2A_SAVE_CHECKING, S2A_SAVE_EV_OPEN_NO_TX), S2A_SAVE_EV_NO_SERVICE); b = s2a_save_buttons(p, 0, 0, 1, 0);
    CK(b.start && !b.import && !b.override, "缺服务无事务：可开始、不可导入、无仍要开始");
    // 还原失败留下事务 = 恢复失败；还原成功放开；读不到存档位置与恢复失败同一个确认（审计 18:00 P2-14）
    p = s2a_save_next(S2A_SAVE_READY, S2A_SAVE_EV_RESTORE_FAIL_TX); b = s2a_save_buttons(p, 0, 1, 1, 0);
    CK(!b.start && b.override, "还原失败留事务：开始灰、出现仍要开始");
    p = s2a_save_next(p, S2A_SAVE_EV_RESTORE_OK); CK(s2a_save_buttons(p, 0, 1, 1, 0).start, "还原成功：可开始");
    p = s2a_save_next(S2A_SAVE_CHECKING, S2A_SAVE_EV_NO_ROOT); b = s2a_save_buttons(p, 0, 1, 1, 0);
    CK(!b.start && b.override && !b.import && !b.export_, "读不到存档位置：开始灰、出现仍要开始、不能导入导出");
    b = s2a_save_buttons(p, 1, 1, 1, 0);
    CK(b.start && !b.override && !b.import && !b.export_, "读不到存档位置、确认后：可开始，仍不能导入导出");
    printf("%s：%d 条红\n", fails ? "红" : "绿", fails);
    return fails != 0;
}
