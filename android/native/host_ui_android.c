#include "host_ui_android.h"
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#if defined(__ANDROID__)
#include <android/log.h>
#endif

static pthread_mutex_t producer_lock = PTHREAD_MUTEX_INITIALIZER;
static s2a_ui_broker *broker;
static uint64_t bound_session = 1;   // 兼容旧宿主；正式 runtime 在启动前绑定真实 session
static uint64_t generation;
static int ready, stopped;

static int ensure_broker(void) {
    if (broker) return 0;
    broker = s2a_ui_broker_create(bound_session);
    return broker ? 0 : -1;
}

int s2a_android_ui_bind_session(uint64_t session) {
    if (!session) return S2A_HOST_E_ARGUMENT;
    pthread_mutex_lock(&producer_lock);
    int rc = S2A_HOST_E_OK;
    if (stopped) rc = S2A_HOST_E_UNSUPPORTED;
    else if (broker && broker != NULL && bound_session != session) {
        if (s2a_ui_broker_pending(broker)) rc = S2A_HOST_E_UNSUPPORTED;
        else {
            s2a_ui_broker_available(broker, bound_session, 0);
            s2a_ui_broker_destroy(broker);
            broker = s2a_ui_broker_create(session);
            if (!broker) rc = S2A_HOST_E_INTERNAL;
            else {
                bound_session = session;
                ready = generation != 0 && s2a_ui_broker_available(broker, bound_session, 1) == 0;
            }
        }
    } else bound_session = session;
    pthread_mutex_unlock(&producer_lock);
    return rc;
}

uint64_t s2a_android_ui_attach(void) {
    pthread_mutex_lock(&producer_lock);
    uint64_t result = 0;
    if (ensure_broker() == 0 && !stopped && generation != UINT64_MAX) {
        s2a_ui_broker_available(broker, bound_session, 0);
        ++generation;
        ready = s2a_ui_broker_available(broker, bound_session, 1) == 0;
        if (ready) result = generation;
    }
    pthread_mutex_unlock(&producer_lock);
    return result;
}
void s2a_android_ui_detach(uint64_t owner) {
    pthread_mutex_lock(&producer_lock);
    if (owner && owner == generation && broker) {
        ready = 0;
        s2a_ui_broker_available(broker, bound_session, 0);
    }
    pthread_mutex_unlock(&producer_lock);
}
void s2a_android_ui_stop(void) {
    pthread_mutex_lock(&producer_lock);
    stopped = 1; ready = 0;
    if (broker) s2a_ui_broker_stop(broker, bound_session);
    pthread_mutex_unlock(&producer_lock);
}
// The HostApi context is android_host, not the broker. Delegate explicitly.
static int begin(void *host, const char *text, uint64_t *id) {
    (void)host;
    return s2a_ui_broker_table()->begin(broker, text, id);
}
static int wait_reply(void *host, uint64_t id, int timeout, char *text, size_t cap, size_t *length) {
    (void)host;
    // No producer lock across a wait. Broker storage lives until process exit.
    return s2a_ui_broker_table()->wait(broker, id, timeout, text, cap, length);
}
static int cancel(void *host, uint64_t id) {
    (void)host;
    return s2a_ui_broker_table()->cancel(broker, id);
}
const s2a_host_ui_v1 *s2a_android_ui_table(void) {
    static const s2a_host_ui_v1 table = {{sizeof(s2a_host_ui_v1), S2A_HOST_API_ABI_VERSION}, begin, wait_reply, cancel};
    pthread_mutex_lock(&producer_lock);
    const s2a_host_ui_v1 *result = ready && !stopped && broker ? &table : NULL;
    pthread_mutex_unlock(&producer_lock);
    return result;
}
int s2a_android_ui_take(uint64_t owner, uint64_t *id, char *text, size_t cap, size_t *length) {
    pthread_mutex_lock(&producer_lock);
    int rc = (owner && owner == generation && ready && broker)
        ? s2a_ui_broker_take(broker, bound_session, id, text, cap, length) : S2A_HOST_E_UNSUPPORTED;
    pthread_mutex_unlock(&producer_lock);
    return rc;
}
int s2a_android_ui_complete(uint64_t owner, uint64_t id, const char *text) {
    pthread_mutex_lock(&producer_lock);
    int rc = (owner && owner == generation && ready && broker)
        ? s2a_ui_broker_complete(broker, bound_session, id, text) : S2A_HOST_E_UNSUPPORTED;
    pthread_mutex_unlock(&producer_lock);
    return rc;
}

struct selftest_waiter { s2a_ui_broker *broker; uint64_t id; };
// Preview consumer: the production applet waiter is C# (AndroidHostUi). This one only
// proves the broker wakes its waiter and logs a terminal status without player text.
static void *selftest_waiter(void *opaque) {
    struct selftest_waiter *w = opaque;
    char reply[S2A_UI_REPLY_LIMIT + 1];
    size_t length = 0;
    int rc = s2a_ui_broker_table()->wait(w->broker, w->id, 30000, reply, sizeof reply, &length);
    const char *status = "none";
    if (rc == 0) {
        if (strstr(reply, "\"status\":\"ok\"")) status = "ok";
        else if (strstr(reply, "\"status\":\"cancel\"")) status = "cancel";
        else status = "other";
    }
#if defined(__ANDROID__)
    __android_log_print(ANDROID_LOG_INFO, "S2Arm",
        "Keyboard selftest reply: rc=%d status=%s bytes=%zu (text not logged)", rc, status, length);
#else
    fprintf(stderr, "Keyboard selftest reply: rc=%d status=%s bytes=%zu (text not logged)\n",
            rc, status, length);
#endif
    free(w);
    return NULL;
}

int s2a_android_ui_selftest(int mode, int min, int max) {
    if (mode < 0 || (mode > 3 && mode != 5) || min < 0 || max < min || max > 1024) return 0;
    pthread_mutex_lock(&producer_lock);
    int result = 0;
    if (ready && !stopped && broker) {
        char request[512];
        int request_length = snprintf(request, sizeof request,
            "{\"version\":1,\"type\":\"software-keyboard\",\"mode\":%d,\"min\":%d,\"max\":%d,"
            "\"header\":\"S2Arm IME selftest\",\"subtitle\":\"输入后点确定\",\"guide\":\"hello\","
            "\"initial\":\"\",\"submit\":\"确定\"}", mode, min, max);
        uint64_t id = 0;
        if (request_length > 0 && request_length < (int)sizeof request &&
            s2a_ui_broker_table()->begin(broker, request, &id) == 0 && id) {
            struct selftest_waiter *waiter = malloc(sizeof *waiter);
            pthread_t thread;
            if (waiter) { waiter->broker = broker; waiter->id = id; }
            if (!waiter || pthread_create(&thread, NULL, selftest_waiter, waiter)) {
                free(waiter);
                s2a_ui_broker_table()->cancel(broker, id);
            } else {
                pthread_detach(thread);
#if defined(__ANDROID__)
                __android_log_print(ANDROID_LOG_INFO, "S2Arm",
                    "Keyboard selftest request: id=%llu mode=%d min=%d max=%d",
                    (unsigned long long)id, mode, min, max);
#else
                fprintf(stderr, "Keyboard selftest request: id=%llu mode=%d min=%d max=%d\n",
                        (unsigned long long)id, mode, min, max);
#endif
                result = (int)id;
            }
        }
    }
    pthread_mutex_unlock(&producer_lock);
    return result;
}
