#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Android-local primitives until the shared platform/plat.h migration lands.
// Returns errno values; never overwrites an existing mapping with MAP_FIXED.
int s2a_android_reserve(size_t size, size_t alignment, uint64_t limit, void **out);
int s2a_android_check_alias(int fd, size_t size);

#ifdef __cplusplus
}
#endif

