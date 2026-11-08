/* 本仓库自有的 AArch64 可调用测试程序，不含游戏代码。
 * entry(x0=device, x1=fetch) 保存调用方寄存器，执行 loader 后返回。
 * 编译器/链接器生成真实指令；MOD0/EH/RELA 是本程序自己的模块元数据。
 * 固定布局只供测试手算预期，不进入生产工具。
 */
.section .text,"ax"
.global entry, loader, loader_end
    b entry
    .word module
.org 0x80
entry:
    stp x19, x30, [sp, #-16]!
    mov x19, x1
    bl loader
    ldp x19, x30, [sp], #16
    ret
.org 0x100
loader:
#ifdef CASE_NO_NAMES
    ret
#else
    stp x20, x30, [sp, #-16]!
    mov x20, x0
    adrp x1, name_a
    add x1, x1, :lo12:name_a
#ifdef CASE_NAME_CLOBBER
    mov x1, xzr
#endif
    blr x19
    /* 下一名称在上一个返回值保存之前准备，不能按连续三条匹配。 */
#ifdef CASE_DUP_NAME
    adr x1, name_a
#else
    adr x1, name_b
#endif
#ifdef CASE_RETURN_CLOBBER
    mov x0, xzr
#endif
#ifdef CASE_DIRECT
    adrp x8, slot_a
    add x8, x8, :lo12:slot_a
#else
    adrp x8, got_a
    ldr x8, [x8, :lo12:got_a]
#endif
#ifndef CASE_MISSING_STORE
    str x0, [x8]
#endif
    mov x0, x20
    blr x19
#ifdef CASE_GOT
    adrp x8, got_b
    ldr x8, [x8, :lo12:got_b]
    str x0, [x8]
#elif defined(CASE_DUP_GOT)
    adrp x8, got_a
    ldr x8, [x8, :lo12:got_a]
    str x0, [x8]
#elif defined(CASE_DUP_SLOT)
    adrp x8, slot_a
    str x0, [x8, :lo12:slot_a]
#else
    adrp x8, slot_b
    add x8, x8, :lo12:slot_b
#ifndef CASE_UNSTORED_FINAL
    str x0, [x8]
#endif
#endif
    ldp x20, x30, [sp], #16
    ret
#endif
loader_end:
.org 0x300
/* 静态读点：0x304 读取 GOT；0x310、0x314 直接读取第二槽。 */
read_slots:
#ifdef CASE_DIRECT
    adrp x8, slot_a
    ldr x8, [x8, :lo12:slot_a]
    nop
#else
    adrp x8, got_a
    ldr x8, [x8, :lo12:got_a]
    ldr x9, [x8]
#endif
    adrp x8, slot_b
    ldr x9, [x8, :lo12:slot_b]
    ldr x10, [x8, :lo12:slot_b]
    ret
.org 0x1000

.section .rodata,"a"
module:
    .ascii "MOD0"
    .word dynamic - module
    .word 0, 0
    .word eh_header - module
    .word eh_end - module
.org 0x80
dynamic:
    .xword 7, rela
    .xword 8, rela_end - rela
    .xword 9, 24
    .xword 0, 0
.org 0x100
eh_header:
    .byte 1, 0x1b, 0x03, 0x3b
    .word cie - .
    .word 1
    .word loader - eh_header
    .word fde - eh_header
eh_end:
.org 0x180
rela:
    .xword got_a, 1027, slot_a /* R_AARCH64_RELATIVE */
#ifdef CASE_GOT
    .xword got_b, 1027, slot_b
#endif
rela_end:
.org 0x200
cie:
    .word 0x14, 0
    .byte 1
    .asciz "zR"
    .byte 4, 0x78, 30, 1, 0x1b
    .zero 7
fde:
    .word 0x10
    .word . - cie
    .word loader - .
    .word loader_end - loader
    .word 0
.org 0x300
name_a:
    .asciz "nvnDeviceGetInteger"
name_b:
    .asciz "nvnDeviceGetProcAddress"
.org 0x1000

.section .data,"aw"
.org 0x80
got_a:
    .xword slot_a
got_b:
    .xword slot_b
.org 0x100
slot_a:
    .xword 0
slot_b:
    .xword 0
.org 0x1000
