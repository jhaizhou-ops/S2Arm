// 「同一配方只有一份」的装载判定，见 nvn_vk_pipe_once.h 的合同。
#include "nvn_vk_pipe_once.h"

int nvk_pipe_once_adopt(const nvk_pipe_once_ops *ops, const void *key, size_t key_bytes, void *fresh, void **out) {
    if (out) *out = NULL;
    if (!ops || !ops->find || !ops->link || !ops->destroy || !fresh) return -1;
    // 双检：建的过程中别的线程（预热线程 / 另一个提交线程）可能已经把同一配方装进去了。
    // 查到就销毁这份新建的——绝不出现两份同配方管线。
    void *existing = ops->find(ops->ctx, key, key_bytes);
    if (existing) {
        ops->destroy(ops->ctx, fresh);
        if (out) *out = existing;
        return 1;
    }
    ops->link(ops->ctx, fresh);
    if (out) *out = fresh;
    return 0;
}
