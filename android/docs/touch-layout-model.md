# B6-1：F01 布局数据与编辑模型

对应 [#1576](https://github.com/jhaizhou-ops/S2Arm/issues/1576)，属于 [#1574](https://github.com/jhaizhou-ops/S2Arm/issues/1574) 的 B6 / P1 第 16 项。此片是编辑器的数据前置，不是已接入游戏的布局功能。

`TouchLayout` 读取既有 [F01 格式](../../docs/触屏布局_F01.md) 和 [iOS 参考方案](../../ios/layouts/classic-reference.json)，不另立安卓格式。布局对象和子对象不可变：`withButton` 调整已有按键中心、尺寸和圆角；`withStick` 调整已有摇杆的激活区与半径；`copyAs` 生成用户身份的副本。每次操作先验证整个候选布局，失败抛出 `IllegalArgumentException`，原对象保持不变。

读入按 64 KiB 字节上限、严格 UTF-8 与 JSON 数字语法检查；继续复用安卓 `Json` 的对象、数组、重复键与嵌套限制。新增 `Json.parseStrict` 仅由本模型使用，既有启动契约继续使用原 `parse` 入口。按 F01 核对字段全集、14 个必需按键和 2 个可选按键、左右摇杆、数值范围、圆角、区域边界与重叠。与 iOS 相同，跨字段几何边界允许 `1e-12` 浮点误差，单字段范围仍严格校验。

名称按 iOS `NSCharacterSet.controlCharacterSet` 拒绝 Unicode Cc 与 Cf（包含补充平面的格式字符），不能仅用 Java `isISOControl`；语义来源见 [Apple 官方文档](https://developer.apple.com/documentation/foundation/nscharacterset/controlcharacters?language=objc)。字符类别取宿主/安卓 Java 的 Unicode 表，尚未以所有 Unicode 版本对拍 Foundation。

`frameForButton` 与 `frameForStick` 共用私有投影函数，使用调用方提供的安全区：中心按安全区宽高缩放，尺寸按短边缩放，绘制框钳制在安全区内。摇杆编辑预览以激活区中心为圆心、`radius × 2` 为归一化直径；这不改变 F01 浮动摇杆在实际起始触点捕获圆心的语义。模型不猜测安卓 Insets，不定义热区、浮动摇杆捕获或触点所有权；这些由后续视图接线按 F01 实现。`jsonBytes` 导出 UTF-8 F01 文档，供后续沙盒保存/分享使用。读取允许辨识内置身份；`copyAs` 拒绝 `default` / `touch`，实际导入存储层也必须拒绝这两个保留 id。

## 宿主验证

```sh
python3 android/tests/touch_layout_model_test.py --negative-controls
```

需要 PATH 上的 JDK 11+ 与 Python 3，无 SDK、设备、第三方包或自动下载。生产/新测试以 `javac --release 11 -Xlint:all -Werror` 编译。`android/test.sh` 已调用本入口；既有 BootContract、TouchPad、GameTouch、TouchRouting 回归保留各自的调用。BootContract 原套件会创建符号链接，仍需支持该权限的宿主，不能用 Windows 普通权限执行结果冒充通过。

新测试直接读取仓库中现有 iOS 参考 JSON，验证解析、编辑事务、拒绝边界、不可变性及横竖屏安全区投影（按键和摇杆均覆盖，摇杆另测四边钳制）。Java 导出的结果另外由 Python 标准 JSON 解析，与“既有 iOS 参考方案加明确编辑”的独立期望逐字段比较。可选负控在临时目录把摇杆直径误写为半径、撤掉摇杆重叠或未知字段校验，必须在对应断言变红；不改生产文件、不下载依赖。

## 未完成的接线

本片不调用 `TouchLayout` 驱动 TouchPadView，不修改默认布局、屏幕手柄显示、JNI 和客体输入。后续需要编辑入口、拖动/缩放/取消、F01 绘制/热区/浮动摇杆适配、沙盒原子写入与选择记录；再做安卓设备多指、Insets/旋转、失焦/后台、管理页释放与进程重启验证。宿主测试与 Windows 编译不能代替这些证据。

B6-2 须补屏幕坐标到模型坐标的反向映射，供拖动/缩放把手指位移换回模型单位。未钳制时，反向映射应与本片投影互逆，单测验证「投影 → 反投影」回到原值。边界钳制会丢失原始中心信息，须另测边界策略，不能把被钳制的可见框当作能唯一恢复原模型坐标；保留原模型与编辑位移的责任由后续编辑器明确。
