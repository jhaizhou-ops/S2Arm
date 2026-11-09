// 兼容层（移植自 nxnative-hades1 的 dm/host/dm.h）：只保留齿轮菜单「退出游戏」用到的接口。
// S2Arm 单款包没有进程内退出 / 回库 API（多款容器也只提示划掉 App），本阶段空实现并把菜单项置灰。
#pragma once
void dm_host_shutdown(const char *why);
