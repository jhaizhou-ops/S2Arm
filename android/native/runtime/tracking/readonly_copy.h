// Android GPU 正常上下文的只读副本；不改变源页保护，不承担 GPU 读回。
#pragma once
#include <stdint.h>

// 调用者必须是同步 GPU owner，并在复制结束前保持既有 backing before/after 边界。
// 0 成功；errno 拒绝。失败时目标可能部分已写，调用者必须丢弃，不得裸读源兜底。
int s2a_android_copy_guest_readonly(uint64_t address, void *destination, uint64_t size);
// Cold-start diagnostic A/B. Default 1; frozen after the first copy.
int s2a_android_readonly_configure_bounded(int enabled);
