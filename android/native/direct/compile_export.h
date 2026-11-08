// Export authorization is shared by graphics and compute; it is not W2 metadata permission.
#pragma once
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif

// Testable policy: debug_open already combines the build and debug_env gates.
int s2a_compile_export_allowed(int debug_open, int explicit_export);
// Android property adapter; non-Android callers must opt in via their host fixture.
int s2a_compile_export_open(void);
// External dump paths are Debug-only even when release collection is explicitly enabled.
int s2a_compile_export_external_open(void);
// Release collection always derives from the application-private state directory.
int s2a_compile_export_directory(int debug_open, const char *state_dir, const char *debug_dir, char *out, size_t out_size);
// Replaces any old session environment; on failure leaves export disabled.
int s2a_compile_export_configure(int allowed, int debug_open, const char *state_dir, const char *debug_dir);

#ifdef __cplusplus
}
#endif

#ifdef __cplusplus
extern "C" {
#endif
// Publishes one original request per native identity within a session/cohort.
// root must already be the authorized private diagnostic directory.
// Returns 0 on publication or duplicate, -1 on failure; never changes compile outcome.
int s2a_compile_export_request(const char *root, unsigned long long session,
    unsigned long long generation, unsigned abi, unsigned parser_version,
    const char *closure, const char *profile_hash, const char *request_id,
    const unsigned char identity[32], const void *json, size_t json_bytes);
#ifdef __cplusplus
}
#endif
