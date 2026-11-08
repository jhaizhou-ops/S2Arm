// Counterexample: the old attach path proceeded without waiting for the scene.
// Linked only into the negative-control executable, never into the app.
#include "root_ready.h"
void s2a_ios_root_view_ready(void) { }
int s2a_ios_wait_root_view(int timeout_ms) { (void)timeout_ms; return 0; }
// 旧做法（审计 P2-16）：主线程上不等玩家选，直接返回
void s2a_ios_wait_ui_signal(dispatch_semaphore_t done) { (void)done; }
// 旧做法（审计 P2-17）：没有界面也当场开始
void s2a_ios_on_root_view(void (^block)(void)) { block(); }
