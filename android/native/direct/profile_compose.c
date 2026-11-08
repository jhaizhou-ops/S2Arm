// enabled profile 合成（native 侧胶水，仅 nvn_vk 后端编译）。
// 设备事实由 device_caps.c 产出；compiler 常量/哈希在 managed（s2a_direct_profile_json_v1）里算。
// 这里只做：生成 caps → 调 managed → 复制结果（有界）→ 取出 profileHash 供 selection/attempt 使用。
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "profile_compose.h"
#include "device_caps.h"
#include "direct/json.h"
#include "direct/s2a_direct.h"

#define CAPS_MAX 8192

struct capture {
    char *out;
    size_t cap;
    size_t bytes;
    int overflow;
};

// emit 在 managed 侧同步调用：返回值非 0 表示 native 没接住结果。
static int32_t capture_emit(void *sink, s2a_direct_bytes result) {
    struct capture *c = (struct capture *)sink;
    if (!c || !c->out || !result.data || result.bytes == 0) return -1;
    if (result.bytes >= c->cap) { c->overflow = 1; return -1; }
    memcpy(c->out, result.data, (size_t)result.bytes);
    c->out[result.bytes] = 0;
    c->bytes = (size_t)result.bytes;
    return 0;
}

static void set_why(char *why, size_t why_size, const char *text) {
    if (why && why_size) snprintf(why, why_size, "%s", text);
}

int s2a_direct_build_profile(const struct s2a_vk_device *device, const char *translator_closure,
                             char *out, size_t cap, size_t *len, char profile_hash[72],
                             char *why, size_t why_size) {
    if (!device || !translator_closure || !translator_closure[0] || !out || cap < 512 || !profile_hash) {
        set_why(why, why_size, "profile build: bad argument");
        return -1;
    }
    char caps[CAPS_MAX];
    size_t caps_len = 0;
    if (s2a_vk_device_caps_json(device, caps, sizeof caps, &caps_len)) {
        set_why(why, why_size, "device caps json failed");
        return -1;
    }
    struct capture captured;
    memset(&captured, 0, sizeof captured);
    captured.out = out;
    captured.cap = cap;
    s2a_direct_bytes input;
    input.data = (const uint8_t *)caps;
    input.bytes = caps_len;
    // 只有带 NativeAOT 编译器时才有 profile 生产者；诊断/探针构建没有它时明确拒绝，
    // 不伪造一个空 profile 或返回成功的占位实现。
    extern int32_t s2a_direct_profile_json_v1(s2a_direct_bytes caps, const char *translator_closure,
        int32_t (*emit)(void *, s2a_direct_bytes), void *sink) __attribute__((weak));
    if (!s2a_direct_profile_json_v1) {
        set_why(why, why_size, "managed profile producer unavailable (no NativeAOT)");
        return -1;
    }
    int32_t rc = s2a_direct_profile_json_v1(input, translator_closure, capture_emit, &captured);
    if (rc != S2A_DIRECT_RES_OK) {
        // 身份不匹配等错误由 managed 侧用 s2a-direct-error-v1 回在 emit 里：把 code/message 提取出来，
        // 上层（provider_vk → selection）就能显示“包与编译器版本不匹配”及双方实际 closure，
        // 不再只剩一句 rc=-1。
        char detail[448] = "";
        if (captured.bytes && !captured.overflow) {
            const char *txt = out;
            const size_t n = captured.bytes;
            size_t k = 0;
            for (size_t i = 0; i < n && k < sizeof detail - 1; i++) {
                unsigned char ch = (unsigned char)txt[i];
                // 只压掉控制字符：中文提示是 UTF-8 多字节，按 ASCII 过滤会把“包与编译器
                // 版本不匹配”整句变成问号，界面上就看不出该做什么了。
                detail[k++] = (ch >= 0x20 && ch != 0x7f) ? (char)ch : '?';
            }
            detail[k] = 0;
        }
        if (why && why_size)
            snprintf(why, why_size, "profile compose rejected (rc=%d)%s%s", (int)rc,
                     detail[0] ? " 原因=" : "", detail);
        return -1;
    }
    if (captured.overflow || !captured.bytes) {
        if (why && why_size) snprintf(why, why_size, "profile is larger than %zu bytes", cap);
        return -1;
    }
    s2a_json_object object;
    char error[96] = "";
    if (s2a_json_parse_object((const uint8_t *)out, captured.bytes, &object, error, sizeof error)) {
        if (why && why_size) snprintf(why, why_size, "profile json: %s", error[0] ? error : "parse failed");
        return -1;
    }
    const s2a_json_field *hash = s2a_json_get(&object, "profileHash");
    if (!hash || hash->kind != S2A_JSON_STRING || hash->text_bytes != 71 ||
        strncmp(hash->text, "sha256-", 7) != 0) {
        set_why(why, why_size, "profile has no sha256-<64hex> profileHash");
        return -1;
    }
    memcpy(profile_hash, hash->text, 72);
    if (len) *len = captured.bytes;
    return 0;
}
