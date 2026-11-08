#pragma once
#include <stdint.h>
#include <stddef.h>
// hle_nvn.c 在 Android 用 swnvn ELF section；链接器提供 __start/__stop。
extern const char __start_swnvn[] __attribute__((weak));
extern const char __stop_swnvn[] __attribute__((weak));
static inline const uint8_t *getsectiondata(const void *header, const char *segment, const char *section, uint64_t *size) {
    (void)header; (void)segment; (void)section;
    if (!__start_swnvn || !__stop_swnvn) { *size = 0; return 0; }
    *size = (uint64_t)(__stop_swnvn - __start_swnvn);
    return (const uint8_t *)__start_swnvn;
}
