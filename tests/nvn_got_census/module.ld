/* 三段布局与现有 selftest_nso.py 的 NSO 容器一致。 */
ENTRY(entry)
SECTIONS {
    .text 0 : { *(.text) }
    .rodata 0x1000 : { *(.rodata) }
    .data 0x2000 : { *(.data) }
    /DISCARD/ : { *(.comment) *(.note*) }
}
