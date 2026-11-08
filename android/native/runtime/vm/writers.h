// 共享 thread owner 的 Android VM 安全点合同，不是另一套线程系统。
#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
// 启动线程安装真实TSD/停车信号处理；失败返回errno，不发布ready。
int s2a_android_guest_writers_init(void);
// gate的native-memory词法范围：未处理撤销；已处理在最外SVC收尾后finish。
// 只有此入口允许竞争者发布admission-safe等待；任意native/fault回调不享有该承诺。
void s2a_android_memory_svc_enter(int num, uint64_t *regs);
void s2a_android_memory_svc_unhandled(void);
void s2a_android_memory_svc_finish(void);
int s2a_svc_stopping(void);
void s2a_android_guest_writers_notify_stop(void);
void s2a_android_guest_park_forever(void) __attribute__((noreturn));
// 正常 guest SVC 上下文、未持 VM/tracker/GPU 回调锁调用。返回0后，除调用线程外，
// 所有 guest writers 均停在 guest 指令边界或已退出持锁 SVC；禁止仅置 freeze 标志。
// 同时阻止新线程进入 guest；若安全点未接通、失败或超时，返回 errno且不改变任何映射。
// 强链接依赖：VM组合层不提供返回成功的替身。成功后同线程恰好一次 end，不得嵌套。
// 只报告真实全局暂停/恢复安装状态；不是某条线程in_svc或函数符号存在。
int s2a_android_guest_writers_ready(void);
// 只回答“停车通道装过没有”（不看当前处理器是否被覆盖）：收局据此区分“从未安装”与“没停稳”。
int s2a_android_guest_writers_installed(void);
int s2a_android_guest_writers_begin(void);
// 0x2C 已证明只向全空宿主页放新零页时使用：只取得串行锁并发布 epoch，不停其他
// guest writers，也不建第二套映射表。成功后同样恰好一次 end。
int s2a_android_guest_writers_begin_serial(void);
// 只串行事务在持锁状态下发现条件不再成立时升级为全体停稳。成功保留 serial/epoch；
// 失败**已撤销** serial/epoch（active 清零）：调用方不能再走正常 end()（二次收尾会撞
// “end 没有同线程 begin”），必须查 s2a_android_guest_writers_revoked() 后重新准入再重做映射。
int s2a_android_guest_writers_quiesce(void);
// 本线程的事务是否已在调用栈里被撤销（quiesce 升级失败）。为真时本次映射按“未完成”处理，
// 由外层重新 begin 再重做；为假时按一一对应收尾。
int s2a_android_guest_writers_revoked(void);
int s2a_android_guest_writers_serial_only(void);
unsigned s2a_android_guest_writers_epoch(void);
void s2a_android_guest_writers_end(void);
#ifdef __cplusplus
}
#endif
