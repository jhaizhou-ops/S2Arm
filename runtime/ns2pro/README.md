# iOS NS2Pro 模块

在 iPad / iPhone 系统「设置 → App → 对应游戏」打开「启用 Switch 2 Pro 手柄适配」，
再回到游戏轻点连接按钮，并长按手柄顶部 SYNC 键。每个 App 的开关默认关闭，
历史连接记录和其他游戏的开关不改变此默认值。退出 App 后重新连接仍可能需要
SYNC；记住系统 UUID 不等于完成 Nintendo 主机绑定。

`make ios` 在 App 内构建 `Frameworks/NS2Pro.framework/NS2Pro`。主程序不链接
此 framework 或 CoreBluetooth。宿主先检查默认关闭的每 App 设置，开启后才用
`dlopen` 加载模块，并用 `dlsym` 获取唯一导出的 C 符号 `ns2_module_api`。
入口只返回不可变函数表，不创建蓝牙管理器；只有 `start_with_motion` 开始会话。
模块句柄保持到进程结束，运行中关闭设置时调用 `shutdown`。
关闭时移除连接按钮、废弃输入与反馈会话、停止 BLE 并释放服务侧反馈对象；
关闭后的冷启动不加载 NS2Pro 镜像、不读取设备记录。系统 GameController
手柄和触屏继续使用通用输入路径。

`include/NS2Module.h` 定义 ABI 第 1 版。宿主使用函数表前检查 `abi_version` 和
`struct_size`；值类型和回调沿用 `include/NS2Transport.h`，不直接链接其实现。
回调在串行 BLE 队列执行，context 必须存活到 `shutdown` 返回。
`authorization_denied` 仅读取系统授权状态，不创建管理器或发起权限请求。

传输保留工厂摇杆校准、Nintendo 按键位序、report05 运动样本、原始左右侧低高频
幅度及频率、42 字节双频震动编码、增益校验与有界震动租约。只有活动震动保持
15 ms 调度，背压只保留最新 mailbox，停止包优先。编码器与纯解码器从现有
S2Arm 集成原样迁移。模块不含主机地址绑定、readback 命令、诊断扫描或震动
trace 记录器。

前台启动先取回上次达到 READY 的系统外设；没有可取回的已知外设时扫描十秒。
有界直连失败后不自动转扫描。断线立即清空逻辑输入，只有显式 rescan 才重新
扫描。系统 UUID 是重连候选，不是 Nintendo 主机配对记录。候选和连接意愿仅保存
在当前 App 沙盒的 NSUserDefaults，不增加钥匙串权限。

已初始化链路进入后台前调用 `suspend`。返回接受不保证 iOS 保留物理连接。
暂停立即清空逻辑输入、运动和震动，提交零包，等待关闭 IMU 的 ACK，并退订
report09 后报告 PAUSED。report05 保持订阅，但暂停通知不进入游戏；完成暂停
后没有计时器期限。`resume` 丢弃首个 report05 候选，只用它建立计数基线，收到
计数前进的后续报告才重新 READY。订阅失效和超时显式报错。暂停或恢复请求被
拒绝时，宿主关闭旧会话。不申请蓝牙后台模式。

`make native-test-ns2pro`（别名 `make ns2pro-test`）运行迁移的真实报告回归与
震动编码契约检查，不访问硬件。真实 BLE 向量在
`tests/test_captured_reports.c` 中保留 PCAP 来源 URL 和帧号。编码检查证明字节
编码与参数校验，不证明物理震感。构建及符号检查证明模块边界；设备连接、系统
权限界面、后台保链和电机行为仍须实机验证。

来源是 S2Arm 已有的 `runtime/ns2pro` 集成，派生自
[ns2pro-bridge](https://github.com/DanielZhangyc/ns2pro-bridge)，基线提交为
`4d7ce09255cea4cea94f43568d5c2fc56e81d8a0`。协议依据和原作者版权保留在源码
中，完整 MIT 许可在 `LICENSE`，并随构建复制到 framework 内。

## 仅触屏路径的历史对照

在仓库根运行 `make native-test-pad`，直接检查生产 `pad.c` 的仅触屏路径：
16 位按钮逐位锁存、同一读取间隔内不同短按的并集、持有与释放、四轴边界，
以及普通读取与扩展快照交替。它还运行原有切源、后台隔离及并发快照检查。

运行 `python3 runtime/tests/support/touch_baseline_compare.py` 可复现迁移前后对照。
脚本从提交 `e4e5b78b` 和当前 `ios/vpad.m` 提取真实发布存储语句、
读取函数与录制函数，结合生产帧号和构建号读取函数编译运行，不复制一份旧算法
作为替身。当前用例共 41 次读取，按钮和四轴逐位一致；两边各写出 39 条真实
padrec 记录，除末尾墙钟毫秒外的字段一致，包含两次存档标记。毫秒使用真实
单调时钟，各自检查非负且不倒退，不要求两次独立运行耗时相等。
生成源码、输出和 TSV 保存在 `build/review-touch/`。

此对照预先打开录制文件，因此未验证 `rec_open` 首次建目录、选择文件名和打开
文件的路径，也未链接截图钩子或执行存档副本复制。帧号来自未运行渲染器的
生产帧计数器，保持为零。测试输入是宿主接口向量；没有验证 UIKit 真实触摸
分发、游戏采样或设备行为，不能据此声称完整录制路径或触摸实机验收通过。
