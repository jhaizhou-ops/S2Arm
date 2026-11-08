.text
.p2align 2
.global s2a_fault_register_probe
.type s2a_fault_register_probe, %function
s2a_fault_register_probe:
    hint #34
    sub sp, sp, #176
    stp x19, x20, [sp, #0]
    stp x21, x22, [sp, #16]
    stp x23, x24, [sp, #32]
    stp x25, x26, [sp, #48]
    stp x27, x28, [sp, #64]
    stp x29, x30, [sp, #80]
    stp d8, d9, [sp, #96]
    stp d10, d11, [sp, #112]
    stp d12, d13, [sp, #128]
    stp d14, d15, [sp, #144]
    mrs x9, fpcr
    mrs x10, fpsr
    stp x9, x10, [sp, #160]
    mov x9, #0x400000
    msr fpcr, x9
    mov x9, #0x8000000
    msr fpsr, x9
    movi v0.16b, #1
    movi v1.16b, #2
    movi v2.16b, #3
    movi v3.16b, #4
    movi v4.16b, #5
    movi v5.16b, #6
    movi v6.16b, #7
    movi v7.16b, #8
    movi v8.16b, #9
    movi v9.16b, #10
    movi v10.16b, #11
    movi v11.16b, #12
    movi v12.16b, #13
    movi v13.16b, #14
    movi v14.16b, #15
    movi v15.16b, #16
    movi v16.16b, #17
    movi v17.16b, #18
    movi v18.16b, #19
    movi v19.16b, #20
    movi v20.16b, #21
    movi v21.16b, #22
    movi v22.16b, #23
    movi v23.16b, #24
    movi v24.16b, #25
    movi v25.16b, #26
    movi v26.16b, #27
    movi v27.16b, #28
    movi v28.16b, #29
    movi v29.16b, #30
    movi v30.16b, #31
    movi v31.16b, #32
    mov x19, #20755
    mov x20, #20756
    mov x21, #20757
    mov x22, #20758
    mov x23, #20759
    mov x24, #20760
    mov x25, #20761
    mov x26, #20762
    mov x27, #20763
    mov x28, #20764
    mov x29, #20765
    mov x30, #0x5130
    str xzr, [x0]
    mov x0, #1
    mrs x9, fpcr
    cmp x9, #0x400000
    b.ne 1f
    mrs x9, fpsr
    mov x10, #0x8000000
    cmp x9, x10
    b.ne 1f
    mov x12, #0x0101010101010101
    mov x11, #1
    mul x11, x11, x12
    umov x9, v0.d[0]
    umov x10, v0.d[1]
    cmp x9, x11
    b.ne 1f
    cmp x10, x11
    b.ne 1f
    mov x11, #2
    mul x11, x11, x12
    umov x9, v1.d[0]
    umov x10, v1.d[1]
    cmp x9, x11
    b.ne 1f
    cmp x10, x11
    b.ne 1f
    mov x11, #3
    mul x11, x11, x12
    umov x9, v2.d[0]
    umov x10, v2.d[1]
    cmp x9, x11
    b.ne 1f
    cmp x10, x11
    b.ne 1f
    mov x11, #4
    mul x11, x11, x12
    umov x9, v3.d[0]
    umov x10, v3.d[1]
    cmp x9, x11
    b.ne 1f
    cmp x10, x11
    b.ne 1f
    mov x11, #5
    mul x11, x11, x12
    umov x9, v4.d[0]
    umov x10, v4.d[1]
    cmp x9, x11
    b.ne 1f
    cmp x10, x11
    b.ne 1f
    mov x11, #6
    mul x11, x11, x12
    umov x9, v5.d[0]
    umov x10, v5.d[1]
    cmp x9, x11
    b.ne 1f
    cmp x10, x11
    b.ne 1f
    mov x11, #7
    mul x11, x11, x12
    umov x9, v6.d[0]
    umov x10, v6.d[1]
    cmp x9, x11
    b.ne 1f
    cmp x10, x11
    b.ne 1f
    mov x11, #8
    mul x11, x11, x12
    umov x9, v7.d[0]
    umov x10, v7.d[1]
    cmp x9, x11
    b.ne 1f
    cmp x10, x11
    b.ne 1f
    mov x11, #9
    mul x11, x11, x12
    umov x9, v8.d[0]
    umov x10, v8.d[1]
    cmp x9, x11
    b.ne 1f
    cmp x10, x11
    b.ne 1f
    mov x11, #10
    mul x11, x11, x12
    umov x9, v9.d[0]
    umov x10, v9.d[1]
    cmp x9, x11
    b.ne 1f
    cmp x10, x11
    b.ne 1f
    mov x11, #11
    mul x11, x11, x12
    umov x9, v10.d[0]
    umov x10, v10.d[1]
    cmp x9, x11
    b.ne 1f
    cmp x10, x11
    b.ne 1f
    mov x11, #12
    mul x11, x11, x12
    umov x9, v11.d[0]
    umov x10, v11.d[1]
    cmp x9, x11
    b.ne 1f
    cmp x10, x11
    b.ne 1f
    mov x11, #13
    mul x11, x11, x12
    umov x9, v12.d[0]
    umov x10, v12.d[1]
    cmp x9, x11
    b.ne 1f
    cmp x10, x11
    b.ne 1f
    mov x11, #14
    mul x11, x11, x12
    umov x9, v13.d[0]
    umov x10, v13.d[1]
    cmp x9, x11
    b.ne 1f
    cmp x10, x11
    b.ne 1f
    mov x11, #15
    mul x11, x11, x12
    umov x9, v14.d[0]
    umov x10, v14.d[1]
    cmp x9, x11
    b.ne 1f
    cmp x10, x11
    b.ne 1f
    mov x11, #16
    mul x11, x11, x12
    umov x9, v15.d[0]
    umov x10, v15.d[1]
    cmp x9, x11
    b.ne 1f
    cmp x10, x11
    b.ne 1f
    mov x11, #17
    mul x11, x11, x12
    umov x9, v16.d[0]
    umov x10, v16.d[1]
    cmp x9, x11
    b.ne 1f
    cmp x10, x11
    b.ne 1f
    mov x11, #18
    mul x11, x11, x12
    umov x9, v17.d[0]
    umov x10, v17.d[1]
    cmp x9, x11
    b.ne 1f
    cmp x10, x11
    b.ne 1f
    mov x11, #19
    mul x11, x11, x12
    umov x9, v18.d[0]
    umov x10, v18.d[1]
    cmp x9, x11
    b.ne 1f
    cmp x10, x11
    b.ne 1f
    mov x11, #20
    mul x11, x11, x12
    umov x9, v19.d[0]
    umov x10, v19.d[1]
    cmp x9, x11
    b.ne 1f
    cmp x10, x11
    b.ne 1f
    mov x11, #21
    mul x11, x11, x12
    umov x9, v20.d[0]
    umov x10, v20.d[1]
    cmp x9, x11
    b.ne 1f
    cmp x10, x11
    b.ne 1f
    mov x11, #22
    mul x11, x11, x12
    umov x9, v21.d[0]
    umov x10, v21.d[1]
    cmp x9, x11
    b.ne 1f
    cmp x10, x11
    b.ne 1f
    mov x11, #23
    mul x11, x11, x12
    umov x9, v22.d[0]
    umov x10, v22.d[1]
    cmp x9, x11
    b.ne 1f
    cmp x10, x11
    b.ne 1f
    mov x11, #24
    mul x11, x11, x12
    umov x9, v23.d[0]
    umov x10, v23.d[1]
    cmp x9, x11
    b.ne 1f
    cmp x10, x11
    b.ne 1f
    mov x11, #25
    mul x11, x11, x12
    umov x9, v24.d[0]
    umov x10, v24.d[1]
    cmp x9, x11
    b.ne 1f
    cmp x10, x11
    b.ne 1f
    mov x11, #26
    mul x11, x11, x12
    umov x9, v25.d[0]
    umov x10, v25.d[1]
    cmp x9, x11
    b.ne 1f
    cmp x10, x11
    b.ne 1f
    mov x11, #27
    mul x11, x11, x12
    umov x9, v26.d[0]
    umov x10, v26.d[1]
    cmp x9, x11
    b.ne 1f
    cmp x10, x11
    b.ne 1f
    mov x11, #28
    mul x11, x11, x12
    umov x9, v27.d[0]
    umov x10, v27.d[1]
    cmp x9, x11
    b.ne 1f
    cmp x10, x11
    b.ne 1f
    mov x11, #29
    mul x11, x11, x12
    umov x9, v28.d[0]
    umov x10, v28.d[1]
    cmp x9, x11
    b.ne 1f
    cmp x10, x11
    b.ne 1f
    mov x11, #30
    mul x11, x11, x12
    umov x9, v29.d[0]
    umov x10, v29.d[1]
    cmp x9, x11
    b.ne 1f
    cmp x10, x11
    b.ne 1f
    mov x11, #31
    mul x11, x11, x12
    umov x9, v30.d[0]
    umov x10, v30.d[1]
    cmp x9, x11
    b.ne 1f
    cmp x10, x11
    b.ne 1f
    mov x11, #32
    mul x11, x11, x12
    umov x9, v31.d[0]
    umov x10, v31.d[1]
    cmp x9, x11
    b.ne 1f
    cmp x10, x11
    b.ne 1f
    mov x9, #20755
    cmp x19, x9
    b.ne 1f
    mov x9, #20756
    cmp x20, x9
    b.ne 1f
    mov x9, #20757
    cmp x21, x9
    b.ne 1f
    mov x9, #20758
    cmp x22, x9
    b.ne 1f
    mov x9, #20759
    cmp x23, x9
    b.ne 1f
    mov x9, #20760
    cmp x24, x9
    b.ne 1f
    mov x9, #20761
    cmp x25, x9
    b.ne 1f
    mov x9, #20762
    cmp x26, x9
    b.ne 1f
    mov x9, #20763
    cmp x27, x9
    b.ne 1f
    mov x9, #20764
    cmp x28, x9
    b.ne 1f
    mov x9, #20765
    cmp x29, x9
    b.ne 1f
    mov x9, #0x5130
    cmp x30, x9
    b.ne 1f
    b 2f
1:  mov x0, #0
2:  ldp x9, x10, [sp, #160]
    msr fpcr, x9
    msr fpsr, x10
    ldp x19, x20, [sp, #0]
    ldp x21, x22, [sp, #16]
    ldp x23, x24, [sp, #32]
    ldp x25, x26, [sp, #48]
    ldp x27, x28, [sp, #64]
    ldp x29, x30, [sp, #80]
    ldp d8, d9, [sp, #96]
    ldp d10, d11, [sp, #112]
    ldp d12, d13, [sp, #128]
    ldp d14, d15, [sp, #144]
    add sp, sp, #176
    ret
.size s2a_fault_register_probe, .-s2a_fault_register_probe
.section .note.GNU-stack,"",%progbits
