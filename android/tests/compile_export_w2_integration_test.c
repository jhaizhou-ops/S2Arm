/* Real gate + W2 query on the existing synthetic frozen-input fixture. */
#define main w2_fixture_test_main
#include "w2_single_query_test.c"
#undef main
#include "direct/compile_export_w2.h"
#include "direct/sha256.h"

int s2a_compile_export_open(void) { return 1; }
static int provide(void *ctx, const struct s2a_compile_export_w2_key *key,
                   const struct s2a_w2_query_input **input,
                   s2a_w2_query_resolver *resolver, void **snapshot) {
    struct fixture *f = ctx;
    if (key->session != f->input.original.stamp.session || key->generation != f->input.original.stamp.generation) return -1;
    *input = &f->input; *resolver = resolve; *snapshot = f; return 0;
}
int main(void) {
    struct fixture f; init(&f); CHECK(!seal(&f));
    struct s2a_compile_export_w2_key key = {.session = 11, .generation = 12};
    s2a_sha256 sha; s2a_sha256_init(&sha);
    s2a_sha256_update(&sha, f.canonical, f.input.original.canonical_bytes);
    s2a_sha256_final(&sha, key.input_sha);
    struct s2a_w2_query_receipt receipt;
    s2a_compile_export_w2_set_provider(provide, &f);
    CHECK(s2a_compile_export_w2_diagnose(&key, &receipt) == S2A_W2_QUERY_OBSERVED);
    CHECK(receipt.observed && f.calls == 1 && receipt.requested.coordinate.handle == 12);
    CHECK(receipt.original_identity_bytes == f.input.original.canonical_bytes);
    CHECK(!memcmp(receipt.original_identity, f.canonical, f.input.original.canonical_bytes));
    key.input_sha[0] ^= 1;
    CHECK(s2a_compile_export_w2_diagnose(&key, &receipt) == S2A_W2_QUERY_IDENTITY);
    CHECK(!receipt.observed && f.calls == 1);
    s2a_compile_export_w2_set_provider(NULL, NULL);
    CHECK(s2a_compile_export_w2_diagnose(&key, &receipt) == S2A_COMPILE_EXPORT_W2_UNWIRED);
    puts("real gate to real W2 diagnostic: synthetic frozen input PASS");
    return 0;
}
