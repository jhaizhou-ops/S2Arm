#include "direct/compile_export_w2.h"
#include "direct/sha256.h"
#include <assert.h>
#include <errno.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

static int enabled, calls, provider_calls;
static struct s2a_w2_query_input given_input;
static int snapshot_a, snapshot_b;
static const uint8_t canonical[] = {1, 2, 3, 4};
static struct s2a_compile_export_w2_key key;
static pthread_mutex_t test_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t test_cond = PTHREAD_COND_INITIALIZER;
static int entered, release_callback, unregister_started, unregister_finished;
int s2a_compile_export_open(void) { return enabled; }
static int resolver(void *ctx, const struct s2a_w2_query *q, struct s2a_w2_query_source *out) {
    (void)ctx; (void)q; (void)out; return 0;
}
int s2a_w2_single_query_diagnose(const struct s2a_w2_query_input *input,
    s2a_w2_query_resolver resolve, void *snapshot, struct s2a_w2_query_receipt *receipt) {
    assert(input == &given_input && resolve == resolver);
    assert(snapshot == &snapshot_a || snapshot == &snapshot_b);
    calls++; receipt->observed = 1; return S2A_W2_QUERY_OBSERVED;
}
static int provider(void *ctx, const struct s2a_compile_export_w2_key *received, const struct s2a_w2_query_input **input,
    s2a_w2_query_resolver *resolve, void **snapshot) {
    assert(ctx == &snapshot_a || ctx == &snapshot_b);
    assert(received == &key && received->session == 41 && received->generation == 42);
    provider_calls++; *input = &given_input; *resolve = resolver; *snapshot = ctx; return 0;
}
static int provider_b(void *ctx, const struct s2a_compile_export_w2_key *received,
    const struct s2a_w2_query_input **input, s2a_w2_query_resolver *resolve, void **snapshot) {
    assert(ctx == &snapshot_b);
    return provider(ctx, received, input, resolve, snapshot);
}
static int provider_a(void *ctx, const struct s2a_compile_export_w2_key *received,
    const struct s2a_w2_query_input **input, s2a_w2_query_resolver *resolve, void **snapshot) {
    assert(ctx == &snapshot_a);
    return provider(ctx, received, input, resolve, snapshot);
}
static int missing_provider(void *ctx, const struct s2a_compile_export_w2_key *received,
    const struct s2a_w2_query_input **input, s2a_w2_query_resolver *resolve, void **snapshot) {
    (void)ctx; (void)received; (void)input; (void)resolve; (void)snapshot; return -1;
}
/* Deliberately blocked only in this fixture to prove unregister waits for the
 * active call; production callbacks have the opposite, nonblocking contract. */
static int held_provider(void *ctx, const struct s2a_compile_export_w2_key *received,
    const struct s2a_w2_query_input **input, s2a_w2_query_resolver *resolve, void **snapshot) {
    pthread_mutex_lock(&test_lock);
    entered = 1; pthread_cond_broadcast(&test_cond);
    while (!release_callback) pthread_cond_wait(&test_cond, &test_lock);
    pthread_mutex_unlock(&test_lock);
    return provider_a(ctx, received, input, resolve, snapshot);
}
static void *held_call(void *unused) {
    (void)unused;
    struct s2a_w2_query_receipt r;
    assert(s2a_compile_export_w2_diagnose(&key, &r) == S2A_W2_QUERY_OBSERVED);
    return NULL;
}
static void *unregister_call(void *unused) {
    (void)unused;
    pthread_mutex_lock(&test_lock);
    unregister_started = 1; pthread_cond_broadcast(&test_cond);
    pthread_mutex_unlock(&test_lock);
    s2a_compile_export_w2_set_provider(NULL, NULL);
    pthread_mutex_lock(&test_lock);
    unregister_finished = 1; pthread_cond_broadcast(&test_cond);
    pthread_mutex_unlock(&test_lock);
    return NULL;
}
static void *register_loop(void *arg) {
    for (int i = 0; i < 10000; ++i) {
        s2a_compile_export_w2_set_provider(arg == &snapshot_a ? provider_a : provider_b, arg);
        s2a_compile_export_w2_set_provider(NULL, NULL);
    }
    return NULL;
}
static void *call_loop(void *unused) {
    (void)unused;
    for (int i = 0; i < 10000; ++i) {
        struct s2a_w2_query_receipt r;
        int rc = s2a_compile_export_w2_diagnose(&key, &r);
        assert(rc == S2A_W2_QUERY_OBSERVED || rc == S2A_COMPILE_EXPORT_W2_UNWIRED);
        assert(r.observed == (rc == S2A_W2_QUERY_OBSERVED));
    }
    return NULL;
}
int main(void) {
    struct s2a_w2_query_receipt r;
    key.session = 41; key.generation = 42;
    given_input.original.stamp.session = key.session; given_input.original.stamp.generation = key.generation;
    given_input.original.canonical = canonical; given_input.original.canonical_bytes = sizeof canonical;
    s2a_sha256 sha; s2a_sha256_init(&sha); s2a_sha256_update(&sha, canonical, sizeof canonical); s2a_sha256_final(&sha, key.input_sha);
    memset(&r, 0xff, sizeof r); enabled = 0;
    s2a_compile_export_w2_set_provider(provider, &snapshot_a);
    assert(s2a_compile_export_w2_diagnose(&key, &r) == S2A_W2_QUERY_DISABLED);
    assert(!r.observed && calls == 0 && provider_calls == 0);
    enabled = 1; s2a_compile_export_w2_set_provider(NULL, NULL);
    memset(&r, 0xff, sizeof r);
    assert(s2a_compile_export_w2_diagnose(&key, &r) == S2A_COMPILE_EXPORT_W2_UNWIRED);
    assert(!r.observed && calls == 0);
    s2a_compile_export_w2_set_provider(provider, &snapshot_a);
    assert(s2a_compile_export_w2_diagnose(&key, &r) == S2A_W2_QUERY_OBSERVED);
    assert(r.observed && calls == 1 && provider_calls == 1);
    key.input_sha[0] ^= 1;
    assert(s2a_compile_export_w2_diagnose(&key, &r) == S2A_W2_QUERY_IDENTITY);
    assert(!r.observed && calls == 1); key.input_sha[0] ^= 1;
    given_input.original.stamp.generation++;
    assert(s2a_compile_export_w2_diagnose(&key, &r) == S2A_W2_QUERY_IDENTITY);
    assert(!r.observed && calls == 1); given_input.original.stamp.generation--;
    s2a_compile_export_w2_set_provider(NULL, NULL);
    assert(s2a_compile_export_w2_diagnose(&key, &r) == S2A_COMPILE_EXPORT_W2_UNWIRED);
    assert(!r.observed && calls == 1 && provider_calls == 3);
    s2a_compile_export_w2_set_provider(missing_provider, NULL);
    assert(s2a_compile_export_w2_diagnose(&key, &r) == S2A_W2_QUERY_NO_SOURCE);
    assert(!r.observed && calls == 1);
    s2a_compile_export_w2_set_provider(NULL, NULL);
    s2a_compile_export_w2_set_provider(held_provider, &snapshot_a);
    pthread_t active, unregistering;
    assert(!pthread_create(&active, NULL, held_call, NULL));
    pthread_mutex_lock(&test_lock);
    while (!entered) pthread_cond_wait(&test_cond, &test_lock);
    pthread_mutex_unlock(&test_lock);
    assert(!pthread_create(&unregistering, NULL, unregister_call, NULL));
    pthread_mutex_lock(&test_lock);
    while (!unregister_started) pthread_cond_wait(&test_cond, &test_lock);
    struct timespec deadline; timespec_get(&deadline, TIME_UTC); deadline.tv_sec++;
    int wait_rc = 0;
    while (!unregister_finished && !wait_rc)
        wait_rc = pthread_cond_timedwait(&test_cond, &test_lock, &deadline);
    assert(!unregister_finished && wait_rc == ETIMEDOUT);
    release_callback = 1; pthread_cond_broadcast(&test_cond);
    pthread_mutex_unlock(&test_lock);
    assert(!pthread_join(active, NULL)); assert(!pthread_join(unregistering, NULL));
    assert(unregister_finished);
    assert(s2a_compile_export_w2_diagnose(&key, &r) == S2A_COMPILE_EXPORT_W2_UNWIRED);
    pthread_t t[4];
    assert(!pthread_create(&t[0], NULL, register_loop, &snapshot_a));
    assert(!pthread_create(&t[1], NULL, register_loop, &snapshot_b));
    assert(!pthread_create(&t[2], NULL, call_loop, NULL));
    assert(!pthread_create(&t[3], NULL, call_loop, NULL));
    for (unsigned i = 0; i < 4; ++i) assert(!pthread_join(t[i], NULL));
    s2a_compile_export_w2_set_provider(NULL, NULL);
    int finished_calls = provider_calls;
    for (int i = 0; i < 1000; ++i)
        assert(s2a_compile_export_w2_diagnose(&key, &r) == S2A_COMPILE_EXPORT_W2_UNWIRED);
    assert(provider_calls == finished_calls);
    puts("W2 gated provider: registration, exact forwarding, unregistration, concurrent calls PASS");
}
