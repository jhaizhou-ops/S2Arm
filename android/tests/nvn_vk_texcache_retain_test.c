// P0-leak ①：保留账本满不许“既不销毁也不记账”（真机探针：要真实 VkDevice 才能创建/提交上传）。
//
// 反例构造：debug 注入“提交后完成未知”（nvn_vk_texcache_set_upload_fault(1)）→ 每笔上传都把
// fence/命令缓冲/staging 转进保留账本。连续做 100 笔，就会反复撞到 TEX_RETAINED_MAX=32：
//   修前：第 33 笔起 tex_retain_slot() 返回 NULL，句柄既不销毁也不进账；计数里 created 与
//         freed+retained 对不上，retained_overflow 一路涨 —— 静默泄漏。
//   修后：溢出先把已完成（fence 已 signal）的条目结算掉、再有界等待，句柄要么被销毁（freed++）、
//         要么仍在账本里（retained_entries），created 恒等于 freed + retained；overflow 只会在
//         真正无法追踪时出现，并且会打【红】+ 把会话标终态（那一条本用例覆盖不到：需要“永远不
//         完成的 GPU 上工作”，真机上无法构造，报告里列为未验）。
#include <stdio.h>
#include <string.h>
#include "nvn_vk_texcache.h"
#include "nvn_vk_format.h"

static int fails;

// 探针桩：产品里由 nvn_vk_first_draw.c 提供的“framebuffer 缓存按视图失效”钩子。
void nvn_vk_first_draw_forget_view(VkImageView view) { (void)view; }

static void check(const char *what, unsigned long long got, unsigned long long want) {
    if (got != want) { fails++; printf("FAIL %-34s got=%llu want=%llu\n", what, got, want); }
    else printf("OK   %-34s %llu\n", what, got);
}

int main(void) {
    struct s2a_vk_device d; char why[192] = "";
    if (s2a_vk_device_create(&d, why, sizeof why)) { printf("FAIL device: %s\n", why); return 1; }
    struct nvn_vk_texcache c; nvn_vk_texcache_init(&c, &d, NULL, 0);
    static uint8_t green[64];
    for (int i = 0; i < 64; i++) green[i] = (uint8_t)(((i & 3) == 0) ? 0xff : 0x40);

    // 100 笔“已提交但没有完成证明”：每笔都会试图把 fence/CB/staging 交给保留账本。
    nvn_vk_texcache_set_upload_fault(1);
    int got_tex = 0;
    for (int i = 0; i < 100; i++) {
        struct nvn_vk_tex *t = nvn_vk_texcache_get(&c, 0x10000 + (uint64_t)i * 0x1000, (uint64_t)(i + 1),
                                                  0x25 /* R8G8B8A8 */, 4, 4, green, sizeof green);
        if (t) got_tex++;
    }
    struct nvn_vk_tex_upload_stats st;
    nvn_vk_texcache_upload_stats(&st);
    printf("INFO uploads=100 got_tex=%d retained_entries=%u overflow=%llu uncompleted=%llu\n",
           got_tex, st.retained_entries, (unsigned long long)st.retained_overflow,
           (unsigned long long)st.uncompleted);

    // 1) 账本条目有界（32 上限）；2) 溢出必须被回收掉，不许“既不销毁也不记账”。
    if (st.retained_entries > 32) { fails++; printf("FAIL retained_entries=%u 超过上限 32\n", st.retained_entries); }
    check("retained entries within bound", st.retained_entries <= 32, 1);
    check("no untracked overflow", st.retained_overflow, 0);
    // 3) 三个句柄账必须平：创建的 = 已释放 + 仍在保留账本里的。
    // 每个保留下来的句柄必须有一个账本条目持有它（账本条目是 fence 组 + 图像组的混合，
    // 所以断言“创建 - 已释放 <= 账本条目”，而不是恰好相等）：差出的就是没人持有的泄漏。
    check("fences not dropped", st.fences_created - st.fences_freed <= st.retained_entries, 1);
    check("commands not dropped", st.commands_created - st.commands_freed <= st.retained_entries, 1);
    check("staging not dropped", st.staging_created - st.staging_freed <= st.retained_entries, 1);
    printf("INFO ledger: fences %llu/%llu cmds %llu/%llu staging %llu/%llu\n",
           (unsigned long long)st.fences_created, (unsigned long long)st.fences_freed,
           (unsigned long long)st.commands_created, (unsigned long long)st.commands_freed,
           (unsigned long long)st.staging_created, (unsigned long long)st.staging_freed);

    // 4) 溢出回收之后缓存仍能正常工作：正常语义下再取一次必须命中/新建成功。
    nvn_vk_texcache_set_upload_fault(0);
    struct nvn_vk_tex *ok = nvn_vk_texcache_get(&c, 0x90000, 500, 0x25, 4, 4, green, sizeof green);
    check("cache still usable after reclaim", ok != NULL, 1);
    nvn_vk_texcache_set_upload_fault(1);
    struct nvn_vk_tex *again = nvn_vk_texcache_get(&c, 0x91000, 501, 0x25, 4, 4, green, sizeof green);
    (void)again;
    nvn_vk_texcache_set_upload_fault(0);
    nvn_vk_texcache_upload_stats(&st);
    check("overflow still zero at end", st.retained_overflow, 0);
    check("fences not dropped (end)", st.fences_created - st.fences_freed <= st.retained_entries, 1);

    // 设备释放前结算保留账本（完成证明拿不到时允许保留并计数，但不能崩）。
    uint32_t left = 0;
    nvn_vk_texcache_release_retained(&d, 2000000000ull, &left);
    printf("INFO release_retained left=%u\n", left);
    nvn_vk_texcache_destroy(&c);
    s2a_vk_device_destroy(&d, 0);
    if (fails) { printf("nvn-vk-texcache-retain: %d FAILURES\n", fails); return 1; }
    printf("nvn-vk-texcache-retain: ok\n");
    return 0;
}
