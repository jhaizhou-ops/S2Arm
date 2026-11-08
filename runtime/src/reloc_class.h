// 装载器对每条动态重定位的处理分类（runtime/src/loader.c relocate；单测 runtime/tests/t_reloc_class.c）。
// 与游戏 exefs 里任天堂 rtld 同语义：RELATIVE 加基址；ABS64 / GLOB_DAT / JUMP_SLOT 按符号解析；
//   TLS 四种（1028 DTPMOD64 / 1029 DTPREL64 / 1030 TPREL64 / 1031 TLSDESC）rtld 不碰——游戏 sdk 的 nnmusl 在模块初始化
//   （__nnmusl_init_dso，模块各自导入）里按 (type & 0x7ffffffc) == 0x404 自己扫表处理（11-03 火纹 Fortune's Weave subsdk0 一条 TLSDESC，
//   旧装载器报「不认识的重定位类型 1031」整局起不来；rtld / sdk 反汇编核过）。其余类型不认识：装载报红中止，不猜
#pragma once
enum { R_AARCH64_ABS64 = 257, R_AARCH64_GLOB_DAT = 1025, R_AARCH64_JUMP_SLOT = 1026, R_AARCH64_RELATIVE = 1027, R_AARCH64_TLS_DTPMOD64 = 1028 };
enum reloc_class { RELOC_RELATIVE, RELOC_SYMBOL, RELOC_TLS_LEFT, RELOC_UNKNOWN };
static inline enum reloc_class reloc_class(unsigned type) {
    if (type == R_AARCH64_RELATIVE) return RELOC_RELATIVE;
    if (type == R_AARCH64_ABS64 || type == R_AARCH64_GLOB_DAT || type == R_AARCH64_JUMP_SLOT) return RELOC_SYMBOL;
    if ((type & ~3u) == R_AARCH64_TLS_DTPMOD64) return RELOC_TLS_LEFT;   // 1028–1031：留给 nnmusl（同 rtld 跳过）
    return RELOC_UNKNOWN;
}
