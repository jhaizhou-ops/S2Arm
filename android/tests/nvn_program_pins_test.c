// NVN program 生命周期 pin 记账的宿主夹具（与 hle_nvn.c 共用 nvn_program_pins.h）：
//   * 同 key 前缀重复 Bind 去重，不重复 pin；
//   * 换 SetShaders：按 owner 解旧 serial，只解一次；old_serial=0 不误伤；
//   * 拷贝对象 Finalize / Initialize 不改原件的 pin；
//   * SetShaders 后 owner 归原件：拷贝先 Bind 不抢 owner，原件 Finalize 能解；
//   * serial 已 released 后 Bind 拒绝，不产生永久泄漏。
#include <stdio.h>
#include <string.h>

#include "nvn_program_pins.h"

static int fails;
#define CHECK(c, what) do { if (!(c)) { printf("FAIL: %s (line %d)\n", what, __LINE__); fails++; } } while (0)

static struct s2a_source_pin_ref ref_for(uint32_t slot, uint64_t seq, uint8_t seed) {
    struct s2a_source_pin_ref r;
    memset(&r, 0, sizeof r);
    r.slot = slot;
    r.seq = seq;
    for (int i = 0; i < 8; i++) r.key[i] = (uint8_t)(seed + i);
    r.sha[0] = seed;
    return r;
}

int main(void) {
    struct nvn_program_pins p;
    memset(&p, 0, sizeof p);
    struct s2a_source_pin_ref a = ref_for(1, 11, 0x10), b = ref_for(2, 22, 0x20);
    struct s2a_source_pin_ref out[NVN_PROGRAM_PIN_MAX];

    CHECK(nvn_program_pins_add(&p, (void *)0x1000, &a) == 1, "add first stage");
    CHECK(nvn_program_pins_add(&p, (void *)0x1000, &a) == 0, "duplicate key prefix is rejected");
    CHECK(p.n == 1 && p.owner == (void *)0x1000, "duplicate does not add another pin");
    CHECK(nvn_program_pins_add(&p, (void *)0x1000, &b) == 1 && p.n == 2, "second stage adds");

    // 拷贝对象 Finalize：owner 不同，不能解原件的 pin。
    CHECK(nvn_program_pins_release(&p, (void *)0x2000, out) == 0 && p.n == 2 && !p.released,
          "copy finalize does not unpin the original");

    // 同一对象换 SetShaders：解旧 serial 的两条 pin，并标记 released。
    CHECK(nvn_program_pins_release(&p, (void *)0x1000, out) == 2, "owner finalize releases both");
    CHECK(out[0].slot == 1 && out[1].slot == 2, "release returns the pinned refs");
    CHECK(p.n == 0 && p.released == 1, "release marks the serial released");
    CHECK(nvn_program_pins_release(&p, (void *)0x1000, out) == 0, "release is idempotent");

    // 旧拷贝再 Bind 已释放 serial：拒绝，不能重新挂 pin（S2b 的永久泄漏）。
    CHECK(nvn_program_pins_add(&p, (void *)0x2000, &a) == -1 && p.n == 0,
          "bind after release is refused");

    // old_serial=0：新 program Initialize 解不到任何 pin。
    struct nvn_program_pins fresh;
    memset(&fresh, 0, sizeof fresh);
    CHECK(nvn_program_pins_release(&fresh, (void *)0x9000, out) == 0 && !fresh.released,
          "old serial 0 (no pin entry) does not release another program");

    // 同一 serial 的不同阶段 key 前缀不同，均能加入；同名不同 slot 仍按 key 前缀去重。
    struct nvn_program_pins q;
    memset(&q, 0, sizeof q);
    struct s2a_source_pin_ref c = ref_for(3, 33, 0x30);
    CHECK(nvn_program_pins_add(&q, (void *)0x3000, &a) == 1 &&
          nvn_program_pins_add(&q, (void *)0x3000, &b) == 1 &&
          nvn_program_pins_add(&q, (void *)0x3000, &c) == 1 && q.n == 3,
          "three distinct stage keys fit");

    // #1375-r2：SetShaders 建好 serial 的条目后把 owner 直接定为原件。
    // 拷贝对象先 Bind 时只能加 pin，不能把 owner 换成拷贝地址；否则原件 Finalize 解不掉，
    // pin 会一直占槽（旧实现 owner=0x5000，下面 release(0x4000) 返回 0）。
    struct nvn_program_pins r;
    memset(&r, 0, sizeof r);
    nvn_program_pins_set_owner(&r, (void *)0x4000);
    struct s2a_source_pin_ref d = ref_for(4, 44, 0x40);
    CHECK(r.owner == (void *)0x4000, "SetShaders marks the original as owner before any pin");
    CHECK(nvn_program_pins_add(&r, (void *)0x5000, &d) == 1, "copy binds first and adds a pin");
    CHECK(r.owner == (void *)0x4000, "copy bind does not steal owner");
    CHECK(nvn_program_pins_release(&r, (void *)0x5000, out) == 0 && r.n == 1 && !r.released,
          "copy finalize cannot release the original's pin");
    CHECK(nvn_program_pins_release(&r, (void *)0x4000, out) == 1 && out[0].slot == 4,
          "original finalize releases the copy's pin");

    if (fails) { printf("nvn program pins test: %d FAILED\n", fails); return 1; }
    printf("nvn program pins test: ok (dedupe, owner/copy, SetShaders owner, release, old serial, released serial)\n");
    return 0;
}
