.text
.p2align 2
.global s2a_thread_test_loop
.global s2a_thread_test_guest_start
.global s2a_thread_test_guest_end
.type s2a_thread_test_loop,%function
s2a_thread_test_loop:
s2a_thread_test_guest_start:
    ldr x1,[x0]
    add x1,x1,#1
    stlr x1,[x0]
    add x2,x0,#8
    ldar x2,[x2]
    cbz x2,s2a_thread_test_guest_start
    ret
.global s2a_thread_test_fault
.type s2a_thread_test_fault,%function
s2a_thread_test_fault:
    mov x1,#0x5a
    str x1,[x0]
s2a_thread_test_guest_end:
    ret
.size s2a_thread_test_loop,.-s2a_thread_test_loop
.section .note.GNU-stack,"",%progbits
