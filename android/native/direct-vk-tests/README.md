# Android Vulkan 直连第一批原生接缝（#274）

生产实现是相邻的 `direct_vk.c`、`direct_vk.h` 和 `direct_vk_commands.inc`。
无游戏输入的测试不要求密钥，不修改已装游戏，也不联网。

```sh
python3 android/native/direct-vk-tests/run.py \
  --ndk /path/to/android-sdk/ndk/29.0.14206865 \
  --out /absolute/path/outside/checkout
```

默认只编译，不把构建成功当成设备执行通过。显式在自有 ARM64 设备上复验：

```sh
python3 android/native/direct-vk-tests/run.py \
  --ndk /path/to/ndk/29.0.14206865 --out /absolute/path/outside/checkout \
  --adb /path/to/platform-tools/adb --device-file /private/device.json
```

`device.json` 只含 `serial` 字段。序列号不进入回执或输出；脚本使用
`/data/local/tmp/s2arm-direct-vk-stage1`，只写本任务的工具。可选 `--imports`
接受每行一个 Vulkan 命令名的本地文本，只验证入口可解析性，不能当成命令语义覆盖。

- `run_shutdown_contract.py`：主机受控驱动编译实际 `direct_vk.c`，检查已受理 acquire 停止时先出账再 park、终局 present 遇 NOT_READY 后继续等待退休；接入 Android 主机门禁。
- `bridge_test.c`：实际生产桥接层＋实际 `wsi_lease.c`，Vulkan 驱动是受控分派。
  覆盖扩展枚举的 count/短缓冲/layer 行为、NN→Android 改写、回调拒绝、窗口 token
  与 ABI 验证、失败回滚、真实撤销超时、销毁后确认、阻塞放核配对及原始错误传递。
- `driver_probe.c`：真实 Android `libvulkan.so`。通过生产桥接层创建实例/设备/缓冲，
  录制复制与 transfer→host 屏障，提交后等真实 fence，比较 4096 字节，按依赖释放对象。
  此程序从宿主线程发起，没有可见 Surface，不冒充游戏上屏验证。
- `xstack_probe.c`：真实 `runtime/src/xstack.c`、`entry.S`、Android `plat_android.c`
  和 Bionic TSD。64 轮从保护页夹住的 16 KiB 客体栈各作一次静态和动态取名调用，
  核对客体与宿主实际 SP 区间。Vulkan 查询体为受控函数。
- 七个负控分别删除入口包装、扩展改写、失败清理、阻塞放核、allocator 检查，或提前
  释放窗口；另将不包装的实现用于真实切栈用例。预期失败，不能把编译失败算负控成功。
- `session_test.c`：冷启动模式与描述文件校验。通用模式不初始化Vulkan；直连模式冻结
  选择及驱动模块集合；重复配置/热切换拒绝，坏格式或重复模块不发布直连状态。

`results.json` 记录源码 SHA、每条命令退出码及设备是否执行；原始 driver、xstack、
受控用例和负控日志独立保留。不能凭这些原语测试宣称游戏已直连或性能达标。
