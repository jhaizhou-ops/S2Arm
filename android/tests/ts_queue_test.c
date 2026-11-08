// 时间戳待写队列 / validBits 回绕的宿主单测（不依赖 Vulkan，不链 libvulkan）。
// 门禁接线：android/test.sh 编译并运行本文件。
#include <stdint.h>
#include <stdio.h>

#include "../native/nvn/nvn_vk_ts_math.h"
#include "../native/nvn/nvn_vk_ts_queue.h"

static int failures;

#define CHECK(cond, ...) do { \
    if (!(cond)) { failures++; printf("FAIL "); printf(__VA_ARGS__); putchar('\n'); } \
} while (0)

static void test_queue_fifo(void) {
    enum { CAP = 4 };
    struct s2a_ts_slot_ref refs[CAP];
    struct s2a_ts_queue q;
    s2a_ts_queue_init(&q, refs, CAP);
    uint32_t slot = 0;

    // N-1 / N / N+1 三帧入队；N+1 已提交但还没执行。
    CHECK(s2a_ts_queue_append(&q, 10, &slot) == 0 && slot == 0, "append N-1 slot=%u", slot);
    CHECK(s2a_ts_queue_append(&q, 11, &slot) == 0 && slot == 1, "append N slot=%u", slot);
    CHECK(s2a_ts_queue_append(&q, 12, &slot) == 0 && slot == 2, "append N+1 slot=%u", slot);

    // 退休 N-1：只能结算 1 项；N+1 的项不能提前移出/写回。
    CHECK(s2a_ts_queue_ready(&q, 10) == 1, "ready(N-1)=%u want 1", s2a_ts_queue_ready(&q, 10));
    CHECK(s2a_ts_queue_slot(&q, 0) == 0 && s2a_ts_queue_frame(&q, 0) == 10, "queue head slot/frame");
    s2a_ts_queue_release(&q, 1);
    CHECK(s2a_ts_queue_count(&q) == 2, "count after retire N-1=%u want 2", s2a_ts_queue_count(&q));
    CHECK(s2a_ts_queue_slot(&q, 0) == 1 && s2a_ts_queue_frame(&q, 0) == 11, "queue head after retire N-1");

    // 跨帧 FIFO：13 用槽 3，14 复用头部刚释放的槽 0，15 必须因满准确失败。
    CHECK(s2a_ts_queue_append(&q, 13, &slot) == 0 && slot == 3, "append N+2 slot=%u", slot);
    CHECK(s2a_ts_queue_append(&q, 14, &slot) == 0 && slot == 0, "append N+3 reuses slot=%u", slot);
    CHECK(s2a_ts_queue_append(&q, 15, &slot) != 0, "append on full ring must fail");

    // 退休 N：仍只释放 1 项；N+1 还在队里。
    CHECK(s2a_ts_queue_ready(&q, 11) == 1, "ready(N)=%u want 1", s2a_ts_queue_ready(&q, 11));
    s2a_ts_queue_release(&q, 1);
    CHECK(s2a_ts_queue_count(&q) == 3, "count after retire N=%u want 3", s2a_ts_queue_count(&q));
    CHECK(s2a_ts_queue_slot(&q, 0) == 2 && s2a_ts_queue_frame(&q, 0) == 12, "queue head after retire N");
    CHECK(s2a_ts_queue_ready(&q, 12) == 1, "ready(N+1)=%u want 1", s2a_ts_queue_ready(&q, 12));
    s2a_ts_queue_release(&q, 1);
    CHECK(s2a_ts_queue_count(&q) == 2 && s2a_ts_queue_frame(&q, 0) == 13, "queue head after retire N+1");

    // 全部释放后归零，next_slot 回到 0。
    s2a_ts_queue_release(&q, s2a_ts_queue_count(&q));
    CHECK(s2a_ts_queue_count(&q) == 0 && q.head == 0 && q.tail == 0, "queue did not return to zero");
    CHECK(s2a_ts_queue_next_slot(&q) == 0, "next_slot after empty=%u want 0", s2a_ts_queue_next_slot(&q));
    CHECK(s2a_ts_queue_append(&q, 20, &slot) == 0 && slot == 0, "append after empty slot=%u want 0", slot);
}

static void test_queue_full_and_ready(void) {
    enum { CAP = 2 };
    struct s2a_ts_slot_ref refs[CAP];
    struct s2a_ts_queue q;
    s2a_ts_queue_init(&q, refs, CAP);
    uint32_t slot = 0;
    CHECK(s2a_ts_queue_append(&q, 1, &slot) == 0 && slot == 0, "cap2 append 1");
    CHECK(s2a_ts_queue_append(&q, 2, &slot) == 0 && slot == 1, "cap2 append 2");
    CHECK(s2a_ts_queue_append(&q, 3, &slot) != 0, "cap2 full append must fail");
    CHECK(s2a_ts_queue_ready(&q, 0) == 0, "ready below head=%u want 0", s2a_ts_queue_ready(&q, 0));
    s2a_ts_queue_release(&q, 1);
    CHECK(s2a_ts_queue_append(&q, 3, &slot) == 0 && slot == 0, "cap2 append reuses slot=%u want 0", slot);
}

static void test_wrap_diff(void) {
    const uint64_t mask48 = (1ull << 48) - 1;
    CHECK(s2a_ts_valid_mask(48) == mask48, "valid_mask(48)=%#llx", (unsigned long long)s2a_ts_valid_mask(48));
    CHECK(s2a_ts_valid_mask(64) == ~0ull, "valid_mask(64) must be all ones");
    CHECK(s2a_ts_wrap_diff(0x100, 0xf0, 48) == 16, "48-bit positive diff");
    CHECK(s2a_ts_wrap_diff(0xfffffffffff0ull, 0x10, 48) == -32,
          "48-bit wrap diff=%lld want -32", (long long)s2a_ts_wrap_diff(0xfffffffffff0ull, 0x10, 48));
    CHECK(s2a_ts_wrap_diff(0x10, 0xfffffffffff0ull, 48) == 32,
          "48-bit reverse wrap diff=%lld want 32", (long long)s2a_ts_wrap_diff(0x10, 0xfffffffffff0ull, 48));
    CHECK(s2a_ts_wrap_diff(0xfffffffffffffff1ull, 0xffffffffffffffffull, 64) == -14,
          "64-bit wrap diff=%lld want -14",
          (long long)s2a_ts_wrap_diff(0xfffffffffffffff1ull, 0xffffffffffffffffull, 64));
}

int main(void) {
    test_queue_fifo();
    test_queue_full_and_ready();
    test_wrap_diff();
    printf("ts-queue-test: %s (%d failures)\n", failures ? "FAIL" : "ok", failures);
    return failures ? 1 : 0;
}
