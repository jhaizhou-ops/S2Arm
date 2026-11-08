// 真实 gate→SleepThread→nanosleep 与 writers census/SIGURG；只观察内核睡眠入口，不替换其返回。
static _Thread_local int sleep_target;
static _Atomic int sleep_entered, sleep_eintr, sleep_done;
static thr_t *sleep_thread;
static uint64_t sleep_duration, sleep_started, sleep_finished;
int __real_nanosleep(const struct timespec *, struct timespec *);
int __wrap_nanosleep(const struct timespec *request, struct timespec *remaining) {
    if (sleep_target) atomic_store(&sleep_entered, 1);
    int result = __real_nanosleep(request, remaining), error = errno;
    if (sleep_target && result && error == EINTR) atomic_fetch_add(&sleep_eintr, 1);
    errno = error;
    return result;
}
static void *sleep_worker(void *unused) {
    (void)unused;
    thr_t *t = calloc(1, sizeof *t); check(t != NULL, "allocate sleep thread");
    t->pt = pthread_self(); t->started = 1; t->prio = 44; t->mask = 7;
    atomic_store(&t->in_svc, 1);
    check(!pthread_cond_init(&t->cv, NULL), "sleep thread condition");
    glock(); t->all = g_all; g_all = t; pthread_mutex_unlock(&G);
    thread_bind_host(t);
    sw_xstack_thread_init(((uintptr_t)__builtin_frame_address(0) - 0x400) & ~15ull, 0);
    check(!s2a_android_fault_probe(), "sleep thread fault state");
    core_acquire(t); sleep_thread = t;
    uint64_t regs[32] = {sleep_duration}; sleep_started = plat_now_ns(); sleep_target = 1;
    check(gate_dispatch(ret_pc + 0x80, regs) == sleep_duration, "SleepThread preserves guest registers");
    sleep_target = 0; sleep_finished = plat_now_ns();
    check(!atomic_load(&android_vm_epoch), "sleep cannot return through active epoch");
    if (core_mode) check(atomic_load(&t->held_core) != 0, "sleep return reacquires virtual core");
    atomic_store(&sleep_done, 1);
    core_release(t); s2a_tlr_free(t->tlr); t->tlr = NULL;
    s2a_android_fault_thread_fini(); sw_xstack_thread_fini(); s2a_android_altstack_free();
    glock(); t->exited = t->closed = 1; pthread_setspecific(g_keythr, NULL); thr_free(t); pthread_mutex_unlock(&G);
    return NULL;
}
static int run_sleep(const char *name) {
    int expired = !strcmp(name, "sleep-expired"), signals = !strcmp(name, "sleep-signals");
    sleep_duration = expired ? 200000000ull : 600000000ull;
    gate_register(ret_pc + 0x80, "svc", 0x0B, orig_pc + 0x80);
    pthread_t target_thread; check(!pthread_create(&target_thread, NULL, sleep_worker, NULL), "create sleep worker");
    until(&sleep_entered, 1);
    uint64_t census_ns = 0, released = 0;
    if (signals) {
        // 没有VM事务的SIGURG也不能使SleepThread少睡。
        for (int i = 0; i < 5; ++i) { usleep(20000); check(!pthread_kill(target_thread, SIGURG), "send unrelated preemption"); }
    } else {
        uint64_t start_ns = plat_now_ns();
        check(!s2a_android_guest_writers_begin(), "sleep writer begins");
        census_ns = plat_now_ns() - start_ns;
        printf("sleep census_ms=%.3f requested_ms=%.3f interrupts=%d\n", census_ns / 1e6, sleep_duration / 1e6, atomic_load(&sleep_eintr));
        check(census_ns < 100000000ull, "sleep VM census does not wait for requested duration");
        check(!atomic_load(&sleep_done), "sleep remains blocked while writer owns epoch");
        check(atomic_load(&sleep_thread->vm_ack) == atomic_load(&android_vm_epoch), "sleep acknowledges actual writer epoch");
        check(!atomic_load(&sleep_thread->held_core), "sleep safe point holds no virtual core");
        usleep(expired ? 350000 : 200000);
        check(!atomic_load(&sleep_done), "sleep cannot escape writer even after deadline");
        // 先记释放操作起点；目标可能在writers_end返回前就完成，不能事后采时再做无符号差。
        released = plat_now_ns(); s2a_android_guest_writers_end();
    }
    check(!pthread_join(target_thread, NULL), "sleep worker joins");
    uint64_t elapsed = sleep_finished - sleep_started;
    printf("sleep elapsed_ms=%.3f after_release_ms=%.3f interrupts=%d\n", elapsed / 1e6,
           released ? (sleep_finished - released) / 1e6 : 0, atomic_load(&sleep_eintr));
    check(atomic_load(&sleep_eintr) > 0, "actual kernel nanosleep interrupted");
    check(elapsed >= sleep_duration, "interrupted sleep retains full duration");
    if (expired) check(sleep_finished - released < 100000000ull, "expired sleep returns without restarting deadline");
    else check(elapsed < sleep_duration + 100000000ull, "VM park and signals do not extend absolute deadline");
    check(!android_vm_pin_count && !atomic_load(&android_vm_epoch), "sleep epoch and lifetime pins retired");
    printf("PASS actual-gate %s cores=%d checks=%d\n", name, core_mode, checks);
    return 0;
}
static int run_sleep_pause(const char *name) {
    int vm_first = !strcmp(name, "sleep-pause-vm-first"), vm_after = !strcmp(name, "sleep-pause-vm-after");
    int expired = !strcmp(name, "sleep-pause-expired");
    sleep_duration = expired ? 200000000ull : vm_first || vm_after || core_mode ? 600000000ull : 3200000000ull;
    gate_register(ret_pc + 0x80, "svc", 0x0B, orig_pc + 0x80);
    pthread_t target_thread; check(!pthread_create(&target_thread, NULL, sleep_worker, NULL), "create pause sleeper");
    until(&sleep_entered, 1);
    if (vm_first) check(!s2a_android_guest_writers_begin(), "VM epoch precedes pause request");
    uint64_t begin = plat_now_ns(); uint32_t result = thr_pause(sleep_thread);
    uint64_t pause_ns = plat_now_ns() - begin;
    printf("sleep pause_result=%#x pause_ms=%.3f ack=%d\n", result, pause_ns / 1e6, atomic_load(&sleep_thread->paused_ack)); fflush(stdout);
    check(result == 0 && pause_ns < 100000000ull, "SleepThread acknowledges pause before two-second timeout");
    check(atomic_load(&sleep_thread->paused_ack) && !sleep_thread->pmach, "sleep pause owns SVC context acknowledgement");
    check(!atomic_load(&sleep_thread->held_core) && !atomic_load(&sleep_done), "paused sleeper neither holds core nor returns");
    if (vm_after) check(!s2a_android_guest_writers_begin(), "paused condition wait admits VM epoch");
    if (vm_first || vm_after) {
        glock(); check(sleep_thread->vm_wait_safe || atomic_load(&sleep_thread->vm_ack) == atomic_load(&android_vm_epoch), "pause wait or VM acknowledgement satisfies actual census"); pthread_mutex_unlock(&G);
    }
    usleep(expired ? 350000 : 100000);
    uint64_t resumed = plat_now_ns(); check(!thr_unpause(sleep_thread), "resume paused sleeper");
    if (vm_first || vm_after) {
        usleep(20000); check(!atomic_load(&sleep_done), "resume cannot escape active VM epoch");
        s2a_android_guest_writers_end();
    }
    check(!pthread_join(target_thread, NULL), "pause sleeper joins");
    uint64_t elapsed = sleep_finished - sleep_started;
    printf("sleep total_ms=%.3f after_resume_ms=%.3f\n", elapsed / 1e6, (sleep_finished - resumed) / 1e6);
    check(elapsed >= sleep_duration, "pause does not shorten requested sleep");
    if (expired) check(sleep_finished - resumed < 100000000ull, "pause crossing deadline does not restart sleep");
    else check(elapsed < sleep_duration + 100000000ull, "pause and VM do not extend original deadline");
    check(!android_vm_pin_count && !atomic_load(&android_vm_epoch), "pause sleep retires actual VM pins");
    printf("PASS actual-gate %s cores=%d checks=%d\n", name, core_mode, checks); return 0;
}
