// Host fixture exercising the real adapter shutdown decision and callback gate.
// macOS 没有 pthread_mutex_timedlock：生产 mtl_vk_adapter.c 走 mutex_timedlock.h 的可移植实现（单测见 mutex_timedlock_test）。
#include "../native/nvn/mtl_vk_adapter.c"
#include <assert.h>
static int finish_rc, retire_rc, query_ready, session_rc, first_calls, pool_calls, session_calls, retire_calls;
void nvk_exec_owner_get_stats(const struct nvk_exec_owner*o,struct nvk_exec_owner_stats*s){(void)o;memset(s,0,sizeof *s);}
void nvk_exec_owner_request_stop(struct nvk_exec_owner*o){(void)o;}
void nvk_exec_owner_init(struct nvk_exec_owner*o,uint64_t g){(void)o;(void)g;}
int s2a_compile_worker_stop_bounded(uint32_t b,char*w,size_t z){(void)b;(void)w;(void)z;return 0;}
int __system_property_get(const char*n,char*v){(void)n;*v=0;return 0;}
int __android_log_print(int p,const char*t,const char*f,...){(void)p;(void)t;(void)f;return 0;}
int nvn_vk_query_terminal_ready(void){return query_ready;}
int nvn_vk_first_draw_finish(void){return finish_rc;}
int nvn_vk_first_draw_retire_all(void){retire_calls++;return retire_rc;}
void nvn_vk_first_draw_release_device(struct s2a_vk_device*d){assert(d==&g_session.device);first_calls++;}
void s2a_poolahb_shutdown(void){pool_calls++;}
int nvn_vk_session_destroy_with_callback(struct nvn_vk_session*s,void (*release)(struct s2a_vk_device *)) {
    session_calls++; if(session_rc) return session_rc; release(&s->device); return 0;
}
static void run(int finish_fail,int retire_fail,int query_fail,int session_fail) {
    finish_rc=finish_fail;retire_rc=retire_fail;query_ready=!query_fail;session_rc=session_fail;first_calls=pool_calls=session_calls=retire_calls=0;
    g_ready=1;g_retire_failed=0;g_session.ready=1;
    int rc=s2a_vk_adapter_shutdown();
    assert((rc!=0)==(finish_fail || retire_fail || query_fail || session_fail));
    assert(retire_calls==(finish_fail?0:1));
    assert(session_calls==((finish_fail||retire_fail||query_fail)?0:1));
    assert(first_calls==(!finish_fail&&!retire_fail&&!query_fail&&!session_fail));
    assert(pool_calls==(!finish_fail&&!retire_fail&&!query_fail&&!session_fail));
}
int main(void){
    run(1,0,0,0);run(0,1,0,0);run(0,0,1,0);run(0,0,0,1);run(0,0,0,0);puts("adapter release gate passed");}
