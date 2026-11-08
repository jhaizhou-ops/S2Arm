// C2/C3：共享 NVN 控制段（控制内存）的 compute 元数据解析。
// 与 graphics/tools/direct/merge_extract.py:cs_facts（以及上游 shader_split.py）同口径：
//   +0x748 三个 uint32 = local size XYZ；+0x754 uint32 = shared 字节数；shared 按 16 向上取整。
// 读不到 / 越界返回明确错误；绝不回填 1x1x1 或猜测共享内存。
#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define S2A_CONTROL_CS_MIN_BYTES 0x758u
#define S2A_CONTROL_CS_MAX_INVOCATIONS 1024u
#define S2A_CONTROL_CS_MAX_SHARED 0x10000u

struct s2a_cs_facts {
    uint32_t local[3];
    uint32_t shared_bytes;       // 16 字节对齐后的值
};

enum s2a_control_error {
    S2A_CONTROL_OK = 0,
    S2A_CONTROL_ARGUMENT = -1,
    S2A_CONTROL_SHORT = -2,
    S2A_CONTROL_LOCAL_ZERO = -3,
    S2A_CONTROL_LOCAL_LIMIT = -4,
    S2A_CONTROL_SHARED_LIMIT = -5,
};

int s2a_control_parse_cs(const uint8_t *control, size_t bytes, struct s2a_cs_facts *out);

#ifdef __cplusplus
}
#endif
