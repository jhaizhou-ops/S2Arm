// 实际 CreateThread/StartThread/ExitThread/close_handle/wake/peer_yield。
// 仅 guest 入口为 authored host 回调；free 后撤销页面访问用于确定性捕获 UAF。
static int lifetime_mode, lifetime_alloc, lifetime_publication;
static void *lifetime_object;
static size_t lifetime_page;
static pthread_t lifetime_creator, lifetime_created;
static _Atomic(thr_t *) lifetime_pending_publish;
static int lifetime_publish_locked, lifetime_published;
static _Atomic int lifetime_started, lifetime_release, lifetime_freed;
void *__real_calloc(size_t,size_t);
void __real_free(void*);
int __real_pthread_create(pthread_t*,const pthread_attr_t*,void *(*)(void*),void*);
int __real_pthread_mutex_lock(pthread_mutex_t*);
int __real_pthread_mutex_unlock(pthread_mutex_t*);
int __wrap_pthread_mutex_lock(pthread_mutex_t *lock){
 int rc=__real_pthread_mutex_lock(lock);
 if(!rc&&lock==&G&&lifetime_pending_publish&&pthread_equal(pthread_self(),lifetime_creator))lifetime_publish_locked=1;
 return rc;
}
int __wrap_pthread_mutex_unlock(pthread_mutex_t *lock){
 if(lock==&G&&lifetime_pending_publish&&pthread_equal(pthread_self(),lifetime_creator)){
  check(lifetime_publish_locked&&pthread_equal(lifetime_pending_publish->pt,lifetime_created),"parent publishes actual pthread under G");
  lifetime_pending_publish=NULL;lifetime_published=1;
 }
 return __real_pthread_mutex_unlock(lock);
}
void *__wrap_calloc(size_t n,size_t size){
 if(lifetime_alloc&&n*size==sizeof(thr_t)){
  lifetime_alloc=0;size_t page=(size_t)sysconf(_SC_PAGESIZE);
  lifetime_page=(sizeof(thr_t)+page-1)&~(page-1);
  lifetime_object=mmap(NULL,lifetime_page,PROT_READ|PROT_WRITE,MAP_PRIVATE|MAP_ANONYMOUS,-1,0);
  check(lifetime_object!=MAP_FAILED,"protected thread allocation");return lifetime_object;
 }
 return __real_calloc(n,size);
}
void __wrap_free(void *p){
 if(p&&p==lifetime_object){
  if(mprotect(p,lifetime_page,PROT_NONE))_exit(88);
  atomic_store(&lifetime_freed,1);return;
 }
 __real_free(p);
}
int __wrap_pthread_create(pthread_t *out,const pthread_attr_t *attr,void *(*entry)(void*),void *arg){
 int shared=lifetime_publication&&entry==thread_main&&out==&((thr_t*)arg)->pt;
 int rc=__real_pthread_create(out,attr,entry,arg);
 if(shared&&!rc){const char msg[]="RED actual pthread_create writes shared thread handle outside G\n";if (write(2,msg,sizeof msg-1) != (ssize_t)(sizeof msg-1)) _exit(88);_exit(86);}
 if(lifetime_publication&&entry==thread_main&&!rc){lifetime_creator=pthread_self();lifetime_created=*out;lifetime_pending_publish=arg;}
 return rc;
}
static void lifetime_fault(int signal,siginfo_t *info,void *context){
 (void)signal;(void)context;uintptr_t address=(uintptr_t)info->si_addr,base=(uintptr_t)lifetime_object;
 if(atomic_load(&lifetime_freed)&&address>=base&&address<base+lifetime_page){
  const char msg[]="RED actual peer consumer accessed released thread object\n";if (write(2,msg,sizeof msg-1) != (ssize_t)(sizeof msg-1)) _exit(88);_exit(87);
 }
 _exit(89);
}
static void lifetime_child(uint64_t arg){
 (void)arg;atomic_store(&lifetime_started,1);until(&lifetime_release,1);
 thread_exit(cur());abort();
}
static int run_lifetime(const char *name){
 lifetime_mode=1;lifetime_publication=!strcmp(name,"lifetime-publication");
 struct sigaction sa={0};sa.sa_sigaction=lifetime_fault;sa.sa_flags=SA_SIGINFO|SA_ONSTACK;sigemptyset(&sa.sa_mask);
 check(!sigaction(SIGSEGV,&sa,NULL),"install guarded-free observer");
 check(s2a_thread_main_init()!=0,"real main thread registration");thr_t *me=cur();
 lifetime_alloc=1;uint64_t regs[32]={0,(uintptr_t)lifetime_child,0,0,40,0};
 check(svc_thread_impl(me,0x08,regs)&&!regs[0],"real CreateThread");uint32_t handle=(uint32_t)regs[1];
 if(lifetime_publication)check(lifetime_published,"CreateThread completes protected parent publication");
 glock();thr_t *child=h_obj(handle,S2A_OBJ_THREAD);check(child==lifetime_object,"actual handle owns guarded allocation");check(child->pt!=0,"parent published pthread before CreateThread returns");pthread_mutex_unlock(&G);
 regs[0]=handle;check(svc_thread_impl(me,0x09,regs)&&!regs[0],"real StartThread");until(&lifetime_started,1);
 glock();wake(child,0);pthread_mutex_unlock(&G);
 if(!strcmp(name,"lifetime-priority")){
  uint64_t priority[32]={handle,38};check(svc_thread_impl(me,0x0D,priority)&&!priority[0],"actual SetThreadPriority after first wake");
  thr_t next={0};next.prio=39;next.core=0;next.mask=1;check(!pthread_cond_init(&next.cv,NULL),"next-priority condition");
  glock();next.id=g_next_id++;next.handle=h_new(S2A_OBJ_THREAD,&next,0);wake(&next,0);
  check(me->peer.handle==handle,"selection retains current higher priority, not stale sampled priority");h_free(h_idx(next.handle));pthread_mutex_unlock(&G);pthread_cond_destroy(&next.cv);
 }
 check(!close_handle(handle),"actual CloseHandle while target alive");
 atomic_store(&lifetime_release,1);until(&lifetime_freed,1);
 glock();check(!h_obj(handle,S2A_OBJ_THREAD),"released handle no longer resolves");pthread_mutex_unlock(&G);
 if(!strcmp(name,"lifetime-reused-handle")){
  thr_t replacement={0};check(!pthread_cond_init(&replacement.cv,NULL),"replacement condition");
  glock();g_gen=(uint16_t)((handle>>15)-1);replacement.id=g_next_id++;replacement.handle=h_new(S2A_OBJ_THREAD,&replacement,0);
  check(replacement.handle==handle,"forced generation wrap with real handle allocator");pthread_mutex_unlock(&G);
  peer_yield(me);glock();h_free(h_idx(handle));pthread_mutex_unlock(&G);pthread_cond_destroy(&replacement.cv);
 }
 else if(!strcmp(name,"lifetime-wake")){thr_t next={0};next.prio=39;next.core=0;next.mask=1;check(!pthread_cond_init(&next.cv,NULL),"next condition");glock();wake(&next,0);pthread_mutex_unlock(&G);pthread_cond_destroy(&next.cv);}
 else peer_yield(me);
 check(!atomic_load(&g_py_timeout),"released peer causes no timeout");
 printf("PASS actual-gate %s: real create/start/exit/close, protected release, checks=%d\n",name,checks);return 0;
}
