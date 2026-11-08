// Same protocol as runtime/src/entry.S sw_touch_tramp; Linux ELF symbol spelling.
    .text
    .p2align 2
    .global s2a_android_fault_trampoline
    .type s2a_android_fault_trampoline, %function
s2a_android_fault_trampoline:
    hint #34
    mov x29, #0
    bl s2a_android_fault_body
    .global s2a_android_fault_return
s2a_android_fault_return:
    brk #0x7a5
    // A dispatcher that fails to recognize our BRK must not continue or return.
    b s2a_android_fault_return
    .size s2a_android_fault_trampoline, .-s2a_android_fault_trampoline
    .global s2a_android_fault_probe_instruction
    .type s2a_android_fault_probe_instruction, %function
s2a_android_fault_probe_instruction:
    hint #34
    mov x1, #0x5a
    .global s2a_android_fault_probe_store
s2a_android_fault_probe_store:
    str x1, [x0]
    ret
    .size s2a_android_fault_probe_instruction, .-s2a_android_fault_probe_instruction
    .section .note.GNU-stack, "", %progbits
