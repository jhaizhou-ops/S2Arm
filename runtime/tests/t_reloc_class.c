// 装载器重定位分类单测（runtime/src/reloc_class.h）：期望按 AAELF64 类型号与任天堂 rtld 的分派手算——
//   257 / 1025 / 1026 按符号、1027 加基址、1028–1031（TLS 四种）留给 nnmusl、其余（含 1024 COPY、1032 IRELATIVE、0、1035）不认识（装载报红中止）
#include "../src/reloc_class.h"
#include <stdio.h>
int main(void) {
    static const struct { unsigned type; enum reloc_class want; const char *what; } c[] = {
        {257, RELOC_SYMBOL, "ABS64"}, {1025, RELOC_SYMBOL, "GLOB_DAT"}, {1026, RELOC_SYMBOL, "JUMP_SLOT"}, {1027, RELOC_RELATIVE, "RELATIVE"},
        {1028, RELOC_TLS_LEFT, "TLS_DTPMOD64"}, {1029, RELOC_TLS_LEFT, "TLS_DTPREL64"}, {1030, RELOC_TLS_LEFT, "TLS_TPREL64"}, {1031, RELOC_TLS_LEFT, "TLSDESC（火纹 subsdk0）"},
        {1024, RELOC_UNKNOWN, "COPY"}, {1032, RELOC_UNKNOWN, "IRELATIVE"}, {0, RELOC_UNKNOWN, "NONE"}, {1035, RELOC_UNKNOWN, "1028+7"}, {258, RELOC_UNKNOWN, "ABS32"},
    };
    unsigned bad = 0, n = sizeof c / sizeof *c;
    for (unsigned i = 0; i < n; i++) {
        enum reloc_class got = reloc_class(c[i].type);
        if (got != c[i].want) { bad++; printf("✗ t_reloc_class：类型 %u（%s）期望 %d → 得 %d\n", c[i].type, c[i].what, c[i].want, got); }
    }
    if (bad) return 1;
    printf("✓ t_reloc_class：%u 例全符（符号 3 / 基址 1 / TLS 留给 nnmusl 4 / 不认识 5）\n", n);
    return 0;
}
