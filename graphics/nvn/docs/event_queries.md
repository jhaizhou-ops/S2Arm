# Event 存储查询（#270 B 组子片）

补充 `nvnEventGetMemoryPool` 与 `nvnEventGetMemoryOffset`。两入口原来只有名称和跳板，会进入未实现失败路径；现在返回 `EventInitialize` 时保存的真实内存池指针和偏移。基线为 #299 `18d1b320` 与 main `1b966a81` 的合并提交 `b809bab9`，复用前者的完整生产测试链接。

## 语义与 ABI

两份本机自有游戏 SDK 的函数表及指令给出一致结果；只做静态读取，没有执行或提交 SDK。

| 样本 | SDK SHA-256 | GetMemoryPool 入口 | GetMemoryOffset 入口 |
|---|---|---|---|
| 怪物猎人：崛起 16.0.2 | `1c9f198a91c0bcfee5cf8f5b53fb941895e91334dfb766ce79fc68576797f017` | `0x46be70` | `0x46be80` |
| 超级马力欧兄弟 惊奇 1.2.1 | `73bec5989030d4d9f056503066180a6100bb7937370a4d818c8ba53960dfa2f3` | `0x452790` | `0x4527a0` |

两个查询均接收一个对象指针，分别把对象 `+0x10`、`+0x18` 的 64 位字段返回到 x0。怪猎 `EventInitialize` 的 `0x46bdc0` 将 Builder 的 pool 与 offset 存入这两处；惊奇同样保存这两个字段。因此查询的是初始化快照，不能改为读取当前 Builder 或从 `val` 猜池。

指令只能证明 arm64 参数和返回的宽度，不能证明原 C 头的 `const` 或 `ptrdiff_t / int64_t` 拼法。项目采用 `const NVNmemoryPool *(const NVNevent *)` 与 `int64_t(const NVNevent *)`；后者沿用现有 EventBuilder SetStorage、GetMemoryOffset 和 GetStorage 输出的 `int64_t`。声明补入 `include/nvn.h`，由既有生成器重生 `nvn_protos.h`，保留正式 `NVN` 宏签名检查，不用 `NVN_NOPROTO`。

`ev_t` 在末尾追加 pool 和 offset，arm64 大小 16→32 字节，仍满足 `FITS(ev_t, NVNevent)` 的 64 字节界限；`magic@0`、`val@8` 不动，新字段为 `pool@16`、`off@24`。EventSignal / GetValue 和命令缓冲的事件记录继续使用原来的 `val`，GPU 等待和信号行为没有改动。

未为未初始化或已经 Finalize 的对象新增返回值契约；SDK 中未见 offset 边界检查，不据此声称任意 offset 合法。

## 实际验证

Apple M5 Pro / 48 GiB / macOS 27.0，Xcode 27.1。`make native-test-nvn_event` 调用完整生产 bootstrap、swnvn 注册表与计数跳板；真实初始化 Device 及两个独立、页对齐的 MemoryPool，检查 Map 返回的实际 storage。无测试替身或手工拼对象内部字段。

- 107 个真实 API / 存储断言通过：零 offset、非零 offset、两个池、同池不同 offset、Builder 改池与 SetDefaults 后快照不变、Finalize 后重新初始化、对象前后边界。
- 每次查询后用 EventSignal WRITE / ADD 和 EventGetValue 对照真实 backing memory，确认保留的 `val` 路径仍对应预期位置；多个 Event 互不改写。
- Pool getter 临时改为 NULL，重编生产库后仅运行该查询用例，首个 pool 等值断言失败、退出 1。
- Offset getter 临时改为 0，重编生产库后仅运行该查询用例，非零 offset 阶段等值断言失败、退出 1。恢复生产代码后重新运行全组。
- Event offsets 均为 64 字节对齐且保留至少 64 字节存储空间。本机小池测试没有覆盖大于 4 GiB 的 offset；64 位宽度有静态 ABI 与源类型证据，不冒充该场景的动态验证。

对应完整日志保留在本机 `build/event/`。接口测试没有 main.npdm / 游戏程序号，宿主“不占游戏窗口”等环境诊断原样保留，不把单测通过称为零红游戏局。本片没有新增游戏局、真机、帧率或功耗证据，九款金样由维护方验收。
