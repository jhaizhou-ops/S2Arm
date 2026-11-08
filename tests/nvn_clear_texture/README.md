# ClearTexture 有符号整数真 GPU 回归

在仓库根目录、项目 Apple 工具链与 .NET NativeAOT 环境中运行：

```sh
make -j1 native-test-nvn_f
```

测试复用 `runtime/build.mk` 的生产宿主对象、当前 NVN 库与实际 Widen NativeAOT，产物在 `build/tests/`，共享依赖在 `build/tests/nvn/`。它通过生产 NVN bootstrap 取址，核对 `swnvn` 语义注册与 `DeviceGetProcAddress`；通过公开 API 建立 device、queue、memory pool、texture、view 和 command buffer，录制清除、提交、等待完成并读回。没有宿主替身、内部对象或手造命令。

9 组逐 texel 核对手定值：RGBA8I 负值、RGBA32I 精确 INT32 边界与 2²⁴+1、8/32 位有符号格式视图、mip 与数组层选择、录制后修改 rgba/view/region 的快照，以及原有 float/uint 两种清除回归。mip 用例还检查未选中的级别与数组层保持先前 GPU 清除的哨兵值。

Apple M5 Pro 本机实际运行：9 组、764 个 GPU texel 全部通过。

本测试覆盖整 mip、完整通道 mask 的支持路径。局部区域与部分通道清除仍未实现；本机接口回归不代表游戏、iOS 或安卓运行验证。

测试没有装载游戏，宿主初始化会记录程序号 0 的缺省图形模式和未知参数表诊断；这里直接调用生产 NVN API 并核对 Metal 读回，不以宿主启动日志代替游戏直连证据。
