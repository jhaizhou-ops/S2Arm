#include "oodle_fixture.h"
// 复用真实组合夹具端点，只在此编译单元观察SDK首次入口；生产runtime/guest_main原样编译。
#define S2A_ENTRY_FIXTURE 1
#define main sequence_fixture_main
#define s2a_thread_main_init fixture_thread_main_init
#include "runtime_test.c"
#undef s2a_thread_main_init
#undef main
static const char *gate_mode;
// 本夹具隔离线程准入；真实 os.c 文件/描述符与 runtime 消费路径由 session-log 测试覆盖。
int s2a_android_session_log_start(const char *dir, uint64_t id) {
    assert(dir && id == session); return 0;
}
static int attached, probed, registered;
int s2a_android_fault_thread_init(void) { assert(registered==1); return 0; }
int s2a_android_fault_thread_ready(void) { return 1; }
int32_t s2a_android_services_attach_thread(uint64_t id, struct s2a_android_services_status *s) {
    assert(registered==1 && id==session && s2a_android_runtime_session()==session && !probed && !guest_calls);
    attached=1;
    *s=(struct s2a_android_services_status){sizeof *s,1,session,S2A_SERVICES_READY,0};
    if (!strcmp(gate_mode,"attach-fail")) return S2A_SERVICES_INITIALIZE;
    if (!strcmp(gate_mode,"attach-wrong-session")) s->session_id++;
    if (!strcmp(gate_mode,"attach-stop")) stop(host.host,S2A_HOST_STOP_ERROR,"async managed failure");
    return 0;
}
int s2a_android_fault_probe(void) {
    assert(attached && !probed && !guest_calls); probed=1;
    return !strcmp(gate_mode,"probe-fail") ? -1 : 0;
}
int s2a_track_runtime_ready(void) { assert(attached && probed); return strcmp(gate_mode,"prepared-only")!=0; }
uint32_t s2a_thread_main_init(void) { assert(!registered && !attached && !probed); registered++; return fixture_thread_main_init(); }
uint32_t s2a_thread_current(void) { assert(registered==1 && attached && probed); puts("SDK_ENTRY"); fflush(stdout); return 71; }
int main(int argc,char **argv) {
    assert(argc==2); gate_mode=argv[1];
    assert(!s2a_android_runtime_session());
    assert(s2a_android_runtime_enter_guest_thread()==S2A_RUNTIME_ARGUMENT);
    char *args[]={"sequence","ready"}; return sequence_fixture_main(2,args);
}
