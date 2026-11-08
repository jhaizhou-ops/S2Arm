// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
#include "s2a_hostapi.h"
#include <stdint.h>
#include <stdio.h>
#include <string.h>

extern int s2a_plat_android_system_language(const s2a_host_api_v1 *, char *, size_t);
extern int64_t plat_android_test_statm(const char *, long);
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "host fields: failed %s (line %d)\n", #x, __LINE__); return 1; } } while (0)
static int language(void *host, char *out, size_t cap) {
    const char *tag = host; size_t n = strlen(tag) + 1;
    if (n > cap) return S2A_HOST_E_RANGE;
    memcpy(out, tag, n); return 0;
}
int main(void) {
    s2a_host_user_v1 user = { .hdr = {sizeof(user), S2A_HOST_API_ABI_VERSION}, .language = language };
    s2a_host_api_v1 api = { .hdr = {sizeof(api), S2A_HOST_API_ABI_VERSION}, .capabilities = S2A_HOST_CAP_USER,
                            .host = "zh-Hans-CN", .user = &user };
    char out[64] = {0};
    CHECK(s2a_plat_android_system_language(&api, out, sizeof(out)) == 0 && strcmp(out, "zh-Hans-CN") == 0);
    CHECK(s2a_plat_android_system_language(&api, out, 2) != 0);
    CHECK(s2a_plat_android_system_language(NULL, out, sizeof(out)) != 0);
    api.hdr.size = 0; CHECK(s2a_plat_android_system_language(&api, out, sizeof(out)) != 0);
    CHECK(plat_android_test_statm("20 7 1 0 0 0 0\n", 4096) == 28672);
    CHECK(plat_android_test_statm("broken", 4096) == -1);
    CHECK(plat_android_test_statm("20 7", -1) == -1);
    CHECK(plat_android_test_statm("20 18446744073709551615", 4096) == -1);
    puts("host fields: language and RSS tests passed"); return 0;
}
