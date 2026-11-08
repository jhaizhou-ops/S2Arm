// Android 组合层对共享 svc_mem 的一次性准备；没有新增 Native 槽或公开 C ABI。
#pragma once
#ifdef __cplusplus
extern "C" {
#endif
// 只在启动线程、guest尚未放行时调用。安装现有shared VM权限/host-write钩子。
// 已被其它owner登记不相容hooks时EBUSY；成功不代表线程安全点/信号已就绪。
int s2a_android_tracking_vm_prepare(void);
// 核对真实hooks与thread owner安装状态；缺任一条件返回0。
int s2a_android_tracking_vm_ready(void);
#ifdef __cplusplus
}
#endif
