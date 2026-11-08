// Host-only pthread driver. Uses the production private services status ABI.
#include "services_abi.h"
#include <pthread.h>
#include <stdint.h>
#include <string.h>

typedef int (*attach_fn)(uint64_t, struct s2a_android_services_status *);
typedef int (*observe_fn)(uint64_t, int);
struct attach_result {
    int first, repeated, observation, reserved;
    struct s2a_android_services_status first_status, repeated_status;
};
struct attach_job {
    attach_fn attach;
    observe_fn observe;
    uint64_t session;
    struct attach_result *result;
};
_Static_assert(sizeof(struct attach_result) == 64, "fixture result ABI");

static void *attach_pthread(void *opaque) {
    struct attach_job *job = opaque;
    struct attach_result *result = job->result;
    result->first_status.size = sizeof(result->first_status);
    result->first_status.version = S2A_ANDROID_SERVICES_ABI;
    // This is this newly created native pthread's FIRST managed callback. The
    // observer runs afterwards so it cannot pre-attach the thread for the test.
    result->first = job->attach(job->session, &result->first_status);
    result->observation = job->observe(job->session, result->first);
    result->repeated_status.size = sizeof(result->repeated_status);
    result->repeated_status.version = S2A_ANDROID_SERVICES_ABI;
    result->repeated = job->attach(job->session, &result->repeated_status);
    return NULL;
}

int s2a_test_attach_pthreads(attach_fn attach, observe_fn observe, uint64_t session,
                           struct attach_result *results, uint32_t count) {
    if (!attach || !observe || !results || count == 0 || count > 8) return -1;
    pthread_t threads[8];
    struct attach_job jobs[8];
    uint32_t started = 0;
    int error = 0;
    memset(results, 0, count * sizeof(*results));
    for (; started < count; started++) {
        jobs[started] = (struct attach_job){attach, observe, session, &results[started]};
        error = pthread_create(&threads[started], NULL, attach_pthread, &jobs[started]);
        if (error) break;
    }
    for (uint32_t i = 0; i < started; i++) {
        int joined = pthread_join(threads[i], NULL);
        if (joined && !error) error = joined;
    }
    return error;
}
