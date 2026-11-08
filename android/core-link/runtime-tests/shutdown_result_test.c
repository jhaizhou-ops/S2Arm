#include "oodle_fixture.h"
// 真实runtime启动与cleanup结果消费者；服务status生产者在此明确为合成边界。
#define S2A_SHUTDOWN_FIXTURE 1
#define main sequence_fixture_main
#include "runtime_test.c"
#undef main
static const char *shutdown_mode;
static int queries;
int s2a_android_services_status(uint64_t id, struct s2a_android_services_status *s) {
    assert(id==session); queries++;
    *s=(struct s2a_android_services_status){sizeof *s,1,session,S2A_SERVICES_STOPPED,0};
    if (!strcmp(shutdown_mode,"missing-cleanup")) s->state=S2A_SERVICES_STOP_REQUESTED;
    if (!strcmp(shutdown_mode,"wrong-session")) s->session_id++;
    if (!strcmp(shutdown_mode,"failed-cleanup")) { s->state=S2A_SERVICES_FAILED; s->error=S2A_SERVICES_CLEANUP; }
    if (!strcmp(shutdown_mode,"error-with-stopped")) s->error=S2A_SERVICES_CLEANUP;
    if (!strcmp(shutdown_mode,"query-fail")) return -1;
    return 0;
}
int main(int argc,char **argv) {
    assert(argc==2); shutdown_mode=argv[1];
    assert(!s2a_android_runtime_shutdown_result() && !queries); // 未启动不能触达managed provider。
    char *args[]={"sequence",!strcmp(shutdown_mode,"never-start") ? "window" : "ready"};
    assert(!sequence_fixture_main(2,args));
    int rc=s2a_android_runtime_shutdown_result();
    int success=!strcmp(shutdown_mode,"stopped") || !strcmp(shutdown_mode,"never-start");
    assert((rc==0)==success && queries==(!strcmp(shutdown_mode,"never-start") ? 0 : 1));
    puts("PASS actual runtime cleanup admission");return 0;
}
