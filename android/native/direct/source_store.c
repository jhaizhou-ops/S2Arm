#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "sha256.h"
#include "source_store.h"

struct entry {
    uint8_t key[8];
    uint8_t content_sha[32];  // 捕获时的完整 SHA-256(control‖code)，短 key 是它的前 8 字节
    uint32_t array_index;
    uint32_t code_bytes, control_bytes;
    uint8_t *code, *control;
    uint8_t *c1;             // 控制段 +0x700/+0x704 给出的真实范围（相对 code 起点）
    uint32_t c1_bytes;
    uint64_t seq;            // 条目代号（每次填槽新发）；acquire 返回它，release 只认它
    uint32_t pins;           // 跨步骤消费者持有的引用；>0 时不能淘汰/释放
    uint32_t prog_pins;      // 活 NVN program 的生命周期 pin；与编译期 pins 分开计数
    uint8_t retired;         // clear() 时被引用：不再可查，最后一个 release 后回收
    uint8_t ambiguous;       // 同一短 key 出现过不同内容：按该 key 的查找一律失败
};

static struct entry g_entries[S2A_SOURCE_SLOTS];
static uint32_t g_count, g_bytes, g_dropped;
static uint64_t g_seq;
static _Atomic uint64_t g_epoch;
static _Atomic uint64_t g_rejected;
static uint64_t g_pin_calls, g_pin_misses, g_unpins, g_evict_skipped, g_keep_fail_bytes, g_keep_fail_slots;
static unsigned g_keep_fail_logged;
// 失败原因出口（生产由 hle_nvn 接到 logcat；宿主测试不提供）
#ifdef __APPLE__   // macOS 宿主单测：ld64 不接受未定义的弱引用（GNU ld / Android 接受），给一个弱的空实现兜底；Android 构建不走这里
__attribute__((weak)) void s2a_source_log_line(const char *line) { (void)line; }
#else
// 弱链接[androiddraw]：s2a_source_log_line（前端提供；宿主单测不链 source_store.c 时为空）
extern void s2a_source_log_line(const char *line) __attribute__((weak));
#endif
static void keep_fail_log(const char *why) {
    if (!s2a_source_log_line || g_keep_fail_logged++ >= 8) return;
    char line[256];
    snprintf(line, sizeof line, "%s（entries=%u bytes=%u/%u slots=%u/%u）", why, g_count, g_bytes,
             (unsigned)S2A_SOURCE_MAX_BYTES, g_count, (unsigned)S2A_SOURCE_SLOTS);
    s2a_source_log_line(line);
}
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;

// 短 key → 条目下标 的哈希索引：查找从“扫全部条目”变成一次桶探测。键本身已经是摘要前缀，
// 直接取其低 16 位做桶；同一 key 的多个代际/多阶段条目挂在同一条链上。
#define S2A_SOURCE_BUCKETS 8192u
static int32_t g_bucket[S2A_SOURCE_BUCKETS];
static int32_t g_next[S2A_SOURCE_SLOTS];
static int g_index_ready;

// 被证明“同一短 key 指向不同内容”的键：条目即使后来被淘汰，也不允许再把该 key 当成唯一内容。
#define S2A_SOURCE_POISON 1024u
static uint8_t g_poison_key[S2A_SOURCE_POISON][8];
static uint32_t g_poison_n, g_poison_next;
static _Atomic uint64_t g_poison_overflow;

struct pending_entry {
    uint64_t serial;
    uint32_t stage;
    uint8_t *control;
    uint32_t control_bytes;
    uint64_t seq;
};
static struct pending_entry g_pending[S2A_SOURCE_PENDING];
static uint64_t g_pending_seq;

static void index_init_locked(void) {
    if (g_index_ready) return;
    for (uint32_t i = 0; i < S2A_SOURCE_BUCKETS; i++) g_bucket[i] = -1;
    for (uint32_t i = 0; i < S2A_SOURCE_MAX_ENTRIES; i++) g_next[i] = -1;
    g_index_ready = 1;
}

static uint32_t bucket_of(const uint8_t key[8]) {
    uint32_t h = (uint32_t)key[0] | ((uint32_t)key[1] << 8) | ((uint32_t)key[2] << 16) | ((uint32_t)key[3] << 24);
    return (h ^ (h >> 13)) & (S2A_SOURCE_BUCKETS - 1u);
}

static void index_insert_locked(int32_t idx) {
    uint32_t b = bucket_of(g_entries[idx].key);
    g_next[idx] = g_bucket[b];
    g_bucket[b] = idx;
}

static void index_remove_locked(int32_t idx) {
    uint32_t b = bucket_of(g_entries[idx].key);
    int32_t *pp = &g_bucket[b];
    while (*pp >= 0) {
        if (*pp == idx) { *pp = g_next[idx]; g_next[idx] = -1; return; }
        pp = &g_next[*pp];
    }
}

static int poisoned_locked(const uint8_t key[8]) {
    for (uint32_t i = 0; i < g_poison_n; i++)
        if (!memcmp(g_poison_key[i], key, 8)) return 1;
    return 0;
}

static void poison_locked(const uint8_t key[8]) {
    if (poisoned_locked(key)) return;
    if (g_poison_n < S2A_SOURCE_POISON) {
        memcpy(g_poison_key[g_poison_n++], key, 8);
        return;
    }
    // 有界：覆盖最旧的一条并计数。溢出只影响“更早的冲突键不再被单独记住”，
    // 现有条目上的 ambiguous 标记仍然生效。
    memcpy(g_poison_key[g_poison_next], key, 8);
    g_poison_next = (g_poison_next + 1u) % S2A_SOURCE_POISON;
    atomic_fetch_add(&g_poison_overflow, 1);
}

static uint32_t entry_bytes(const struct entry *e) {
    return e->code_bytes + e->control_bytes + e->c1_bytes;
}

static void drop(struct entry *e) {
    uint32_t held = entry_bytes(e);
    if (held <= g_bytes) g_bytes -= held; else g_bytes = 0;
    index_remove_locked((int32_t)(e - g_entries));
    free(e->code);
    free(e->control);
    free(e->c1);
    memset(e, 0, sizeof *e);
}

static int live(const struct entry *e) { return (e->code || e->control) && !e->retired; }

// 超出字节上限时淘汰最旧的一条（有界，不无限增长）；被引用的条目不淘汰。
static int evict_oldest_locked(void) {
    int oldest = -1;
    for (uint32_t i = 0; i < g_count; i++) {
        if (!live(&g_entries[i])) continue;
        if (g_entries[i].pins || g_entries[i].prog_pins) {
            if (g_entries[i].prog_pins) g_evict_skipped++;
            continue;
        }
        if (oldest < 0 || g_entries[i].seq < g_entries[oldest].seq) oldest = (int)i;
    }
    if (oldest < 0) return 0;
    drop(&g_entries[oldest]);
    // 淘汰改变了 key→内容的可证明性：旧备忘继续命中就会绕过“完整路径应报缺源”。
    atomic_fetch_add(&g_epoch, 1);
    g_dropped++;
    return 1;
}

// 未 pin 的活条目数：淘汰只允许在这部分里选最旧；上限 S2A_SOURCE_MAX_ENTRIES 是它的容量。
static uint32_t unpinned_live_locked(void) {
    uint32_t n = 0;
    for (uint32_t i = 0; i < g_count; i++)
        if (live(&g_entries[i]) && !g_entries[i].pins && !g_entries[i].prog_pins) n++;
    return n;
}

static int find_slot_locked(void) {
    for (uint32_t i = 0; i < g_count; i++)
        if (!g_entries[i].code && !g_entries[i].control && !g_entries[i].retired) return (int)i;
    if (g_count < S2A_SOURCE_SLOTS) return (int)g_count++;
    return -1;
}

// 唯一命中才返回条目：同一 key 上出现不同内容时，该 key 无法定位到唯一快照，
// 按 key 的任何查找都必须失败（不能“取最新”）。
static struct entry *find_key_locked(const uint8_t key[8]) {
    if (!g_index_ready || poisoned_locked(key)) return NULL;
    struct entry *best = NULL;
    for (int32_t i = g_bucket[bucket_of(key)]; i >= 0; i = g_next[i]) {
        struct entry *e = &g_entries[i];
        if (!live(e) || memcmp(e->key, key, 8)) continue;
        if (e->ambiguous) return NULL;
        if (best && memcmp(best->content_sha, e->content_sha, 32)) return NULL;
        if (!best || e->seq > best->seq) best = e;
    }
    return best;
}

// c1 的真实范围由控制段 +0x700（起点）/ +0x704（终点）给出，偏移相对 code 起点
// （对齐 graphics/tools/direct/dsh/Dsh.cs 的 JobFor）。不按“控制段前 0x100 字节”猜。
// 返回 -1 表示“控制段声明了合法范围但分配失败”：调用方必须拒绝这次登记，不能把缺 c1
// 当成同一份内容（c1 是真实请求字段，c1 有无/内容不同 = 编译输入不同）。
// 返回 0 时 *out 可为 NULL（该控制段没有合法 c1 范围，这是由控制段字节唯一决定的事实）。
static int build_c1(const uint8_t *code, uint32_t code_bytes, const uint8_t *control,
                    uint32_t control_bytes, uint8_t **out, uint32_t *out_bytes) {
    *out = NULL;
    *out_bytes = 0;
    if (control_bytes < 0x708) return 0;
    uint32_t c1o = 0, c1t = 0;
    memcpy(&c1o, control + 0x700, 4);
    memcpy(&c1t, control + 0x704, 4);
    uint64_t total = (uint64_t)code_bytes + control_bytes;
    if (!(c1o < c1t) || (uint64_t)c1t > total || (uint64_t)(c1t - c1o) > 0x10000u) return 0;
    uint32_t n = c1t - c1o;
    uint8_t *c1 = (uint8_t *)malloc(n);
    if (!c1) return -1;
    for (uint32_t i = 0; i < n; i++) {
        uint32_t src = c1o + i;
        c1[i] = src < code_bytes ? code[src] : control[src - code_bytes];
    }
    *out = c1;
    *out_bytes = n;
    return 0;
}

int s2a_source_keep(const uint8_t key[8], uint32_t array_index, const void *code, uint32_t code_bytes,
                    const void *control, uint32_t control_bytes) {
    if (!key || array_index >= 6) return -1;
    int complete = code && code_bytes && code_bytes <= S2A_SOURCE_MAX_CODE &&
                   control && control_bytes >= S2A_SOURCE_CONTROL_MIN && control_bytes <= S2A_SOURCE_CONTROL_BYTES;
    if (!complete) return -1;   // code/control 任一缺失或长度不合法：不存半成品，调用方按缺源处理

    uint32_t c1_bytes = 0;
    uint8_t *c1 = NULL;
    if (build_c1((const uint8_t *)code, code_bytes, (const uint8_t *)control, control_bytes,
                 &c1, &c1_bytes)) {
        // 合法 c1 范围但分配失败：这次登记会改变编译输入，必须拒绝，不能存“缺 c1”的同 key 内容。
        atomic_fetch_add(&g_rejected, 1);
        return -1;
    }
    uint32_t need = code_bytes + control_bytes + c1_bytes;

    // 完整内容摘要只在捕获时算一次（与前端 keys_hash 同一字节顺序：control‖code，同一 SHA-256）。
    uint8_t sha[32];
    {
        s2a_sha256 c;
        s2a_sha256_init(&c);
        s2a_sha256_update(&c, control, control_bytes);
        s2a_sha256_update(&c, code, code_bytes);
        s2a_sha256_final(&c, sha);
    }
    if (memcmp(sha, key, 8)) {
        // 调用方给的短 key 不是这份内容的摘要前缀：存下来就是“不同内容、同一身份”的入口。
        // 如果该 key 已经指向另一份内容（真实的 8 字节碰撞），把 key 标成歧义：之后按它的
        // 查找一律失败，不能让别的 draw 静默拿到先前那份内容。
        pthread_mutex_lock(&g_mu);
        index_init_locked();
        int conflict = 0;
        for (int32_t i = g_bucket[bucket_of(key)]; i >= 0; i = g_next[i]) {
            struct entry *e = &g_entries[i];
            if (!live(e) || memcmp(e->key, key, 8)) continue;
            if (memcmp(e->content_sha, sha, 32)) { e->ambiguous = 1; conflict = 1; }
        }
        // 无论该 key 当前是否还有活条目，都推进代际：调用方声称“这个短 key 对应这份内容”，
        // 而存储里这个 key 的映射无法再被证明唯一（可能曾经指向别的内容、现在已被淘汰）。
        // 内容备忘因此不能沿用冲突前的条目；这是拒绝路径上唯一安全的处理。
        if (conflict) poison_locked(key);
        atomic_fetch_add(&g_epoch, 1);
        atomic_fetch_add(&g_rejected, 1);
        pthread_mutex_unlock(&g_mu);
        free(c1);
        return -1;
    }

    pthread_mutex_lock(&g_mu);
    index_init_locked();
    struct entry *conflict = NULL, *same = NULL;
    for (int32_t i = g_bucket[bucket_of(key)]; i >= 0; i = g_next[i]) {
        struct entry *e = &g_entries[i];
        if (!live(e) || memcmp(e->key, key, 8)) continue;
        // 只有“摘要相同且真实长度也相同”才是同一份内容。同一拼接字节按不同 control/code
        // 切分时摘要相同、长度不同：请求体（两个 base64 字段）会不同，必须按不同内容处理。
        if (e->ambiguous || memcmp(e->content_sha, sha, 32) || e->code_bytes != code_bytes ||
            e->control_bytes != control_bytes) { conflict = e; break; }
        same = e;
    }
    if (conflict || poisoned_locked(key)) {
        // 同一短 key 已经指向别的字节：不覆盖、不淘汰、不取最新。把该 key 标成歧义，
        // 之后按它的查找一律失败（调用方准确报缺源），并推进代际让内容备忘失效。
        if (conflict) conflict->ambiguous = 1;
        poison_locked(key);
        atomic_fetch_add(&g_rejected, 1);
        atomic_fetch_add(&g_epoch, 1);
        pthread_mutex_unlock(&g_mu);
        free(c1);
        return -1;
    }

    // 同一内容已被活 program pin：直接复用，不进入字节淘汰循环（重复 SetShaders 不占新字节）。
    for (int32_t i = g_bucket[bucket_of(key)]; i >= 0; i = g_next[i]) {
        struct entry *cand = &g_entries[i];
        if (!live(cand) || memcmp(cand->key, key, 8) || cand->array_index != array_index) continue;
        if (cand->prog_pins) {
            pthread_mutex_unlock(&g_mu);
            free(c1);
            return 0;
        }
    }
    while (g_bytes + need > S2A_SOURCE_MAX_BYTES) {
        if (!evict_oldest_locked()) {
            // 所有可淘汰条目都在被引用：不能为了新条目丢掉在用的源，准确失败并点名原因。
            g_keep_fail_bytes++;
            keep_fail_log("源快照 keep 失败：字节预算被 pin 条目占满");
            pthread_mutex_unlock(&g_mu);
            free(c1);
            return -1;
        }
    }
    struct entry *e = NULL;
    for (int32_t i = g_bucket[bucket_of(key)]; i >= 0 && !e; i = g_next[i]) {
        struct entry *cand = &g_entries[i];
        if (!live(cand) || memcmp(cand->key, key, 8) || cand->array_index != array_index) continue;
        // 编译期 acquire 的 pin 保持原语义：不顶掉旧代，另开新代（旧令牌仍有效）。
        if (!cand->pins) { drop(cand); e = cand; }
    }
    // 未 pin 部分保持 S2A_SOURCE_MAX_ENTRIES 的容量：超了先淘汰最旧未 pin 条目；
    // 被活 program pin 的条目走额外的 S2A_SOURCE_SLOTS 槽位，不会被这里淘汰。
    while (unpinned_live_locked() >= S2A_SOURCE_MAX_ENTRIES) {
        if (!evict_oldest_locked()) break;
    }
    if (!e) {
        int slot = find_slot_locked();
        if (slot < 0) {
            if (!evict_oldest_locked() || (slot = find_slot_locked()) < 0) {
                g_keep_fail_slots++;
                keep_fail_log("源快照 keep 失败：槽位被 pin 条目占满");
                pthread_mutex_unlock(&g_mu);
                free(c1);
                g_dropped++;
                return -1;
            }
        }
        e = &g_entries[slot];
        memset(e, 0, sizeof *e);
    }
    e->code = (uint8_t *)malloc(code_bytes);
    e->control = (uint8_t *)malloc(control_bytes);
    if (!e->code || !e->control) {
        free(e->code); free(e->control); free(c1);
        memset(e, 0, sizeof *e);
        g_dropped++;
        atomic_fetch_add(&g_epoch, 1);
        pthread_mutex_unlock(&g_mu);
        return -1;
    }
    memcpy(e->code, code, code_bytes);
    memcpy(e->control, control, control_bytes);
    memcpy(e->key, key, 8);
    memcpy(e->content_sha, sha, 32);
    e->array_index = array_index;
    e->code_bytes = code_bytes;
    e->control_bytes = control_bytes;
    e->c1 = c1;
    e->c1_bytes = c1_bytes;
    e->seq = ++g_seq;
    e->pins = 0;
    e->retired = 0;
    e->ambiguous = 0;
    index_insert_locked((int32_t)(e - g_entries));
    g_bytes += need;
    // 代际只表示“key→内容”的映射发生了变化：同 key 同内容的重登记（游戏每帧重复 SetShaders
    // 的常见形态）不推进，否则 P1 备忘会被无意义地作废；新 key、淘汰后重登记、冲突都推进。
    if (!same) atomic_fetch_add(&g_epoch, 1);
    pthread_mutex_unlock(&g_mu);
    return 0;
}

static void fill_view(const struct entry *e, struct s2a_source_entry_view *out) {
    out->key = e->key;
    out->array_index = e->array_index;
    out->code = e->code;
    out->code_bytes = e->code_bytes;
    out->control = e->control;
    out->control_bytes = e->control_bytes;
    out->complete = e->code && e->control;
    out->c1 = e->c1;
    out->c1_bytes = e->c1_bytes;
    memcpy(out->content_sha, e->content_sha, 32);
    out->ref = 0;
}

int s2a_source_get_key(const uint8_t key[8], struct s2a_source_entry_view *out) {
    if (!key || !out) return 0;
    int hit = 0;
    pthread_mutex_lock(&g_mu);
    struct entry *e = find_key_locked(key);
    if (e) { fill_view(e, out); hit = 1; }
    pthread_mutex_unlock(&g_mu);
    return hit;
}

int s2a_source_has(const uint8_t key[8]) {
    if (!key) return 0;
    int hit = 0;
    pthread_mutex_lock(&g_mu);
    hit = find_key_locked(key) != NULL;
    pthread_mutex_unlock(&g_mu);
    return hit;
}

int s2a_source_get(const uint8_t key[8], uint32_t array_index, struct s2a_source_entry_view *out) {
    if (!key || !out) return 0;
    int found = 0;
    pthread_mutex_lock(&g_mu);
    if (g_index_ready && !poisoned_locked(key)) {
        for (int32_t i = g_bucket[bucket_of(key)]; i >= 0; i = g_next[i]) {
            struct entry *e = &g_entries[i];
            if (!live(e) || e->ambiguous || memcmp(e->key, key, 8) || e->array_index != array_index) continue;
            fill_view(e, out);
            found = 1;
            break;
        }
    }
    pthread_mutex_unlock(&g_mu);
    return found;
}

int s2a_source_acquire(const uint8_t key[8], struct s2a_source_entry_view *out) {
    if (!key || !out) return 0;
    int hit = 0;
    pthread_mutex_lock(&g_mu);
    struct entry *e = find_key_locked(key);
    if (e) {
        e->pins++;
        fill_view(e, out);
        out->ref = e->seq;
        hit = 1;
    }
    pthread_mutex_unlock(&g_mu);
    return hit;
}

void s2a_source_release(uint64_t ref) {
    if (!ref) return;
    pthread_mutex_lock(&g_mu);
    struct entry *e = NULL;
    for (uint32_t i = 0; i < g_count; i++) {
        if (g_entries[i].seq == ref) { e = &g_entries[i]; break; }
    }
    if (e && e->pins) {
        e->pins--;
        if (!e->pins && !e->prog_pins && e->retired) drop(e);
    }
    pthread_mutex_unlock(&g_mu);
}

int s2a_source_identity(const uint8_t key[8], uint8_t sha[32], uint32_t *code_bytes, uint32_t *control_bytes) {
    if (!key || !sha) return -1;
    int rc = -1;
    pthread_mutex_lock(&g_mu);
    struct entry *e = find_key_locked(key);
    if (e && e->code && e->control) {
        memcpy(sha, e->content_sha, 32);
        if (code_bytes) *code_bytes = e->code_bytes;
        if (control_bytes) *control_bytes = e->control_bytes;
        rc = 0;
    }
    pthread_mutex_unlock(&g_mu);
    return rc;
}

uint64_t s2a_source_epoch(void) { return atomic_load(&g_epoch); }
uint64_t s2a_source_rejected(void) { return atomic_load(&g_rejected); }

int s2a_source_hold_pending(uint64_t prog_serial, uint32_t stage, const void *control, uint32_t control_bytes) {
    if (!control || control_bytes < S2A_SOURCE_CONTROL_MIN || control_bytes > S2A_SOURCE_CONTROL_BYTES || stage >= 6)
        return -1;
    uint8_t *copy = (uint8_t *)malloc(control_bytes);
    if (!copy) return -1;
    memcpy(copy, control, control_bytes);
    pthread_mutex_lock(&g_mu);
    struct pending_entry *slot = NULL;
    int oldest = -1;
    for (uint32_t i = 0; i < S2A_SOURCE_PENDING; i++) {
        struct pending_entry *e = &g_pending[i];
        if (e->control && e->serial == prog_serial && e->stage == stage) { slot = e; break; }
        if (!e->control && !slot) slot = e;
        if (e->control && (oldest < 0 || e->seq < g_pending[oldest].seq)) oldest = (int)i;
    }
    if (!slot) {
        if (oldest < 0) { pthread_mutex_unlock(&g_mu); free(copy); return -1; }
        slot = &g_pending[oldest];
        free(slot->control);
    }
    slot->serial = prog_serial;
    slot->stage = stage;
    slot->control = copy;
    slot->control_bytes = control_bytes;
    slot->seq = ++g_pending_seq;
    pthread_mutex_unlock(&g_mu);
    return 0;
}

int s2a_source_pending_control(uint64_t prog_serial, uint32_t stage, const uint8_t **control, uint32_t *control_bytes) {
    if (!control || !control_bytes) return 0;
    int hit = 0;
    pthread_mutex_lock(&g_mu);
    for (uint32_t i = 0; i < S2A_SOURCE_PENDING; i++) {
        struct pending_entry *e = &g_pending[i];
        if (!e->control || e->serial != prog_serial || e->stage != stage) continue;
        *control = e->control;
        *control_bytes = e->control_bytes;
        hit = 1;
        break;
    }
    pthread_mutex_unlock(&g_mu);
    return hit;
}

void s2a_source_drop_pending(uint64_t prog_serial) {
    pthread_mutex_lock(&g_mu);
    for (uint32_t i = 0; i < S2A_SOURCE_PENDING; i++) {
        struct pending_entry *e = &g_pending[i];
        if (!e->control || e->serial != prog_serial) continue;
        free(e->control);
        memset(e, 0, sizeof *e);
    }
    pthread_mutex_unlock(&g_mu);
}

int s2a_source_pin_key(const uint8_t key[8], struct s2a_source_pin_ref *out) {
    if (!key || !out) return -1;
    int rc = -1;
    pthread_mutex_lock(&g_mu);
    g_pin_calls++;
    struct entry *e = find_key_locked(key);
    if (e && e->code && e->control) {
        e->prog_pins++;
        memset(out, 0, sizeof *out);
        out->slot = (uint32_t)(e - g_entries);
        out->seq = e->seq;
        memcpy(out->key, key, 8);
        memcpy(out->sha, e->content_sha, 32);
        rc = 0;
    } else {
        g_pin_misses++;
    }
    pthread_mutex_unlock(&g_mu);
    return rc;
}

int s2a_source_unpin_ref(const struct s2a_source_pin_ref *ref) {
    if (!ref) return -1;
    int rc = -1;
    pthread_mutex_lock(&g_mu);
    if (ref->slot < g_count) {
        struct entry *e = &g_entries[ref->slot];
        if (e->seq == ref->seq && e->prog_pins) {
            e->prog_pins--;
            g_unpins++;
            if (!e->pins && !e->prog_pins && e->retired) drop(e);
            rc = 0;
        }
    }
    pthread_mutex_unlock(&g_mu);
    return rc;
}

void s2a_source_pin_stats(struct s2a_source_pin_stats *out) {
    if (!out) return;
    memset(out, 0, sizeof *out);
    pthread_mutex_lock(&g_mu);
    for (uint32_t i = 0; i < g_count; i++) {
        struct entry *e = &g_entries[i];
        if (!e->prog_pins) continue;
        out->pinned_entries++;
        out->pins += e->prog_pins;
    }
    out->pin_calls = g_pin_calls;
    out->pin_misses = g_pin_misses;
    out->unpins = g_unpins;
    out->evict_skipped = g_evict_skipped;
    out->keep_fail_bytes = g_keep_fail_bytes;
    out->keep_fail_slots = g_keep_fail_slots;
    pthread_mutex_unlock(&g_mu);
}

void s2a_source_stats(uint32_t *entries, uint32_t *bytes, uint32_t *dropped) {
    pthread_mutex_lock(&g_mu);
    uint32_t n = 0;
    for (uint32_t i = 0; i < g_count; i++) if (live(&g_entries[i])) n++;
    if (entries) *entries = n;
    if (bytes) *bytes = g_bytes;   // 含被引用/已 retired 但尚未回收的字节
    if (dropped) *dropped = g_dropped;
    pthread_mutex_unlock(&g_mu);
}

void s2a_source_clear(void) {
    pthread_mutex_lock(&g_mu);
    for (uint32_t i = 0; i < g_count; i++) {
        struct entry *e = &g_entries[i];
        if (!e->code && !e->control && !e->retired) continue;
        if (e->pins || e->prog_pins) {
            index_remove_locked((int32_t)i);
            e->retired = 1;
            continue;
        }
        drop(e);
    }
    for (uint32_t i = 0; i < S2A_SOURCE_PENDING; i++) {
        free(g_pending[i].control);
        memset(&g_pending[i], 0, sizeof g_pending[i]);
    }
    g_poison_n = 0;
    g_poison_next = 0;
    atomic_fetch_add(&g_epoch, 1);
    // 已 retired 的条目仍占内存（被引用），g_bytes 保持真实；未被引用的都已回收。
    g_dropped = 0;
    pthread_mutex_unlock(&g_mu);
}
