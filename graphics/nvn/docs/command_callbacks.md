# CommandBuffer 回调查询（#270 D 组子片）

原独立验证基线为 `34bd2907`；当前分支叠在 #299 的 `7e2f2a84` 之上。补充 `nvnCommandBufferGetMemoryCallback` 和 `nvnCommandBufferGetMemoryCallbackData`，直接返回生产命令缓冲对象已保存的回调函数、用户数据指针。初始化时均为空；Set 替换相应值，Begin/EndRecording 保留它们。查询不分配内存、不录制命令、不调用回调。

## ABI 与状态依据

仓库头文件将 `GetMemoryCallbackData` 错写为返回 `void`。两份自有游戏 SDK 均明确读取完整 64 位指针后返回，因此源头声明修正为 `void *`，再由 `translator/gen_protos.py` 重生签名检查表；两个实现均使用正式 `NVN` 宏。

| 自有 SDK | SHA-256 | Set / Get 回调 | Set / Get 数据 |
|---|---|---|---|
| 怪猎崛起 16.0.2 | `1c9f198a91c0bcfee5cf8f5b53fb941895e91334dfb766ce79fc68576797f017` | `0x45cdd0` / `0x45cdf0`，对象 `+0x8` | `0x45cde0` / `0x45ce00`，对象 `+0x10` |
| 惊奇 1.2.1 | `73bec5989030d4d9f056503066180a6100bb7937370a4d818c8ba53960dfa2f3` | `0x442f20` / `0x442f40`，对象 `+0x68` | `0x442f30` / `0x442f50`，对象 `+0x70` |

以上 getter 都是 `ldr x0, [x0, #字段偏移]; ret`，setter 对同一字段存入 `x1`。两份 SDK 的 Begin/EndRecording 均保留这些字段。实际间接回调调用点传入 commandBuffer、memory event、required size、保存的用户指针，与现有四参 `PFNNVNCOMMANDBUFFERMEMORYCALLBACKPROC` 一致。只静态检查 SDK，没有执行或分发游戏代码；表中偏移仅用于核对契约，生产实现使用自己的 `cmd_t` 状态。

## 范围与验证入口

`graphics/nvn/tests/t_nvn_d.c` 经完整生产 bootstrap、`swnvn` 注册表和计数跳板访问 API，链接真实原生宿主、NVN 与 Widen NativeAOT。验证初始化、Set/Get、替换与清空、多对象隔离、录制前后保留、重新初始化，以及查询不改变对象或触发回调。测试从真实内存池提供命令内存；两个回调都被生产录制路径实际调用并供给内存，不是链接替身。运行 `make native-test-nvn_d`，或用 `NVN_D_TEST_QUERY=<完整函数名>` 单独验证一个查询。

Apple M5 Pro / macOS 27.0、Xcode 27.1、.NET 10.0.402 上，两项查询共 410 条真实 API 断言通过。内存池初始化会创建真实 Metal 设备，但此测试不提交 GPU 命令、不装载游戏。原生宿主构造函数仍提示测试目录没有 `main.npdm`、未预留游戏地址窗口；测试对象和命令内存由本机分配，不以这条提示作为游戏启动验证。

两项分别做错误输出反证：临时将对应生产 getter 改为返回 NULL，按函数名过滤运行，均在 Set/Get 阶段的指针相等断言失败、退出 1。恢复生产实现后全组 410 条断言再次通过。原始日志留在本地 `build/nvn-d-{first,mutation-callback,mutation-data,restored}.log`。

共享构建集成验证：`make native-test-nvn_a native-test-nvn_d` 在同一次调用中通过 A 组 360 条与 D 组 410 条断言；`make -C gfx/nvn mac` 和 `dotnet publish` 在该构建日志中各出现 1 次。两组使用同一套 `NVN_TEST_HOST_OBJS` / `NVN_TEST_LIB` / `NVN_TEST_WIDEN`，D 组只增加链接与运行目标。证据为 `build/nvn-ad-shared.log`；生产 bootstrap 为 446 个语义入口 + 14 个空操作，未实现 76。

## 正式分类工具核准

分类器已在 main 的正式提交 `b475a624b9e3afeb1a9997792d2b5d713dbb5e6b` 修正，识别同样登记进 `swnvn` 的 `NVN_NOPROTO`；本片仅同步该文件，`git diff b475a624 -- graphics/nvn/tools/nvn_func_table.py` 为空。

实际执行维护方命令 `python3 graphics/nvn/tools/nvn_func_table.py | awk -F'\t' '{c[$2]++} END{for(k in c) print k, c[k]}'` 与 `python3 graphics/nvn/tools/nvn_func_table.py --md`，均得到 443 已实现 / 3 部分 / 14 空操作 / 76 未实现（0 局）；旧工具的 436/3/14/83 保留为历史口径。输出为 `build/nvn-d-official-classifier-counts.log`、`build/nvn-d-official-classifier.md`。

这次提交只有官方工具和文档增量，运行时、测试及构建保持原自检提交 `25d54e9e` 不变；没有重新运行 NVN、GPU 或 iOS 构建，已有自检证据仍对应原提交。

本片不补 copy stride、control memory 和 callback-enable 行为。copy stride 由 #310 单独处理对象状态与录制快照；control memory 仍缺少生产记账，不能用这些查询的实现方式推定已经支持。

没有游戏或真机运行证据，九款金样由维护方验收；CPU 状态查询测试不等于所有内存回调行为或 GPU 回放通过。
