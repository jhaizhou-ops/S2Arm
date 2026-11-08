// 单处绘制兜底（10-26 总指挥：不再整局切通用）：直接包含生产 nvn_mtl.m。期望按规则手写，不由被测实现推出：
//   ① GPU 报错隔离：提交前新建的程序对是嫌疑；非无辜受害的报错 → 嫌疑全部隔离、quar_has 命中、写进 gpu_quarantine.tsv；新进程读文件同样命中（以后的局也跳过）
//      嫌疑超过 QUAR_MAX（16）对 → 一个也不隔离；隔离之后新建的不受影响
//   ② 编译服务失败（XPC 连接中断 / 超时）判为暂时性，管线本身的错（线程组内存超限）不算
//   反证：改前的 nvn_mtl.m 没有 quar_* / pso_err_transient，本单测编不过
#include "../gfx/nvn/nvn_mtl.m"
#include <sys/wait.h>

static unsigned failures, checks;
#define VERIFY(c, ...) do { checks++; int ok_ = !!(c); if (!ok_) failures++; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); putchar('\n'); fflush(stdout); } while (0)
static NvShader *sh(const char *key) { NvShader *s = [NvShader new]; strlcpy(s->key, key, sizeof s->key); return s; }

int main(void) {
    @autoreleasepool {
        char dir[] = "/tmp/t_drawfb_XXXXXX"; if (!mkdtemp(dir)) return 2;
        char user[300]; snprintf(user, sizeof user, "%s/pso_user.tsv", dir); setenv("DM_PSO_USER", user, 1);
        NvShader *va = sh("aaaaaaaaaaaaaaaa_b"), *fa = sh("bbbbbbbbbbbbbbbb_b"), *vb = sh("cccccccccccccccc_b"), *fb = sh("dddddddddddddddd_b");
        quar_built(va, fa); NSArray *sus = quar_take();
        VERIFY(sus.count == 1 && !quar_has(va, fa), "① 提交前新建 1 对，报错前不隔离");
        quar_fault(sus, [NSError errorWithDomain:@"t" code:1 userInfo:nil]);
        VERIFY(quar_has(va, fa) && !quar_has(vb, fb), "① 报错后那一对隔离、别的不受影响");
        quar_built(vb, fb); VERIFY(quar_take().count == 1 && !quar_has(vb, fb), "① 隔离之后新建的不受影响，下一个提交照常收嫌疑");
        NSMutableArray *many = [NSMutableArray array]; for (int i = 0; i < 17; i++) [many addObject:[NSString stringWithFormat:@"%016x_b\t%016x_b", i, i]];
        quar_fault(many, nil);
        VERIFY(![g_quar containsObject:many[0]], "① 嫌疑 17 对（> 16）：一个也不隔离");
        NSString *f = [NSString stringWithContentsOfFile:[@(dir) stringByAppendingPathComponent:@"gpu_quarantine.tsv"] encoding:NSUTF8StringEncoding error:nil];
        VERIFY([f isEqualToString:@"aaaaaaaaaaaaaaaa\tbbbbbbbbbbbbbbbb\n"], "① 写进 gpu_quarantine.tsv（实得「%s」）", f.UTF8String);
        pid_t c = fork();
        if (c == 0) { g_quar = nil; g_quar_n = 0; _exit(quar_has(va, fa) && !quar_has(vb, fb) ? 0 : 1); }
        int st = 0; waitpid(c, &st, 0);
        VERIFY(WIFEXITED(st) && !WEXITSTATUS(st), "① 新进程读文件：那一对一开局就跳过");
        NSError *(^E)(NSString *) = ^(NSString *d) { return [NSError errorWithDomain:@"t" code:1 userInfo:@{NSLocalizedDescriptionKey: d}]; };
        VERIFY(pso_err_transient(E(@"Compilation failed due to an interrupted connection: XPC_ERROR_CONNECTION_INTERRUPTED. This error occurred after multiple retries.")), "② 巫师3 那条（XPC 连接中断）判暂时性");
        VERIFY(!pso_err_transient(E(@"Threadgroup memory size (36880) exceeds the maximum threadgroup memory allowed (32768)")) && !pso_err_transient(nil), "② 管线本身的错 / 无错误不算暂时性");
        char cmd[400]; snprintf(cmd, sizeof cmd, "rm -rf '%s'", dir); system(cmd);
    }
    if (failures) { printf("✗ t_nvn_draw_fallback：%u / %u 项不过\n", failures, checks); return 1; }
    printf("✓ t_nvn_draw_fallback：%u 项全过（GPU 报错隔离与记住、编译服务失败判暂时性）\n", checks);
    return 0;
}
