// Assembly-side TSD base access.  Included by runtime/src/entry.S.
//
// The rewritten guest code loads the TSD base itself (the rewriter emits the
// target-specific sequence into the module), but the host's gate / stack-switch
// stubs also need it on every entry.  Keep the two sequences here so the .S
// file stays target-independent.
//
// Apple: tpidrro_el0 is the pthread TSD array; slots are base + key * 8.
// Android: tpidr_el0 points at the thread control block; TCB[-1] is
// bionic_tls, whose first member is the pthread key table.  The loader writes
// the measured slot offsets into the key page; this macro only supplies the
// base.
#pragma once

#if defined(__APPLE__)

#define PLAT_TSD_BASE(reg)        mrs reg, tpidrro_el0
#define PLAT_TSD_BASE_SECOND(reg)

// Mach-O symbols carry a leading underscore; ELF symbols do not.
#define PLAT_ASM_SYM(sym)         _##sym
#define PLAT_ASM_ADRP(reg, sym)   adrp reg, sym@PAGE
#define PLAT_ASM_ADD(reg, sym)    add reg, reg, sym@PAGEOFF
#define PLAT_ASM_LDR(reg, base, sym) ldr reg, [base, sym@PAGEOFF]

#elif defined(__ANDROID__)

#define PLAT_TSD_BASE(reg)        mrs reg, tpidr_el0
#define PLAT_TSD_BASE_SECOND(reg) ldur reg, [reg, #-8]

#define PLAT_ASM_SYM(sym)         sym
#define PLAT_ASM_ADRP(reg, sym)   adrp reg, sym
#define PLAT_ASM_ADD(reg, sym)    add reg, reg, :lo12:sym
#define PLAT_ASM_LDR(reg, base, sym) ldr reg, [base, :lo12:sym]

#else

#error "platform/plat_asm.h: unsupported target (expected __APPLE__ or __ANDROID__)"

#endif
