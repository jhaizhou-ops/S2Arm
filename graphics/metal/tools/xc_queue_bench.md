# 首遇编译调度验证

> 通用链接版 10-30 删除（日志 0 次顶上）：下文的链接版分支、`NXGAL_PSO_FG`、`NXGAL_LINK_FORCE` / `NXGAL_LINK_HOLD` 随之删除，基础管线首遇现由主编译器直接建；以下为当时的测量记录。

运行时首遇着色器默认用 `USER_INITIATED` 队列编译（10-28 起；原 `UTILITY` 在宿主负载下被饿住，渲染线程首用时等它 = 优先级反转，见 docs/坑记录.md「喷3 冷局第 42 帧停帧」）。iOS 仍是 2 槽；Mac 保持 `max(activeProcessorCount / 4, 2)`。绘制线程首用仍等待正确结果，不跳绘制。

诊断环境变量 `NXGAL_XC_QOS=utility` 显式回到旧档（A/B 用），`user-initiated` 显式选择默认值；其他值立即报错。它不进入产品设置。队列初始化日志报告所选档位和槽数。

`xjob` 也承接主机缓存重建后的 `CreateProgram`，目前没有区分这种预热来源；普通的提前热程序表通过 `LoadProgramBinary` 载入，不经过 `xjob`。MSL 编译仍调用 `MTLDevice`，首用通过 semaphore 等待，尚未测量 XPC 内部提优。Apple 的 [Metal 4 编译说明](https://developer.apple.com/documentation/metal/using-the-metal-4-compilation-api) 对 `MTL4Compiler` 描述了优先级继承与依赖提优，不能据旧 MTLDevice 路径的对照推断 Metal 4 请求不能提优。

## 必需 PSO 与后台任务

默认正确绘制路径保留原有后台创建、链接版顶上和链接失败后等待的顺序。`NXGAL_PSO_FG=1` 显式开启试验路径：先查归档，再尝试正确的链接版管线；只有链接版已经可绘制，才把完整版排进后台队列。链接版缺失时直接调用主编译器创建必需 PSO，避免先排在归档补录 / 特化预热的共享槽后，再由绘制线程等待。真正的首次 PSO 编译仍可能阻塞当前绘制，不能据此声称消除了冷编译停顿。

显式 `NXGAL_PSO_ASYNC=1`、`NXGAL_LINK_FORCE=1` 和 `NXGAL_LINK_HOLD=1` 保留原有诊断口径。后台 PSO 队列仍是 UTILITY / 2 槽；本次不扩大并发，也没有改变设备归档写盘锁。重排继续调用现有创建接口，因此归档首次未命中后，最终创建接口可能再次查索引；已有分片对象会复用，不会因此重新映射整库。若后台创建接口意外返回归档命中的完整版，则清除临时链接版并优先使用该完整版。

Apple [WWDC25 的游戏编译建议](https://developer.apple.com/videos/play/wwdc2025/254/) 是预热 / streaming 采用 DEFAULT，并低于渲染线程；这适合后续区分需求与预热任务时验证。本次没有把所有后台 PSO 补录提高到前台优先级。

## 真实语料基准

`xc_bench --queued` 提交现有目录里按文件名排序的普通 `.spv` 文件，经过产品 `xjob_start` 的去重、槽与队列。等待端只收结果，不抢认领。每行报告工作线程进入编译时的 `qos_class_self()`、当时在编数、SPIRV-Cross 与 Metal 耗时；退出码检查全部编译成功、实际 QoS 正确、在编数没有超过原槽数。

每个进程运行一遍；`.vt.spv` / `.fbf.spv` 需要专门翻译参数，因此不纳入这条入口。此模式保留指定 MSL 缓存，也不清系统 Metal 缓存。原来不带 `--queued` 的两遍同步基准行为不变。

在仓库根目录构建，令 `qos_bench_corpus` 指向已有的真实游戏 SPIR-V 目录：

```sh
make -C graphics/metal DEVELOPER_DIR="$(xcode-select -p)" "$PWD/build/gal/xc_bench"
NXGAL_XC_QOS=utility build/gal/xc_bench --queued "$qos_bench_corpus" build/xc-qos-utility 128 > build/xc-qos-utility.tsv 2> build/xc-qos-utility.log
NXGAL_XC_QOS=user-initiated build/gal/xc_bench --queued "$qos_bench_corpus" build/xc-qos-initiated 128 > build/xc-qos-initiated.tsv 2> build/xc-qos-initiated.log
NXGAL_XC_QOS=utility build/gal/xc_bench --queued "$qos_bench_corpus" build/xc-qos-utility 128 > build/xc-qos-utility-repeat.tsv 2> build/xc-qos-utility-repeat.log
```

新缓存目录只控制本项目的 MSL 缓存，不能制造系统 Metal 冷缓存。先运行的档位可能付出真正的 Metal 编译成本，而后一档命中系统缓存；不能用这种顺序差值计算 QoS 收益。需要目标设备同一场景的受控测量才能回答卡顿改善多少。线程 QoS 读数也不等于已测到 Metal XPC 服务内部优先级。

## 本地验证记录（2026-10-23）

使用保留的 SMBW v1.2.1 真实提取语料，共 20,567 支普通 SPIR-V，固定取文件名排序前 128 支。其键与本次 iPad 冷日志的 319 支首遇键不重合。本机原槽数为 4。

| 运行顺序 | 实际 QoS | 成功 / QoS 不符 | 峰值并发 | 墙钟 | Metal 中位数 |
| --- | --- | --- | --- | --- | --- |
| UTILITY，首次项目 MSL 缓存 | `0x11` | 128 / 0 | 4 / 4 | 6171.9 ms | 134.28 ms |
| USER_INITIATED（采集时默认），另一空 MSL 缓存 | `0x19` | 128 / 0 | 4 / 4 | 183.1 ms | 0.19 ms |
| UTILITY，复用首遍 MSL 缓存 | `0x11` | 128 / 0 | 4 / 4 | 15.2 ms | 0.18 ms |

这些结果证明真实线程档位、原并发限制和编译成功；后两遍的 Metal 时间说明系统缓存已经热，不能据此认定 USER_INITIATED 加速了冷编译。此组既有数据采集时 USER_INITIATED 还是候选默认值；当前已恢复 UTILITY 默认，USER_INITIATED 必须显式开启。

同一源码的既有检查：`t_prog` 91/91、`t_aa` 130/130、`t_draw` 107/107；`gal_prog.m` 以 iOS 26 arm64 目标编译通过。非法 QoS 的独立子进程立即输出允许值并以 `SIGABRT` 退出。产物与日志位于 `build/xc-qos-check/`。未重启设备游戏，未删除项目或系统着色器缓存。

PSO 重排后的最终检查：`t_psoasync --sync` 4/4、显式异步 6/6、强制链接加 `--sync` 4/4、`NXGAL_VPULL=1 t_psodev` 4/4、`t_psopf` 7/7、真实归档登记门禁通过；程序 91/91、AA 130/130、绘制 107/107 重跑通过。最终 `gal_state.m` / `gal_prog.m` 均以 iOS 26 arm64 目标编译通过。

真实断点验证使用已有 `t_psoasync` 和顶点自取：候选前台路径首次绘制命中 `gal_link_base` 1 次，`gal_new_render_pso_async` / `gal_pso_job_wait` 均为 0 次，首帧与后续渐变像素检查通过。另一轮使用 `t_psodev` 真编译并序列化的归档：命中新普通分支的创建接口，`g_pso_hit` 从 0 变为 1，现编 / 特化均为 0；两次 RG16F 读回逐字节一致。日志分别为 `pso-link-miss-lldb.log` 与 `pso-archive-hit-lldb.log`。这些结果验证分支与计数，不是卡顿改善幅度的测量；该前台路径当前仅在 `NXGAL_PSO_FG=1` 时开启。

## owner 审查后的默认值回归（2026-10-23）

恢复 UTILITY 默认、为前台 PSO 路径加开关，并将 AA 的函数描述、参数表和计算派发收进 `gal_be.h` 后，Metal 4 直接调用计数回到既有基线 172，未改基线。`t_aa` 130/130；`t_psoasync --sync` 默认与 `NXGAL_PSO_FG=1` 均 4/4，显式异步 6/6；`t_psopf` 7/7。

顶点自取下的真实断点回归确认默认首次绘制分别调用链接尝试、后台创建、等待各 1 次；`NXGAL_PSO_FG=1` 分别为 1、0、0 次，两轮像素检查均 4/4。`t_psodev` 的普通顶点输入、默认顶点自取及前台试验三种路径均 4/4；默认顶点自取的基础管线直接由后台编译器序列化，补录计数为 1，另两种路径为 2，三种都写入基础管线与完整管线两条，下一进程的像素逐字节一致。

使用 `verified-main-02/spirv` 的真实游戏语料按文件名排序前 128 支，默认 UTILITY、显式 USER_INITIATED、显式 UTILITY 三个独立进程均 128/128，实际 QoS 为 `0x11`、`0x19`、`0x11`，不符数均为 0，峰值并发均为原有 4 槽。系统 Metal 缓存随后变热，不能从顺序耗时推断冷编收益。非法值 `invalid` 立即报错并以 `SIGABRT` 退出。日志为 `build/review-metal-qos-*.log`、`build/review-metal-pso-*-lldb.log` 与 `build/review-metal-psodev-*.log`；`gal_aa.m`、`gal_state.m`、`gal_prog.m` 均以 iOS 26 arm64 目标编译通过。未运行设备游戏。
