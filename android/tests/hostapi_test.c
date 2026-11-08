#include "s2a_hostapi.h"

#include <stdio.h>
#include <string.h>

static int language(void *host, char *out, size_t cap) {
    (void)host;
    const char *value = "zh-Hans-CN";
    if (cap < strlen(value) + 1) return S2A_HOST_E_RANGE;
    memcpy(out, value, strlen(value) + 1);
    return S2A_HOST_E_OK;
}

static int region(void *host, char *out, size_t cap) {
    (void)host;
    if (cap < 3) return S2A_HOST_E_RANGE;
    memcpy(out, "CN", 3);
    return S2A_HOST_E_OK;
}

static int timezone(void *host, char *out, size_t cap) {
    (void)host;
    const char *value = "Asia/Shanghai";
    if (cap < strlen(value) + 1) return S2A_HOST_E_RANGE;
    memcpy(out, value, strlen(value) + 1);
    return S2A_HOST_E_OK;
}

int main(void) {
    s2a_host_user_v1 user = {
        .hdr = {.size = sizeof(s2a_host_user_v1), .abi_version = S2A_HOST_API_ABI_VERSION},
        .language = language,
        .region = region,
        .timezone = timezone,
    };
    s2a_host_api_v1 api = {
        .hdr = {.size = sizeof(s2a_host_api_v1), .abi_version = S2A_HOST_API_ABI_VERSION},
        .capabilities = S2A_HOST_CAP_USER,
        .user = &user,
    };
    char buf[64];

    if (s2a_host_register(&api) != S2A_HOST_E_OK || s2a_host_get() != &api) {
        fputs("hostapi: registration failed\n", stderr);
        return 1;
    }
    if (language(NULL, buf, sizeof buf) != 0 || strcmp(buf, "zh-Hans-CN") ||
        region(NULL, buf, sizeof buf) != 0 || strcmp(buf, "CN") ||
        timezone(NULL, buf, sizeof buf) != 0 || strcmp(buf, "Asia/Shanghai")) {
        fputs("hostapi: user callbacks failed\n", stderr);
        return 1;
    }

    s2a_host_api_v1 bad = api;
    bad.hdr.abi_version = S2A_HOST_API_ABI_VERSION + 1;
    if (s2a_host_register(&bad) != S2A_HOST_E_VERSION) return 2;

    bad = api;
    user.hdr.size = sizeof(s2a_host_user_v1) - 1;
    if (s2a_host_register(&bad) != S2A_HOST_E_VERSION) return 3;
    user.hdr.size = sizeof(s2a_host_user_v1);

    bad = api;
    bad.capabilities = 1u << 20;
    if (s2a_host_register(&bad) != S2A_HOST_E_ARGUMENT) return 4;

    bad = api;
    bad.capabilities = S2A_HOST_CAP_USER | S2A_HOST_CAP_MEMINFO;
    if (s2a_host_register(&bad) != S2A_HOST_E_ARGUMENT) return 5;

    if (s2a_host_get() != &api) return 6;

    // A newer host appends fields: size grows, abi_version stays 1, old reader
    // accepts the prefix and ignores the tail.
    struct extended_user {
        s2a_host_user_v1 v1;
        uint64_t extra;
    } eu = {.v1 = user, .extra = 1};
    struct extended_api {
        s2a_host_api_v1 v1;
        uint64_t extra;
    } ea = {.v1 = api, .extra = 2};
    ea.v1.hdr.size = sizeof ea;
    ea.v1.user = &eu.v1;
    eu.v1.hdr.size = sizeof eu;
    if (s2a_host_register(&ea.v1) != S2A_HOST_E_OK || s2a_host_get() != &ea.v1) return 7;

    bad = api;
    bad.hdr.size = sizeof(s2a_host_api_v1) - 1;
    if (s2a_host_register(&bad) != S2A_HOST_E_VERSION) return 8;

    puts("host api: ok");
    return 0;
}
