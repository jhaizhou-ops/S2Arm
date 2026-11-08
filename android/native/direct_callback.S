// uint64_t call_guest6(fn, guest_sp, args[6], &xs_slot.cur).
// All Vulkan allocation callbacks have <=5 integer arguments and <=1 word result.
// Preserve the driver stack and move the xstack cursor below our live host frame
// before the guest callback can re-enter a svc or another wrapped host function.
    .text
    .p2align 2
    .global s2a_android_vk_call_guest6
    .hidden s2a_android_vk_call_guest6
    .type s2a_android_vk_call_guest6, %function
s2a_android_vk_call_guest6:
    hint #34
    stp x29, x30, [sp, #-64]!
    stp x19, x20, [sp, #16]
    stp x21, x22, [sp, #32]
    mov x29, sp
    mov x19, sp
    mov x20, x3
    ldr x21, [x20]
    str x19, [x20]
    mov x9, x0
    mov x10, x1
    mov x11, x2
    sub x10, x10, #16
    mov sp, x10
    ldp x0, x1, [x11]
    ldp x2, x3, [x11, #16]
    ldp x4, x5, [x11, #32]
    blr x9
    mov sp, x19
    str x21, [x20]
    ldp x19, x20, [sp, #16]
    ldp x21, x22, [sp, #32]
    ldp x29, x30, [sp], #64
    ret
    .size s2a_android_vk_call_guest6, .-s2a_android_vk_call_guest6
    .section .note.GNU-stack,"",%progbits
