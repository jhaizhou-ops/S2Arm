# 图形会话与释放队列回归

在支持当前 GAL 后端的 Apple Silicon Mac 上，从仓库根目录运行：

```sh
bash graphics/metal/tests/session/build_run.sh
```

脚本沿用生产 `graphics/metal/Makefile` 构建 `libnxgal.dylib`，使用 `DOTNET` 指定的 SDK（默认 `~/.dotnet/dotnet`）发布真实 NativeAOT 可执行文件。建议使用微软官方 .NET 10 SDK，与 `services/nxaot.sh` 一致。编译和运行产物均放在 `build/threaded-session/`；不替换渲染器、不注入宿主桩、不读取游戏、密钥或存档。

核心构建和正例命令为：

```sh
~/.dotnet/dotnet publish graphics/metal/tests/session/Session.csproj \
  -c Release -r osx-arm64 --self-contained -p:PublishAot=true \
  --artifacts-path build/threaded-session/official-art \
  -p:OutDir="$PWD/build/threaded-session/official-bin/" \
  -o build/threaded-session/official
NXGAL_LIB="$PWD/build/gal/libnxgal.dylib" \
  build/threaded-session/official/Session --native-create
```

正例在同一进程连续执行 10 局。每局使用真实 `ThreadedRenderer` 和 `NxGal`，完成 120 次纹理清屏、呈现及逐像素 GPU 读回；同时用生产截图入口读取实际呈现定格图，逐像素核对 BGRA 内容，不能只凭回调计数通过。再创建 10,032 个实际 Metal 小缓冲并核对末个缓冲的数据。停止并 join GPU 生产者后，编码线程继续消费释放命令。测试在 `Renderer.Dispose` 前读取原生资源账，要求所有缓冲均已释放；之后停止编码线程并销毁渲染器。第 2–10 局从 `NxThread.StartJoinable` 创建的原生 pthread 进入 NativeAOT 并建立新渲染器。

旧顺序负例主动先停止编码线程，再释放同样数量的真实资源：

```sh
NXGAL_LIB="$PWD/build/gal/libnxgal.dylib" \
  build/threaded-session/official/Session --stop-backend-before-disposal
```

负例必须返回 1，并报告“资源释放队列堵住”。释放命令超过 10,000 项命令环容量后没有消费者，故不能完成；测试不会通过提前清空队列或全局资源 reset 掩盖此故障。脚本同时检查正例成功和负例的具体错误。

测试没有窗口或 `CAMetalLayer`。生产呈现路径会定格纹理并提交 GPU，测试确认命令回调与读回；它不验证屏幕显示、实际游戏第二局、服务重建或 iOS 行为。

原生 NVN、GL、Vulkan 与 GAL 的退休阶段探针：

```sh
make BUILD=build/graphics-session S2A_CS=1 native-graphics-session-probe
build/graphics-session/probe_graphics_session
DM_METAL3=1 NXGAL_BE=mtl3 build/graphics-session/probe_graphics_session
```

探针链接正式宿主及 NativeAOT，不加载客体线程。每轮重用同一地址的 NVN 内存池，核对初始内容、GPU 清除与后续会话初始内容；GL 核对真实缓冲、FBO 清除读回和弱引用释放；Vulkan 通过正式入口创建设备、缓冲、图像和命令池，执行 GPU 清除/拷贝/读回，留下对象由会话退休释放。末尾核对普通终局封存后拒绝重新起局和完整退休。资源探针通过不等于游戏、联机或设备重启通过。

普通生产收局只执行请求停止、生产者 join、已有命令排空和编码消费者 join，并保留 GPU、追踪及客体地址引用至进程结束。系统调用 park 不能证明全部客体 writer 已静止，因此普通 `AfterShutdown` 不调用 `DisposeGpu`。

普通退出的各收尾步骤失败时报红并继续尝试输入、服务、存档及音频收尾，报红在此路径不触发 `Red.Strict` 的 FailFast。编码线程成功停止后释放 `GalRecorder`，使文件流写出末尾缓冲；停止失败时保留仍可能被写入的录像器。`AfterGuestJoinedShutdown` / `ShutdownSession` 继续严格拒绝不安全退休。

GAL 的 `nxgal-present` 是跨会话的 detached 宿主显示线程，退休时排空该局呈现与回调并撤去 `g_layer`，线程回到等待状态；它不属于每局退出/join 的显示线程。NVN 每局 display-link 的注销与 join 另由对应后端负责。

后续 C 片必须实际 join 全部客体线程并完成服务停止，然后调用 `AfterGuestJoinedShutdown(Switch)`：GPU 析构命令由仍存活的编码消费者排空，再 join 消费者，最后释放渲染器。若已经走过普通关闭，该入口和再次起局均明确拒绝。随后才可调用 `s2a_graphics_shutdown_session` / `s2a_graphics_native_shutdown_session` 清理 native 地址表、追踪和诊断引用。这些完整退休能力提供 guest-free 资源探针，须实际运行后才能记录通过；尚无 C 的生产接线，普通 App 退出不具备进程内重启能力。

2026-10-28 实测：Apple M5 Pro / macOS 27.0（26A428），生产代码 `c16601c3e`，实际定格像素判据 `6b4c7f474`。GAL 独立资源在 M3/M4 各完成 10 代；原生 NVN/GAL、GL、Vulkan 资源在两种后端各完成 10 代，其退出码均为 0。原生探针未加载客体 NPDM 或客体着色器包，相关启动红行保留，不能据此证明完整前端绘制或游戏冷启。

M4 ThreadedRenderer 完成 10×120 次源纹理与实际定格图逐像素核对，每代 10,032 个真实缓冲在 renderer 释放前归零；旧关闭顺序在第一代以“资源释放队列堵住”返回 1。强制 M3 的实际定格图在第一代第 0 帧缺失，测试返回 1：`gal_present.m` 仍向 M3 工厂交 `MTL4RenderPipelineDescriptor`，并直接使用 M4 参数表、通道描述与事件路径。隔离抽取冻结主线 `d4365a43f` 的原 `t_present` 同样返回 1（16/61 项通过、首张截图 0×0）。M3 完整呈现未通过，不是生命周期成功项。

正式自有 GLSL 包的 M3 归档/实际像素专项通过：原包命中 4、未命中 0，变更反证命中 0、未命中 2；原始日志保留“缺本机 Metal3 函数体动态库目录”诊断，该专项不证明链接动态库可用。未运行九款游戏、联机、iOS 或完整贡献者自检；这些结果不满足完整 App 重启验收。
