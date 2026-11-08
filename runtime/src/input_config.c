// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// schema 1 input parsing shared by Mac/iOS. The private JSON reader below is
// adapted from android/native/direct/json.{c,h} in this repository;
// symbols stay private, and core never includes an Android platform header.
// Retained object/string/UTF-8/number validation; unused array access API omitted.
// Embedded NUL field names are rejected before C-string field lookup.
#include "s2a_input_config.h"
#include <stdint.h>
#include <math.h>
#include <locale.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define IC_JSON_MAX_BYTES (1u << 20)   // 单个文档 1 MiB：与契约 §4.3 的限额分开，描述文件远小于此
#define IC_JSON_MAX_DEPTH 16
#define IC_JSON_MAX_FIELDS 64
#define IC_JSON_MAX_SHORT 256

enum ic_json_kind {
    IC_JSON_STRING = 1,
    IC_JSON_NUMBER = 2,
    IC_JSON_OBJECT = 3,
    IC_JSON_ARRAY = 4,
    IC_JSON_TRUE = 5,
    IC_JSON_FALSE = 6,
    IC_JSON_NULL = 7,
};

typedef struct {
    char key[64];
    uint32_t kind;
    const uint8_t *raw;      // 值在原文中的跨度（含引号/括号）
    uint32_t raw_bytes;
    char text[IC_JSON_MAX_SHORT]; // STRING 的解码结果；NUMBER 保留原文
    uint32_t text_bytes;
    double number;           // NUMBER 且有限
    uint32_t is_unsigned;    // NUMBER 是非负整数
    uint64_t unsigned_value;
} ic_json_field;

typedef struct {
    ic_json_field fields[IC_JSON_MAX_FIELDS];
    uint32_t count;
} ic_json_object;

enum ic_json_error {
    IC_JSON_OK = 0,
    IC_JSON_ERROR_EMPTY = -1,
    IC_JSON_ERROR_TOO_LARGE = -2,
    IC_JSON_ERROR_SYNTAX = -3,
    IC_JSON_ERROR_UTF8 = -4,
    IC_JSON_ERROR_DUPLICATE_KEY = -5,
    IC_JSON_ERROR_TOKEN_LIMIT = -6,
    IC_JSON_ERROR_NUMBER = -7,
    IC_JSON_ERROR_STRING = -8,
    IC_JSON_ERROR_TRAILING = -9,
};

// 解析顶层对象。成功返回 IC_JSON_OK；失败时 out 不可用、err 写入 ASCII 原因。
static int ic_json_parse_object(const uint8_t *data, size_t bytes, ic_json_object *out,
                          char *err, size_t err_size);

// 取字段；缺失返回 NULL。重复键在解析阶段已拒绝。
static const ic_json_field *ic_json_get(const ic_json_object *object, const char *key);


typedef struct {
    const uint8_t *data;
    size_t size, pos;
    ic_json_object *out;
    char *err;
    size_t err_size;
    int failed;
} parser;

static int fail(parser *p, int code, const char *why) {
    if (!p->failed && p->err && p->err_size)
        snprintf(p->err, p->err_size, "%s at byte %zu", why, p->pos);
    p->failed = 1;
    return code;
}

static void skip_ws(parser *p) {
    while (p->pos < p->size) {
        uint8_t c = p->data[p->pos];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') p->pos++;
        else break;
    }
}

// 严格 UTF-8：拒绝 overlong、代理区、> U+10FFFF、截断。返回序列长度，0 = 非法。
static unsigned utf8_seq(const uint8_t *s, size_t left, uint32_t *cp) {
    if (!left) return 0;
    uint8_t c = s[0];
    if (c < 0x80) { *cp = c; return 1; }
    if (c >= 0xC2 && c <= 0xDF) {
        if (left < 2 || (s[1] & 0xC0) != 0x80) return 0;
        *cp = ((uint32_t)(c & 0x1F) << 6) | (s[1] & 0x3F);
        return 2;
    }
    if (c >= 0xE0 && c <= 0xEF) {
        if (left < 3 || (s[1] & 0xC0) != 0x80 || (s[2] & 0xC0) != 0x80) return 0;
        if (c == 0xE0 && s[1] < 0xA0) return 0;                 // overlong
        if (c == 0xED && s[1] >= 0xA0) return 0;                // UTF-16 代理区
        *cp = ((uint32_t)(c & 0x0F) << 12) | ((uint32_t)(s[1] & 0x3F) << 6) | (s[2] & 0x3F);
        return 3;
    }
    if (c >= 0xF0 && c <= 0xF4) {
        if (left < 4 || (s[1] & 0xC0) != 0x80 || (s[2] & 0xC0) != 0x80 || (s[3] & 0xC0) != 0x80) return 0;
        if (c == 0xF0 && s[1] < 0x90) return 0;                 // overlong
        if (c == 0xF4 && s[1] > 0x8F) return 0;                 // > U+10FFFF
        *cp = ((uint32_t)(c & 0x07) << 18) | ((uint32_t)(s[1] & 0x3F) << 12)
            | ((uint32_t)(s[2] & 0x3F) << 6) | (s[3] & 0x3F);
        return 4;
    }
    return 0;
}

static int put_utf8(char *dst, size_t cap, size_t *used, uint32_t cp) {
    uint8_t bytes[4];
    unsigned n;
    if (cp < 0x80) { bytes[0] = (uint8_t)cp; n = 1; }
    else if (cp < 0x800) { bytes[0] = (uint8_t)(0xC0 | (cp >> 6)); bytes[1] = (uint8_t)(0x80 | (cp & 0x3F)); n = 2; }
    else if (cp < 0x10000) {
        bytes[0] = (uint8_t)(0xE0 | (cp >> 12)); bytes[1] = (uint8_t)(0x80 | ((cp >> 6) & 0x3F));
        bytes[2] = (uint8_t)(0x80 | (cp & 0x3F)); n = 3;
    } else {
        bytes[0] = (uint8_t)(0xF0 | (cp >> 18)); bytes[1] = (uint8_t)(0x80 | ((cp >> 12) & 0x3F));
        bytes[2] = (uint8_t)(0x80 | ((cp >> 6) & 0x3F)); bytes[3] = (uint8_t)(0x80 | (cp & 0x3F)); n = 4;
    }
    if (!dst) return 0;
    if (*used + n > cap) return -1;
    memcpy(dst + *used, bytes, n);
    *used += n;
    return 0;
}

// 解析字符串（p->pos 指向开引号），验证并可选解码到 dst/cap。
static int parse_string(parser *p, char *dst, size_t cap, size_t *out_bytes) {
    if (p->pos >= p->size || p->data[p->pos] != '"') return fail(p, IC_JSON_ERROR_STRING, "expected string");
    p->pos++;
    size_t used = 0;
    while (p->pos < p->size) {
        uint8_t c = p->data[p->pos++];
        if (c == '"') {
            if (dst) {
                if (used >= cap) return fail(p, IC_JSON_ERROR_STRING, "string too long");
                dst[used] = 0;
            }
            if (out_bytes) *out_bytes = (uint32_t)used;
            return IC_JSON_OK;
        }
        if (c < 0x20) return fail(p, IC_JSON_ERROR_STRING, "raw control character");
        if (c == '\\') {
            if (p->pos >= p->size) return fail(p, IC_JSON_ERROR_STRING, "truncated escape");
            uint8_t e = p->data[p->pos++];
            uint32_t cp;
            switch (e) {
            case '"': cp = '"'; break;
            case '\\': cp = '\\'; break;
            case '/': cp = '/'; break;
            case 'b': cp = 8; break;
            case 'f': cp = 12; break;
            case 'n': cp = 10; break;
            case 'r': cp = 13; break;
            case 't': cp = 9; break;
            case 'u': {
                if (p->pos + 4 > p->size) return fail(p, IC_JSON_ERROR_STRING, "truncated unicode escape");
                uint32_t unit = 0;
                for (int i = 0; i < 4; i++) {
                    uint8_t h = p->data[p->pos++];
                    unit <<= 4;
                    if (h >= '0' && h <= '9') unit |= (uint32_t)(h - '0');
                    else if (h >= 'a' && h <= 'f') unit |= (uint32_t)(h - 'a' + 10);
                    else if (h >= 'A' && h <= 'F') unit |= (uint32_t)(h - 'A' + 10);
                    else return fail(p, IC_JSON_ERROR_STRING, "bad unicode escape");
                }
                if (unit >= 0xD800 && unit <= 0xDBFF) {
                    if (p->pos + 6 > p->size || p->data[p->pos] != '\\' || p->data[p->pos + 1] != 'u')
                        return fail(p, IC_JSON_ERROR_STRING, "unpaired surrogate");
                    p->pos += 2;
                    uint32_t low = 0;
                    for (int i = 0; i < 4; i++) {
                        uint8_t h = p->data[p->pos++];
                        low <<= 4;
                        if (h >= '0' && h <= '9') low |= (uint32_t)(h - '0');
                        else if (h >= 'a' && h <= 'f') low |= (uint32_t)(h - 'a' + 10);
                        else if (h >= 'A' && h <= 'F') low |= (uint32_t)(h - 'A' + 10);
                        else return fail(p, IC_JSON_ERROR_STRING, "bad low surrogate");
                    }
                    if (low < 0xDC00 || low > 0xDFFF) return fail(p, IC_JSON_ERROR_STRING, "unpaired surrogate");
                    cp = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00);
                } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
                    return fail(p, IC_JSON_ERROR_STRING, "unpaired surrogate");
                } else cp = unit;
                break;
            }
            default: return fail(p, IC_JSON_ERROR_STRING, "unknown escape");
            }
            if (put_utf8(dst, cap, &used, cp)) return fail(p, IC_JSON_ERROR_STRING, "string too long");
            continue;
        }
        if (c < 0x80) {
            if (dst) {
                if (used + 1 > cap) return fail(p, IC_JSON_ERROR_STRING, "string too long");
                dst[used] = (char)c;
            }
            used++;
            continue;
        }
        // 多字节序列：回到序列起点做严格校验。
        size_t start = --p->pos;
        uint32_t cp;
        unsigned n = utf8_seq(p->data + start, p->size - start, &cp);
        if (!n) return fail(p, IC_JSON_ERROR_UTF8, "invalid UTF-8");
        p->pos = start + n;
        if (put_utf8(dst, cap, &used, cp)) return fail(p, IC_JSON_ERROR_STRING, "string too long");
    }
    return fail(p, IC_JSON_ERROR_STRING, "unterminated string");
}

static int parse_number(parser *p, double *value, uint32_t *is_unsigned, uint64_t *uvalue) {
    size_t start = p->pos;
    int negative = 0;
    if (p->pos < p->size && p->data[p->pos] == '-') { negative = 1; p->pos++; }
    if (p->pos >= p->size) return fail(p, IC_JSON_ERROR_NUMBER, "number");
    if (p->data[p->pos] == '0') {
        p->pos++;
        if (p->pos < p->size && p->data[p->pos] >= '0' && p->data[p->pos] <= '9')
            return fail(p, IC_JSON_ERROR_NUMBER, "leading zero");
    } else if (p->data[p->pos] >= '1' && p->data[p->pos] <= '9') {
        while (p->pos < p->size && p->data[p->pos] >= '0' && p->data[p->pos] <= '9') p->pos++;
    } else return fail(p, IC_JSON_ERROR_NUMBER, "number");
    int integer = 1;
    if (p->pos < p->size && p->data[p->pos] == '.') {
        integer = 0;
        p->pos++;
        if (p->pos >= p->size || p->data[p->pos] < '0' || p->data[p->pos] > '9')
            return fail(p, IC_JSON_ERROR_NUMBER, "fraction");
        while (p->pos < p->size && p->data[p->pos] >= '0' && p->data[p->pos] <= '9') p->pos++;
    }
    if (p->pos < p->size && (p->data[p->pos] == 'e' || p->data[p->pos] == 'E')) {
        integer = 0;
        p->pos++;
        if (p->pos < p->size && (p->data[p->pos] == '+' || p->data[p->pos] == '-')) p->pos++;
        if (p->pos >= p->size || p->data[p->pos] < '0' || p->data[p->pos] > '9')
            return fail(p, IC_JSON_ERROR_NUMBER, "exponent");
        while (p->pos < p->size && p->data[p->pos] >= '0' && p->data[p->pos] <= '9') p->pos++;
    }
    size_t length = p->pos - start;
    char buffer[96];
    if (length >= 64) return fail(p, IC_JSON_ERROR_NUMBER, "number too long");
    // JSON always spells its decimal point with '.', independently of the
    // process locale. Translate that one token for standard-C strtod; the JSON
    // lexer above still rejects locale punctuation in the original document.
    const char *decimal = localeconv()->decimal_point;
    const uint8_t *dot = memchr(p->data + start, '.', length);
    size_t point_bytes = strlen(decimal);
    if (dot && strcmp(decimal, ".")) {
        if (!point_bytes || length - 1 + point_bytes >= sizeof buffer) return fail(p, IC_JSON_ERROR_NUMBER, "decimal point too long");
        size_t prefix = (size_t)(dot - (p->data + start));
        memcpy(buffer, p->data + start, prefix); memcpy(buffer + prefix, decimal, point_bytes);
        memcpy(buffer + prefix + point_bytes, dot + 1, length - prefix - 1);
        buffer[length - 1 + point_bytes] = 0;
    } else { memcpy(buffer, p->data + start, length); buffer[length] = 0; }
    char *end = NULL;
    double parsed = strtod(buffer, &end);
    if (!end || *end || !isfinite(parsed)) return fail(p, IC_JSON_ERROR_NUMBER, "non-finite number");
    *value = parsed;
    *is_unsigned = integer && !negative;
    if (*is_unsigned) {
        uint64_t number = strtoull(buffer, &end, 10);
        if (!end || *end) return fail(p, IC_JSON_ERROR_NUMBER, "integer");
        *uvalue = number;
    } else *uvalue = 0;
    return IC_JSON_OK;
}

static int parse_value(parser *p, int depth, ic_json_field *field);

static int parse_object_nested(parser *p, int depth) {
    if (depth >= IC_JSON_MAX_DEPTH) return fail(p, IC_JSON_ERROR_SYNTAX, "nesting too deep");
    p->pos++; // {
    skip_ws(p);
    if (p->pos < p->size && p->data[p->pos] == '}') { p->pos++; return IC_JSON_OK; }
    for (;;) {
        skip_ws(p);
        if (parse_string(p, NULL, 0, NULL)) return IC_JSON_ERROR_STRING;
        skip_ws(p);
        if (p->pos >= p->size || p->data[p->pos] != ':') return fail(p, IC_JSON_ERROR_SYNTAX, "expected colon");
        p->pos++;
        skip_ws(p);
        if (parse_value(p, depth + 1, NULL)) return IC_JSON_ERROR_SYNTAX;
        skip_ws(p);
        if (p->pos >= p->size) return fail(p, IC_JSON_ERROR_SYNTAX, "unterminated object");
        if (p->data[p->pos] == ',') { p->pos++; continue; }
        if (p->data[p->pos] == '}') { p->pos++; return IC_JSON_OK; }
        return fail(p, IC_JSON_ERROR_SYNTAX, "expected comma");
    }
}

static int parse_array_nested(parser *p, int depth) {
    if (depth >= IC_JSON_MAX_DEPTH) return fail(p, IC_JSON_ERROR_SYNTAX, "nesting too deep");
    p->pos++; // [
    skip_ws(p);
    if (p->pos < p->size && p->data[p->pos] == ']') { p->pos++; return IC_JSON_OK; }
    for (;;) {
        skip_ws(p);
        if (parse_value(p, depth + 1, NULL)) return IC_JSON_ERROR_SYNTAX;
        skip_ws(p);
        if (p->pos >= p->size) return fail(p, IC_JSON_ERROR_SYNTAX, "unterminated array");
        if (p->data[p->pos] == ',') { p->pos++; continue; }
        if (p->data[p->pos] == ']') { p->pos++; return IC_JSON_OK; }
        return fail(p, IC_JSON_ERROR_SYNTAX, "expected comma");
    }
}

static int parse_value(parser *p, int depth, ic_json_field *field) {
    if (depth >= IC_JSON_MAX_DEPTH) return fail(p, IC_JSON_ERROR_SYNTAX, "nesting too deep");
    if (p->pos >= p->size) return fail(p, IC_JSON_ERROR_SYNTAX, "unexpected end");
    size_t start = p->pos;
    uint8_t c = p->data[p->pos];
    int kind;
    if (c == '"') {
        size_t used = 0;
        if (parse_string(p, field ? field->text : NULL,
                         field ? IC_JSON_MAX_SHORT : 0, &used)) return IC_JSON_ERROR_STRING;
        kind = IC_JSON_STRING;
        if (field) field->text_bytes = (uint32_t)used;
    } else if (c == '{') {
        if (parse_object_nested(p, depth)) return IC_JSON_ERROR_SYNTAX;
        kind = IC_JSON_OBJECT;
    } else if (c == '[') {
        if (parse_array_nested(p, depth)) return IC_JSON_ERROR_SYNTAX;
        kind = IC_JSON_ARRAY;
    } else if (c == 't' && p->size - p->pos >= 4 && !memcmp(p->data + p->pos, "true", 4)) {
        p->pos += 4; kind = IC_JSON_TRUE;
    } else if (c == 'f' && p->size - p->pos >= 5 && !memcmp(p->data + p->pos, "false", 5)) {
        p->pos += 5; kind = IC_JSON_FALSE;
    } else if (c == 'n' && p->size - p->pos >= 4 && !memcmp(p->data + p->pos, "null", 4)) {
        p->pos += 4; kind = IC_JSON_NULL;
    } else if (c == '-' || (c >= '0' && c <= '9')) {
        // parse_number 成功时三项都会写；先初始化是为了在 -O1 -Werror=maybe-uninitialized
        // 的宿主编译器（GCC 15）下不误报——调用方只读返回值 0 之后的字段。
        double number = 0;
        uint32_t is_unsigned = 0;
        uint64_t uvalue = 0;
        if (parse_number(p, &number, &is_unsigned, &uvalue)) return IC_JSON_ERROR_NUMBER;
        kind = IC_JSON_NUMBER;
        if (field) {
            field->number = number;
            field->is_unsigned = is_unsigned;
            field->unsigned_value = uvalue;
        }
    } else return fail(p, IC_JSON_ERROR_SYNTAX, "unexpected value");
    if (field) {
        field->kind = (uint32_t)kind;
        field->raw = p->data + start;
        field->raw_bytes = (uint32_t)(p->pos - start);
    }
    return IC_JSON_OK;
}

static int ic_json_parse_object(const uint8_t *data, size_t bytes, ic_json_object *out,
                          char *err, size_t err_size) {
    if (err && err_size) err[0] = 0;
    if (!data || !out) {
        if (err && err_size) snprintf(err, err_size, "null input");
        return IC_JSON_ERROR_EMPTY;
    }
    if (!bytes) {
        if (err && err_size) snprintf(err, err_size, "empty input");
        return IC_JSON_ERROR_EMPTY;
    }
    if (bytes > IC_JSON_MAX_BYTES) {
        if (err && err_size) snprintf(err, err_size, "document larger than %u", IC_JSON_MAX_BYTES);
        return IC_JSON_ERROR_TOO_LARGE;
    }
    parser p = { data, bytes, 0, out, err, err_size, 0 };
    memset(out, 0, sizeof *out);
    skip_ws(&p);
    if (p.pos >= p.size || p.data[p.pos] != '{') {
        fail(&p, IC_JSON_ERROR_SYNTAX, "top-level object required");
        return IC_JSON_ERROR_SYNTAX;
    }
    p.pos++;
    skip_ws(&p);
    if (p.pos < p.size && p.data[p.pos] == '}') p.pos++;
    else {
        for (;;) {
            skip_ws(&p);
            if (out->count == IC_JSON_MAX_FIELDS) {
                fail(&p, IC_JSON_ERROR_TOKEN_LIMIT, "too many top-level fields");
                return IC_JSON_ERROR_TOKEN_LIMIT;
            }
            ic_json_field *field = &out->fields[out->count];
            memset(field, 0, sizeof *field);
            size_t key_bytes = 0;
            if (parse_string(&p, field->key, sizeof field->key, &key_bytes)) return p.failed ? IC_JSON_ERROR_STRING : IC_JSON_ERROR_STRING;
            if (strlen(field->key) != key_bytes) return fail(&p, IC_JSON_ERROR_STRING, "NUL in field name");
            skip_ws(&p);
            if (p.pos >= p.size || p.data[p.pos] != ':') {
                fail(&p, IC_JSON_ERROR_SYNTAX, "expected colon");
                return IC_JSON_ERROR_SYNTAX;
            }
            p.pos++;
            skip_ws(&p);
            if (parse_value(&p, 1, field)) return IC_JSON_ERROR_SYNTAX;
            for (uint32_t i = 0; i < out->count; i++) {
                if (!strcmp(out->fields[i].key, field->key)) {
                    fail(&p, IC_JSON_ERROR_DUPLICATE_KEY, "duplicate key");
                    return IC_JSON_ERROR_DUPLICATE_KEY;
                }
            }
            out->count++;
            skip_ws(&p);
            if (p.pos >= p.size) { fail(&p, IC_JSON_ERROR_SYNTAX, "unterminated object"); return IC_JSON_ERROR_SYNTAX; }
            if (p.data[p.pos] == ',') { p.pos++; continue; }
            if (p.data[p.pos] == '}') { p.pos++; break; }
            fail(&p, IC_JSON_ERROR_SYNTAX, "expected comma");
            return IC_JSON_ERROR_SYNTAX;
        }
    }
    skip_ws(&p);
    if (p.pos != p.size) {
        fail(&p, IC_JSON_ERROR_TRAILING, "trailing bytes");
        return IC_JSON_ERROR_TRAILING;
    }
    return IC_JSON_OK;
}

static const ic_json_field *ic_json_get(const ic_json_object *object, const char *key) {
    if (!object || !key) return NULL;
    for (uint32_t i = 0; i < object->count; i++)
        if (!strcmp(object->fields[i].key, key)) return &object->fields[i];
    return NULL;
}


static const char *const input_targets[S2A_INPUT_TARGET_COUNT] = {
    "A", "B", "X", "Y", "LS", "RS", "L", "R", "ZL", "ZR", "PLUS", "MINUS",
    "LEFT", "UP", "RIGHT", "DOWN", "LS_LEFT", "LS_UP", "LS_RIGHT", "LS_DOWN",
    "RS_LEFT", "RS_UP", "RS_RIGHT", "RS_DOWN"
};
static const char *const input_pads[] = {
    "east", "south", "north", "west", "leftStick", "rightStick", "leftShoulder", "rightShoulder",
    "leftTrigger", "rightTrigger", "menu", "options", "dpadLeft", "dpadUp", "dpadRight", "dpadDown"
};
static const char *const input_axes[] = {"leftX", "leftY", "rightX", "rightY"};
static const char *const axis_targets[] = {"LX", "LY", "RX", "RY"};
const char *s2a_input_target_name(int i) { return i >= 0 && i < S2A_INPUT_TARGET_COUNT ? input_targets[i] : NULL; }
const char *s2a_input_pad_name(int i) { return i >= 0 && i < 16 ? input_pads[i] : NULL; }
const char *s2a_input_axis_name(int i) { return i >= 0 && i < 4 ? input_axes[i] : NULL; }
static void input_empty(s2a_input_config *c) {
    memset(c, 0, sizeof *c);
    for (int i = 0; i < S2A_INPUT_TARGET_COUNT; i++) c->keyboard[i].code = c->mouse[i] = c->gamepad[i] = -1;
    for (int i = 0; i < 4; i++) c->axes[i].source = -1;
    c->recenter = c->mouse_camera = 1; c->deadzone = .15; c->sensitivity_x = c->sensitivity_y = 1;
}
void s2a_input_config_default(s2a_input_config *out) {
    if (!out) return;
    input_empty(out);
    // Frozen from front_mac.m default_config(), same schema 1 key meanings.
    const int keys[24] = {14,56,49,-1,59,8,12,5,-1,15,48,46,123,126,124,125,0,13,2,1,-1,-1,-1,-1};
    const int pads[16] = {0,1,2,3,4,5,6,7,8,9,10,11,12,13,14,15};
    for (int i = 0; i < 24; i++) out->keyboard[i].code = keys[i];
    for (int i = 0; i < 16; i++) out->gamepad[i] = pads[i];
    out->mouse[3] = 0; out->mouse[8] = 1;
    for (int i = 0; i < 4; i++) out->axes[i].source = i;
}
static int input_index(const char *name, const char *const *names, int n) {
    for (int i = 0; i < n; i++) if (!strcmp(name, names[i])) return i;
    return -1;
}
static int input_string(const ic_json_field *f, const char *value) {
    return f && f->kind == IC_JSON_STRING && f->text_bytes == strlen(value) && !memcmp(f->text, value, f->text_bytes);
}
static int input_string_index(const ic_json_field *f, const char *const *names, int n) {
    if (!f || f->kind != IC_JSON_STRING || strlen(f->text) != f->text_bytes) return -1;
    return input_index(f->text, names, n);
}
static int input_integer(const ic_json_field *f, int hi, int *value) {
    if (!f || f->kind != IC_JSON_NUMBER || f->number < 0 || f->number > hi) return 0;
    // JSON integer type, including -0; decimal/exponent spelling is a float in
    // the existing saveInput schema and cannot stand in for a key/button code.
    for (uint32_t i = 0; i < f->raw_bytes; i++) if (f->raw[i] == '.' || f->raw[i] == 'e' || f->raw[i] == 'E') return 0;
    *value = (int)f->number; return 1;
}
static int input_bool(const ic_json_field *f, int fallback, int *value) {
    if (!f) { *value = fallback; return 1; }
    if (f->kind != IC_JSON_TRUE && f->kind != IC_JSON_FALSE) return 0;
    *value = f->kind == IC_JSON_TRUE; return 1;
}
static int input_object(const ic_json_field *f, ic_json_object *o) {
    return f && f->kind == IC_JSON_OBJECT && ic_json_parse_object(f->raw, f->raw_bytes, o, NULL, 0) == IC_JSON_OK;
}
const char *s2a_input_config_error_message(int e) {
    static const char *const messages[] = {"ok", "invalid input JSON", "unsupported input schema", "incomplete input config",
        "invalid input target", "invalid input binding", "duplicate input binding", "input value out of range", "cannot read input config"};
    return e >= 0 && e <= S2A_INPUT_CONFIG_IO ? messages[e] : "unknown input config error";
}
int s2a_input_config_parse(const char *json, size_t bytes, s2a_input_config *out) {
    if (!out || !json || !bytes || bytes > S2A_INPUT_CONFIG_MAX_BYTES) return S2A_INPUT_CONFIG_JSON;
    ic_json_object root;
    if (ic_json_parse_object((const uint8_t *)json, bytes, &root, NULL, 0)) return S2A_INPUT_CONFIG_JSON;
    const ic_json_field *f = ic_json_get(&root, "schema");
    if (!f || f->kind != IC_JSON_NUMBER || f->number != 1) return S2A_INPUT_CONFIG_SCHEMA;
    s2a_input_config result; input_empty(&result);
    const char *const groups[] = {"keyboard", "mouse", "gamepad", "axes"};
    for (int g = 0; g < 4; g++) {
        ic_json_object group;
        f = ic_json_get(&root, groups[g]);
        if (!f || f->kind != IC_JSON_OBJECT) return S2A_INPUT_CONFIG_FIELDS;
        if (!input_object(f, &group)) return S2A_INPUT_CONFIG_JSON;
        for (uint32_t i = 0; i < group.count; i++) {
            const ic_json_field *v = &group.fields[i];
            int target = input_index(v->key, g == 3 ? axis_targets : input_targets, g == 3 ? 4 : 24);
            if (target < 0) return S2A_INPUT_CONFIG_TARGET;
            int code, modifiers = 0, invert = 0; ic_json_object binding;
            if (g == 0) {
                if (!input_object(v, &binding) || !input_integer(ic_json_get(&binding, "code"), 127, &code)) return S2A_INPUT_CONFIG_BINDING;
                f = ic_json_get(&binding, "modifiers");
                if (f && !input_integer(f, 7, &modifiers)) return S2A_INPUT_CONFIG_BINDING;
                for (int k = 0; k < 24; k++) if (result.keyboard[k].code == code && result.keyboard[k].modifiers == (unsigned)modifiers) return S2A_INPUT_CONFIG_DUPLICATE;
                result.keyboard[target] = (s2a_input_key){code, (unsigned)modifiers};
            } else if (g == 1) {
                if (!input_integer(v, 4, &code)) return S2A_INPUT_CONFIG_BINDING;
                for (int k = 0; k < 24; k++) if (result.mouse[k] == code) return S2A_INPUT_CONFIG_DUPLICATE;
                result.mouse[target] = code;
            } else if (g == 2) {
                code = input_string_index(v, input_pads, 16);
                if (code < 0) return S2A_INPUT_CONFIG_BINDING;
                for (int k = 0; k < 24; k++) if (result.gamepad[k] == code) return S2A_INPUT_CONFIG_DUPLICATE;
                result.gamepad[target] = code;
            } else {
                if (!input_object(v, &binding)) return S2A_INPUT_CONFIG_BINDING;
                code = input_string_index(ic_json_get(&binding, "source"), input_axes, 4);
                if (code < 0 || !input_bool(ic_json_get(&binding, "invert"), 0, &invert)) return S2A_INPUT_CONFIG_BINDING;
                for (int k = 0; k < 4; k++) if (result.axes[k].source == code) return S2A_INPUT_CONFIG_DUPLICATE;
                result.axes[target] = (s2a_input_axis){code, invert};
            }
        }
    }
    f = ic_json_get(&root, "deadzone");
    if (!f || f->kind != IC_JSON_NUMBER || f->number < 0 || f->number >= 1) return S2A_INPUT_CONFIG_RANGE;
    result.deadzone = f->number;
    ic_json_object options;
    if (!input_object(ic_json_get(&root, "mouseOptions"), &options)) return S2A_INPUT_CONFIG_FIELDS;
    f = ic_json_get(&options, "mode");
    if (!input_string(f, "camera") && !input_string(f, "off")) return S2A_INPUT_CONFIG_BINDING;
    result.mouse_camera = input_string(f, "camera");
    const char *const sensitivity[] = {"sensitivityX", "sensitivityY"};
    for (int i = 0; i < 2; i++) {
        f = ic_json_get(&options, sensitivity[i]);
        if (!f || f->kind != IC_JSON_NUMBER || f->number < .1 || f->number > 10) return S2A_INPUT_CONFIG_RANGE;
        if (i) result.sensitivity_y = f->number; else result.sensitivity_x = f->number;
    }
    if (!input_bool(ic_json_get(&options, "invertX"), 0, &result.invert_x) ||
        !input_bool(ic_json_get(&options, "invertY"), 0, &result.invert_y) ||
        !input_bool(ic_json_get(&options, "recenter"), 1, &result.recenter)) return S2A_INPUT_CONFIG_BINDING;
    *out = result;
    return S2A_INPUT_CONFIG_OK;
}
