#include "control.h"

static uint32_t le32(const uint8_t *p) {
    return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24;
}

int s2a_control_parse_cs(const uint8_t *control, size_t bytes, struct s2a_cs_facts *out) {
    if (!control || !out) return S2A_CONTROL_ARGUMENT;
    if (bytes < S2A_CONTROL_CS_MIN_BYTES) return S2A_CONTROL_SHORT;
    uint32_t x = le32(control + 0x748), y = le32(control + 0x74C), z = le32(control + 0x750);
    uint32_t shared = le32(control + 0x754);
    if (!x || !y || !z) return S2A_CONTROL_LOCAL_ZERO;
    if ((uint64_t)x * y * z > S2A_CONTROL_CS_MAX_INVOCATIONS) return S2A_CONTROL_LOCAL_LIMIT;
    if (shared > S2A_CONTROL_CS_MAX_SHARED) return S2A_CONTROL_SHARED_LIMIT;
    out->local[0] = x; out->local[1] = y; out->local[2] = z;
    out->shared_bytes = (shared + 15u) / 16u * 16u;
    return S2A_CONTROL_OK;
}
