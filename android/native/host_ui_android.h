#pragma once
#include "host_ui.h"
#ifdef __cplusplus
extern "C" {
#endif
// One game session per process. Activity generations own producer delivery;
// replacement/detach cancels old requests and rejects late UI answers.
// 绑定本进程实际 runtime session（在 HLE 启动前调用；已有在途请求时拒绝）。
int s2a_android_ui_bind_session(uint64_t session);
uint64_t s2a_android_ui_attach(void);
void s2a_android_ui_detach(uint64_t generation);
void s2a_android_ui_stop(void);
const s2a_host_ui_v1 *s2a_android_ui_table(void);
int s2a_android_ui_take(uint64_t generation, uint64_t *id, char *text, size_t capacity, size_t *length);
int s2a_android_ui_complete(uint64_t generation, uint64_t id, const char *text);
// Debug preview request (mode 0..3/5; min/max in UTF-16 units). The waiter logs the
// terminal status and byte length, never the reply text. Returns the request ID or 0.
int s2a_android_ui_selftest(int mode, int min, int max);
#ifdef __cplusplus
}
#endif
