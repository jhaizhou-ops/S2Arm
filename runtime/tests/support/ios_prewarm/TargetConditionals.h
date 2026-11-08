// 在 Mac 上执行真实 iOS 启动分支；不模拟 UIKit，scene 生命周期另做真机验证。
#include_next <TargetConditionals.h>
#undef TARGET_OS_IPHONE
#undef TARGET_OS_OSX
#define TARGET_OS_IPHONE 1
#define TARGET_OS_OSX 0
