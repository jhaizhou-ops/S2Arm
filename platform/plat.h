// Platform primitives shared by the native core.  The core includes only this
// header and never Mach / Bionic / Android headers directly.
//
// v1 implements the first batch (page size, time, TSD, signal/altstack, thread
// stack and handle).  v2 adds the memory/alias group (reserve, alias, protect);
// more capabilities are added only when the call site and the platform
// semantics are agreed.
#pragma once

#include <signal.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define S2A_PLAT_API_VERSION 2

// Opaque platform thread handle.  Apple stores a Mach thread port, Linux /
// Android a pthread_t.  Borrowed; valid until the thread exits.
typedef uintptr_t plat_thread_t;

enum {
    PLAT_FAULT_ONSTACK = 1u << 0,
    PLAT_FAULT_RESTART = 1u << 1,
};

// 0 = success, positive errno = failure.  ENOTSUP means the platform cannot
// provide the capability; the caller must take its documented fallback.
size_t plat_page_size(void);              // 0 = unavailable; process constant
uint64_t plat_now_ns(void);               // monotonic; never fails
// Safe 32-bit access; nonzero on invalid/unreadable/unwritable addresses.
// A failed read leaves *value unchanged.
int plat_mem_read32(uint64_t addr, uint32_t *value);
int plat_mem_write32(uint64_t addr, uint32_t value);
// Module-validated guest addresses: preserve access width and platform tracking.
uint8_t plat_guest_load8(uint64_t addr);
uint32_t plat_guest_load32(uint64_t addr);
uint64_t plat_guest_load64(uint64_t addr);
void plat_guest_store32(uint64_t addr, uint32_t value);
// Name the current worker for diagnostics; nonzero if unsupported or rejected.
int plat_thread_name(const char *name);

// Page protections.  PLAT_PROT_NONE is 0; unknown bits are EINVAL.
enum {
    PLAT_PROT_NONE  = 0,
    PLAT_PROT_READ  = 1u << 0,
    PLAT_PROT_WRITE = 1u << 1,
    PLAT_PROT_EXEC  = 1u << 2,
};

// Reserve [size] bytes, aligned to [alignment], below the exclusive [limit].
// The result is PROT_NONE; no existing mapping is overwritten.  size and
// alignment must be page multiples / powers of two.  out is unchanged on error.
int plat_vm_reserve(size_t size, size_t alignment, uint64_t limit, void **out);

// Map the same physical pages as [src] at the already-reserved [dst].
// [src] must be a shared-backed mapping and must outlive [dst].  [dst] may be
// replaced; callers must reserve it and not use any old contents.  [prot]
// applies to [dst] only.  ENOTSUP when the platform cannot alias.  On failure
// dst is restored to its PROT_NONE reservation; if that restoration itself
// fails, EIO is returned and dst must be treated as poisoned (do not use).
int plat_vm_alias(void *dst, const void *src, size_t size, uint32_t prot);

// Change protections of an existing mapping.
int plat_vm_protect(void *addr, size_t size, uint32_t prot);

// Optional platform-owned window layout. ENOTSUP selects the shared Apple/main
// layout; success returns the exact layout and required span without trimming.
struct s2a_layout;
int plat_layout_override(const char *npdm, uint32_t as_type, uint64_t sysres,
                         uint64_t program_id, uint64_t window_base, uint64_t window_size,
                         struct s2a_layout *out, uint64_t *need, char *detail, size_t detail_size);

// TSD: the core writes each key's slot offset into the rewritten module's key
// page, and reads another thread's slot from its base + offset.
int plat_tsd_init(void);                  // after pthread_key_create, before key page
uint64_t plat_tsd_base(void);             // current thread; 0 = unavailable
int plat_tsd_offset(uint32_t key, uint64_t *out);  // 0 / errno; *out != 0

// Signal installation.  SA_SIGINFO is always set; ONSTACK / RESTART follow the
// flags.  Android additionally forces SA_ONSTACK because guest threads run on
// their own small alternate stack.
int plat_fault_install(int sig, void (*fn)(int, siginfo_t *, void *), unsigned flags);

// Per-thread guest alternate stack: 256 KiB plus one guard page.  Idempotent.
int plat_fault_altstack_init(void);
void plat_fault_altstack_free(void);
// 备用栈内存来源（可选，10-24）：原生层起局时注入窗口尾部分配，不注入时用 mmap。alloc(len) 回可读写内存或 NULL；release(p, len) 还回
void plat_fault_altstack_set_mem(void *(*alloc)(size_t), void (*release)(void *, size_t));

// Current thread's stack bounds: low = bottom, high = top.
int plat_thread_stack_bounds(uintptr_t *low, uintptr_t *high);
int plat_thread_self(plat_thread_t *out);

#ifdef __cplusplus
}
#endif
