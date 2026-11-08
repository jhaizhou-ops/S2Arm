// Keep libc's ELF types out of native.h, which currently defines its own ELF
// loader structures for Apple. This helper reads the actual loaded ELF images.
#define _GNU_SOURCE
#include <link.h>
#include <stdint.h>

struct host_code_query { uint64_t address; int found; };
static int host_code_segment(struct dl_phdr_info *info, size_t size, void *opaque) {
    (void)size;
    struct host_code_query *query = opaque;
    for (ElfW(Half) i = 0; i < info->dlpi_phnum; ++i) {
        const ElfW(Phdr) *p = &info->dlpi_phdr[i];
        if (p->p_type != PT_LOAD || !(p->p_flags & PF_X)) continue;
        uint64_t start = info->dlpi_addr + p->p_vaddr;
        if (start >= info->dlpi_addr && query->address >= start && query->address - start < p->p_memsz) {
            query->found = 1; return 1;
        }
    }
    return 0;
}
int s2a_android_is_host_code(uint64_t address) {
    struct host_code_query query = {address, 0};
    dl_iterate_phdr(host_code_segment, &query);
    return query.found;
}
