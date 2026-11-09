// 兼容层（移植自 nxnative-hades1 的 dm/host/hle.h）：源文件只用到 LOG 与金手指引擎接口。
// LOG 直接复用 S2Arm 原生层的 native.h（写 fd 2 / host.log，与壳内其他日志同一套）。
#pragma once
#include "native.h"

// ---- 金手指（引擎在 ios/dmpad_cheats.m，页面在 ios/DmCheats.m） ----
int dm_cheats_count(void);
int dm_cheats_is_master(int i);
int dm_cheats_unswitchable(int i);
int dm_cheats_stores(int i);
const char *dm_cheats_source(void);
const char *dm_cheats_name(int i);
int dm_cheats_needs_bake(int i);
unsigned dm_cheats_hotkey(int i);
int dm_cheats_on(int i);
void dm_cheats_set(int i, int on);
void dm_cheats_set_all(int on);
void dm_cheats_ensure(void);
int dm_cheats_reload(void);
int dm_cheats_load(const char *path);
int dm_cheats_cond(int i);
void dm_cheats_tick(void);
