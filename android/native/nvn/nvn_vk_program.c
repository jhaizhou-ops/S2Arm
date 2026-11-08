// 新后端消费统一编译结果（s2a-direct-program-v1），不再有任何 XGS 解析或回退。
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "nvn_vk_program.h"
#include "direct/json.h"
#include "direct/sha256.h"

#define PROGRAM_MAX_BYTES (4u * 1024u * 1024u)

struct file_bytes {
    uint8_t *data;
    size_t bytes;
};

static int fail(char *why, size_t n, const char *text) {
    if (why && n) snprintf(why, n, "%s", text);
    return -1;
}

static const char *const k_stage_names[6] = { "vs", "fs", "gs", "tcs", "tes", "cs" };

static int stage_from_name(const char *name) {
    if (!name) return -1;
    for (int i = 0; i < 6; i++) if (!strcmp(name, k_stage_names[i])) return i;
    return -1;
}

static int read_file(const char *path, struct file_bytes *out, char *why, size_t why_size) {
    FILE *f = fopen(path, "rb");
    if (!f) { if (why && why_size) snprintf(why, why_size, "cannot open %s", path); return -1; }
    if (fseek(f, 0, SEEK_END)) { fclose(f); return fail(why, why_size, "seek failed"); }
    long length = ftell(f);
    rewind(f);
    if (length <= 0 || (size_t)length > PROGRAM_MAX_BYTES) { fclose(f); return fail(why, why_size, "program file length out of range"); }
    uint8_t *bytes = malloc((size_t)length);
    if (!bytes) { fclose(f); return fail(why, why_size, "out of memory"); }
    if (fread(bytes, 1, (size_t)length, f) != (size_t)length) { free(bytes); fclose(f); return fail(why, why_size, "program file read failed"); }
    fclose(f);
    out->data = bytes;
    out->bytes = (size_t)length;
    return 0;
}

static int b64_value(char c) {
    if (c >= 'A' && c <= 'Z') return c - 'A';
    if (c >= 'a' && c <= 'z') return c - 'a' + 26;
    if (c >= '0' && c <= '9') return c - '0' + 52;
    if (c == '+') return 62;
    if (c == '/') return 63;
    return -1;
}

static int b64_decode(const char *text, size_t length, uint8_t **out, size_t *out_bytes, char *why, size_t why_size) {
    while (length && text[length - 1] == '=') length--;
    if (!length || length % 4 == 1) return fail(why, why_size, "invalid base64 length");
    size_t capacity = length / 4 * 3 + 3;
    uint8_t *bytes = malloc(capacity);
    if (!bytes) return fail(why, why_size, "out of memory");
    size_t n = 0;
    uint32_t acc = 0, bits = 0;
    for (size_t i = 0; i < length; i++) {
        int v = b64_value(text[i]);
        if (v < 0) { free(bytes); return fail(why, why_size, "invalid base64 character"); }
        acc = (acc << 6) | (uint32_t)v;
        bits += 6;
        if (bits >= 8) { bits -= 8; bytes[n++] = (uint8_t)(acc >> bits); }
    }
    *out = bytes;
    *out_bytes = n;
    return 0;
}

static int field_uint(const s2a_json_field *f, uint32_t *out) {
    if (!f || f->kind != S2A_JSON_NUMBER || !f->is_unsigned) return -1;
    *out = (uint32_t)f->unsigned_value;
    return 0;
}

static int stage_object(const uint8_t *data, uint32_t bytes, s2a_json_object *out, char *why, size_t why_size) {
    char err[96] = "";
    int rc = s2a_json_parse_object(data, bytes, out, err, sizeof err);
    if (rc != S2A_JSON_OK) {
        if (why && why_size) snprintf(why, why_size, "json: %s", err[0] ? err : "parse failed");
        return -1;
    }
    return 0;
}

// info 里的一个描述符数组 → binding 表（保留真实 set/binding，不做任何重映射）。
static int collect_bindings(const s2a_json_field *array, uint32_t type, struct nvn_vk_stage *st,
                            char *why, size_t why_size) {
    if (!array) return 0;
    if (array->kind != S2A_JSON_ARRAY) return fail(why, why_size, "descriptor list is not an array");
    uint32_t count = s2a_json_array_count(array);
    for (uint32_t i = 0; i < count; i++) {
        const uint8_t *span = NULL;
        uint32_t span_bytes = 0;
        if (s2a_json_array_span(array, i, &span, &span_bytes)) return fail(why, why_size, "descriptor element span failed");
        s2a_json_object item;
        if (stage_object(span, span_bytes, &item, why, why_size)) return -1;
        uint32_t set = 0, binding = 0, slot = 0;
        if (field_uint(s2a_json_get(&item, "set"), &set) || field_uint(s2a_json_get(&item, "binding"), &binding))
            return fail(why, why_size, "descriptor without set/binding");
        (void)field_uint(s2a_json_get(&item, "slot"), &slot);
        if (st->binding_count >= NVK_PROGRAM_MAX_BINDINGS) return fail(why, why_size, "too many descriptors");
        st->bindings[st->binding_count].set = set;
        st->bindings[st->binding_count].binding = binding;
        st->bindings[st->binding_count].type = type;
        st->bindings[st->binding_count].count = 1;
        st->bindings[st->binding_count].slot = slot;
        st->binding_count++;
    }
    return 0;
}

// 读一个阶段的 program 文件：只认 s2a-direct-program-v1 的 content.stages[]。
static int load_stage(struct s2a_vk_device *d, const char *path, uint32_t expected_nvn, uint32_t array_index,
                      struct nvn_vk_program *p, char *why, size_t why_size) {
    struct file_bytes file = { NULL, 0 };
    char local[192] = "";
    if (read_file(path, &file, local, sizeof local)) {
        const char *base = strrchr(path, '/');
        if (why && why_size) snprintf(why, why_size, "nvn stage %u key %s: %s", expected_nvn, base ? base + 1 : path, local);
        return -1;
    }
    s2a_sha256 ctx;
    uint8_t digest[32];
    s2a_sha256_init(&ctx);
    s2a_sha256_update(&ctx, file.data, file.bytes);
    s2a_sha256_final(&ctx, digest);
    s2a_sha256_hex(digest, p->identity);

    s2a_json_object top;
    if (stage_object(file.data, (uint32_t)file.bytes, &top, why, why_size)) { free(file.data); return -1; }
    const s2a_json_field *schema = s2a_json_get(&top, "schema");
    if (schema && schema->kind == S2A_JSON_STRING)
        snprintf(p->schema, sizeof p->schema, "%s", schema->text);
    const s2a_json_field *content = s2a_json_get(&top, "content");
    if (!content || content->kind != S2A_JSON_OBJECT) {
        free(file.data);
        return fail(why, why_size, "not a s2a-direct-program-v1 result (no content object)");
    }
    s2a_json_object content_obj;
    if (stage_object(content->raw, content->raw_bytes, &content_obj, why, why_size)) { free(file.data); return -1; }
    const s2a_json_field *stages = s2a_json_get(&content_obj, "stages");
    if (!stages || stages->kind != S2A_JSON_ARRAY) { free(file.data); return fail(why, why_size, "program has no stages array"); }

    uint32_t count = s2a_json_array_count(stages);
    int found = 0;
    for (uint32_t i = 0; i < count && !found; i++) {
        const uint8_t *span = NULL;
        uint32_t span_bytes = 0;
        if (s2a_json_array_span(stages, i, &span, &span_bytes)) { free(file.data); return fail(why, why_size, "stage span failed"); }
        s2a_json_object stage;
        if (stage_object(span, span_bytes, &stage, why, why_size)) { free(file.data); return -1; }
        const s2a_json_field *name = s2a_json_get(&stage, "stage");
        if (!name || name->kind != S2A_JSON_STRING) continue;
        if (stage_from_name(name->text) != (int)expected_nvn) continue;

        const s2a_json_field *spirv = s2a_json_get(&stage, "spirv");
        if (!spirv || spirv->kind != S2A_JSON_STRING) { free(file.data); return fail(why, why_size, "stage has no spirv"); }
        uint8_t *words = NULL;
        size_t word_bytes = 0;
        if (b64_decode(spirv->text, spirv->text_bytes, &words, &word_bytes, why, why_size)) { free(file.data); return -1; }
        if (word_bytes < 20 || (word_bytes & 3u) || *(const uint32_t *)words != 0x07230203u) {
            free(words); free(file.data);
            return fail(why, why_size, "stage spirv is not a SPIR-V module");
        }
        VkShaderModuleCreateInfo ci = { VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO };
        ci.codeSize = word_bytes;
        ci.pCode = (const uint32_t *)words;
        struct nvn_vk_stage *st = &p->stage[expected_nvn];
        if (vkCreateShaderModule(d->device, &ci, NULL, &st->module) != VK_SUCCESS) {
            free(words); free(file.data);
            return fail(why, why_size, "vkCreateShaderModule failed");
        }
        st->present = 1;
        st->nvn_enum = expected_nvn;
        st->array_index = array_index;
        st->spirv_words = (uint32_t)(word_bytes / 4);
        uint32_t mask = 0;
        if (!field_uint(s2a_json_get(&stage, "attributeReadMask"), &mask)) st->attribute_read_mask = mask;
        st->input_count = 0;
        for (uint32_t bit = 0; bit < 32 && st->input_count < NVK_PROGRAM_MAX_INPUTS; bit++)
            if (mask & (1u << bit)) st->inputs[st->input_count++] = bit;

        const s2a_json_field *info = s2a_json_get(&stage, "info");
        if (info && info->kind == S2A_JSON_OBJECT) {
            s2a_json_object info_obj;
            if (stage_object(info->raw, info->raw_bytes, &info_obj, why, why_size)) { free(words); free(file.data); return -1; }
            if (collect_bindings(s2a_json_get(&info_obj, "cbuffers"), VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER, st, why, why_size) ||
                collect_bindings(s2a_json_get(&info_obj, "sbuffers"), VK_DESCRIPTOR_TYPE_STORAGE_BUFFER, st, why, why_size) ||
                collect_bindings(s2a_json_get(&info_obj, "textures"), VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER, st, why, why_size) ||
                collect_bindings(s2a_json_get(&info_obj, "images"), VK_DESCRIPTOR_TYPE_STORAGE_IMAGE, st, why, why_size)) {
                free(words); free(file.data);
                return -1;
            }
        }
        memcpy(st->key, path + (strlen(path) - 16 - 13), 16);   // "<key>.program.json"
        st->key[16] = 0;
        p->stage_mask |= 1u << expected_nvn;
        free(words);
        found = 1;
    }
    free(file.data);
    if (!found) {
        if (why && why_size) snprintf(why, why_size, "program file has no stage '%s'", k_stage_names[expected_nvn]);
        return -1;
    }
    return 0;
}

int nvn_vk_program_load(struct s2a_vk_device *d, const char *directory, const uint8_t keys[6][8], uint32_t stages,
                        struct nvn_vk_program *out, char *why, size_t why_size) {
    if (!d || !d->device || !directory || !keys || !out) return fail(why, why_size, "bad program arguments");
    memset(out, 0, sizeof *out);
    uint32_t array_index = 0;
    for (uint32_t nvn = 0; nvn < 6 && array_index < 6; nvn++) {
        if (!(stages & (1u << nvn))) continue;
        char path[512];
        int n = snprintf(path, sizeof path, "%s/%02x%02x%02x%02x%02x%02x%02x%02x.program.json", directory,
                         keys[array_index][0], keys[array_index][1], keys[array_index][2], keys[array_index][3],
                         keys[array_index][4], keys[array_index][5], keys[array_index][6], keys[array_index][7]);
        if (n < 0 || (size_t)n >= sizeof path) { nvn_vk_program_destroy(d, out); return fail(why, why_size, "program path too long"); }
        if (load_stage(d, path, nvn, array_index, out, why, why_size)) { nvn_vk_program_destroy(d, out); return -1; }
        array_index++;
    }
    if (!out->stage_mask) return fail(why, why_size, "program has no shader stage");
    return 0;
}

void nvn_vk_program_destroy(struct s2a_vk_device *d, struct nvn_vk_program *p) {
    if (!p) return;
    for (int i = 0; i < NVK_STAGE_COUNT; i++) {
        if (p->stage[i].module && d && d->device) vkDestroyShaderModule(d->device, p->stage[i].module, NULL);
        p->stage[i].module = VK_NULL_HANDLE;
    }
    memset(p, 0, sizeof *p);
}

void nvn_vk_program_summary(const struct nvn_vk_program *p, char *out, size_t n) {
    if (!out || !n || !p) return;
    uint32_t bindings = 0;
    for (int i = 0; i < NVK_STAGE_COUNT; i++)
        if (p->stage[i].present) bindings += p->stage[i].binding_count;
    snprintf(out, n, "stages=0x%x bindings=%u identity=%.12s", p->stage_mask, bindings, p->identity);
}
