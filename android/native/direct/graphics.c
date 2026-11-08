// graphics.v1.json 严格消费端，见 graphics.h。
#include "graphics.h"

#include "json.h"
#include "s2a_direct.h"
#include "sha256.h"

#include <stdio.h>
#include <string.h>

static int bad(char *why, size_t n, int code, const char *text) {
    if (why && n) snprintf(why, n, "%s", text);
    return code;
}

static int hex_n(const char *text, size_t n, int upper) {
    for (size_t i = 0; i < n; i++) {
        char c = text[i];
        if (upper) { if (!((c >= '0' && c <= '9') || (c >= 'A' && c <= 'F'))) return 0; }
        else if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return 0;
    }
    return 1;
}

static int content_root(const char *text) {
    return strlen(text) == 71 && !strncmp(text, "sha256-", 7) && hex_n(text + 7, 64, 0);
}

int s2a_graphics_has_profile(const struct s2a_graphics_descriptor_v1 *descriptor, const char *profile) {
    if (!descriptor || !profile || descriptor->profile_count > 8) return 0;
    for (uint32_t i = 0; i < descriptor->profile_count; i++)
        if (!strcmp(descriptor->profile_hashes[i], profile)) return 1;
    return 0;
}

int s2a_graphics_storage_admit(int vertex_feature_enabled, uint32_t write_stages) {
    // VS, GS, TCS, TES use the NVN stage numbering; FS/CS do not use this feature.
    return vertex_feature_enabled || !(write_stages & 0x1du);
}

static int relative_components_ok(const char *text) {
    if (!*text) return 0;
    const char *start = text;
    for (const char *p = text;; p++) {
        if ((unsigned char)*p >= 128 || *p == '\\') return 0;
        if (*p != '/' && *p) continue;
        size_t n = (size_t)(p - start);
        if (!n || (n == 1 && start[0] == '.') ||
            (n == 2 && start[0] == '.' && start[1] == '.')) return 0;
        if (!*p) return 1;
        start = p + 1;
    }
}

static int closure_ok(const char *text) {
    size_t n = strlen(text);
    if (!n || n >= 128) return 0;
    for (size_t i = 0; i < n; i++) {
        char c = text[i];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
              c == '.' || c == '_' || c == '-' || c == '+' || c == ':')) return 0;
    }
    return 1;
}

static int require_string(const s2a_json_object *o, const char *key, char *dst, size_t cap,
                          char *why, size_t why_n) {
    const s2a_json_field *f = s2a_json_get(o, key);
    if (!f) return bad(why, why_n, S2A_GRAPHICS_MISSING, key);
    if (f->kind != S2A_JSON_STRING) return bad(why, why_n, S2A_GRAPHICS_VALUE, key);
    if (f->text_bytes >= cap) return bad(why, why_n, S2A_GRAPHICS_LIMIT, key);
    memcpy(dst, f->text, f->text_bytes + 1);
    return S2A_GRAPHICS_OK;
}

static int require_uint(const s2a_json_object *o, const char *key, uint32_t *out,
                        char *why, size_t why_n) {
    const s2a_json_field *f = s2a_json_get(o, key);
    if (!f) return bad(why, why_n, S2A_GRAPHICS_MISSING, key);
    if (f->kind != S2A_JSON_NUMBER || !f->is_unsigned || f->unsigned_value > UINT32_MAX)
        return bad(why, why_n, S2A_GRAPHICS_VALUE, key);
    *out = (uint32_t)f->unsigned_value;
    return S2A_GRAPHICS_OK;
}

int s2a_graphics_descriptor_parse(const uint8_t *json, size_t bytes,
                                  struct s2a_graphics_descriptor_v1 *out,
                                  char *why, size_t why_size) {
    if (!out) return bad(why, why_size, S2A_GRAPHICS_MISSING, "output");
    memset(out, 0, sizeof *out);
    s2a_json_object object;
    char error[96];
    int rc = s2a_json_parse_object(json, bytes, &object, error, sizeof error);
    if (rc) return bad(why, why_size, S2A_GRAPHICS_SCHEMA_ERROR, error);
    char schema[32], frontend[16], backend[24];
    if ((rc = require_string(&object, "schema", schema, sizeof schema, why, why_size))) return rc;
    if (strcmp(schema, S2A_GRAPHICS_SCHEMA)) return bad(why, why_size, S2A_GRAPHICS_SCHEMA_ERROR, "schema");
    if ((rc = require_string(&object, "titleId", out->title_id, sizeof out->title_id, why, why_size))) return rc;
    char title_upper[17];
    if (strlen(out->title_id) != 16) return bad(why, why_size, S2A_GRAPHICS_IDENTITY, "titleId");
    for (int i = 0; i < 16; i++) {
        char c = out->title_id[i];
        if (c >= 'a' && c <= 'f') c = (char)(c - 'a' + 'A');
        if (!((c >= '0' && c <= '9') || (c >= 'A' && c <= 'F')))
            return bad(why, why_size, S2A_GRAPHICS_IDENTITY, "titleId");
        title_upper[i] = c;
    }
    title_upper[16] = 0;
    memcpy(out->title_id, title_upper, sizeof title_upper);
    if ((rc = require_string(&object, "gameContentRoot", out->game_content_root,
                             sizeof out->game_content_root, why, why_size))) return rc;
    if (!content_root(out->game_content_root)) return bad(why, why_size, S2A_GRAPHICS_IDENTITY, "gameContentRoot");
    if ((rc = require_string(&object, "moduleSetDigest", out->module_set_digest,
                             sizeof out->module_set_digest, why, why_size))) return rc;
    if (!content_root(out->module_set_digest)) return bad(why, why_size, S2A_GRAPHICS_IDENTITY, "moduleSetDigest");
    if ((rc = require_string(&object, "frontend", frontend, sizeof frontend, why, why_size))) return rc;
    if (strcmp(frontend, S2A_GRAPHICS_FRONTEND)) return bad(why, why_size, S2A_GRAPHICS_FRONTEND_ERROR, "frontend");
    if ((rc = require_string(&object, "backend", backend, sizeof backend, why, why_size))) return rc;
    if (strcmp(backend, S2A_GRAPHICS_BACKEND)) return bad(why, why_size, S2A_GRAPHICS_FRONTEND_ERROR, "backend");
    if ((rc = require_uint(&object, "directABI", &out->direct_abi, why, why_size))) return rc;
    if (out->direct_abi != S2A_DIRECT_ABI) return bad(why, why_size, S2A_GRAPHICS_VERSION, "directABI");
    if ((rc = require_string(&object, "translatorClosure", out->translator_closure,
                             sizeof out->translator_closure, why, why_size))) return rc;
    if (!closure_ok(out->translator_closure)) return bad(why, why_size, S2A_GRAPHICS_VALUE, "translatorClosure");
    if ((rc = require_uint(&object, "sourceParserVersion", &out->source_parser_version, why, why_size))) return rc;
    if (out->source_parser_version == 0) return bad(why, why_size, S2A_GRAPHICS_VERSION, "sourceParserVersion");
    if ((rc = require_string(&object, "runtimeCompilerABI", out->runtime_compiler_abi,
                             sizeof out->runtime_compiler_abi, why, why_size))) return rc;
    if (strcmp(out->runtime_compiler_abi, S2A_GRAPHICS_RUNTIME_COMPILER_ABI))
        return bad(why, why_size, S2A_GRAPHICS_VERSION, "runtimeCompilerABI");
    const s2a_json_field *requirements = s2a_json_get(&object, "shaderStorageRequirements");
    if (requirements) {
        if (requirements->kind != S2A_JSON_OBJECT)
            return bad(why, why_size, S2A_GRAPHICS_VALUE, "shaderStorageRequirements");
        s2a_json_object storage;
        if (s2a_json_parse_object(requirements->raw, requirements->raw_bytes, &storage, error, sizeof error))
            return bad(why, why_size, S2A_GRAPHICS_SCHEMA_ERROR, "shaderStorageRequirements");
        for (uint32_t i = 0; i < storage.count; i++)
            if (strcmp(storage.fields[i].key, "schema") && strcmp(storage.fields[i].key, "writeStages") &&
                strcmp(storage.fields[i].key, "coverage"))
                return bad(why, why_size, S2A_GRAPHICS_VALUE, "shaderStorageRequirements unknown field");
        uint32_t version;
        char coverage[16];
        if ((rc = require_uint(&storage, "schema", &version, why, why_size))) return rc;
        if (version != 1) return bad(why, why_size, S2A_GRAPHICS_VERSION, "storage schema");
        if ((rc = require_uint(&storage, "writeStages", &out->storage_write_stages, why, why_size))) return rc;
        if (out->storage_write_stages & ~63u) return bad(why, why_size, S2A_GRAPHICS_VALUE, "writeStages");
        if ((rc = require_string(&storage, "coverage", coverage, sizeof coverage, why, why_size))) return rc;
        if (strcmp(coverage, "complete") && strcmp(coverage, "unknown"))
            return bad(why, why_size, S2A_GRAPHICS_VALUE, "coverage");
        out->storage_coverage_complete = !strcmp(coverage, "complete");
    }
    const s2a_json_field *profiles = s2a_json_get(&object, "profiles");
    if (!profiles) return bad(why, why_size, S2A_GRAPHICS_MISSING, "profiles");
    if (profiles->kind != S2A_JSON_ARRAY) return bad(why, why_size, S2A_GRAPHICS_VALUE, "profiles");
    // profiles 仅列实际离线文件对应的设备档；空库没有设备档。
    uint32_t count = s2a_json_array_count(profiles);
    if (count > 8) return bad(why, why_size, S2A_GRAPHICS_LIMIT, "profiles");
    for (uint32_t i = 0; i < count; i++) {
        const uint8_t *span; uint32_t span_bytes;
        if (s2a_json_array_span(profiles, i, &span, &span_bytes))
            return bad(why, why_size, S2A_GRAPHICS_SCHEMA_ERROR, "profiles element");
        s2a_json_object entry;
        char entry_error[96];
        if (s2a_json_parse_object(span, span_bytes, &entry, entry_error, sizeof entry_error))
            return bad(why, why_size, S2A_GRAPHICS_SCHEMA_ERROR, "profiles element");
        const s2a_json_field *hash = s2a_json_get(&entry, "profileHash");
        if (!hash) return bad(why, why_size, S2A_GRAPHICS_MISSING, "profileHash");
        if (hash->kind != S2A_JSON_STRING || !content_root(hash->text))
            return bad(why, why_size, S2A_GRAPHICS_IDENTITY, "profileHash");
        for (uint32_t j = 0; j < i; j++)
            if (!strcmp(out->profile_hashes[j], hash->text))
                return bad(why, why_size, S2A_GRAPHICS_IDENTITY, "duplicate profileHash");
        memcpy(out->profile_hashes[i], hash->text, strlen(hash->text) + 1);
    }
    out->profile_count = count;
    const s2a_json_field *files = s2a_json_get(&object, "files");
    if (!files) return bad(why, why_size, S2A_GRAPHICS_MISSING, "files");
    if (files->kind != S2A_JSON_ARRAY) return bad(why, why_size, S2A_GRAPHICS_VALUE, "files");
    uint32_t nfiles = s2a_json_array_count(files), matched = 0;
    if (!!nfiles != !!count) return bad(why, why_size, S2A_GRAPHICS_VALUE, "files/profiles empty mismatch");
    char prefix[64];
    snprintf(prefix, sizeof prefix, "shaders/vulkan/direct/%u/", out->direct_abi);
    uint32_t cursor = 1;
    for (uint32_t i = 0; i < nfiles; i++) {
        const uint8_t *span; uint32_t span_bytes;
        if (s2a_json_array_next(files, &cursor, &span, &span_bytes) != 1)
            return bad(why, why_size, S2A_GRAPHICS_SCHEMA_ERROR, "files element");
        s2a_json_object entry; char entry_error[96];
        if (s2a_json_parse_object(span, span_bytes, &entry, entry_error, sizeof entry_error))
            return bad(why, why_size, S2A_GRAPHICS_SCHEMA_ERROR, "files element");
        const s2a_json_field *path = s2a_json_get(&entry, "path");
        if (!path || path->kind != S2A_JSON_STRING)
            return bad(why, why_size, S2A_GRAPHICS_VALUE, "file path");
        for (uint32_t j = 0; j < entry.count; j++)
            if (strcmp(entry.fields[j].key, "path") && strcmp(entry.fields[j].key, "size") &&
                strcmp(entry.fields[j].key, "sha256"))
                return bad(why, why_size, S2A_GRAPHICS_VALUE, "unknown file field");
        const s2a_json_field *digest = s2a_json_get(&entry, "sha256");
        const s2a_json_field *size = s2a_json_get(&entry, "size");
        if (!digest || digest->kind != S2A_JSON_STRING ||
            !((strlen(digest->text) == 64 && hex_n(digest->text, 64, 0)) || content_root(digest->text)))
            return bad(why, why_size, S2A_GRAPHICS_IDENTITY, "file sha256");
        if (size && (size->kind != S2A_JSON_NUMBER || !size->is_unsigned))
            return bad(why, why_size, S2A_GRAPHICS_VALUE, "file size");
        if (!strcmp(path->text, "shaders/vulkan/direct/library.v1.json")) continue;
        size_t prefix_len = strlen(prefix);
        if (strncmp(path->text, prefix, prefix_len) || strlen(path->text + prefix_len) < 73)
            return bad(why, why_size, S2A_GRAPHICS_IDENTITY, "file profile path");
        const char *hash = path->text + prefix_len;
        if (hash[71] != '/' || !relative_components_ok(hash + 72))
            return bad(why, why_size, S2A_GRAPHICS_IDENTITY, "file profile path");
        int found = 0;
        for (uint32_t j = 0; j < count; j++)
            if (!strncmp(hash, out->profile_hashes[j], 71)) { matched |= 1u << j; found = 1; break; }
        if (!found) return bad(why, why_size, S2A_GRAPHICS_IDENTITY, "file profile not declared");
    }
    if (matched != ((1u << count) - 1u))
        return bad(why, why_size, S2A_GRAPHICS_IDENTITY, "declared profile has no files");
    return S2A_GRAPHICS_OK;
}

int s2a_direct_implementation_key(const struct s2a_graphics_descriptor_v1 *descriptor,
                                  const char *effective_profile_hash, char out[65],
                                  char *why, size_t why_size) {
    if (!descriptor || !effective_profile_hash || !out)
        return bad(why, why_size, S2A_GRAPHICS_MISSING, "implementationKey input");
    size_t profile_len = strlen(effective_profile_hash);
    if (!content_root(effective_profile_hash) &&
        !(profile_len && hex_n(effective_profile_hash, profile_len, 0)))
        return bad(why, why_size, S2A_GRAPHICS_IDENTITY, "effectiveProfileHash");
    s2a_sha256 ctx;
    s2a_sha256_init(&ctx);
    const char *fields[] = { descriptor->game_content_root, descriptor->module_set_digest,
                             descriptor->translator_closure, effective_profile_hash };
    char abi[16];
    snprintf(abi, sizeof abi, "%u", descriptor->direct_abi);
    const char *all[] = { fields[0], fields[1], abi, fields[2], fields[3] };
    for (int i = 0; i < 5; i++) {
        s2a_sha256_update(&ctx, all[i], strlen(all[i]) + 1);   // NUL 分隔，避免字段拼接歧义
    }
    uint8_t digest[32];
    s2a_sha256_final(&ctx, digest);
    s2a_sha256_hex(digest, out);
    return S2A_GRAPHICS_OK;
}
