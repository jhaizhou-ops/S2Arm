# #274 一加 Vulkan 直连操作与退出复验（2026-10-25）

## 身份与范围

- 设备：OnePlus PJA110 / SM8550 / Adreno 740 / Android 15 / API 35 / 4KiB。
- 样本：哈迪斯 1.0.38233，Build ID `d41357a3da356b09fa400b90f303b564`。
- v46 APK SHA256：`dc46611472d5d4bcf4a70b011bc7736ec383d5a34f3b0d95b1750bc0072e7e7a`。
- v47 APK SHA256：`6251bd5ef51725bc9b01104215036385d997ccbf09607981258a245221d18951`；移除上一帧present未退休就禁止获取其他可用图像的额外等待。
- 分支：`android/vulkan-direct-wsi`，在 ae9a79bb 上修正终局对象清理；恢复原 1.5 秒 watchdog。
- 仅使用玩家本地资源；APK、存档、截图、会话日志留在本地 `build/at01/oneplus/hades-v46/`，不随仓库交付。

## 操作证据

一加实际截图是 2772×1240；预览缩放至2048宽时，不能直接把预览像素交给ADB。
此前的 `(2134,568)` 没有命中虚拟 A。按完整截图和生产布局核对，A约在 `(2588,694)`、Y约在 `(2270,694)`、B约在 `(2428,837)`；这些坐标仅属于本次设备测试，不写入运行时。

v43 未改手柄代码即以真实触摸得到 A `0x0001→0`，从标题进入存档页；v46 复验覆盖 A 180ms按压、A短点、左摇杆移动、Y持续按压挥剑、B短点冲刺，实际游戏画面发生对应变化，输入松开后回零。截图为 slots、before-move、after-move、attack、dash，日志为 input.log。

v46 第一局开启 Khronos CPU validation：进入实际场景并操作后，通过 `s2arm.finish` 结束；GPU/present fence排空，全部登记子对象先释放再销毁device，完整退出0.542秒；同PID退出记录为EXIT_SELF/status=0，当前会话无validation error。标题页v45同路径退出0.419秒，无validation error。

v46 同APK关闭validation重开后再次到实际场景，移动/挥剑/冲刺、松开回零，退出0.254秒；v47重复该操作退出0.304秒。零时长ADB tap在v47存档页曾未被采样到，180ms按压可触发；本轮不宣称任意零时长事件可靠送达。

v47 再次冷启动加载 `VK_LAYER_KHRONOS_validation`（同PID loader日志证实），返回标题并正常退出0.614秒，EXIT_SELF/status=0，当前会话validation error为0；测试结束恢复此前的GPU诊断设置。

## 游戏内帧率

取真实成功queue-present累计计数的只读8字节采样，不暂停进程；每局实际场景窗口60秒，包含移动/挥剑/冲刺及站立，排除标题和载入。没有GPU执行时间/扫描输出/逐帧慢帧比例证据。

| APK | validation | 平均成功呈现节拍 | USB供电 | 电量 / 电池温度 |
| --- | --- | --- | --- | --- |
| v46 第二局 | 关 | 52.96 FPS | 是 | 61% / 31.2°C |
| v47 第一局 | 关 | 54.22 FPS | 是 | 61% / 32.5°C |

两次不同热状态的单局结果不证明稳定性能收益；尚未达到60 FPS，不能用标题页60 FPS替代。

## 退出实现修正

`VUID-vkDestroyDevice-device-05137` 是有效用法错误，不是最佳实践提醒；设备销毁不免除子对象的显式释放责任。删除大于64个对象时直接清零账本的分支。规范来源：[vkDestroyDevice](https://docs.vulkan.org/refpages/latest/refpages/source/vkDestroyDevice.html)。

宿主分配表原先对每次free做线性查找。收尾静默后一次排序，固定前缀二分查找并保留退休标记，临时scratch追加在尾部；不回调已经停车的客体分配器。真实游戏v45退出处理266,237次客体分配释放记录，完整收局0.419秒，证明旧“驱动不支持逐项销毁”的结论不成立。该数据不证明所有驱动都已覆盖。

## 自动验证

- 新增独立驱动计数夹具：128个子对象必须全部销毁才能销毁设备；旧阈值分支断言退出134，修复后通过。
- 75,000条分配记录FIFO释放：同一加旧搜索916.2ms，二分版本7.9ms；另覆盖退休记录不重复释放、终局scratch重分配保留内容及释放归零。
- `direct-vk-tests/run.py`：编译/签名、受控派发、真实驱动/xstack/终局清理、既有12项破坏负控及新夹具通过；原始证据在本地 `virtual-wsi/final-v46`。
- 本机Xcode26.3执行 `make native-test-lifecycle`：0处不符；没有改动Apple执行路径。贡献者整套门禁结果另附PR。
- Android生命周期夹具补齐前次新增入口的测试provider，NDK编译后在一加运行10个成功/失败/信号/看门狗场景，退出码符合预期；hang与满stderr场景分别1.576/1.537秒退出124。夹具不替代真实客体静默证明。
- 新增WSI可用图像夹具：一张图像present仍pending时，另一张图像可正常acquire；旧实现超时断言失败，修复后通过。不伪造旧图像退休。

## 验收边界

当前结论限于上述功能链路与已记录的退出场景。没有把标题页FPS当作游戏内性能、没有把退出码0当作validation通过。

零配置自动选择仍未启用（`s2a_vk_lib_ready` 返回0，测试显式启用直连）；整机≤3.7W未测，USB供电且电流/电压sysfs节点Permission denied；窗口切换/旋转/后台压力、其他GPU与长期存档恢复不在本轮证据中。因此不能声明#274全部要求或产品全部指标已完成。
