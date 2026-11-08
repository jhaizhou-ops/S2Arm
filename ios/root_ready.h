#pragma once
#include <dispatch/dispatch.h>
// Scene signals after its window is visible. Idempotent; all current/future
// render-thread waiters are released. Wait returns 0 when ready, -1 on timeout.
void s2a_ios_root_view_ready(void);
int s2a_ios_wait_root_view(int timeout_ms);
// 等玩家在界面上选完（done 由按钮回调发）：非主线程睡等；主线程上 UIKit 事件也走这条线程、睡下去按钮永远点不到，
//   改为转运行循环直到信号到（审计 P2-16：直连安全网原先在主线程上直接返回、照常起局）。
void s2a_ios_wait_ui_signal(dispatch_semaphore_t done);
// 根视图就绪后在主线程跑 block（已就绪则主队列下一拍跑）：要先在界面上说明、再开始的事，没有界面时挂到这里（审计 P2-17）。
void s2a_ios_on_root_view(void (^block)(void));
