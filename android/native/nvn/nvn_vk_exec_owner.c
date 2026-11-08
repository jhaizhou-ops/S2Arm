#include "nvn_vk_exec_owner.h"

#include <string.h>

void nvk_exec_owner_init(struct nvk_exec_owner *o, uint64_t generation) {
    if (!o) return;
    memset(o, 0, sizeof *o);
    o->generation = generation;
    o->next_token = 1;   // 0 保留为“没有挂起令牌”
}

void nvk_exec_owner_set_generation(struct nvk_exec_owner *o, uint64_t generation) {
    if (!o) return;
    o->generation = generation;
    // 换代后旧包/旧令牌都不能再用；adapter 只会在没有执行包时换代，这里仍把挂起清掉，
    // 让任何迟到的 resume 走 STALE 而不是在旧上下文上恢复。
    if (o->suspended) o->stats.refused_stale++;   // 旧挂起不会再被恢复
    o->suspended = 0;
    o->suspend_token = 0;
}

void nvk_exec_owner_request_stop(struct nvk_exec_owner *o) {
    if (!o) return;
    if (o->suspended) o->stats.stop_during_suspend++;
    o->stop_requested = 1;
}

int nvk_exec_owner_enter(struct nvk_exec_owner *o, uint64_t thread) {
    if (!o) return NVK_EXEC_ENTER_STOPPED;
    if (o->stop_requested) return NVK_EXEC_ENTER_STOPPED;
    if (o->busy) {
        o->stats.wait_enters++;
        return NVK_EXEC_ENTER_WAIT;
    }
    o->busy = 1;
    o->owner_thread = thread;
    o->suspended = 0;
    o->suspend_token = 0;
    o->stats.enters++;
    return NVK_EXEC_ENTER_READY;
}

int nvk_exec_owner_leave(struct nvk_exec_owner *o, uint64_t thread) {
    if (!o) return -2;
    if (!o->busy) return -2;
    if (o->owner_thread != thread) return -1;
    if (o->suspended) {
        // 没恢复就退出：不能把挂起包当成正常完成。清掉状态并记协议错误。
        o->stats.leaves_while_suspended++;
        o->suspended = 0;
        o->suspend_token = 0;
    }
    o->busy = 0;
    o->owner_thread = 0;
    return 0;
}

uint64_t nvk_exec_owner_suspend(struct nvk_exec_owner *o, uint64_t thread) {
    if (!o) return 0;
    if (!o->busy || o->owner_thread != thread) {
        o->stats.refused_foreign++;
        return 0;
    }
    if (o->stop_requested) {
        o->stats.refused_after_stop++;
        return 0;
    }
    if (o->suspended) {
        o->stats.refused_double_suspend++;
        return 0;
    }
    if (o->next_token == 0) o->next_token = 1;
    o->suspend_token = o->next_token++;
    o->suspended = 1;
    o->stats.suspends++;
    return o->suspend_token;
}

int nvk_exec_owner_resume(struct nvk_exec_owner *o, uint64_t thread, uint64_t token) {
    if (!o) return NVK_EXEC_RESUME_NOT_OWNER;
    if (!o->busy || o->owner_thread != thread) {
        o->stats.refused_foreign++;
        return NVK_EXEC_RESUME_NOT_OWNER;
    }
    if (o->stop_requested) {
        o->stats.refused_after_stop++;
        if (o->suspended) {
            o->suspended = 0;
            o->suspend_token = 0;
        }
        return NVK_EXEC_RESUME_STOPPED;
    }
    if (!o->suspended) {
        o->stats.refused_double_resume++;
        return NVK_EXEC_RESUME_NOT_SUSPENDED;
    }
    if (token == 0 || token != o->suspend_token) {
        o->stats.refused_stale++;
        return NVK_EXEC_RESUME_STALE;
    }
    o->suspended = 0;
    o->suspend_token = 0;
    o->stats.resumes++;
    return NVK_EXEC_RESUME_OK;
}

int nvk_exec_owner_busy(const struct nvk_exec_owner *o) { return o ? o->busy : 0; }
int nvk_exec_owner_suspended(const struct nvk_exec_owner *o) { return o ? o->suspended : 0; }
int nvk_exec_owner_stop_requested(const struct nvk_exec_owner *o) { return o ? o->stop_requested : 1; }
uint64_t nvk_exec_owner_suspend_token(const struct nvk_exec_owner *o) { return o ? o->suspend_token : 0; }
uint64_t nvk_exec_owner_generation(const struct nvk_exec_owner *o) { return o ? o->generation : 0; }

void nvk_exec_owner_get_stats(const struct nvk_exec_owner *o, struct nvk_exec_owner_stats *out) {
    if (!out) return;
    if (!o) {
        memset(out, 0, sizeof *out);
        return;
    }
    *out = o->stats;
}
