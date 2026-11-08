# A-W4：HostApi UI 有界 broker 首个切片

本目录验证 `runtime/host_ui.{h,c}` 的生产请求生命周期，使用既有
`s2a_host_ui_v1` 与真实 `hostapi.c` 注册/获取函数。它不是 Android 对话框实现，
没有修改正式 HostApi、C# 服务、JNI bridge 或输入路径，也没有启用 UI capability。

当前根因是：已有 begin/wait/cancel 函数表，但 Android 没有 producer 和请求生命周期，
也尚无已发布的 UI type/reply schema。先把独立可验证的生命周期做好；协议未齐前不假装可用。

## 实现边界

- 每个 broker 最多 8 个活请求，request 4 KiB、reply 8 KiB；包括已回答未消费的请求。
- 请求/应答同步拷贝，UTF-8 边界验证，不借用 caller 指针。broker 不解释 JSON；
  受控 fixture 的 JSON 只作为不透明 payload，不发布正式 wire type。
- request ID 在进程内不复用，销毁旧 broker 后也不回绕；producer 交付同时检查 session。
- 创建默认 unavailable。owner 只有在有真实、schema-aware producer 时才可开启；
  此文件不注册 HostApi，不自动打开 capability。
- producer 非阻塞 take → 校验并展示 → complete；只有已 take 的请求能 complete。
- wait 使用单调时钟；0 ms 轮询，负数拒绝。RANGE 保留同一答案：返回容量含 NUL，
  成功返回字节数不含 NUL；只有成功取走才消费。该长度解释需 W11 确认后再接正式 caller。
- cancel 幂等；unavailable/stop 清所有活请求并唤醒等待；stop 终态不能重新开启。
  wait 在 stopped/unavailable 时先返回 E_UNSUPPORTED；available 时，进入 wait 就已找不到
  的 ID 返回 E_ARGUMENT（可能是未知、已取消或已消费）。已经被接纳的 wait 在循环中发现
  ID 消失则 E_UNSUPPORTED（可能被取消或被另一 wait 消费）。FREE 不保留终止原因，
  这些错误码不能用于区分原因；未新增公共取消码/JSON，需 W11 确认正式消费者解释。
- OS condvar 即使返回 ETIMEDOUT，仍在持锁状态重查可用性、ID 与 ANSWERED，只有仍 pending
  才返回 TIMEOUT。该边界已回答则按实际缓冲容量返回 OK/RANGE，不丢失答案。
- 满容量/ID耗尽返回 E_INTERNAL，不覆盖旧请求。错 session、迟到/重复答案拒绝。
- 不在 signal/UI/renderer 线程 wait。destroy 前 owner 必须先 stop 并等待所有调用者退出；
  不承诺并发 free 安全，也不负责 Android UI thread/Activity 生命周期。

接入已有 Android HostApi 时，其统一 host context 不是 broker；producer adapter 必须显式
委托到自己的 broker，而不能强转现有 host context。只有正式 producer 已接通才登记 UI 表。
本切片保持 `host_android.c` 原行为，不给不存在的 producer 加 capability。

## 独立 host 验证

构建目录由调用者指定，产物不放源码目录。macOS 示例：

```sh
export W4_BUILD_DIR=<独立构建目录>
mkdir -p "$W4_BUILD_DIR"
clang -std=c11 -Wall -Wextra -Werror -g -fsanitize=address,undefined -pthread \
  -I runtime/include -I android/native \
  android/native/host_ui.c android/native/hostapi.c \
  android/w4-tests/host_ui_test.c android/w4-tests/wait_probe.c \
  -o "$W4_BUILD_DIR/host_ui_test"
"$W4_BUILD_DIR/host_ui_test"
```

Linux 链接器如未自动提供 dlsym，可另加 `-ldl`。本轮已验证 macOS 和 Linux host；
尚未构建 Android APK 或在 Android 设备运行。

fixture 实际调用生产函数表、broker 和 HostApi validator；受控 peer 使用 take/complete。
`wait_probe.c` 是测试专属 OS wait 链接观察器，调用真实 pthread condvar wait：
在 broker mutex 尚持有时发出进入通知，取消方须等 OS 原子注册/解锁后才能获取该锁。
它不直接写broker内部状态，仍调用真实OS等待，使cancel/stop唤醒用例不依赖固定sleep。

初版134项断言覆盖两等待者仅一次消费、RANGE重试、UTF-8/容量、所有权、FIFO、重复取消、
可用性丢失、stop、跨session迟到响应。追加超时竞态fixture：真实OS先返回ETIMEDOUT，
测试专属调度接缝释放/重获mutex，中间只调用生产complete/cancel/stop/available，模拟
“timeout后重获mutex时谓词已改变”的合法交错；不复制broker状态/条件算法。旧生产源在
已答/已取消/已stop/已不可用/已答但缓冲小5组失败，纯pending正控通过。修复后完整199项
断言分别通过ASan/UBSan/Werror和TSan（macOS host）；无Android或真实UI验收。
初版另有四个仅私有构建目录中的生产源变体负控均失败：RANGE 即丢答、session 创建重置 ID、
cancel 漏 broadcast、成功消费后仍留答。负控不编入生产或普通 fixture。

root 独立复跑 macOS ASan/UBSan/Werror 的 199 项；接入 CMake 后，在 Debian 12
ARM64 断网容器执行完整 `android/test.sh`：11/11 CTest（含 broker）、
Java/契约检查与 Python 14+7+8 项通过。该基线的 guest_signal fixture 假定
SIGRTMIN 初始为 SIG_DFL，测试父进程显式建立该前提，未改生产信号代码。
这些仍是 host 证据，不是 APK、真实 UI、NativeAOT/服务消费者、driver、游戏或
完整 W4 的通过证据。

## W11 / W3 后续最小接缝

W11 需先冻结：首个 UI request type/version及字段/UTF-8界限、reply/取消/未知类型规则、
RANGE长度语义与错误码解释，以及 producer-ready/session-stop/Activity替换的调用归属。
不能在此自行定义软件键盘的公开 JSON 格式，也不能复制 S2A SDK 寄存器结构。

现有 CMake 已把 broker 编入 Android native 目标，并把 host fixture 接入
`android/test.sh` 使用的 CTest；编入不等于注册 UI capability。
W3 后续在 bridge.cpp 接正式 take/complete/session stop 与 JNI 所有权。
W4 shell 以后才实现 schema-aware producer/主线程投递/取消旧 UI；C# 公共消费者需共同审查。
本次没有修改触点 JNI、HostApi 公共 ABI 或正式 UI 协议。
