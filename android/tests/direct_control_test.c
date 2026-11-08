// C2：控制段 compute 元数据解析；边界与 Python cs_facts 同口径。
#include "../native/direct/control.h"

#include <stdio.h>
#include <string.h>

static int failures;
#define CHECK(c, w) do { if (!(c)) { printf("FAIL %s\n", w); failures++; } } while (0)

static void put(uint8_t *control, size_t offset, uint32_t value) {
    control[offset] = (uint8_t)value; control[offset + 1] = (uint8_t)(value >> 8);
    control[offset + 2] = (uint8_t)(value >> 16); control[offset + 3] = (uint8_t)(value >> 24);
}

int main(void) {
    uint8_t control[0x800];
    memset(control, 0xCD, sizeof control);
    struct s2a_cs_facts facts;
    uint8_t zeros[0x800] = {0};
    CHECK(s2a_control_parse_cs(zeros, sizeof zeros, &facts) == S2A_CONTROL_LOCAL_ZERO, "all-zero local rejected");

    put(control, 0x748, 8); put(control, 0x74C, 4); put(control, 0x750, 2); put(control, 0x754, 17);
    CHECK(s2a_control_parse_cs(control, sizeof control, &facts) == S2A_CONTROL_OK, "valid 8x4x2");
    CHECK(facts.local[0] == 8 && facts.local[1] == 4 && facts.local[2] == 2 && facts.shared_bytes == 32,
          "local and aligned shared");
    put(control, 0x754, 0);
    CHECK(s2a_control_parse_cs(control, sizeof control, &facts) == S2A_CONTROL_OK && facts.shared_bytes == 0,
          "zero shared stays zero");
    put(control, 0x754, 1);
    CHECK(s2a_control_parse_cs(control, sizeof control, &facts) == S2A_CONTROL_OK && facts.shared_bytes == 16,
          "one byte shared rounds to 16");
    put(control, 0x754, 0x10000);
    CHECK(s2a_control_parse_cs(control, sizeof control, &facts) == S2A_CONTROL_OK && facts.shared_bytes == 0x10000,
          "max shared accepted");
    put(control, 0x754, 0x10001);
    CHECK(s2a_control_parse_cs(control, sizeof control, &facts) == S2A_CONTROL_SHARED_LIMIT,
          "shared over 64 KiB rejected");

    put(control, 0x748, 0); put(control, 0x74C, 1); put(control, 0x750, 1); put(control, 0x754, 0);
    CHECK(s2a_control_parse_cs(control, sizeof control, &facts) == S2A_CONTROL_LOCAL_ZERO, "x=0 rejected");
    put(control, 0x748, 1); put(control, 0x74C, 1); put(control, 0x750, 1025);
    CHECK(s2a_control_parse_cs(control, sizeof control, &facts) == S2A_CONTROL_LOCAL_LIMIT,
          "1025 invocations rejected");
    put(control, 0x750, 4); put(control, 0x74C, 4); put(control, 0x748, 64);   // 1024 exactly
    CHECK(s2a_control_parse_cs(control, sizeof control, &facts) == S2A_CONTROL_OK, "1024 invocations accepted");

    CHECK(s2a_control_parse_cs(control, 0x757, &facts) == S2A_CONTROL_SHORT, "short control rejected");
    CHECK(s2a_control_parse_cs(NULL, sizeof control, &facts) == S2A_CONTROL_ARGUMENT, "null control rejected");
    CHECK(s2a_control_parse_cs(control, sizeof control, NULL) == S2A_CONTROL_ARGUMENT, "null output rejected");

    if (failures) { printf("direct-control: %d FAILURES\n", failures); return 1; }
    printf("direct-control: ok\n");
    return 0;
}
