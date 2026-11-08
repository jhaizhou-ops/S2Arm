#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Independent expectations for the T221 XMAD cases (integer/xmad_*.json).

A small interpreter over the cases' readable instruction text, all results mod 2^32. XMAD is a 16 x 16 multiply-add:
a = the low half of A (or the high half with .H1), zero-extended (.U16, the default) or sign-extended (.S16); b likewise from B
(the I form's B is an unsigned 16-bit immediate, extended the same way, never .H1); product = a * b, shifted left 16 with .PSL;
the C term is C (default), C & 0xffff (.CLO), C >> 16 (.CHI) or C + (B << 16) (.CBCC, B the whole 32-bit operand);
result = product + C term, and .MRG replaces its high half with B's low half: (result & 0xffff) | (B << 16).
Provenance, stated plainly: envytools gm107.c (f102b82381f3f11cee113d16374c87091db039d9, lines 1457 / 1465 / 1580 / 2031 / 2050 /
2064 / 2149) gives only the fields and modifier names. The per-mode rules above (.H1 / .S16 extension, .PSL, .CLO / .CHI, .CBCC,
.MRG) were written AFTER reading the translator under test (Ryujinx InstEmitIntegerArithmetic.cs EmitXmad), so for the single-mode
cases (xmad_r, xmad_i, xmad_cbuf_zero) this model is not independent of it: they catch translator regressions, not a misreading
the two would share. The composite cases are independent: each is an instruction sequence whose result is plain integer arithmetic,
checked word by word against that arithmetic rather than the per-mode rules:
  xmad_mul32  - XMAD; XMAD.MRG (B.H1); XMAD.PSL.CBCC (A.H1, MRG result .H1)  = a * b      mod 2^32;
  xmad_mad32  - Mesa nouveau's MUL / MAD lowering (handleMULMAD, nv50_ir_peephole.cpp lines 2491-2532 of Mesa 24.0.2 as vendored in
                VirtualBox c826979b27a75c3ca8fbc28f60cbb38c8a789ba8): XMAD b,a,c; XMAD.MRG b,a.H1,0; XMAD.PSL.CBCC b.H1,t1.H1,t0
                                                                              = a * b + c  mod 2^32;
  xmad_muli16 - Mesa's multiply by a 16-bit immediate (same file, lines 1030-1036): XMAD a,imm,c; XMAD.PSL a.H1,imm,t
                                                                              = a * imm + c mod 2^32.
Mesa is an independent compiler that emits these sequences for integer multiplies on Maxwell and later.
Caveat (#1159 slice 7): XmadOptimizer recognises exactly these three sequences and rewrites them into a multiply (IR evidence), so
their results come from the optimizer's rewrite, not from the per-mode XMAD emitter. A per-mode mistake that changes the emitted IR
shape stops the rewrite and also fails them, but a misreading shared by the emitter and the optimizer's matcher would not show.
The *_split cases (xmad_mul32_split / xmad_mad32_split / xmad_muli16_split) store each intermediate to its own scratch word
(w40-w51; xmad_muli16_split uses w40, w42, ..., w50) and load it back, which XmadOptimizer cannot match (IR unchanged), so the per-mode
emitter computes the result; their result words 8-13 are the independent check of .H1 / .PSL / .MRG / .CBCC / CFULL (R form) and
.H1 / .PSL (I form). The scratch words' expectations come from the per-mode model above, so they are not independent. Reusing one scratch word for both
intermediates hits the known-red #1414 (a single-use load is moved past a later store to the same address). .CSFU, .X, .CC are outside the modelled domain (rejected), as is the C form's
.CBCC and the Rc form's .PSL / .MRG (their encodings have no such field).
Immediates are 0..0xffff; c[0][offset] reads the framework's zero-filled C0. MOV32I sets a register.
It imports no encoder, translator, SPIR-V or produced result.
Usage: python3 tests/shader_cases/integer/xmad_reference_test.py
"""
import copy
import json
from pathlib import Path
import re

M = 0xffffffff


def half(v, high, signed):
    h = (v >> 16) & 0xffff if high else v & 0xffff
    return (h - 0x10000 if signed and h & 0x8000 else h) & M


def execute(instructions, initial):
    if len(initial) != 64 or any(type(v) is not int or not 0 <= v <= M for v in initial):
        raise ValueError("reference domain is exactly 64 uint32 words")
    memory = list(initial)
    registers = {255: 0}

    def number(token):
        if token == "RZ":
            return 255
        if not re.fullmatch(r"R\d+", token) or not 0 <= int(token[1:]) < 255:
            raise ValueError("bad register " + token)
        return int(token[1:])

    def read(token):
        n = number(token)
        if n not in registers:
            raise ValueError("undefined reference register " + token)
        return registers[n]

    def write(token, value):
        if number(token) != 255:
            registers[number(token)] = value & M

    def operand(token, allow_imm):
        """(32-bit value, kind) of a register / zero-C0 c[0][x] / 16-bit immediate."""
        if token.startswith("R"):
            return read(token), "r"
        if re.fullmatch(r"c\[0\]\[\w+\]", token):
            return 0, "c"   # framework C0: 64 KiB of zeros
        v = int(token, 0)
        if not allow_imm or not 0 <= v <= 0xffff:
            raise ValueError("XMAD immediate is an unsigned 16-bit B only: " + token)
        return v, "i"

    def word(base, offset):
        if read(base) or read("R" + str(number(base) + 1)):
            raise ValueError("reference uses the zero C0 base address only")
        pos = int(offset, 0)
        if pos % 4 or not 0 <= pos <= 252:
            raise ValueError("reference uses only aligned, in-range uint32 access")
        return pos // 4

    for index, line in enumerate(instructions):
        op, *a = line.split()
        m = op.split(".")
        if op == "LDC64" and a[1:] == ["0", "0"] and number(a[0]) < 254:
            write(a[0], 0)
            write("R" + str(number(a[0]) + 1), 0)
        elif op == "LDG32" and len(a) == 3:
            write(a[0], memory[word(a[1], a[2])])
        elif op == "STG32" and len(a) == 3:
            memory[word(a[1], a[2])] = read(a[0])
        elif op == "MOV32I" and len(a) == 2:
            write(a[0], int(a[1], 0))
        elif m[0] == "XMAD" and len(a) == 4:
            f = m[1:]
            signs = f[:2] if f[:2] and f[0] in ("U16", "S16") else []
            if signs and (len(signs) < 2 or signs[1] not in ("U16", "S16")):
                raise ValueError("XMAD takes both signedness modifiers or neither: " + line)
            rest = f[len(signs):]
            if set(rest) - {"CLO", "CHI", "CBCC", "PSL", "MRG"} or len(set(rest)) != len(rest) or len(set(rest) & {"CLO", "CHI", "CBCC"}) > 1:
                raise ValueError("outside the modelled XMAD modifiers: " + line)
            sa, sb = (signs[0] == "S16", signs[1] == "S16") if signs else (False, False)
            ha, ta = a[1].endswith(".H1"), a[1].removesuffix(".H1")
            hb, tb = a[2].endswith(".H1"), a[2].removesuffix(".H1")
            if not ta.startswith("R") or a[3].endswith(".H1"):
                raise ValueError("XMAD A is a register and C takes no .H1: " + line)
            A = read(ta)
            B, kb = operand(tb, True)
            C, kc = operand(a[3], False)
            if kb == "i" and hb:
                raise ValueError("the I form's immediate has no .H1: " + line)
            if kc == "c" and (kb != "r" or "PSL" in rest or "MRG" in rest or "CBCC" in rest):
                raise ValueError("Rc form: B a register, no .PSL / .MRG / .CBCC: " + line)
            if kb == "c" and "CBCC" in rest:
                raise ValueError("C form has no .CBCC: " + line)
            product = half(A, ha, sa) * half(B, hb, sb) & M
            if "PSL" in rest:
                product = product << 16 & M
            cterm = C & 0xffff if "CLO" in rest else C >> 16 if "CHI" in rest else C + (B << 16) if "CBCC" in rest else C
            result = (product + cterm) & M
            if "MRG" in rest:
                result = (result & 0xffff) | (B << 16 & M)
            write(a[0], result)
        elif op == "EXIT" and not a and index == len(instructions) - 1:
            return memory
        else:
            raise ValueError("outside reference instruction domain: " + line)
    raise ValueError("explicit final EXIT required")


def verify(case):
    if case["stage"] != "compute" or set(case["inputs"]) != {"storage0"}:
        raise ValueError("reference is single-invocation storage0 only")
    actual = execute(case["instructions"], case["inputs"]["storage0"])
    if actual != case["expected"]:
        raise AssertionError("independent expectation mismatch: " + case["id"])
    return actual


MUL32_IDIOM = ["XMAD R40 R{a} R{b} RZ", "XMAD.MRG R41 R{a} R{b}.H1 RZ", "XMAD.PSL.CBCC R{d} R{a}.H1 R41.H1 R40"]
# Mesa 24.0.2 nouveau handleMULMAD (mkOp3(OP_XMAD, tmp0, b, a, c); MRG | H1(1) on (b, a, 0); PSL | CBCC | H1(0) | H1(1) on (b, tmp1, tmp0))
MAD32_IDIOM = ["XMAD R40 R{b} R{a} R{c}", "XMAD.MRG R41 R{b} R{a}.H1 RZ", "XMAD.PSL.CBCC R{d} R{b}.H1 R41.H1 R40"]
# Mesa 24.0.2 nouveau multiply by an immediate 0..0xffff (XMAD a, imm, c; PSL | H1(0) on (a, imm, tmp))
MULI16_IDIOM = ["XMAD R40 R{a} {imm} R{c}", "XMAD.PSL R{d} R{a}.H1 {imm} R40"]
# *_split: the same sequences with every intermediate stored to its own scratch word and loaded back before its use. The arithmetic
# is unchanged, but the def chain XmadOptimizer pattern-matches is broken, so the translator's per-mode XMAD code (not the
# optimizer's rewritten multiply) produces the result; the IR evidence shows XmadOptimizer leaves these cases unchanged.
# (two distinct scratch words per sequence: reusing one word for both intermediates hits the known-red load / store ordering bug)
MUL32_SPLIT = ["XMAD R40 R{a} R{b} RZ", "STG32 R40 R0 {o1}", "LDG32 R42 R0 {o1}", "XMAD.MRG R41 R{a} R{b}.H1 RZ", "STG32 R41 R0 {o2}",
               "LDG32 R43 R0 {o2}", "XMAD.PSL.CBCC R{d} R{a}.H1 R43.H1 R42"]
MAD32_SPLIT = ["XMAD R40 R{b} R{a} R{c}", "STG32 R40 R0 {o1}", "LDG32 R42 R0 {o1}", "XMAD.MRG R41 R{b} R{a}.H1 RZ", "STG32 R41 R0 {o2}",
               "LDG32 R43 R0 {o2}", "XMAD.PSL.CBCC R{d} R{b}.H1 R43.H1 R42"]
MULI16_SPLIT = ["XMAD R40 R{a} {imm} R{c}", "STG32 R40 R0 {o1}", "LDG32 R42 R0 {o1}", "XMAD.PSL R{d} R{a}.H1 {imm} R42"]
# xmad_mul32: result word -> (input word of a, input word of b); expectation must equal a * b mod 2^32
MUL32_WORDS = {8: (5, 7), 9: (1, 1), 10: (4, 2), 11: (6, 3), 12: (7, 7), 13: (0, 5)}
# xmad_mad32: result word -> (a, b, c) input words, expectation = a * b + c mod 2^32
MAD32_WORDS = {8: (5, 7, 6), 9: (1, 1, 1), 10: (4, 2, 3), 11: (7, 5, 0), 12: (3, 4, 7), 13: (6, 6, 2)}
# xmad_muli16: result word -> (a input word, immediate, c input word), expectation = a * imm + c mod 2^32
MULI16_WORDS = {8: (5, 0x0000, 7), 9: (5, 0xffff, 0), 10: (1, 0xffff, 1), 11: (7, 0x1234, 6), 12: (4, 0x8000, 3), 13: (2, 0x0003, 5)}


def main():
    # Hand-computed anchors, so a slip in the interpreter itself cannot pass silently.
    run = lambda lines, regs: execute(["LDC64 R0 0 0"] + [f"MOV32I R{r} {v:#x}" for r, v in regs.items()] + lines + ["STG32 R9 R0 0", "EXIT"], [0] * 64)[0]
    x = {2: 0x00010003, 3: 0x00020005, 4: 0xabcd0010}
    assert run(["XMAD R9 R2 R3 RZ"], x) == 15 and run(["XMAD R9 R2.H1 R3.H1 RZ"], x) == 2
    assert run(["XMAD.S16.S16 R9 R2 R3 RZ"], {2: 0xffff, 3: 2}) == 0xfffffffe and run(["XMAD R9 R2 R3 RZ"], {2: 0xffff, 3: 2}) == 0x1fffe
    assert run(["XMAD.PSL R9 R2 R3 RZ"], x) == 0xf0000 and run(["XMAD.CHI R9 R2 R3 R4"], x) == 15 + 0xabcd
    assert run(["XMAD.CLO R9 R2 R3 R4"], x) == 15 + 0x10 and run(["XMAD.MRG R9 R2 R3 RZ"], x) == 0x0005000f
    assert run(["XMAD.CBCC R9 R2 R3 R4"], x) == (15 + 0xabcd0010 + 0x00050000) & M
    assert run(["XMAD.U16.S16 R9 R2 0xffff RZ"], {2: 3}) == 0xfffffffd and run(["XMAD R9 R2 0xffff RZ"], {2: 3}) == 0x2fffd
    assert run(["XMAD R9 R2 c[0][0x10] R4"], x) == 0xabcd0010 and run(["XMAD R9 R2 R3 c[0][0x10]"], x) == 15
    for av, bv in ((0x12345678, 0xdeadbeef), (M, M), (0x80000001, 0x55555555), (0x0001ffff, 0xfffe0003), (0, 7)):
        got = run([s.format(a=2, b=3, d=9) for s in MUL32_IDIOM], {2: av, 3: bv})
        assert got == (av * bv) & M, ("mul32 idiom", hex(av), hex(bv), hex(got))
    for av, bv, cv in ((0x12345678, 0xdeadbeef, 0x0f0f00ff), (M, M, M), (0x80000001, 0x55555555, 0xaaaaaaaa), (0, 0, 7)):
        got = run([s.format(a=2, b=3, c=4, d=9) for s in MAD32_IDIOM], {2: av, 3: bv, 4: cv})
        assert got == (av * bv + cv) & M, ("mad32 idiom", hex(av), hex(bv), hex(cv), hex(got))
    for av, bv in ((0x12345678, 0xdeadbeef), (M, 3)):
        got = execute(["LDC64 R0 0 0", f"MOV32I R2 {av:#x}", f"MOV32I R3 {bv:#x}"] + [s.format(a=2, b=3, d=9, o1=4, o2=8) for s in MUL32_SPLIT] + ["STG32 R9 R0 0", "EXIT"], [0] * 64)[0]
        assert got == (av * bv) & M, ("mul32 split", hex(av), hex(bv), hex(got))
    for av, imm, cv in ((0x12345678, 0xffff, 0xdeadbeef), (M, 0x8000, 1), (0x0001ffff, 0, 5), (0x80000001, 0x1234, M)):
        got = run([s.format(a=2, imm=hex(imm), c=4, d=9) for s in MULI16_IDIOM], {2: av, 4: cv})
        assert got == (av * imm + cv) & M, ("muli16 idiom", hex(av), hex(imm), hex(cv), hex(got))
    paths = sorted(Path(__file__).parent.glob("xmad_*.json"))
    if not paths:
        raise ValueError("no original XMAD cases")
    for path in paths:
        case = json.loads(path.read_text())
        actual = verify(case)
        inp = case["inputs"]["storage0"]
        mul = {w: (inp[i] * inp[j]) & M for w, (i, j) in MUL32_WORDS.items()}
        mad = {w: (inp[i] * inp[j] + inp[k]) & M for w, (i, j, k) in MAD32_WORDS.items()}
        muli = {w: (inp[i] * imm + inp[k]) & M for w, (i, imm, k) in MULI16_WORDS.items()}
        arithmetic = {"integer/xmad_mul32": mul, "integer/xmad_mad32": mad, "integer/xmad_muli16": muli,
                      "integer/xmad_mul32_split": mul, "integer/xmad_mad32_split": mad, "integer/xmad_muli16_split": muli}.get(case["id"], {})
        for w, want in arithmetic.items():
            if case["expected"][w] != want:
                raise AssertionError(f"{case['id']} word {w} is not the plain integer result {want:#010x}")
        changed = [i for i, (p, q) in enumerate(zip(actual, case["inputs"]["storage0"])) if p != q]
        for i in changed:
            bad = copy.deepcopy(case)
            bad["expected"][i] ^= 1
            try:
                verify(bad)
            except AssertionError:
                pass
            else:
                raise AssertionError("wrong expectation survived: %s word %d" % (case["id"], i))
        print("reference %s: 64 words match; %d result words, each one-bit wrong expectation rejected" % (case["id"], len(changed)))
    for bad_line in ("XMAD.CSFU R3 R2 R2 R2", "XMAD.S16 R3 R2 R2 R2", "XMAD R3 R2 0x10000 R2", "XMAD R3 R2 0x10.H1 R2",
                     "XMAD.PSL R3 R2 R2 c[0][0x10]", "XMAD.CBCC R3 R2 c[0][0x10] R2", "XMAD R3 R2 R2 R2.H1", "XMAD.CLO.CHI R3 R2 R2 R2"):
        try:
            execute(["LDC64 R0 0 0", "MOV32I R2 1", bad_line, "EXIT"], [0] * 64)
        except ValueError:
            pass
        else:
            raise AssertionError("instruction outside the modelled domain accepted: " + bad_line)
    print("reference: %d XMAD cases; composite sequences (mul32 / Mesa mad32 / Mesa muli16) checked against plain integer arithmetic; out-of-domain forms rejected" % len(paths))


if __name__ == "__main__":
    main()
