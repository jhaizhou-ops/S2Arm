// Same-thread reverse calls for the Vulkan allocator ABI. No guest SDK hooks.
// xs_slot and the 112-byte xs_entry frame are private native xstack ABI; the
// actual-core tests must fail if those layouts or cursor semantics change.
#include "direct_callback.h"
#include <stdio.h>
#include <stdlib.h>

#if defined(S2A_ANDROID_GAME_RUNTIME) || defined(S2A_DIRECT_CALLBACK_TEST)
#include <pthread.h>
extern uint64_t g_xs_key;
struct xs_slot { uint64_t cur, top, bottom, guest_top; };
extern uint64_t s2a_android_vk_call_guest6(void *, uint64_t, const uint64_t *, uint64_t *);
static _Thread_local unsigned depth;
static _Noreturn void invalid(const char *why) {
    fprintf(stderr, "[vk-direct] 【红】allocator反向调用：%s\n", why); abort();
}

uint64_t s2a_android_vk_guest_callback(void *function, const uint64_t args[6]) {
    struct xs_slot *slot = pthread_getspecific((pthread_key_t)g_xs_key);
    if (!slot || !function || !args || depth) invalid("没有客体线程/函数，或回调递归");
    uint64_t cursor = slot->cur;
    if (cursor <= slot->bottom || cursor > slot->top || slot->top - cursor < 112)
        invalid("没有有效的外层xs_entry帧");
    const uint64_t *frame = (const uint64_t *)(uintptr_t)cursor;
    if (frame[12] != (uint64_t)(uintptr_t)slot) invalid("外层xs_entry帧主人不匹配");
    uint64_t guest_sp = frame[8];
    if ((guest_sp & 15) || guest_sp < 16 || (slot->guest_top && guest_sp > slot->guest_top) ||
        (guest_sp > slot->bottom && guest_sp <= slot->top)) invalid("客体栈位置无效");
    depth++;
    uint64_t result = s2a_android_vk_call_guest6(function, guest_sp, args, &slot->cur);
    depth--;
    if (slot->cur != cursor) invalid("回调返回后宿主栈游标未恢复");
    return result;
}
#else
uint64_t s2a_android_vk_guest_callback(void *function, const uint64_t args[6]) {
    (void)function; (void)args;
    fprintf(stderr, "[vk-direct] 【红】诊断目标没有客体反向调用上下文\n"); abort();
}
#endif
