// Gate target for the rewrite self-test: rewritten `svc` blocks load this from
// the KGATE slot and `blr x30` to it, so x30 holds the gate return point that
// gates.tsv records. Returning it in x0 lets the test check the whole path.
    .text
    .p2align 2
    .globl s2a_selftest_gate
    .type s2a_selftest_gate, %function
s2a_selftest_gate:
    hint #34            // bti c
    mov x0, x30
    ret
    .size s2a_selftest_gate, . - s2a_selftest_gate

    .section .note.GNU-stack, "", %progbits
