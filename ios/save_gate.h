// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// iOS 存档页的状态与按钮（纯函数，不碰 UIKit；单测 tests/save_gate_test.sh）。
// 审计 P0-1：旧页面在「恢复失败」时只返回、不改状态，开始游戏和导出永久灰、重开 App 还卡在这页。
// 现在恢复失败进 RECOVER_FAILED：给「仍要开始游戏…」，玩家单独确认可能丢掉没做完的导入 / 恢复后放开开始游戏。
#pragma once

enum s2a_save_phase {
    S2A_SAVE_CHECKING,        // 有没做完的事务，正在恢复
    S2A_SAVE_READY,           // 没有事务，或恢复 / 还原成功
    S2A_SAVE_RECOVER_FAILED,  // 恢复失败、缺存档服务没法恢复、还原失败留下了事务
    S2A_SAVE_NO_ROOT,         // 读不到存档位置
};
enum s2a_save_event {
    S2A_SAVE_EV_OPEN_NO_TX,   // 打开页面，没有事务记录
    S2A_SAVE_EV_OPEN_TX,      // 打开页面，有事务记录（或读不出事务目录）
    S2A_SAVE_EV_NO_SERVICE,   // 安装包缺存档服务 / 游戏身份
    S2A_SAVE_EV_RECOVER_OK,
    S2A_SAVE_EV_RECOVER_FAIL,
    S2A_SAVE_EV_RESTORE_OK,
    S2A_SAVE_EV_RESTORE_FAIL_TX,  // 还原失败且留下了事务（没留事务的还原失败不改状态）
    S2A_SAVE_EV_NO_ROOT,
};
static inline enum s2a_save_phase s2a_save_next(enum s2a_save_phase p, enum s2a_save_event e) {
    switch (e) {
    case S2A_SAVE_EV_OPEN_NO_TX: return S2A_SAVE_READY;
    case S2A_SAVE_EV_OPEN_TX: return S2A_SAVE_CHECKING;
    // 缺服务：有事务就没法恢复；没事务照常能玩（只是不能导入导出）
    case S2A_SAVE_EV_NO_SERVICE: return p == S2A_SAVE_CHECKING ? S2A_SAVE_RECOVER_FAILED : p;
    case S2A_SAVE_EV_RECOVER_OK: case S2A_SAVE_EV_RESTORE_OK: return S2A_SAVE_READY;
    case S2A_SAVE_EV_RECOVER_FAIL: case S2A_SAVE_EV_RESTORE_FAIL_TX: return S2A_SAVE_RECOVER_FAILED;
    case S2A_SAVE_EV_NO_ROOT: return S2A_SAVE_NO_ROOT;
    }
    return p;
}
// overridden = 玩家在 RECOVER_FAILED / NO_ROOT 页确认过「仍要开始」；service = 存档服务与游戏身份都在
//   读不到存档位置（审计 18:00 P2-14）与恢复失败用同一个确认：确认后可开始；没有存档位置就不能导入 / 导出
struct s2a_save_buttons { int start, import, export_, override; };
static inline struct s2a_save_buttons s2a_save_buttons(enum s2a_save_phase p, int overridden, int service, int has_save, int busy) {
    int blocked = p == S2A_SAVE_RECOVER_FAILED || p == S2A_SAVE_NO_ROOT;
    int ok = p == S2A_SAVE_READY || (blocked && overridden);
    struct s2a_save_buttons b = { !busy && ok, !busy && service && ok && p != S2A_SAVE_NO_ROOT, 0, blocked && !overridden };
    b.export_ = b.import && has_save;
    return b;
}
