# 显式 provider owner 的 host 回归

在 macOS 上运行（需要现有 .NET 10 SDK、Xcode CLI 和已恢复的 NuGet 包）：

```sh
python3 android/core-link/provider-tests/run.py \
  --out /tmp/s2arm-provider-owner-tests
```

`--out` 必须在 checkout 外。恢复只使用 `--packages` 指向的本地缓存（默认
`~/.nuget/packages`），缺包明确失败，不联网补包。每个场景都新起进程，避免把热换
provider 当成支持的产品能力。`commands.json` 和逐步日志保存在输出目录。

测试直接编译生产 `Native.cs`、`AndroidSelfTest.cs`、`NativeTickSource.cs`、`Red.cs`
及其接口。C 文件是作者编写的 loader fixture，只实现测试调用的 ScreenW/BootMark
和可选导出，不实现原生 core。macOS 的真实 `dlopen(RTLD_LOCAL)` 形成主程序看不到
符号的条件；另一个真实 GLOBAL 库形成主程序能看到错误 sentinel 的条件。fixture
工作目录让 `NativeLibrary.Load("libs2arm_android.so")` 能找到同一个库，不拦截
`NativeLibrary.Load` / `TryGetExport`。仅 JIT 的 `s2a_native` P/Invoke resolver 指向
该库，代替产品 NativeAOT 的静态 DirectPInvoke 链接。

覆盖实际 AndroidSelfTest → Native → NativeTickSource/确定性写入路径：

- 主程序不可见和主程序错误 sentinel，实际 owner 的 clock 必须命中。
- 无可选导出的诊断库可运行 selftest，报告 absent，清除预先注入的旧 extras。
- 任意方向的半组 det 必须在发布前失败，全部 21 个基础槽和 3 个 extras 保持进入前状态；失败不锁定 owner。
- 同 owner 重复绑定、重复真实 selftest 保持指针；释放 fixture 自己的额外引用后，composition 的引用继续保活。
- 已成功发布后，零 owner、另一 owner、另一绑定合同都拒绝，原表不变。
- Apple 无参入口保留主程序查找、缺 clock 报红、半组 det 按整组 absent 的既有语义。

生命周期合同：composition 第一次 selftest 取得实际库句柄，进程期保活；同 owner
重复调用使用 `Lazy` 缓存，无卸载或热换。绑定须在消费者启动前完成，锁只串行化绑定，
不宣称公开的可写函数表能在并发消费者运行中原子换表。该测试未动态计数 dlopen
调用次数；一次获取/从不 Free 的性质由生产 `Lazy` 及无释放路径共同保证。

这些结果只验证 host 加载器与托管消费者，不验证 Android linker namespace、
NativeAOT 链接、21 个原生实现的完整性、S2A_Init 或真实游戏。诊断结果固定
`game_ready=false`；`Native.Ready` 的原含义未升级。Android 真机及 Apple 产品构建仍需
各自后续验收。本基线没有 `tools/contrib_check.sh`，本测试不冒充该检查。
