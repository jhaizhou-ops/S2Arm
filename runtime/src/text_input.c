// 系统键盘桥接的公用分发（约定见 runtime/include/s2a_text_input.h）：服务层经 Native.cs Imports 直连这两个导出，
//   平台的输入框实现在启动时登记（iOS ios/textinput.m、Mac 玩家前端 macos/textinput_mac.m）；
//   没登记的平台（安卓、Mac 开发宿主）回 0 = 不交互，服务层退回自动应答
#include "s2a_text_input.h"
#include <stdatomic.h>
#include <stddef.h>

static _Atomic(s2a_text_input_begin_fn) g_begin;
static _Atomic(s2a_text_input_cancel_fn) g_cancel;

void s2a_text_input_provide(s2a_text_input_begin_fn begin, s2a_text_input_cancel_fn cancel) {
    atomic_store(&g_cancel, cancel);
    atomic_store(&g_begin, begin);
}

int s2a_host_text_input(int64_t id, const char *json, s2a_text_input_cb cb) {
    s2a_text_input_begin_fn b = atomic_load(&g_begin);
    return b ? b(id, json, cb) : 0;
}

void s2a_host_text_input_cancel(int64_t id) {
    s2a_text_input_cancel_fn c = atomic_load(&g_cancel);
    if (c) c(id);
}
