// Red-zone probes for runtime/guest_signal.c. Each fills the 14 words below sp
// (sp - 8 ... sp - 112, the depth rewritten blocks borrow), takes a signal with no
// stack use in between, then returns a mask: bit i-1 set = word at sp - 8*i survived.

.macro FILL
    mov x9, #0x5a00
    movk x9, #0x5332, lsl #16
    mov x10, #1
1:  eor x11, x9, x10
    sub x12, sp, x10, uxtx #3
    str x11, [x12]
    add x10, x10, #1
    cmp x10, #14
    b.ls 1b
.endm

.macro COUNT
    mov x0, #0
    mov x10, #1
2:  eor x11, x9, x10
    sub x12, sp, x10, uxtx #3
    ldr x13, [x12]
    cmp x13, x11
    mov x14, #1
    sub x15, x10, #1
    lsl x14, x14, x15
    orr x15, x0, x14
    csel x0, x15, x0, eq
    add x10, x10, #1
    cmp x10, #14
    b.ls 2b
.endm

    .text
    .p2align 2
// uint64_t s2a_redzone_tgkill(int tgid, int tid, int sig): delivered on syscall return
    .globl s2a_redzone_tgkill
    .type s2a_redzone_tgkill, %function
s2a_redzone_tgkill:
    hint #34            // bti c
    FILL
    mov x8, #131        // __NR_tgkill
    svc #0
    COUNT
    ret
    .size s2a_redzone_tgkill, . - s2a_redzone_tgkill

    .p2align 2
// uint64_t s2a_redzone_store(uint64_t *target): faults while target is read-only
    .globl s2a_redzone_store
    .type s2a_redzone_store, %function
s2a_redzone_store:
    hint #34
    FILL
    str x9, [x0]
    COUNT
    ret
    .size s2a_redzone_store, . - s2a_redzone_store

    .section .note.GNU-stack, "", %progbits
