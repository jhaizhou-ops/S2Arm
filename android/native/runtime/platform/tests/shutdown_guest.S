.text
.p2align 2
.global s2a_shutdown_test_guest_start
.global s2a_shutdown_test_guest_end
.global s2a_shutdown_test_loop
.global s2a_shutdown_test_store
.type s2a_shutdown_test_loop,%function
s2a_shutdown_test_guest_start:
s2a_shutdown_test_loop:
    ldr x1,[x0]
    add x1,x1,#1
    stlr x1,[x0]
    add x2,x0,#8
    ldar x2,[x2]
    cbz x2,s2a_shutdown_test_loop
    ret
.size s2a_shutdown_test_loop,.-s2a_shutdown_test_loop
.type s2a_shutdown_test_store,%function
s2a_shutdown_test_store:
    mov x1,#0x5a
    strb w1,[x0]
    ret
.size s2a_shutdown_test_store,.-s2a_shutdown_test_store
s2a_shutdown_test_guest_end:
.section .note.GNU-stack,"",%progbits
