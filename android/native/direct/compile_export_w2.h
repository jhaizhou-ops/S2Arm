// Single gated entry point for W2 diagnostic observations; no synthetic producer.
#pragma once
#include "w2_single_query.h"
#ifdef __cplusplus
extern "C" {
#endif

enum { S2A_COMPILE_EXPORT_W2_UNWIRED = -100 };
struct s2a_compile_export_w2_key {
    uint64_t session, generation;
    uint8_t input_sha[32]; /* SHA-256 of the full canonical input, not requestId. */
};
/* The provider owns all returned storage and keeps it immutable until the
 * diagnosis returns. It must not call set_provider or diagnose recursively.
 * A nonzero return means the frozen input is unavailable. The key identifies
 * content within a session, not a unique compile attempt: if several failures
 * match, the provider must reject ambiguity rather than choose one.
 *
 * Lock order: the draw caller can hold source pins and its own outer locks;
 * this module then holds provider_lock across provider and resolver callbacks.
 * Registration/unregistration must be called with no draw, worker or provider
 * snapshot locks held. Callbacks must not wait for draw/worker or acquire a
 * lock whose owner may register/unregister. Both callbacks must be bounded and
 * nonblocking: this synchronous diagnostic has no timeout or cancellation and
 * a stalled callback will stall the calling compile thread and registration. */
typedef int (*s2a_compile_export_w2_provider)(void *ctx, const struct s2a_compile_export_w2_key *key,
    const struct s2a_w2_query_input **input, s2a_w2_query_resolver *resolver,
    void **snapshot);
/* Replacement/unregistration waits for any in-flight provider and resolver.
 * After this returns the prior provider's context may be released. */
void s2a_compile_export_w2_set_provider(s2a_compile_export_w2_provider provider, void *ctx);
int s2a_compile_export_w2_diagnose(const struct s2a_compile_export_w2_key *key,
    struct s2a_w2_query_receipt *receipt);
#ifdef __cplusplus
}
#endif
