// Direct-mode ABI 校验的唯一实现（契约 §2.1）。native owner、runtime 与测试共用；
// 任何一端需要“更宽松”的检查时必须改这里并补负例，不能各写一份。
#include "s2a_direct.h"

int32_t s2a_direct_status_init(s2a_direct_status_v1 *status) {
    if (!status) return S2A_DIRECT_RES_ARGUMENT;
    status->size = S2A_DIRECT_STATUS_SIZE;
    status->version = S2A_DIRECT_ABI;
    status->state = S2A_DIRECT_PREPARED;
    status->blockers = 0;
    status->error = 0;
    status->reserved = 0;
    return S2A_DIRECT_RES_OK;
}

int32_t s2a_direct_status_check(const s2a_direct_status_v1 *status) {
    if (!status) return S2A_DIRECT_RES_ARGUMENT;
    if (status->size < S2A_DIRECT_STATUS_SIZE) return S2A_DIRECT_RES_ARGUMENT;
    if (status->version != S2A_DIRECT_ABI) return S2A_DIRECT_RES_VERSION;
    if (status->state > S2A_DIRECT_FAILED) return S2A_DIRECT_RES_ARGUMENT;
    if (status->blockers & ~S2A_DIRECT_BLOCK_ALL) return S2A_DIRECT_RES_ARGUMENT;
    if (status->state == S2A_DIRECT_STOPPED && status->blockers) return S2A_DIRECT_RES_ARGUMENT;
    if (status->reserved) return S2A_DIRECT_RES_ARGUMENT;
    if (status->error > 0 || status->error < S2A_DIRECT_RES_INTERNAL) return S2A_DIRECT_RES_ARGUMENT;
    if (status->state == S2A_DIRECT_FAILED && status->error == 0) return S2A_DIRECT_RES_ARGUMENT;
    return S2A_DIRECT_RES_OK;
}

int32_t s2a_direct_table_check(const s2a_direct_api_v1 *table) {
    if (!table) return S2A_DIRECT_RES_ARGUMENT;
    if (table->size < S2A_DIRECT_TABLE_SIZE) return S2A_DIRECT_RES_ARGUMENT;
    if (table->version != S2A_DIRECT_ABI) return S2A_DIRECT_RES_VERSION;
    if (!table->session || !table->context) return S2A_DIRECT_RES_ARGUMENT;
    if (!table->activate || !table->request_stop || !table->query || !table->poll || !table->destroy)
        return S2A_DIRECT_RES_ARGUMENT;
    return S2A_DIRECT_RES_OK;
}
