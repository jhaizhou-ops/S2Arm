#include "host_ui_android.h"
#include <assert.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
static const s2a_host_ui_v1 *api;
static uint64_t pending;
static int wait_result;
static void *waiter(void *unused) {
    (void)unused;
    char reply[32]; size_t length;
    wait_result = api->wait(NULL, pending, 1000, reply, sizeof reply, &length);
    return NULL;
}
int main(void) {
    assert(s2a_android_ui_table() == NULL);
    uint64_t first = s2a_android_ui_attach(); assert(first);
    api = s2a_android_ui_table(); assert(api);
    assert(!api->begin((void *)123, "{\"text\":\"你好\"}", &pending));
    uint64_t id; char buffer[128]; size_t length;
    assert(s2a_android_ui_take(first + 1, &id, buffer, sizeof buffer, &length) == S2A_HOST_E_UNSUPPORTED);
    assert(!s2a_android_ui_take(first, &id, buffer, sizeof buffer, &length) && id == pending);
    assert(!strcmp(buffer, "{\"text\":\"你好\"}"));
    assert(!s2a_android_ui_complete(first, id, "{\"text\":\"测试😀\"}"));
    assert(api->wait(NULL, id, 0, buffer, 2, &length) == S2A_HOST_E_RANGE);
    assert(!api->wait(NULL, id, 0, buffer, sizeof buffer, &length));
    assert(!strcmp(buffer, "{\"text\":\"测试😀\"}"));
    assert(s2a_android_ui_complete(first, id, "{}") == S2A_HOST_E_ARGUMENT);
    assert(!api->begin(NULL, "{}", &pending));
    assert(!s2a_android_ui_take(first, &id, buffer, sizeof buffer, &length));
    uint64_t second = s2a_android_ui_attach(); assert(second > first);
    assert(s2a_android_ui_complete(first, id, "{}") == S2A_HOST_E_UNSUPPORTED);
    assert(api->wait(NULL, id, 0, buffer, sizeof buffer, &length) == S2A_HOST_E_ARGUMENT);
    s2a_android_ui_detach(first); assert(s2a_android_ui_table());
    assert(!api->begin(NULL, "{}", &pending));
    pthread_t thread; assert(!pthread_create(&thread, NULL, waiter, NULL));
    s2a_android_ui_detach(second); assert(!pthread_join(thread, NULL));
    assert(wait_result == S2A_HOST_E_UNSUPPORTED);
    assert(s2a_android_ui_table() == NULL);
    assert(s2a_android_ui_attach() > second);
    assert(!api->begin(NULL, "{}", &pending));
    assert(!pthread_create(&thread, NULL, waiter, NULL));
    s2a_android_ui_stop(); assert(!pthread_join(thread, NULL));
    assert(wait_result == S2A_HOST_E_UNSUPPORTED);
    assert(!s2a_android_ui_attach() && !s2a_android_ui_table());
    puts("PASS keyboard producer: UTF-8, RANGE, ownership, late reply, detach, stop, terminal state");
}
