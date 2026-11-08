// source_store 宿主测试：SetShaders 期的真实字节在源内存被复用后仍然稳定；
// 按 key 查与 SetShaders 数组序号无关（VS/FS 分开绑定、数组顺序不同的基础）。
//
// F4.3/F4.2A 修订后的合同（2026-10-27）：
//   * keep 只接受“短 key = SHA-256(control‖code) 前 8 字节”的输入；不符就拒绝，不存可能误命中的条目。
//     同一短 key 已指向别的内容时，该 key 被标成歧义：之后按它的查找一律失败，不覆盖、不取最新。
//   * acquire 返回引用令牌，release 只认令牌；同 key 重新登记后，旧代的 release 不会误放新代。
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "direct/sha256.h"
#include "direct/source_store.h"

// source_store 的失败日志出口在设备上由 hle_nvn 接到 logcat；宿主测试给空实现。
static int g_source_log_lines;
void s2a_source_log_line(const char *line) { (void)line; g_source_log_lines++; }

static int fails;
#define CHECK(cond, what) do { if (!(cond)) { printf("FAIL: %s\n", what); fails++; } } while (0)

// 生产口径的短 key：SHA-256(control‖code) 的前 8 字节（与前端 keys_hash 同一字节顺序）。
static void make_key(const void *code, uint32_t code_bytes, const void *control, uint32_t control_bytes,
                     uint8_t out[8]) {
    s2a_sha256 c;
    uint8_t md[32];
    s2a_sha256_init(&c);
    s2a_sha256_update(&c, control, control_bytes);
    s2a_sha256_update(&c, code, code_bytes);
    s2a_sha256_final(&c, md);
    memcpy(out, md, 8);
}

static void make_digest(const void *code, uint32_t code_bytes, const void *control, uint32_t control_bytes,
                        uint8_t out[32]) {
    s2a_sha256 c;
    s2a_sha256_init(&c);
    s2a_sha256_update(&c, control, control_bytes);
    s2a_sha256_update(&c, code, code_bytes);
    s2a_sha256_final(&c, out);
}

static uint8_t g_code_a[0x200];   // 原始 code_a 的副本：用例会故意涂掉工作缓冲验证快照自持
static uint8_t g_ctl_a[S2A_SOURCE_CONTROL_BYTES];
static int s2a_source_identity_ok_for_test(const uint8_t key[8]) {
    uint8_t sha[32];
    uint32_t cb = 0, ctlb = 0;
    return s2a_source_identity(key, sha, &cb, &ctlb) == 0;
}

int main(void) {
    enum { CODE_BYTES = 0x200 };
    static uint8_t code_a[CODE_BYTES], code_b[CODE_BYTES], ctl_a[S2A_SOURCE_CONTROL_BYTES], ctl_b[S2A_SOURCE_CONTROL_BYTES];
    for (int i = 0; i < CODE_BYTES; i++) code_a[i] = (uint8_t)(i * 7 + 1);
    memcpy(g_code_a, code_a, CODE_BYTES);
    for (int i = 0; i < CODE_BYTES; i++) code_b[i] = (uint8_t)(i * 13 + 5);
    for (unsigned i = 0; i < S2A_SOURCE_CONTROL_BYTES; i++) { ctl_a[i] = (uint8_t)(i * 3u); ctl_b[i] = (uint8_t)(0xffu - i); }
    // 让控制段 +0x704 的 code 长度字段与真实 code 一致（与实际生产者同样按真实值存）。
    uint32_t n = CODE_BYTES;
    memcpy(ctl_a + 0x704, &n, 4);
    memcpy(ctl_b + 0x704, &n, 4);
    // c1 的真实范围：+0x700 起点 / +0x704 终点，偏移相对 code 起点（tail = code + control）。
    // 取 code 尾部 0x40 字节 + control 开头 0x40 字节，验证跨界切片。
    uint32_t c1_begin = CODE_BYTES - 0x40, c1_end = CODE_BYTES + 0x40;
    memcpy(ctl_a + 0x700, &c1_begin, 4); memcpy(ctl_a + 0x704, &c1_end, 4);
    memcpy(ctl_b + 0x700, &c1_begin, 4); memcpy(ctl_b + 0x704, &c1_end, 4);
    memcpy(g_ctl_a, ctl_a, sizeof g_ctl_a);
    uint8_t key_a[8], key_b[8], sha_a[32], sha_b[32];
    make_key(code_a, CODE_BYTES, ctl_a, S2A_SOURCE_CONTROL_BYTES, key_a);
    make_key(code_b, CODE_BYTES, ctl_b, S2A_SOURCE_CONTROL_BYTES, key_b);
    make_digest(code_a, CODE_BYTES, ctl_a, S2A_SOURCE_CONTROL_BYTES, sha_a);
    make_digest(code_b, CODE_BYTES, ctl_b, S2A_SOURCE_CONTROL_BYTES, sha_b);
    CHECK(memcmp(key_a, sha_a, 8) == 0, "test key derives from the same digest as production");
    CHECK(memcmp(key_a, key_b, 8) != 0, "fixtures have distinct keys");

    // 真实 SetShaders 顺序：FS 在数组前面、VS 在后面。
    CHECK(s2a_source_keep(key_b, 0, code_b, CODE_BYTES, ctl_b, S2A_SOURCE_CONTROL_BYTES) == 0, "keep fs at index 0");
    CHECK(s2a_source_keep(key_a, 1, code_a, CODE_BYTES, ctl_a, S2A_SOURCE_CONTROL_BYTES) == 0, "keep vs at index 1");

    // 源内存被复用（游戏在 SetShaders 返回后重写同一块内存）：快照必须不受影响。
    memset(code_a, 0xaa, sizeof code_a);
    memset(code_b, 0xbb, sizeof code_b);
    memset(ctl_a, 0xcc, sizeof ctl_a);
    memset(ctl_b, 0xdd, sizeof ctl_b);

    struct s2a_source_entry_view v;
    memset(&v, 0, sizeof v);
    CHECK(s2a_source_get_key(key_a, &v) == 1, "find vs by key");
    CHECK(v.c1 && v.c1_bytes == 0x80, "c1 uses the control-declared real range (0x80 bytes)");
    if (v.c1 && v.c1_bytes == 0x80) {
        int c1_ok = 1;
        for (unsigned i = 0; i < 0x40; i++) {
            if (v.c1[i] != (uint8_t)((CODE_BYTES - 0x40 + i) * 7 + 1)) c1_ok = 0;
            if (v.c1[0x40 + i] != (uint8_t)(i * 3u)) c1_ok = 0;   // control 开头，跳过被 0x700/0x704 覆盖的字节
        }
        CHECK(c1_ok, "c1 spans code tail and control head with the declared offsets");
    }
    CHECK(v.complete && v.code_bytes == CODE_BYTES && v.control_bytes == S2A_SOURCE_CONTROL_BYTES, "vs complete");
    CHECK(v.array_index == 1, "vs keeps its real SetShaders index");
    CHECK(memcmp(v.content_sha, sha_a, 32) == 0, "capture-time full digest is exposed unchanged");
    CHECK(v.ref == 0, "a borrowed view carries no reference token");
    CHECK(memcmp(v.code, code_a, CODE_BYTES) != 0, "vs snapshot is not the scribbled buffer");
    int good = 1;
    for (int i = 0; i < CODE_BYTES; i++) if (v.code[i] != (uint8_t)(i * 7 + 1)) good = 0;
    CHECK(good, "vs code bytes stable after the source buffer was reused");
    good = 1;
    for (unsigned i = 0; i < S2A_SOURCE_CONTROL_BYTES; i++) {
        if (i >= 0x700 && i < 0x708) continue;   // c1 起点/终点字段（测试里被真实值覆盖）
        if (v.control[i] != (uint8_t)(i * 3u)) good = 0;
    }
    CHECK(good, "vs control bytes stable after the source buffer was reused");

    memset(&v, 0, sizeof v);
    CHECK(s2a_source_get_key(key_b, &v) == 1, "find fs by key");
    CHECK(v.array_index == 0, "fs keeps its real SetShaders index");
    good = 1;
    for (int i = 0; i < CODE_BYTES; i++) if (v.code[i] != (uint8_t)(i * 13 + 5)) good = 0;
    CHECK(good, "fs code bytes stable");

    // 合并后的阶段顺序（vs 在前）与 SetShaders 数组序号不同：按 key 查仍然命中。
    memset(&v, 0, sizeof v);
    CHECK(s2a_source_get_key(key_a, &v) == 1, "vs found regardless of merged stage order");
    memset(&v, 0, sizeof v);
    CHECK(s2a_source_get(key_a, 1, &v) == 1, "get(key, real index) hits");
    CHECK(s2a_source_get(key_a, 0, &v) == 0, "get(key, wrong index) does not fabricate a stage");

    uint32_t entries = 0, bytes = 0, dropped = 0;
    s2a_source_stats(&entries, &bytes, &dropped);
    CHECK(entries == 2, "two snapshots retained");
    CHECK(bytes == 2u * (CODE_BYTES + S2A_SOURCE_CONTROL_BYTES + 0x80u),
          "byte budget counts code + control + c1 for both snapshots");

    // ---- 身份接口：完整摘要 + 真实长度，缺源准确失败 ----
    {
        uint8_t sha[32];
        uint32_t cb = 0, ctlb = 0;
        CHECK(s2a_source_identity(key_a, sha, &cb, &ctlb) == 0, "identity available for a unique key");
        CHECK(!memcmp(sha, sha_a, 32) && cb == CODE_BYTES && ctlb == S2A_SOURCE_CONTROL_BYTES,
              "identity returns the captured digest and real lengths");
        uint8_t missing[8] = { 0xde, 0xad, 0xbe, 0xef, 9, 9, 9, 9 };
        CHECK(s2a_source_identity(missing, sha, &cb, &ctlb) != 0, "missing source has no identity");
    }

    // ---- 内容代际：只表示 key→内容 映射的变化，不能被“同内容重登记”刷掉 ----
    {
        uint8_t ctl_clean[S2A_SOURCE_CONTROL_BYTES];
        memset(ctl_clean, 0x2b, sizeof ctl_clean);
        memcpy(ctl_clean + 0x700, &c1_begin, 4);
        memcpy(ctl_clean + 0x704, &c1_end, 4);
        make_key(g_code_a, CODE_BYTES, ctl_clean, S2A_SOURCE_CONTROL_BYTES, key_a);
        make_digest(g_code_a, CODE_BYTES, ctl_clean, S2A_SOURCE_CONTROL_BYTES, sha_a);
        s2a_source_clear();
        CHECK(s2a_source_keep(key_a, 1, g_code_a, CODE_BYTES, ctl_clean, S2A_SOURCE_CONTROL_BYTES) == 0,
              "register content for the epoch checks");
        uint64_t e0 = s2a_source_epoch();
        CHECK(s2a_source_keep(key_a, 1, g_code_a, CODE_BYTES, ctl_clean, S2A_SOURCE_CONTROL_BYTES) == 0,
              "same-content re-registration succeeds");
        CHECK(s2a_source_epoch() == e0, "same-content re-registration does not advance the source epoch");
        uint8_t fresh[8];
        static uint8_t ctl_fresh[S2A_SOURCE_CONTROL_BYTES];
        memset(ctl_fresh, 0x37, sizeof ctl_fresh);
        memcpy(ctl_fresh + 0x700, &c1_begin, 4);
        memcpy(ctl_fresh + 0x704, &c1_end, 4);
        make_key(code_b, CODE_BYTES, ctl_fresh, S2A_SOURCE_CONTROL_BYTES, fresh);
        CHECK(s2a_source_keep(fresh, 0, code_b, CODE_BYTES, ctl_fresh, S2A_SOURCE_CONTROL_BYTES) == 0,
              "new key registers");
        CHECK(s2a_source_epoch() > e0, "a new key->content mapping advances the source epoch");
        s2a_source_clear();
    }

    // ---- 反例：同一拼接摘要、不同 control/code 切分必须按不同内容处理 ----
    {
        // control 0x850 + code 0x130 与 control 0x880 + code 0x100 的拼接字节可以完全相同，
        // 但请求体（两个 base64 字段）不同。短 key 只能定位，不能证明内容相同。
        static uint8_t split_code[0x130], split_ctl[0x880];
        for (unsigned i = 0; i < sizeof split_code; i++) split_code[i] = (uint8_t)(0x60u + i * 3u);
        memset(split_ctl, 0x22, 0x850);
        memcpy(split_ctl + 0x850, split_code, 0x30);      // 后 0x30 字节来自 code 的前缀
        uint32_t ncode = sizeof split_code;
        memcpy(split_ctl + 0x700, &c1_begin, 4);
        memcpy(split_ctl + 0x704, &c1_end, 4);
        uint8_t split_key[8];
        // 两段拼接 = ctl[0..0x850) ‖ code[0..0x130)，与 ctl[0..0x880) ‖ code[0x30..0x130) 相同。
        make_key(split_code, sizeof split_code, split_ctl, 0x850, split_key);
        s2a_source_clear();
        CHECK(s2a_source_keep(split_key, 0, split_code, sizeof split_code, split_ctl, 0x850) == 0,
              "first split is stored");
        CHECK(s2a_source_keep(split_key, 0, split_code + 0x30, sizeof split_code - 0x30, split_ctl, 0x880) != 0,
              "same concatenated digest with a different control/code split is rejected");
        uint8_t ident_sha[32];
        uint32_t cb = 0, ctlb = 0;
        CHECK(s2a_source_identity(split_key, ident_sha, &cb, &ctlb) != 0,
              "an ambiguous split leaves no usable content identity");
        // 歧义 key 不能靠“重新登记原始内容”复活：那会清掉 ambiguous 标记却不推进代际。
        CHECK(s2a_source_keep(split_key, 0, split_code, sizeof split_code, split_ctl, 0x850) != 0,
              "re-registering the original content cannot revive an ambiguous key");
        CHECK(s2a_source_identity(split_key, ident_sha, &cb, &ctlb) != 0,
              "the ambiguous key stays unresolvable after a rejected revival attempt");
        (void)ncode;
        s2a_source_clear();
    }

    // ---- 淘汰推进内容代际：P1 不能绕过“完整路径应报缺源” ----
    {
        s2a_source_clear();
        // 先放一条“会被淘汰”的小条目。
        uint8_t old_key[8], old_ctl[S2A_SOURCE_CONTROL_BYTES];
        memset(old_ctl, 0x44, sizeof old_ctl);
        memcpy(old_ctl + 0x700, &c1_begin, 4);
        memcpy(old_ctl + 0x704, &c1_end, 4);
        make_key(g_code_a, CODE_BYTES, old_ctl, S2A_SOURCE_CONTROL_BYTES, old_key);
        CHECK(s2a_source_keep(old_key, 0, g_code_a, CODE_BYTES, old_ctl, S2A_SOURCE_CONTROL_BYTES) == 0,
              "store the oldest entry");
        static uint8_t huge[256u * 1024u];
        static uint8_t hctl[300][S2A_SOURCE_CONTROL_BYTES];
        memset(huge, 0x6b, sizeof huge);
        uint64_t e_before = s2a_source_epoch();
        int n = 0;
        for (; n < 300; n++) {
            memset(hctl[n], (uint8_t)(0xa0 + n), sizeof hctl[n]);
            memcpy(hctl[n] + 0x700, &c1_begin, 4);
            memcpy(hctl[n] + 0x704, &c1_end, 4);
            uint8_t k[8];
            make_key(huge, sizeof huge, hctl[n], S2A_SOURCE_CONTROL_BYTES, k);
            if (s2a_source_keep(k, 1, huge, sizeof huge, hctl[n], S2A_SOURCE_CONTROL_BYTES) != 0) break;
        }
        CHECK(n > 240, "fill the store close to its byte budget");
        CHECK(s2a_source_epoch() > e_before, "eviction advances the source epoch");
        CHECK(s2a_source_identity(old_key, (uint8_t[32]){0}, NULL, NULL) != 0,
              "the evicted key is no longer resolvable (memo must not outlive it)");
        s2a_source_clear();
    }

    // ---- 反例：短 key 与内容不符不得进入存储 ----
    {
        // 先让 key_a 真的指向 A 的内容，否则这里只是在测“缺源”，测不到歧义。
        make_key(g_code_a, CODE_BYTES, g_ctl_a, S2A_SOURCE_CONTROL_BYTES, key_a);
        s2a_source_clear();
        CHECK(s2a_source_keep(key_a, 1, g_code_a, CODE_BYTES, g_ctl_a, S2A_SOURCE_CONTROL_BYTES) == 0,
              "register A before forcing a same-key conflict");
        CHECK(s2a_source_identity_ok_for_test(key_a), "A is resolvable before the conflict");
        uint64_t rejected_before = s2a_source_rejected();
        // 用 A 的 key 登记 B 的内容（强制“同短 key 不同内容”）。
        CHECK(s2a_source_keep(key_a, 1, code_b, CODE_BYTES, ctl_b, S2A_SOURCE_CONTROL_BYTES) != 0,
              "keep rejects a short key that is not this content's digest prefix");
        CHECK(s2a_source_rejected() == rejected_before + 1, "rejection is counted");
        // 该 key 已经指向别的内容：之后按它查找必须失败，不能“取最新”也不能继续返回 A。
        memset(&v, 0, sizeof v);
        CHECK(s2a_source_get_key(key_a, &v) == 0, "ambiguous key is no longer resolvable (no silent reuse)");
        CHECK(s2a_source_acquire(key_a, &v) == 0, "ambiguous key cannot be pinned either");
        uint8_t sha[32];
        uint32_t cb = 0, ctlb = 0;
        CHECK(s2a_source_identity(key_a, sha, &cb, &ctlb) != 0, "ambiguous key has no content identity");
        // 冲突登记推进源代际：P1 备忘不能沿用冲突前的条目。
        CHECK(s2a_source_epoch() > 0, "source epoch advances on a conflicting registration");
    }

    // ---- F4.2 生命周期：引用期间不淘汰/不释放；release 只认 acquire 的令牌 ----
    for (int i = 0; i < CODE_BYTES; i++) code_a[i] = (uint8_t)(i * 7 + 1);
    memcpy(g_code_a, code_a, CODE_BYTES);
    for (int i = 0; i < CODE_BYTES; i++) code_b[i] = (uint8_t)(i * 13 + 5);
    for (unsigned i = 0; i < S2A_SOURCE_CONTROL_BYTES; i++) { ctl_a[i] = (uint8_t)(i * 3u); ctl_b[i] = (uint8_t)(0xffu - i); }
    memcpy(ctl_a + 0x700, &c1_begin, 4);
    memcpy(ctl_a + 0x704, &c1_end, 4);
    memcpy(ctl_b + 0x700, &c1_begin, 4);
    memcpy(ctl_b + 0x704, &c1_end, 4);
    make_key(code_a, CODE_BYTES, ctl_a, S2A_SOURCE_CONTROL_BYTES, key_a);
    make_key(code_b, CODE_BYTES, ctl_b, S2A_SOURCE_CONTROL_BYTES, key_b);
    make_digest(code_a, CODE_BYTES, ctl_a, S2A_SOURCE_CONTROL_BYTES, sha_a);
    s2a_source_clear();
    CHECK(s2a_source_keep(key_a, 1, code_a, CODE_BYTES, ctl_a, S2A_SOURCE_CONTROL_BYTES) == 0, "keep pinned source");
    struct s2a_source_entry_view held;
    memset(&held, 0, sizeof held);
    CHECK(s2a_source_acquire(key_a, &held) == 1, "acquire pins the snapshot");
    CHECK(held.ref != 0, "acquire returns a generation token");
    CHECK(held.code && held.control, "pinned view exposes the bytes");
    uint64_t token_old = held.ref;
    // 同 key、同内容再次登记（游戏每帧重新 SetShaders 的常见形态）：旧条目被引用的那份不能被顶掉。
    CHECK(s2a_source_keep(key_a, 1, code_a, CODE_BYTES, ctl_a, S2A_SOURCE_CONTROL_BYTES) == 0,
          "re-register the same content under the same key");
    memset(&v, 0, sizeof v);
    CHECK(s2a_source_acquire(key_a, &v) == 1 && v.ref != token_old, "new registration gets its own token");
    uint64_t token_new = v.ref;
    s2a_source_clear();
    CHECK(s2a_source_get_key(key_a, &v) == 0, "cleared snapshot is no longer findable");
    CHECK(s2a_source_acquire(key_a, &v) == 0, "cleared snapshot cannot be acquired again");
    good = 1;
    for (int i = 0; i < CODE_BYTES; i++) if (held.code[i] != (uint8_t)(i * 7 + 1)) good = 0;
    CHECK(good, "pinned bytes stay valid across clear()");
    s2a_source_keep(key_b, 0, code_b, CODE_BYTES, ctl_b, S2A_SOURCE_CONTROL_BYTES);
    s2a_source_stats(&entries, &bytes, &dropped);
    CHECK(bytes >= CODE_BYTES + S2A_SOURCE_CONTROL_BYTES, "retired pinned bytes are still accounted");
    uint32_t bytes_before = bytes;
    // 反例（旧实现按 key 找最新条目）：释放旧令牌必须回收当初 acquire 的那一代，而不是最新那代。
    s2a_source_release(token_old);
    s2a_source_stats(&entries, &bytes, &dropped);
    CHECK(bytes == bytes_before - (CODE_BYTES + S2A_SOURCE_CONTROL_BYTES + 0x80u),
          "release(token) frees the acquired generation, not the newest one");
    // 新代仍然被引用：它的字节不能随旧的释放一起回收。
    CHECK(s2a_source_get_key(key_b, &v) == 1, "the second registration is still owned by its own pin");
    s2a_source_release(token_new);
    s2a_source_stats(&entries, &bytes, &dropped);
    CHECK(bytes < bytes_before - (CODE_BYTES + S2A_SOURCE_CONTROL_BYTES + 0x80u),
          "releasing the second token frees the re-registered generation");
    // 重复释放同一令牌不得多减引用或释放别人。
    s2a_source_release(token_new);
    s2a_source_stats(&entries, &bytes, &dropped);
    CHECK(entries >= 1, "double release does not corrupt the store");

    // 引用中的条目不参与字节淘汰：塞满预算后仍能读回。
    s2a_source_clear();
    static uint8_t big[256u * 1024u];
    memset(big, 0x5a, sizeof big);
    uint8_t key_pin[8] = { 0xde, 0xad, 0xbe, 0xef, 1, 2, 3, 4 };
    uint8_t ctl_big[S2A_SOURCE_CONTROL_BYTES];
    memset(ctl_big, 0x21, sizeof ctl_big);
    memcpy(ctl_big + 0x700, &c1_begin, 4);
    memcpy(ctl_big + 0x704, &c1_end, 4);
    make_key(code_a, CODE_BYTES, ctl_big, S2A_SOURCE_CONTROL_BYTES, key_pin);
    CHECK(s2a_source_keep(key_pin, 0, code_a, CODE_BYTES, ctl_big, S2A_SOURCE_CONTROL_BYTES) == 0,
          "keep the pinned oldest");
    CHECK(s2a_source_acquire(key_pin, &held) == 1, "pin the oldest entry");
    uint8_t keys[300][8];
    static uint8_t bigctl[300][S2A_SOURCE_CONTROL_BYTES];
    for (int i = 0; i < 300; i++) {
        memset(bigctl[i], (uint8_t)(i * 5), S2A_SOURCE_CONTROL_BYTES);
        memcpy(bigctl[i] + 0x700, &c1_begin, 4);
        memcpy(bigctl[i] + 0x704, &c1_end, 4);
        make_key(big, sizeof big, bigctl[i], S2A_SOURCE_CONTROL_BYTES, keys[i]);
        if (s2a_source_keep(keys[i], 1, big, sizeof big, bigctl[i], S2A_SOURCE_CONTROL_BYTES) != 0) break;
    }
    memset(&v, 0, sizeof v);
    CHECK(s2a_source_get_key(key_pin, &v) == 1 && v.code && !memcmp(v.code, code_a, CODE_BYTES),
          "pinned oldest survives byte-budget eviction");
    s2a_source_stats(&entries, &bytes, &dropped);
    CHECK(bytes <= S2A_SOURCE_MAX_BYTES, "budget stays bounded while a pin is held");
    s2a_source_release(held.ref);
    s2a_source_clear();

    // ---- program 生命周期 pin：活 program 引用的源不参与淘汰；解 pin 后可淘汰 ----
    {
        s2a_source_clear();
        // 先存一条小条目并 pin（模拟 nvnProgramSetShaders 存源时的 pin）。
        uint8_t ctl_pin[S2A_SOURCE_CONTROL_BYTES];
        memset(ctl_pin, 0x2e, sizeof ctl_pin);
        memcpy(ctl_pin + 0x700, &c1_begin, 4);
        memcpy(ctl_pin + 0x704, &c1_end, 4);
        uint8_t key_pin2[8], sha_pin[32];
        struct s2a_source_pin_ref pin_ref;
        make_key(g_code_a, CODE_BYTES, ctl_pin, S2A_SOURCE_CONTROL_BYTES, key_pin2);
        make_digest(g_code_a, CODE_BYTES, ctl_pin, S2A_SOURCE_CONTROL_BYTES, sha_pin);
        CHECK(s2a_source_keep(key_pin2, 0, g_code_a, CODE_BYTES, ctl_pin, S2A_SOURCE_CONTROL_BYTES) == 0,
              "keep a source before the program pin");
        CHECK(s2a_source_pin_key(key_pin2, &pin_ref) == 0 && !memcmp(pin_ref.sha, sha_pin, 32),
              "program pin returns the full content_sha identity");
        // 同一 program 再次 SetShaders 同一内容：复用被 pin 的条目，不替换字节、不产生新代。
        CHECK(s2a_source_keep(key_pin2, 0, g_code_a, CODE_BYTES, ctl_pin, S2A_SOURCE_CONTROL_BYTES) == 0,
              "re-registering the same content while program-pinned succeeds");
        {
            struct s2a_source_pin_stats again;
            s2a_source_pin_stats(&again);
            CHECK(again.pinned_entries == 1 && again.pins == 1, "re-registration keeps exactly one program pin");
        }
        // 用 256 KB 大条目把 64 MiB 字节预算填爆：被 pin 的小条目必须留下。
        static uint8_t pin_fill[300][8];
        static uint8_t pin_fill_ctl[300][S2A_SOURCE_CONTROL_BYTES];
        int filled = 0;
        for (; filled < 300; filled++) {
            memset(pin_fill_ctl[filled], (uint8_t)(0x80 + filled), S2A_SOURCE_CONTROL_BYTES);
            memcpy(pin_fill_ctl[filled] + 0x700, &c1_begin, 4);
            memcpy(pin_fill_ctl[filled] + 0x704, &c1_end, 4);
            make_key(big, sizeof big, pin_fill_ctl[filled], S2A_SOURCE_CONTROL_BYTES, pin_fill[filled]);
            if (s2a_source_keep(pin_fill[filled], 1, big, sizeof big, pin_fill_ctl[filled],
                                S2A_SOURCE_CONTROL_BYTES) != 0) break;
        }
        CHECK(filled > 240, "fill past the byte budget with a program pin held");
        struct s2a_source_pin_stats ps;
        s2a_source_pin_stats(&ps);
        CHECK(ps.pinned_entries == 1 && ps.pins == 1, "exactly the program-pinned source is reported pinned");
        CHECK(ps.evict_skipped > 0, "eviction skipped the pinned entry");
        CHECK(s2a_source_identity(key_pin2, (uint8_t[32]){0}, NULL, NULL) == 0,
              "a program-pinned source survives byte-budget eviction");
        // 模拟 program 销毁/换 SetShaders：解 pin 后该条目回到可淘汰集合。
        s2a_source_unpin_ref(&pin_ref);
        s2a_source_pin_stats(&ps);
        CHECK(ps.pinned_entries == 0 && ps.pins == 0, "unpin clears the program pin");
        uint8_t extra_key[8], extra_ctl[S2A_SOURCE_CONTROL_BYTES];
        memset(extra_ctl, 0x91, sizeof extra_ctl);
        memcpy(extra_ctl + 0x700, &c1_begin, 4);
        memcpy(extra_ctl + 0x704, &c1_end, 4);
        make_key(big, sizeof big, extra_ctl, S2A_SOURCE_CONTROL_BYTES, extra_key);
        CHECK(s2a_source_keep(extra_key, 1, big, sizeof big, extra_ctl, S2A_SOURCE_CONTROL_BYTES) == 0,
              "after unpin the store can evict again");
        CHECK(s2a_source_identity(key_pin2, (uint8_t[32]){0}, NULL, NULL) != 0,
              "the unpinned source is the oldest and gets evicted");
        s2a_source_clear();
    }

    // ---- 源条数超过未 pin 容量（MAX_ENTRIES）且全部被活 program pin：
    //      pin 走额外槽位、不淘汰被引用者；总槽位也满后 keep 准确失败。 ----
    {
        s2a_source_clear();
        enum { TOTAL = S2A_SOURCE_MAX_ENTRIES + S2A_SOURCE_MAX_PINNED };
        static uint8_t tiny_ctl[TOTAL][S2A_SOURCE_CONTROL_MIN];
        static uint8_t tiny_key[TOTAL][8];
        static struct s2a_source_pin_ref tiny_ref[TOTAL];
        uint8_t tiny_code = 0x5a;
        int stored = 0;
        for (; stored < TOTAL; stored++) {
            memset(tiny_ctl[stored], 0x33, sizeof tiny_ctl[stored]);
            uint32_t unique = (uint32_t)stored;
            memcpy(tiny_ctl[stored] + 0x10, &unique, 4);   // 每条内容不同，避免同一短 key 重复
            uint32_t ncode = 1;
            memcpy(tiny_ctl[stored] + 0x704, &ncode, 4);   // code 长度字段（c1 范围保持 0 → 无 c1）
            make_key(&tiny_code, 1, tiny_ctl[stored], sizeof tiny_ctl[stored], tiny_key[stored]);
            if (s2a_source_keep(tiny_key[stored], (uint32_t)(stored % 6), &tiny_code, 1,
                                tiny_ctl[stored], sizeof tiny_ctl[stored]) != 0) break;
            if (s2a_source_pin_key(tiny_key[stored], &tiny_ref[stored]) != 0) break;
        }
        CHECK(stored == TOTAL, "fill the unpinned cap and the pinned extra slots, pinning each");
        struct s2a_source_pin_stats ps;
        uint8_t overflow_key[8], overflow_ctl[S2A_SOURCE_CONTROL_MIN], overflow_code = 0x7e;
        memset(overflow_ctl, 0xd1, sizeof overflow_ctl);
        uint32_t ncode = 1;
        memcpy(overflow_ctl + 0x704, &ncode, 4);
        make_key(&overflow_code, 1, overflow_ctl, sizeof overflow_ctl, overflow_key);
        CHECK(s2a_source_keep(overflow_key, 1, &overflow_code, 1, overflow_ctl, sizeof overflow_ctl) != 0,
              "all slots pinned: keep fails instead of evicting a live program's source");
        CHECK(s2a_source_identity(tiny_key[0], (uint8_t[32]){0}, NULL, NULL) == 0,
              "the oldest pinned entry is still intact after the failed keep");
        s2a_source_pin_stats(&ps);
        CHECK(ps.pinned_entries == TOTAL && ps.pins == TOTAL,
              "all live-program pins are accounted beyond the unpinned cap");
        CHECK(ps.keep_fail_slots >= 1 && g_source_log_lines >= 1,
              "slot exhaustion is attributed and logs a failure reason");
        CHECK(ps.pin_misses == 0, "no pin failed while filling the store");
        // 模拟 program 销毁：只解最旧一条，下一次 keep 必须能淘汰它。
        s2a_source_unpin_ref(&tiny_ref[0]);
        CHECK(s2a_source_keep(overflow_key, 1, &overflow_code, 1, overflow_ctl, sizeof overflow_ctl) == 0,
              "after one program is destroyed its source becomes evictable");
        CHECK(s2a_source_identity(tiny_key[0], (uint8_t[32]){0}, NULL, NULL) != 0,
              "the destroyed program's source was the eviction victim");
        // 清理：clear 会 retire 仍被 pin 的条目，再逐条解 pin 回收。
        s2a_source_clear();
        for (int i = 1; i < stored; i++) s2a_source_unpin_ref(&tiny_ref[i]);
        s2a_source_pin_stats(&ps);
        CHECK(ps.pins == 0 && ps.pinned_entries == 0, "all program pins released");
    }

    // 短 control（+0x20 自描述）：0x850 合法，0x700 不完整。
    static uint8_t short_ctl[0x850];
    memset(short_ctl, 0x11, sizeof short_ctl);
    uint32_t own = 0x850;
    memcpy(short_ctl + 0x20, &own, 4);
    memcpy(short_ctl + 0x700, &c1_begin, 4);
    memcpy(short_ctl + 0x704, &c1_end, 4);
    uint8_t key_short[8];
    make_key(code_a, CODE_BYTES, short_ctl, 0x850, key_short);
    CHECK(s2a_source_keep(key_short, 0, code_a, CODE_BYTES, short_ctl, 0x850) == 0, "short control is accepted");
    memset(&v, 0, sizeof v);
    CHECK(s2a_source_get_key(key_short, &v) == 1 && v.control_bytes == 0x850, "short control keeps its own length");
    CHECK(v.c1 && v.c1_bytes == 0x80, "short control still yields the declared c1 range");
    uint8_t key_short_bad[8];
    make_key(code_a, CODE_BYTES, short_ctl, 0x700, key_short_bad);
    CHECK(s2a_source_keep(key_short_bad, 0, code_a, CODE_BYTES, short_ctl, 0x700) != 0,
          "too-short control is rejected");

    // pending control：SetShaders 自持，Bind 取回同一份；有界淘汰。
    const uint8_t *pc = NULL;
    uint32_t pn = 0;
    CHECK(s2a_source_hold_pending(4242, 1, ctl_a, S2A_SOURCE_CONTROL_BYTES) == 0, "hold pending control");
    CHECK(s2a_source_pending_control(4242, 1, &pc, &pn) == 1 && pn == S2A_SOURCE_CONTROL_BYTES &&
          !memcmp(pc, ctl_a, pn), "pending control returns the same bytes");
    CHECK(s2a_source_pending_control(4242, 0, &pc, &pn) == 0, "pending control is per stage");
    for (int i = 0; i < (int)S2A_SOURCE_PENDING + 4; i++)
        s2a_source_hold_pending((uint64_t)(1000 + i), 0, ctl_a, S2A_SOURCE_CONTROL_BYTES);
    CHECK(s2a_source_pending_control(4242, 1, &pc, &pn) == 0, "pending table is bounded (oldest dropped)");
    s2a_source_drop_pending(1000 + (uint64_t)S2A_SOURCE_PENDING + 3);
    CHECK(s2a_source_pending_control(1000 + (uint64_t)S2A_SOURCE_PENDING + 3, 0, &pc, &pn) == 0, "drop pending");

    if (fails) { printf("direct source store test: %d FAILED\n", fails); return 1; }
    printf("direct source store test: ok\n");
    return 0;
}
