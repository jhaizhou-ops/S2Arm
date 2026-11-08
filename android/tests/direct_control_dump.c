// 测试辅助：读控制段文件，打印与 merge_extract.cs_facts 对拍的一行结果。
#include "../native/direct/control.h"

#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    if (argc != 2) return 2;
    FILE *f = fopen(argv[1], "rb");
    if (!f) return 2;
    static uint8_t buffer[1 << 20];
    size_t bytes = fread(buffer, 1, sizeof buffer, f);
    fclose(f);
    struct s2a_cs_facts facts;
    int rc = s2a_control_parse_cs(buffer, bytes, &facts);
    if (rc) { printf("error %d\n", rc); return 0; }
    printf("ok %u %u %u %u\n", facts.local[0], facts.local[1], facts.local[2], facts.shared_bytes);
    return 0;
}
