// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
// 真实 Mach 映射扫描，仅替换 TASK_VM_INFO 的进程地址上限；不启动游戏。
#include "../src/native.h"
#include <mach/mach.h>
#include <string.h>
static int fake_top;
static uint64_t top;
kern_return_t s2a_test_task_info(task_name_t task, task_flavor_t flavor, task_info_t data, mach_msg_type_number_t *count) {
    if (!fake_top || flavor != TASK_VM_INFO) return task_info(task, flavor, data, count);
    if (!top) return KERN_FAILURE;
    memset(data, 0, sizeof(task_vm_info_data_t));
    ((task_vm_info_t)data)->max_address = top;
    *count = TASK_VM_INFO_REV2_COUNT;
    return KERN_SUCCESS;
}
int main(void) {
    uint64_t before, largest_before, total, largest; int bad = 0;
    s2a_low_holes(&before, &largest_before);
    fake_top = 1;
    const uint64_t limits[] = {12ull << 30, 63ull << 30, 3ull << 30};
    for (unsigned i = 0; i < sizeof limits / sizeof *limits; i++) {
        top = limits[i]; s2a_low_holes(&total, &largest);
        uint64_t max = top > (4ull << 30) ? top - (4ull << 30) : 0;
        if (total > max || largest > total) { printf("✗ 地址上限 %llu GB：空洞合计 %llu MB、最大 %llu MB 超范围\n", (unsigned long long)(top >> 30), (unsigned long long)(total >> 20), (unsigned long long)(largest >> 20)); bad++; }
    }
    top = 0; s2a_low_holes(&total, &largest);
    if (total != before || largest != largest_before) { puts("✗ 读不到上限时未保持原扫描边界"); bad++; }
    top = 1ull << 47; s2a_low_holes(&total, &largest);
    if (total != before || largest != largest_before) { puts("✗ Mac 大地址档扫描边界改变"); bad++; }
    printf("%s t_vawin_limits：%d 处不符\n", bad ? "✗" : "✓", bad);
    return bad != 0;
}
