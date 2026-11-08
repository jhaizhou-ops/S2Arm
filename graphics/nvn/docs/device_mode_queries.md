# Device 原点与深度模式查询（#270 C 组子片）

原始基线 `f0852fba`；当前集成基线为 #299 的 `7e2f2a84`。`DeviceGetWindowOriginMode` / `DeviceGetDepthMode` 返回指定 Device 对象先前保存的枚举状态。Initialize 的缺省分别为 `LOWER_LEFT=0`、`NEAR_IS_MINUS_W=0`；两字段由各自 setter 更新，不互相覆盖。查询不写对象、不分配、不向 GPU 录制或提交命令。

## 契约依据

两份自有 SDK 的静态路径与仓库既有头文件一致；返回值为 32 位枚举，唯一参数为 `const NVNdevice *`，没有输出指针。没有执行或分发 SDK。

| 样本 | GetWindowOriginMode / GetDepthMode | Setter 与缺省 |
|---|---|---|
| 怪猎崛起 16.0.2，SDK SHA-256 `1c9f198a91c0bcfee5cf8f5b53fb941895e91334dfb766ce79fc68576797f017` | `0x466180` / `0x4660c0` 分别 `ldr w0` 读取对象 `+0x19d8` / `+0x19dc`，立即返回 | `0x466210` / `0x4661f0` 分别 `str w1` 写同槽；初始化 `0x46aee8` 清零寄存器后，`0x46aef0` 将两字段同时写 0 |
| 惊奇 1.2.1，SDK SHA-256 `73bec5989030d4d9f056503066180a6100bb7937370a4d818c8ba53960dfa2f3` | `0x44e180` / `0x44e0c0` 分别读取对象 `+0` / `+4`，立即返回 | `0x44e210` / `0x44e1f0` 分别写同槽；初始化 `0x451798` 将两字段同时写 0 |

这些地址仅用于静态核对，不进入生产判断。宿主 `dev_t_` 已保存 `origin` / `depth_mode`，本片通过正式 `NVN` 宏直接读回；复用既有签名检查，无需修改 ABI 声明、对象布局或 setter 的渲染状态更新行为。逐对象查询不取最近一次全局 Metal 状态。

本地静态证据：`build/nvn-device-mhr-sdk.txt`、`build/nvn-device-wonder-sdk.txt`。

## 验证方法与范围

`make native-test-nvn_c` 链接完整生产 NVN、原生宿主与 Widen NativeAOT，调用真实 bootstrap / swnvn 注册 / 计数跳板，不抽取另一份函数体，不提供测试替身。依赖共用 `NVN_TEST_HOST_OBJS` / `NVN_TEST_LIB` / `NVN_TEST_WIDEN`；`NVN_C_TEST_QUERY=<完整查询函数名>` 可单独运行一项。

测试在真实 Initialize 之前填充 opaque 对象，避免依赖调用者清零；覆盖默认值、合法 0↔1 切换、两字段独立、多 Device 交错、Finalize 后重新初始化。查询前后比较完整对象，并检查对象前后边界。多对象用例有意让另一对象最后设置的全局渲染状态与当前查询对象不同，捕获错误地读取全局状态的实现。

原始 `f0852fba` 上的验证：Apple M5 Pro / 48 GiB / macOS 27.0，Xcode 27.1、.NET 10.0.402，全组 244 条断言通过、退出 0。两项查询分别临时固定返回错误的默认值 0、重编生产库后，按函数名过滤运行；2/2 在各自 Set/Get 断言失败、退出 1。恢复真实实现后全组再次为 244 条通过。日志为 `build/nvn-c-mutant-{origin,depth}.log`、`build/nvn-c-restored.log`，最终源码与产物哈希为 `build/nvn-c-restored.sha256`。

## 与 #299 集成验证

变基到 `7e2f2a84` 后，继承 A 组生产实现、ABI 头文件和测试；共享 `NVN_TEST_*` 支持保留一次，只新增 C 组链接与运行目标。未引入 #303 / #309 / #310 的查询，两个 getter 的生产实现及测试均未改变语义，未重做原始反证。

同机实际执行 `make native-test-nvn_a native-test-nvn_c`：退出 0，A 组 360 条与 C 组 244 条断言通过；NVN 子 make 与 `dotnet publish` 各调用一次。当时使用旧分类器，`nvn_func_table.py --md` 实测为 436/3/14/83，完整 bootstrap 为 446 个语义入口、14 个空操作、76 个未实现。日志为 `build/nvn-c-builder-integration.log`，旧分类输出为 `build/nvn-c-builder-coverage.md`；源码与产物哈希为 `build/nvn-c-builder-integration.sha256`。这些记录保留为原集成验证。

## 正式分类工具核准

分类器已在 main 正式提交 `b475a624b9e3afeb1a9997792d2b5d713dbb5e6b` 修正，识别同样登记进 `swnvn` 的 `NVN_NOPROTO`；本片仅同步该文件，`git diff b475a624 -- graphics/nvn/tools/nvn_func_table.py` 为空。

实际执行维护方命令 `python3 graphics/nvn/tools/nvn_func_table.py | awk -F'\t' '{c[$2]++} END{for(k in c) print k, c[k]}'` 与 `python3 graphics/nvn/tools/nvn_func_table.py --md`，均得到 443 已实现 / 3 部分 / 14 空操作 / 76 未实现（0 局）。输出为 `build/nvn-c-official-classifier-counts.log`、`build/nvn-c-official-classifier.md`。

这次提交只有官方工具和文档增量，运行时、测试及构建保持原自检提交 `ba436104` 不变；没有重新运行 NVN、GPU 或 iOS 构建，已有自检证据仍对应原提交。

本片只补 CPU 对象查询，没有提交 GPU 命令、启动游戏或安装设备。完整宿主构造函数关于测试目录没有 main.npdm、未预留游戏地址窗口的提示保留；接口断言不是游戏或画面验收。本片不改变既有多 Device 渲染状态管理。
