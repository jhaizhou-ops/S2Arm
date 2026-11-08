// Test-only stack switch. Production reuses runtime/src/entry.S sw_call_on_stack.
    .text
    .p2align 2
    .global s2a_fault_test_guest_stack
    .type s2a_fault_test_guest_stack, %function
s2a_fault_test_guest_stack:
    hint #34
    stp x29, x30, [sp, #-32]!
    str x19, [sp, #16]
    mov x29, sp
    mov x19, sp
    mov x2, x0
    mov sp, x1
    blr x2
    mov sp, x19
    ldr x19, [sp, #16]
    ldp x29, x30, [sp], #32
    ret
    .size s2a_fault_test_guest_stack, .-s2a_fault_test_guest_stack
    .section .note.GNU-stack,"",%progbits
