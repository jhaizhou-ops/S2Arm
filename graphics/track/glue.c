// 宿主专用（单测不链）：启动时把原生层 §4.5 的两个钩子指到写跟踪——原生层改游戏页权限后报 prot_changed、自己写游戏内存前报 host_write（= CPU 写）
#include "s2a_track.h"
#include "s2a_native.h"
void s2a_track_bind_host(void) {
    static const s2a_track_hooks h = { s2a_track_prot_changed, s2a_track_write, s2a_track_backing_changed, s2a_track_set_guest_protection };   // 第四个：客人 SetMemoryPermission 先占页再 mprotect（10-28 审计 #806，原先苹果为 0）
    s2a_register_track_hooks(&h);
    s2a_register_track_backing(s2a_track_backing_begin, s2a_track_backing_end);   // 换页事务：改表窗口与排空期互斥（审计 #806 第 5 条续）
}
__attribute__((constructor)) static void track_hooks_init(void) { s2a_track_bind_host(); }
