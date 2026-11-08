// P0-4 反例（宿主回归）：GPU 还有未完成工作时，事件值不得提前可见。
//
// 生产语义：nvnCommandBufferSignalEvent / nvnCommandBufferReportValue 录成 OP_SIGNAL_EVENT，
// GPU 执行到这条才写事件值；客户读到新值 = 它之前的命令已完成（Metal 侧由提交完成回调落地，
// 见 graphics/nvn/gfx/nvn/nvn_mtl.m 的 mtl_sub_event / post 列表）。本后端回放时若用 CPU 直接写 guest 值，
// 那一刻之前录制的 draw 还只在帧队列里没提交，值会提前可见（读回纹理/缓冲会读到旧内容）。
//
// 这个用例把问题钉在适配层：直接编译生产 mtl_vk_adapter.c，用 nvn_vk_first_draw_pass_break 替身
// 控制“帧队列有没有完成证明”，用 s2a_record_exec_one 替身按 vk_record.c 的信号写值语义落 guest 值
// （该语义本身另由 vk_record_test 的正控/负控钉住，5d9e778bc）。要求：
//   1) 没有完成证明 → 信号一个字节都不写，回放报 GPU 错误（fail-closed）；
//   2) 有完成证明（关 pass + 提交 + 等 fence 成功）→ 照常写 replace / accumulate；
//   3) 带 NVN_EV_WAIT 位的记录（nvnCommandBufferWaitEvent）不是信号，不写值也不要完成证明；
//   4) 非事件 opcode 不受影响。
// 修前（适配层没有闸门）：1) 值提前可见；2) 没有向帧队列要过完成证明 → 红。
// 修后：全绿。变异控制（把闸门调用去掉）复查 1)/2) 重新变红。
#include <assert.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "../native/nvn/mtl_vk_adapter.c"

// 不得与生产实现重名冲突；测试里用强符号替身顶掉真实实现。
int __system_property_get(const char *name, char *value) {
    (void)name;
    if (value) value[0] = 0;
    return 0;
}
int __android_log_print(int prio, const char *tag, const char *fmt, ...) {
    (void)prio; (void)tag; (void)fmt;
    return 0;
}
void s2a_record_set_tex_resolver(s2a_record_tex_resolve resolve, void *opaque) {
    (void)resolve; (void)opaque;
}
void s2a_record_set_draw_builder(s2a_record_draw_fn draw, void *opaque) {
    (void)draw; (void)opaque;
}
int nvk_draw_builder(struct s2a_vk_device *device, const struct s2a_record_draw_state *state,
                     struct s2a_record_result *result, void *opaque) {
    (void)device; (void)state; (void)result; (void)opaque;
    return 0;
}
// 纹理解析与格式映射只被 record_resolve_tex 引用；本用例的流里没有纹理，替身不会被调用。
struct nvn_vk_tex *nvn_vk_session_tex(struct nvn_vk_session *s, const tex_t *t, char *why, size_t why_size) {
    (void)s; (void)t;
    if (why && why_size) why[0] = 0;
    return NULL;
}
VkFormat nvn_vk_format(uint32_t nvn_format) {
    (void)nvn_format;
    return VK_FORMAT_UNDEFINED;
}

// ---- 完成证明替身：生产里是 nvn_vk_first_draw_pass_break（关 open pass + 提交 + 等 fence）----
// sync=1 会真的等待；sync=0 只保证队列顺序。g_proof_fail=1 模拟帧队列拿不到完成证明（提交失败/超时）。
static int g_proof_fail;
static int g_proof_calls;       // 所有 pass_break 调用
static int g_proof_sync_calls;  // 其中真正要求“完成证明”的（sync=1）
static const char g_proof_error[] = "frame queue: injected no-completion-proof (test)";

int nvn_vk_first_draw_pass_break(int sync);
int nvn_vk_first_draw_pass_break(int sync) {
    g_proof_calls++;
    if (sync) {
        g_proof_sync_calls++;
        return g_proof_fail ? -1 : 0;
    }
    return 0;
}
const char *nvn_vk_first_draw_first_error(void);
const char *nvn_vk_first_draw_first_error(void) { return g_proof_fail ? g_proof_error : ""; }

// ---- 回放层替身：按 vk_record.c 的 OP_SIGNAL_EVENT 分支写 guest 值（mode 0 = replace，其余 = add；
//      带 NVN_EV_WAIT 位的不当信号写值，见 vk_record.c:2424 的保护）。----
static int g_replay_calls;
static uint32_t g_replay_last_op;

int s2a_record_exec_one(struct s2a_vk_device *device, const uint8_t *packet, size_t len,
                        const struct s2a_record_memory *memory, struct s2a_record_result *result);
int s2a_record_exec_one(struct s2a_vk_device *device, const uint8_t *packet, size_t len,
                        const struct s2a_record_memory *memory, struct s2a_record_result *result) {
    (void)device;
    g_replay_calls++;
    if (result) memset(result, 0, sizeof *result);
    if (!packet || len < sizeof(op_hdr)) return S2A_RECORD_ARGUMENT;
    op_hdr h;
    memcpy(&h, packet, sizeof h);
    g_replay_last_op = h.op;
    if (h.op == OP_SIGNAL_EVENT && len >= 24) {
        uint64_t addr = 0;
        uint32_t mode = 0, value = 0, cur = 0;
        memcpy(&addr, packet + 8, 8);
        memcpy(&mode, packet + 16, 4);
        memcpy(&value, packet + 20, 4);
        if (mode & 0x80000000u) return S2A_RECORD_OK;   // nvnCommandBufferWaitEvent：不是信号
        if (addr && memory && memory->read && memory->write &&
            memory->read(memory->opaque, addr, &cur, 4) == 0) {
            cur = mode ? cur + value : value;
            (void)memory->write(memory->opaque, addr, &cur, 4);
        }
    }
    return S2A_RECORD_OK;
}

static size_t put_record(uint8_t *stream, uint32_t op, uint32_t size) {
    op_hdr h = { op, size };
    memcpy(stream, &h, sizeof h);
    return size;
}

static void put_signal(uint8_t *stream, uint64_t addr, uint32_t mode, uint32_t value) {
    memset(stream, 0, 24);
    put_record(stream, OP_SIGNAL_EVENT, 24);
    memcpy(stream + 8, &addr, 8);
    memcpy(stream + 16, &mode, 4);
    memcpy(stream + 20, &value, 4);
}

static void put_barrier(uint8_t *stream) {
    memset(stream, 0, 8);
    put_record(stream, OP_BARRIER, 8);
}

static int g_failures;
static int g_cases;

static void expect(const char *name, const uint8_t *packet, size_t len, uint32_t seed,
                   int proof_fail, int want_rc, uint32_t want_value,
                   int want_proof_sync, int want_replay) {
    uint32_t ev = seed;
    uint64_t addr = (uint64_t)(uintptr_t)&ev;
    uint8_t stream[32];
    memcpy(stream, packet, len);
    // 把信号目标地址换成测试变量（生产记录里是 guest 内存池地址；本适配层的内存接口就是进程内地址）。
    if (len >= 24 && stream[0] == (uint8_t)OP_SIGNAL_EVENT) memcpy(stream + 8, &addr, 8);
    struct s2a_record_result result;
    memset(&result, 0, sizeof result);
    g_proof_fail = proof_fail;
    g_proof_calls = g_proof_sync_calls = g_replay_calls = 0;
    g_replay_last_op = 0xFFFFFFFFu;
    g_ready = 1;
    g_cancel = 0;
    if (g_session.device.device == VK_NULL_HANDLE) g_session.device.device = (VkDevice)(uintptr_t)0x1;
    nvk_exec_owner_init(&g_exec, 7);
    int rc = s2a_vk_adapter_exec_guest(stream, len, &result);
    g_cases++;
    int ok = 1;
    if ((rc == S2A_RECORD_OK) != (want_rc == S2A_RECORD_OK)) ok = 0;
    if (want_rc != S2A_RECORD_OK && rc != want_rc) ok = 0;
    if (ev != want_value) ok = 0;
    if (g_proof_sync_calls != want_proof_sync) ok = 0;
    if (g_replay_calls != want_replay) ok = 0;
    if (!ok) {
        g_failures++;
        printf("FAIL %s: rc=%d value=%u(want %u) proof(sync)=%d(want %d) replay=%d(want %d) op=%u why=%s\n",
               name, rc, ev, want_value, g_proof_sync_calls, want_proof_sync, g_replay_calls, want_replay,
               g_replay_last_op, result.why);
    } else {
        printf("INFO %s: rc=%d value %u -> %u, proof(sync)=%d, replay=%d\n",
               name, rc, seed, ev, g_proof_sync_calls, g_replay_calls);
    }
}

int main(void) {
    g_ready = 1;
    g_session.ready = 1;
    g_session.device.device = (VkDevice)(uintptr_t)0x1;
    nvk_exec_owner_init(&g_exec, 7);

    uint8_t pkt[32];

    // 1) 没有完成证明：值必须一个字节都不写，回放准确报 GPU 失败（fail-closed）。
    //    修前：信号照写、回放成功 → 红。
    put_signal(pkt, 0, 0, 7);
    expect("signal without completion proof (fail-closed)", pkt, 24, 42, 1,
           S2A_RECORD_GPU, 42, 1, 0);

    // 2) 有完成证明：照写 replace，并且确实向帧队列要过完成证明（sync pass break）。
    //    修前：值对，但从没要过证明 → 红。
    put_signal(pkt, 0, 0, 7);
    expect("signal with completion proof", pkt, 24, 42, 0, S2A_RECORD_OK, 7, 1, 1);

    // 3) accumulate 同理。
    put_signal(pkt, 0, 1, 5);
    expect("accumulate with completion proof", pkt, 24, 42, 0, S2A_RECORD_OK, 47, 1, 1);

    // 4) 带 NVN_EV_WAIT 位的是 GPU 等事件，不是信号：不写值、不要完成证明。
    put_signal(pkt, 0, 0x80000000u, 99);
    expect("wait event is not a signal write", pkt, 24, 42, 0, S2A_RECORD_OK, 42, 0, 1);

    // 5) 非事件 opcode 不受影响：不要证明、照常回放。
    put_barrier(pkt);
    expect("non-event opcode ungated", pkt, 8, 42, 0, S2A_RECORD_OK, 42, 0, 1);

    if (g_failures) {
        printf("FAIL event completion: %d/%d cases failed\n", g_failures, g_cases);
        return 1;
    }
    printf("event completion: ok (%d cases)\n", g_cases);
    return 0;
}
