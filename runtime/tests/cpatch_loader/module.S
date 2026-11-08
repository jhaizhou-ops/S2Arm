/* SPDX-License-Identifier: 0BSD
 * 自有 AArch64 模块：64 个可调用的 30 帧探针和 256 个数据字节。
 * MOD0 是本程序的装载元数据；动态符号表 / EH 表由 ELF 链接器生成。
 */
.section .text,"ax"
.global entry, fps_probe
    b entry
    .word module - . + 4
.org 0x80
entry:
    .cfi_startproc
    ret
    .cfi_endproc
.org 0x100
fps_probe:
    .cfi_startproc
    .rept 64
    mov w0, #30
    ret
    .endr
    .cfi_endproc
.org 0x1000

.section .rodata,"a"
module:
    .ascii "MOD0"
    .word _DYNAMIC - module
    .word __bss_start - module
    .word __bss_end - module
    .word __eh_frame_hdr - module
    .word __eh_frame_hdr_end - module
    .word 0

.section .data,"aw"
.global patch_data
patch_data:
    .fill 256, 1, 0x11
