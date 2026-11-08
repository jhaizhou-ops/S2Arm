#include "registry.h"
#include "runtime.h"
#include <errno.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

// 只记录实际 alias 涉及的映射。object/offset 保存物理关系，删除中介 VA 不丢链式别名。
typedef struct { uint64_t addr, size, object, offset; } mapping;
typedef struct { mapping *items; size_t count, capacity; } mappings;
typedef struct { uint64_t addr, size; } range;
static pthread_mutex_t registry_mutex = PTHREAD_MUTEX_INITIALIZER;
static mappings live, planned;
static range *gpu; static size_t gpu_count;
static uint64_t next_object;
static struct { range destination, source; int active; } pending;

static int overlaps(uint64_t a, uint64_t n, uint64_t b, uint64_t m) {
    return a < b + m && b < a + n;
}
static int compare_range(const void *left, const void *right) {
    uint64_t a = ((const range *)left)->addr, b = ((const range *)right)->addr;
    return a < b ? -1 : a > b;
}
static int append(mappings *list, mapping item) {
    if (list->count == list->capacity) {
        size_t capacity = list->capacity ? list->capacity * 2 : 16;
        if (capacity < list->capacity || capacity > SIZE_MAX / sizeof(mapping)) return ENOMEM;
        void *items = realloc(list->items, capacity * sizeof(mapping));
        if (!items) return ENOMEM;
        list->items = items; list->capacity = capacity;
    }
    list->items[list->count++] = item;
    return 0;
}
static int copy_without(mappings *out, const mappings *in, uint64_t addr, uint64_t size) {
    uint64_t end = addr + size;
    for (size_t i = 0; i < in->count; i++) {
        mapping m = in->items[i]; int error;
        if (!overlaps(m.addr, m.size, addr, size)) { if ((error = append(out, m))) return error; continue; }
        if (m.addr < addr && (error = append(out, (mapping){m.addr, addr - m.addr, m.object, m.offset}))) return error;
        if (m.addr + m.size > end && (error = append(out, (mapping){end, m.addr + m.size - end, m.object, m.offset + end - m.addr}))) return error;
    }
    return 0;
}
static int is_alias(uint64_t addr, uint64_t size) {
    for (size_t i = 0; i < live.count; i++) {
        mapping a = live.items[i];
        if (!overlaps(addr, size, a.addr, a.size)) continue;
        uint64_t start = addr > a.addr ? addr : a.addr;
        uint64_t end = addr + size < a.addr + a.size ? addr + size : a.addr + a.size;
        for (size_t j = 0; j < live.count; j++) {
            mapping b = live.items[j];
            if (i != j && a.object == b.object && overlaps(a.offset + start - a.addr, end - start, b.offset, b.size)) return 1;
        }
    }
    return 0;
}
int s2a_track_gpu_reserve(uint64_t addr, uint64_t size) {
    if (!size || size > UINT64_MAX - addr) return EINVAL;
    pthread_mutex_lock(&registry_mutex);
    int error = 0;
    if (pending.active && (overlaps(addr, size, pending.destination.addr, pending.destination.size)
        || (pending.source.size && overlaps(addr, size, pending.source.addr, pending.source.size)))) error = EBUSY;
    else if (is_alias(addr, size)) error = EOPNOTSUPP;
    if (!error) {
        // session-lifetime reservation：合并重叠/相邻范围，重复跟踪不增长表。
        if (gpu_count == SIZE_MAX / sizeof(range) - 1) error = ENOMEM;
        else {
            range *updated = malloc((gpu_count + 1) * sizeof(range));
            if (!updated) error = ENOMEM;
            else {
                if (gpu_count) memcpy(updated, gpu, gpu_count * sizeof(range));
                updated[gpu_count] = (range){addr, size};
                qsort(updated, gpu_count + 1, sizeof(range), compare_range);
                size_t count = 0;
                for (size_t i = 0; i <= gpu_count; i++) {
                    range item = updated[i];
                    if (count && item.addr <= updated[count - 1].addr + updated[count - 1].size) {
                        uint64_t end = item.addr + item.size;
                        if (end > updated[count - 1].addr + updated[count - 1].size) updated[count - 1].size = end - updated[count - 1].addr;
                    } else updated[count++] = item;
                }
                free(gpu); gpu = updated; gpu_count = count;
            }
        }
    }
    pthread_mutex_unlock(&registry_mutex);
    return error;
}
int s2a_track_registry_begin(uint64_t addr, uint64_t size, uint64_t source) {
    pthread_mutex_lock(&registry_mutex);
    int error = pending.active ? EBUSY : 0;
    if (!error && source) for (size_t i = 0; i < gpu_count; i++) {
        if (overlaps(addr, size, gpu[i].addr, gpu[i].size) || overlaps(source, size, gpu[i].addr, gpu[i].size)) { error = EOPNOTSUPP; break; }
    }
    if (!error && source && overlaps(addr, size, source, size)) error = EINVAL;
    mappings materialized = {0}, aliases = {0}, result = {0};
    // 所有分配在内核修改前完成；成功 commit 无分配失败窗口。
    for (size_t i = 0; !error && i < live.count; i++) error = append(&materialized, live.items[i]);
    for (uint64_t cursor = source, end = source + (source ? size : 0); !error && cursor < end;) {
        mapping *found = NULL; uint64_t next = end;
        for (size_t i = 0; i < materialized.count; i++) {
            mapping *m = &materialized.items[i];
            if (m->addr <= cursor && cursor < m->addr + m->size) { found = m; break; }
            if (m->addr > cursor && m->addr < next) next = m->addr;
        }
        mapping part;
        if (found) {
            if (found->addr + found->size < next) next = found->addr + found->size;
            part = (mapping){cursor, next - cursor, found->object, found->offset + cursor - found->addr};
        } else {
            if (next_object == UINT64_MAX) { error = EOVERFLOW; break; }
            part = (mapping){cursor, next - cursor, ++next_object, 0};
            error = append(&materialized, part);
        }
        part.addr = addr + cursor - source;
        if (!error) error = append(&aliases, part);
        cursor = next;
    }
    if (!error) error = copy_without(&result, &materialized, addr, size);
    for (size_t i = 0; !error && i < aliases.count; i++) error = append(&result, aliases.items[i]);
    if (!error) {
        planned = result; result = (mappings){0};
        pending.destination = (range){addr, size}; pending.source = (range){source, source ? size : 0}; pending.active = 1;
    }
    free(materialized.items); free(aliases.items); free(result.items);
    pthread_mutex_unlock(&registry_mutex);
    return error;
}
void s2a_track_registry_finish(int committed) {
    pthread_mutex_lock(&registry_mutex);
    if (committed) { free(live.items); live = planned; }
    else free(planned.items);
    planned = (mappings){0}; pending.active = 0;
    pthread_mutex_unlock(&registry_mutex);
}
