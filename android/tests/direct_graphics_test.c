// C1：graphics.v1.json 严格消费端向量。合成描述只验证身份/版本/缺项规则，不含游戏数据。
#include "../native/direct/graphics.h"
#include "../native/direct/s2a_direct.h"

#include <stdio.h>
#include <string.h>

static int g_failures;
#define CHECK(cond, what) do { if (!(cond)) { printf("FAIL %s\n", what); g_failures++; } } while (0)

static char a64[65], b64[65];

static void fill(char *out, char c) { memset(out, c, 64); out[64] = 0; }

static int build(char *out, size_t cap, const char *overrides) {
    // 默认合法描述；overrides 按 "key=value;" 组装（value 为 JSON 原文）。
    return snprintf(out, cap,
        "{\"schema\":\"s2a-graphics-v1\",\"titleId\":\"01001b300b9be000\","
        "\"gameContentRoot\":\"sha256-%s\",\"moduleSetDigest\":\"sha256-%s\","
        "\"frontend\":\"nvn\",\"backend\":\"vulkan-direct\",\"directABI\":1,"
        "\"translatorClosure\":\"ryujinx-2026.10-dsh1\",\"sourceParserVersion\":1,"
        "\"profiles\":[{\"profileHash\":\"sha256-%s\"}],"
        "\"files\":[{\"path\":\"shaders/vulkan/direct/1/sha256-%s/file.program\",\"size\":1,\"sha256\":\"%s\"}],"
        "\"runtimeCompilerABI\":\"s2a-direct-compile-v1\"%s}",
        a64, b64, a64, a64, b64, overrides ? overrides : "");
}

static int parse(const char *json, struct s2a_graphics_descriptor_v1 *out, char *why, size_t n) {
    return s2a_graphics_descriptor_parse((const uint8_t *)json, strlen(json), out, why, n);
}

static void custom(char *out, size_t cap, const char *profiles, const char *files) {
    snprintf(out, cap,
        "{\"schema\":\"s2a-graphics-v1\",\"titleId\":\"01001B300B9BE000\","
        "\"gameContentRoot\":\"sha256-%s\",\"moduleSetDigest\":\"sha256-%s\","
        "\"frontend\":\"nvn\",\"backend\":\"vulkan-direct\",\"directABI\":1,"
        "\"translatorClosure\":\"synthetic-closure-v1\",\"sourceParserVersion\":1,"
        "\"profiles\":%s,\"files\":%s,\"runtimeCompilerABI\":\"s2a-direct-compile-v1\"}",
        a64, b64, profiles, files);
}

// 出包器产物对拍：直接解析一个 graphics.v1.json 文件（tools/direct_pack_consumer_check.sh 用）。
static int parse_file(const char *path) {
    static char json[1 << 20];
    FILE *file = fopen(path, "rb");
    if (!file) { printf("direct graphics file: cannot open %s\n", path); return 1; }
    size_t bytes = fread(json, 1, sizeof json, file);
    int extra = fgetc(file);
    fclose(file);
    if (extra != EOF) { printf("direct graphics file: larger than %zu bytes\n", sizeof json); return 1; }
    struct s2a_graphics_descriptor_v1 d;
    char why[160] = "";
    int rc = s2a_graphics_descriptor_parse((const uint8_t *)json, bytes, &d, why, sizeof why);
    if (rc) { printf("direct graphics file: FAIL rc=%d why=%s\n", rc, why); return 1; }
    printf("direct graphics file: ok title=%s abi=%u parser=%u profiles=%u compiler=%s\n",
           d.title_id, d.direct_abi, d.source_parser_version, d.profile_count, d.runtime_compiler_abi);
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 2) return parse_file(argv[1]);
    if (argc != 1) { printf("usage: direct_graphics_test [graphics.v1.json]\n"); return 2; }
    fill(a64, 'a'); fill(b64, 'b');
    char json[4096], why[128];
    struct s2a_graphics_descriptor_v1 d;
    {
        char candidate[4096], profiles[200], mismatch[512], two_profiles[350], matching[512];
        snprintf(profiles, sizeof profiles, "[{\"profileHash\":\"sha256-%s\"}]", a64);
        snprintf(mismatch, sizeof mismatch, "[{\"path\":\"shaders/vulkan/direct/1/sha256-%s/file.program\",\"size\":1,\"sha256\":\"%s\"}]", b64, b64);
        custom(candidate, sizeof candidate, "[]", "[]");
        CHECK(parse(candidate, &d, why, sizeof why) == S2A_GRAPHICS_OK && d.profile_count == 0, "empty library and empty profiles accepted");
        custom(candidate, sizeof candidate, profiles, "[]");
        CHECK(parse(candidate, &d, why, sizeof why) != S2A_GRAPHICS_OK, "empty library with profiles rejected");
        custom(candidate, sizeof candidate, profiles, mismatch);
        CHECK(parse(candidate, &d, why, sizeof why) != S2A_GRAPHICS_OK, "unlisted file profile rejected");
        snprintf(two_profiles, sizeof two_profiles, "[{\"profileHash\":\"sha256-%s\"},{\"profileHash\":\"sha256-%s\"}]", a64, b64);
        snprintf(matching, sizeof matching, "[{\"path\":\"shaders/vulkan/direct/1/sha256-%s/file.program\",\"size\":1,\"sha256\":\"%s\"}]", a64, b64);
        custom(candidate, sizeof candidate, two_profiles, matching);
        CHECK(parse(candidate, &d, why, sizeof why) != S2A_GRAPHICS_OK, "profile with no file rejected");
        snprintf(matching, sizeof matching,
                 "[{\"path\":\"shaders/vulkan/direct/1/sha256-%s/a.program\",\"sha256\":\"%s\"},"
                 "{\"path\":\"shaders/vulkan/direct/1/sha256-%s/b.program\",\"sha256\":\"%s\"}]",
                 a64, b64, b64, a64);
        custom(candidate, sizeof candidate, two_profiles, matching);
        CHECK(parse(candidate, &d, why, sizeof why) == S2A_GRAPHICS_OK && d.profile_count == 2,
              "two declared profiles and corresponding files accepted");
        snprintf(two_profiles, sizeof two_profiles, "[{\"profileHash\":\"sha256-%s\"},{\"profileHash\":\"sha256-%s\"}]", a64, a64);
        custom(candidate, sizeof candidate, two_profiles, matching);
        CHECK(parse(candidate, &d, why, sizeof why) != S2A_GRAPHICS_OK, "duplicate profiles rejected");
    }
    build(json, sizeof json, NULL);
    CHECK(parse(json, &d, why, sizeof why) == S2A_GRAPHICS_OK, "valid descriptor");
    CHECK(!strcmp(d.title_id, "01001B300B9BE000"), "title normalized to uppercase");
    CHECK(d.direct_abi == 1 && d.source_parser_version == 1 && d.profile_count == 1, "versions/count");
    CHECK(s2a_graphics_has_profile(&d, d.profile_hashes[0]), "declared live profile hits");
    CHECK(!s2a_graphics_has_profile(&d, "sha256-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"),
          "unlisted live profile misses");
    CHECK(!strcmp(d.runtime_compiler_abi, S2A_GRAPHICS_RUNTIME_COMPILER_ABI), "compiler ABI");

    // Old descriptors carry no coverage proof. Unknown is reported, but does
    // not itself disqualify a device; known write stages are independently kept.
    CHECK(d.storage_write_stages == 0 && !d.storage_coverage_complete, "legacy storage requirements unknown");
    build(json, sizeof json, ",\"shaderStorageRequirements\":{\"schema\":1,\"writeStages\":1,\"coverage\":\"unknown\"}");
    CHECK(parse(json, &d, why, sizeof why) == S2A_GRAPHICS_OK && d.storage_write_stages == 1 &&
          !d.storage_coverage_complete, "unknown coverage retains known vertex write");
    build(json, sizeof json, ",\"shaderStorageRequirements\":{\"schema\":1,\"writeStages\":0,\"coverage\":\"complete\"}");
    CHECK(parse(json, &d, why, sizeof why) == S2A_GRAPHICS_OK && d.storage_coverage_complete, "complete coverage");
    build(json, sizeof json, ",\"shaderStorageRequirements\":{\"schema\":1,\"writeStages\":64,\"coverage\":\"unknown\"}");
    CHECK(parse(json, &d, why, sizeof why) != S2A_GRAPHICS_OK, "unknown stage bits rejected");
    CHECK(s2a_graphics_storage_admit(0, 0) == 1, "unknown empty lower bound permits missing vertex feature");
    CHECK(s2a_graphics_storage_admit(0, 1) == 0, "known vertex write requires feature");
    CHECK(s2a_graphics_storage_admit(1, 1) == 1, "enabled vertex feature admits known write");
    CHECK(s2a_graphics_storage_admit(0, 2 | 32) == 1, "fragment and compute excluded from vertex feature");
    build(json, sizeof json, NULL);

    char tmp[4096];
    build(tmp, sizeof tmp, ",\"schema\":\"s2a-graphics-v2\"");   // duplicate key -> parser rejection
    CHECK(parse(tmp, &d, why, sizeof why) != S2A_GRAPHICS_OK, "duplicate top-level key rejected");
    snprintf(tmp, sizeof tmp, "%.*s", (int)strlen(json) - 1, json);
    CHECK(parse(tmp, &d, why, sizeof why) != S2A_GRAPHICS_OK, "truncated rejected");
    char *schema = strstr(json, "s2a-graphics-v1");
    memcpy(schema, "s2a-graphics-v2", 15);
    CHECK(parse(json, &d, why, sizeof why) == S2A_GRAPHICS_SCHEMA_ERROR, "unknown schema");
    memcpy(schema, "s2a-graphics-v1", 15);

    build(json, sizeof json, ",");
    CHECK(parse(json, &d, why, sizeof why) != S2A_GRAPHICS_OK, "trailing comma");

    custom(json, sizeof json, "[]", "{}");
    CHECK(parse(json, &d, why, sizeof why) == S2A_GRAPHICS_VALUE, "files kind");
    char *pos;
    build(json, sizeof json, NULL);
    {
        char needle[160];
        snprintf(needle, sizeof needle, "\"profiles\":[{\"profileHash\":\"sha256-%s\"}]", a64);
        pos = strstr(json, needle);
        CHECK(pos != NULL, "profiles needle");
        memmove(pos + strlen("\"profiles\":[]"), pos + strlen(needle), strlen(pos + strlen(needle)) + 1);
        memcpy(pos, "\"profiles\":[]", strlen("\"profiles\":[]"));
        CHECK(parse(json, &d, why, sizeof why) == S2A_GRAPHICS_VALUE, "empty profiles");
    }
    build(json, sizeof json, NULL);
    pos = strstr(json, "vulkan-direct"); memcpy(pos, "vulkan-nvn00", 12);
    CHECK(parse(json, &d, why, sizeof why) == S2A_GRAPHICS_FRONTEND_ERROR, "backend");
    build(json, sizeof json, NULL);
    pos = strstr(json, "\"nvn\""); memcpy(pos, "\"gl \"", 5);
    CHECK(parse(json, &d, why, sizeof why) == S2A_GRAPHICS_FRONTEND_ERROR, "frontend");
    build(json, sizeof json, NULL);
    pos = strstr(json, "\"directABI\":1"); memcpy(pos + 12, "2", 1);
    CHECK(parse(json, &d, why, sizeof why) == S2A_GRAPHICS_VERSION, "directABI");
    build(json, sizeof json, NULL);
    pos = strstr(json, "s2a-direct-compile-v1"); memcpy(pos, "s2a-direct-compile-v2", 21);
    CHECK(parse(json, &d, why, sizeof why) == S2A_GRAPHICS_VERSION, "runtimeCompilerABI");
    build(json, sizeof json, NULL);
    pos = strstr(json, "\"sha256-aaaaaaaa"); memcpy(pos + 7, "A", 1);   // 大写 hex 不是冻结格式
    CHECK(parse(json, &d, why, sizeof why) == S2A_GRAPHICS_IDENTITY, "content root lowercase");
    build(json, sizeof json, NULL);
    pos = strstr(json, "\"titleId\":\"01001b300b9be000\""); memcpy(pos + 11, "zz", 2);
    CHECK(parse(json, &d, why, sizeof why) == S2A_GRAPHICS_IDENTITY, "title hex");
    custom(json, sizeof json, "[]", "[]");
    pos = strstr(json, "\"files\":[]"); memmove(pos - 1, pos + 10, strlen(pos + 10) + 1);
    CHECK(parse(json, &d, why, sizeof why) == S2A_GRAPHICS_MISSING, "files missing");

    build(json, sizeof json, NULL);
    CHECK(parse(json, &d, why, sizeof why) == S2A_GRAPHICS_OK, "valid again");
    char key1[65], key2[65], key3[65];
    CHECK(s2a_direct_implementation_key(&d, "sha256-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", key1, why, sizeof why) == 0, "key 1");
    CHECK(s2a_direct_implementation_key(&d, "sha256-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", key2, why, sizeof why) == 0, "key 2");
    CHECK(!strcmp(key1, key2) && strlen(key1) == 64, "key deterministic");
    CHECK(s2a_direct_implementation_key(&d, "sha256-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", key3, why, sizeof why) == 0, "key 3");
    CHECK(strcmp(key1, key3) != 0, "profile changes key");
    CHECK(s2a_direct_implementation_key(&d, "", key3, why, sizeof why) != 0, "empty profile rejected");
    CHECK(s2a_direct_implementation_key(&d, "not-a-hash", key3, why, sizeof why) != 0, "bad profile rejected");

    if (g_failures) { printf("direct-graphics: %d FAILURES\n", g_failures); return 1; }
    printf("direct-graphics: ok\n");
    return 0;
}
