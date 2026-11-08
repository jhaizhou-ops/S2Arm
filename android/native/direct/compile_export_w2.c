#include "compile_export_w2.h"
#include "compile_export.h"
#include "sha256.h"
#include <pthread.h>
#include <string.h>

static pthread_mutex_t provider_lock = PTHREAD_MUTEX_INITIALIZER;
static s2a_compile_export_w2_provider registered_provider;
static void *registered_context;

void s2a_compile_export_w2_set_provider(s2a_compile_export_w2_provider provider, void *ctx) {
    pthread_mutex_lock(&provider_lock);
    registered_provider = provider;
    registered_context = provider ? ctx : NULL;
    pthread_mutex_unlock(&provider_lock);
}

int s2a_compile_export_w2_diagnose(const struct s2a_compile_export_w2_key *key,
    struct s2a_w2_query_receipt *receipt) {
    if (!receipt) return S2A_W2_QUERY_INVALID;
    memset(receipt, 0, sizeof *receipt);
    if (!s2a_compile_export_open()) return S2A_W2_QUERY_DISABLED;
    if (!key || !key->session || !key->generation) return S2A_W2_QUERY_INVALID;
    const struct s2a_w2_query_input *input = NULL;
    s2a_w2_query_resolver resolver = NULL;
    void *snapshot = NULL;
    pthread_mutex_lock(&provider_lock);
    int result;
    if (!registered_provider) result = S2A_COMPILE_EXPORT_W2_UNWIRED;
    else if (registered_provider(registered_context, key, &input, &resolver, &snapshot) || !input || !resolver)
        result = S2A_W2_QUERY_NO_SOURCE;
    else if (input->original.stamp.session != key->session || input->original.stamp.generation != key->generation ||
             !input->original.canonical || !input->original.canonical_bytes ||
             input->original.canonical_bytes > S2A_INPUT_IDENTITY_MAX) result = S2A_W2_QUERY_IDENTITY;
    else {
        s2a_sha256 sha;
        uint8_t digest[32];
        s2a_sha256_init(&sha);
        s2a_sha256_update(&sha, input->original.canonical, input->original.canonical_bytes);
        s2a_sha256_final(&sha, digest);
        result = memcmp(digest, key->input_sha, sizeof digest) ? S2A_W2_QUERY_IDENTITY :
            s2a_w2_single_query_diagnose(input, resolver, snapshot, receipt);
    }
    pthread_mutex_unlock(&provider_lock);
    return result;
}
