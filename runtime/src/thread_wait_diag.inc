// 由 thread.c 在句柄表后引入；所有 *_locked 辅助函数要求持有 G。
// 独立 S2A_WAIT_DIAG=1 开启观察；诊断自身不改变等待策略。
// 固定容量只保留尚未取出打印的记录；G 内不分配、不调用 logger 或 I/O。
// v1 begin 字段：0x18 count=句柄数 ns=超时；0x1c object=key(x1) handle=w2 ns=x3；
// 0x1a handle=w0 object=key(x1) ns=-1 count=-1；
// 0x34 object=key(x0) kind=w1 count=(int)w2 ns=x3。object 不暴露原始地址。
#define WD_CAP 1024
#define WD_KEYS 128
#define WD_BATCH 8
enum { WD_BEGIN = 1, WD_HANDLE, WD_BLOCK, WD_CONDITION, WD_WAKE, WD_EVENT, WD_END, WD_CV_SIGNAL };
typedef struct {
    uint64_t seq, wait, tid, mono, real, pc, lr, object, source_tid, elapsed;
    int64_t ns, result;
    uint64_t deadline;
    uint64_t request, deadline_mono;
    unsigned sends, signal_seen, signal_native;
    int activity, started, exited, in_svc, paused_ack, pmach, wait_safe, paused, send_error;
    uint32_t handle;
    int event, svc, source_svc, kind, index, count, state;
    char pc_module[16], lr_module[16];
} wait_diag_record_t;
static wait_diag_record_t g_wd[WD_CAP];
static size_t g_wd_used, g_wd_read;
static uint64_t g_wd_seq, g_wd_wait, g_wd_dropped, g_wd_emitted, g_wd_object, g_wd_key_overflow;
static struct { uint64_t address, token; } g_wd_keys[WD_KEYS];
static _Atomic int g_wd_enabled;
static _Thread_local int g_wd_source_svc;
#ifdef S2A_UNIT_TEST
static _Thread_local int g_wd_test_source_svc;
#endif
static unsigned g_wd_reports;
static uint64_t g_wd_pause_cond_suppressed;
static int g_wd_cap_reported;
static atomic_flag g_wd_flushing = ATOMIC_FLAG_INIT;
// 由线程子系统唯一初始化；热路径只读原子开关，0/其他值都关闭。
static void wait_diag_init(void) {
    const char *value=getenv("S2A_WAIT_DIAG");
    atomic_store_explicit(&g_wd_enabled,value && !strcmp(value,"1"),memory_order_release);
}
static int wait_diag_on(void) { return atomic_load_explicit(&g_wd_enabled,memory_order_relaxed); }
static uint64_t wait_diag_clock(clockid_t clock) {
    struct timespec ts;
    if (clock_gettime(clock, &ts)) return 0;
    return (uint64_t)ts.tv_sec * 1000000000ull + (uint64_t)ts.tv_nsec;
}
static void wait_diag_pc(uint64_t pc, char name[16], uint64_t *offset) {
    module_t *m = pc ? module_of((void *)(uintptr_t)pc) : NULL;
    *offset = m ? pc - (uintptr_t)m->base : 0;
    memset(name, 0, 16);
    if (!m) { name[0] = '?'; return; }
    for (int i = 0; i < 15 && m->name[i]; ++i) {
        char c = m->name[i];
        name[i] = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
            (c >= '0' && c <= '9') || c == '_' || c == '-' ? c : '_';
    }
}
static uint64_t wait_diag_key_locked(uint64_t address) {
    for (int i = 0; i < WD_KEYS; ++i) {
        if (g_wd_keys[i].address == address && address) return g_wd_keys[i].token;
        if (!g_wd_keys[i].address && address) {
            g_wd_keys[i].address = address;
            return g_wd_keys[i].token = ++g_wd_object;
        }
    }
    ++g_wd_key_overflow; return 0; // 身份未知，绝不输出地址。
}
static uint64_t wait_diag_event_id_locked(event_t *e) {
    if (!e->trace_id) e->trace_id = ++g_wd_object;
    return e->trace_id; // 代号保存在事件自身，分配器复用时取得新身份。
}
static wait_diag_record_t *wait_diag_add_locked(thr_t *t, int event) {
    uint64_t seq = ++g_wd_seq;
    if (g_wd_used == WD_CAP) { g_wd_read=(g_wd_read+1)%WD_CAP; --g_wd_used; ++g_wd_dropped; }
    wait_diag_record_t *r = &g_wd[(g_wd_read+g_wd_used++)%WD_CAP];
    *r = (wait_diag_record_t){.seq=seq, .wait=t->trace_wait, .tid=t->id,
        .mono=wait_diag_clock(CLOCK_MONOTONIC), .real=wait_diag_clock(CLOCK_REALTIME),
        .event=event, .svc=t->last_svc};
    return r;
}
static void wait_diag_begin_locked(thr_t *t, int svc, const uint64_t *regs) {
    t->trace_wait = ++g_wd_wait;
    t->trace_start = wait_diag_clock(CLOCK_MONOTONIC);
    wait_diag_record_t *r = wait_diag_add_locked(t, WD_BEGIN);
    if (r) {
        r->svc=svc; r->ns=(int64_t)regs[3];
        wait_diag_pc(t->svc_pc, r->pc_module, &r->pc);
        wait_diag_pc(regs[30], r->lr_module, &r->lr);
        if (svc == 0x1c) { r->object=wait_diag_key_locked(regs[1]); r->handle=(uint32_t)regs[2]; }
        else if (svc == 0x1a) { r->handle=(uint32_t)regs[0]; r->object=wait_diag_key_locked(regs[1]); r->ns=-1; r->count=-1; }
        else if (svc == 0x34) { r->object=wait_diag_key_locked(regs[0]); r->kind=(int)(uint32_t)regs[1]; r->count=(int32_t)regs[2]; }
        else r->count=(int)regs[2];
    }
    if (svc != 0x18 || (uint64_t)regs[2] > 64) return;
    const uint32_t *handles = (const uint32_t *)(uintptr_t)regs[1];
    for (int j = 0; j < (int)regs[2]; ++j) {
        r=wait_diag_add_locked(t, WD_HANDLE); if (!r) break;
        r->index=j; r->handle=handles[j]; r->state=-1;
        int i=h_idx(handles[j]); r->kind=i ? (int)g_h[i].kind : 0;
        if (i && r->kind == S2A_OBJ_EVENT_R) {
            event_t *e=g_h[i].obj; r->object=wait_diag_event_id_locked(e); r->state=e->signaled;
        } else if (i && r->kind == S2A_OBJ_THREAD) {
            thr_t *target=g_h[i].obj; r->object=target->id; r->state=target->exited;
        }
    }
}
static void wait_diag_block_locked(thr_t *t, int kind, int64_t ns, const struct timespec *dl) {
    if (!t->trace_wait) return;
    wait_diag_record_t *r=wait_diag_add_locked(t, WD_BLOCK); if (!r) return;
    t->trace_block_start=r->mono;
    r->kind=kind; r->ns=ns;
    r->deadline=dl ? (uint64_t)dl->tv_sec * 1000000000ull + (uint64_t)dl->tv_nsec : 0;
}
static void wait_diag_condition_locked(thr_t *t, int rc) {
    if (!t->trace_wait) return;
    wait_diag_record_t *r=wait_diag_add_locked(t, WD_CONDITION);
    if (r) { r->result=rc; r->state=t->woke; r->elapsed=r->mono-t->trace_block_start; }
}
static void wait_diag_wake_locked(thr_t *t, int64_t result) {
    if (!t->trace_wait) return;
    wait_diag_record_t *r=wait_diag_add_locked(t, WD_WAKE); if (!r) return;
    thr_t *from=pthread_getspecific(g_keythr);
    r->source_tid=from ? from->id : 0; r->source_svc=g_wd_source_svc;
    r->result=result; r->kind=t->wkind;
}
// wake_sync_waiters 唤醒所有同步等待者；这里只记录精确匹配事件。
// 没有 WD_EVENT 的 WD_WAKE 仅表示要求重新检查对象集合。
static void wait_diag_event_locked(event_t *e, int state) {
    if (!wait_diag_on()) return;
#ifdef S2A_UNIT_TEST
    g_wd_test_source_svc=g_wd_source_svc;
#endif
    for (thr_t *t=g_wait; t; t=t->next) {
        if (!t->trace_wait || t->wkind != 4) continue;
        for (int j=0; j<t->wn && j<64; ++j) {
            int i=h_idx(t->wh[j]);
            if (!i || g_h[i].kind != S2A_OBJ_EVENT_R || g_h[i].obj != e) continue;
            wait_diag_record_t *r=wait_diag_add_locked(t, WD_EVENT); if (!r) return;
            thr_t *from=pthread_getspecific(g_keythr);
            r->source_tid=from ? from->id : 0; r->source_svc=g_wd_source_svc;
            r->object=wait_diag_event_id_locked(e); r->state=state; r->index=j;
        }
    }
}
static void wait_diag_cv_signal_locked(thr_t *t, uint64_t key) {
    if (!t->trace_wait) return;
    wait_diag_record_t *r=wait_diag_add_locked(t, WD_CV_SIGNAL); if (!r) return;
    thr_t *from=pthread_getspecific(g_keythr);
    r->source_tid=from ? from->id : 0; r->source_svc=g_wd_source_svc;
    r->object=wait_diag_key_locked(key);
}
static void wait_diag_end_locked(thr_t *t, const uint64_t *regs) {
    wait_diag_record_t *r=wait_diag_add_locked(t, WD_END);
    if (r) { r->result=(int64_t)regs[0]; r->index=t->last_svc==0x18 ? (int)regs[1] : -1;
        r->elapsed=r->mono-t->trace_start; }
    t->trace_wait=0;
}
#if !defined(__APPLE__)
// G 内固定账；信号处理器只增加锁自由计数。
static uint64_t g_pd_request;
static _Thread_local uint64_t g_pd_current;
static wait_diag_record_t *pause_diag_locked(thr_t *t, int event, int activity, uint32_t result,
                              uint64_t deadline, unsigned sends, int send_error) {
    if (!wait_diag_on()) return NULL;
    wait_diag_record_t *r=wait_diag_add_locked(t,event); if (!r) return NULL;
    thr_t *caller=pthread_getspecific(g_keythr);
    r->request=t->trace_pause; r->object=t->id; r->source_tid=caller?caller->id:0;
    r->source_svc=caller?caller->last_svc:0;
    r->activity=activity; r->result=result; r->deadline_mono=deadline;
    r->started=t->started; r->exited=t->exited; r->in_svc=atomic_load(&t->in_svc);
    r->kind=t->wkind; r->paused_ack=atomic_load_explicit(&t->paused_ack,memory_order_acquire);
    // 目标发布 ack 前，handler 可能正在改 pmach，不能裸读。
    r->pmach=r->paused_ack?t->pmach:-1; r->wait_safe=t->vm_wait_safe;
    r->paused=atomic_load(&t->pause); r->sends=sends; r->send_error=send_error;
    r->signal_seen=atomic_load_explicit(&t->pause_sig_seen,memory_order_relaxed);
    r->signal_native=atomic_load_explicit(&t->pause_sig_native,memory_order_relaxed);
    return r;
}
static void pause_diag_boundary_locked(thr_t *t, int event) {
    if (t->trace_pause) pause_diag_locked(t,event,1,0,0,0,0);
}
// 仅有效暂停请求内第三次起的真实 pthread 返回计入 suppressed；请求结束后不再累加。
static void pause_diag_condition_locked(thr_t *t, int error) {
    if (!t->trace_pause) return;
    if (++t->trace_pause_conditions<=2) pause_diag_locked(t,14,1,(uint32_t)error,0,0,0);
    else ++g_wd_pause_cond_suppressed;
}
static void pause_diag_svc_locked(thr_t *caller, thr_t *target, uint64_t request,
                                  int event, int activity, uint32_t result, uint32_t handle) {
    wait_diag_record_t *r;
    if (target) r=pause_diag_locked(target,event,activity,result,0,0,0);
    else { r=wait_diag_add_locked(caller,event); if (r) r->result=result; }
    if (!r) return;
    r->request=request; r->source_tid=caller->id; r->activity=activity; r->svc=0x32; r->handle=handle;
    wait_diag_pc(caller->svc_pc,r->pc_module,&r->pc);
    wait_diag_pc(caller->last_lr,r->lr_module,&r->lr);
}
#endif
// 仅正常安全上下文调用；不得从信号处理器或持 G 时调用。
// flush 所有权只尝试不等待，避免 logger 重入互锁；seq 保持采集顺序。
// emitted 在锁内复制到私有 batch 时计数，不保证外部日志系统落盘。
static void wait_diag_flush(int finish) {
    if (!wait_diag_on() || atomic_flag_test_and_set_explicit(&g_wd_flushing, memory_order_acquire)) return;
    wait_diag_record_t batch[WD_BATCH];
    for (int turn=0; turn<(finish ? WD_CAP/WD_BATCH : 1); ++turn) {
        pthread_mutex_lock(&G);
        size_t count=g_wd_used; if (count>WD_BATCH) count=WD_BATCH;
        for (size_t i=0; i<count; ++i) batch[i]=g_wd[(g_wd_read+i)%WD_CAP];
        g_wd_read=(g_wd_read+count)%WD_CAP; g_wd_used-=count; g_wd_emitted+=count;
        pthread_mutex_unlock(&G);
        if (!count) break;
        for (size_t i=0; i<count; ++i) {
            const wait_diag_record_t *r=&batch[i];
            LOG("[等待诊断v1] seq=%llu ev=%d wait=%llu tid=%llu svc=%#x mono_ns=%llu real_ns=%llu ns=%lld deadline_real_ns=%llu result=%lld elapsed_ns=%llu kind=%d index=%d count=%d state=%d handle=%#x object=%llu source_tid=%llu source_svc=%#x pc=%s+%#llx lr=%s+%#llx request=%llu activity=%d deadline_mono_ns=%llu started=%d exited=%d in_svc=%d ack=%d pmach=%d wait_safe=%d paused=%d sends=%u send_error=%d signal_seen=%u signal_native=%u",
                (unsigned long long)r->seq,r->event,(unsigned long long)r->wait,(unsigned long long)r->tid,r->svc,
                (unsigned long long)r->mono,(unsigned long long)r->real,(long long)r->ns,(unsigned long long)r->deadline,
                (long long)r->result,(unsigned long long)r->elapsed,r->kind,r->index,r->count,r->state,r->handle,
                (unsigned long long)r->object,(unsigned long long)r->source_tid,r->source_svc,
                r->pc_module,(unsigned long long)r->pc,r->lr_module,(unsigned long long)r->lr,
                (unsigned long long)r->request,r->activity,(unsigned long long)r->deadline_mono,
                r->started,r->exited,r->in_svc,r->paused_ack,r->pmach,r->wait_safe,r->paused,
                r->sends,r->send_error,r->signal_seen,r->signal_native);
        }
    }
    if (finish) {
        pthread_mutex_lock(&G);
        uint64_t produced=g_wd_seq, dropped=g_wd_dropped, keys=g_wd_key_overflow;
        size_t pending=g_wd_used; uint64_t emitted=g_wd_emitted;
        uint64_t suppressed=g_wd_pause_cond_suppressed;
        pthread_mutex_unlock(&G);
        if (finish>1 || g_wd_reports < 8 || (dropped && !g_wd_cap_reported)) {
        if (g_wd_reports < 8) ++g_wd_reports;
        if (dropped) g_wd_cap_reported=1;
        LOG("[等待诊断v1账] produced=%llu emitted=%llu dropped=%llu pending=%zu key_overflow=%llu cap=%d pause_condition_suppressed=%llu",
            (unsigned long long)produced,(unsigned long long)emitted,(unsigned long long)dropped,pending,(unsigned long long)keys,WD_CAP,(unsigned long long)suppressed);
        }
    }
    atomic_flag_clear_explicit(&g_wd_flushing, memory_order_release);
}
