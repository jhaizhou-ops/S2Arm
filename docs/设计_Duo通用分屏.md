# Duo 通用上下分屏：接口草案与拆分

关联任务：[#249](https://github.com/jhaizhou-ops/S2Arm/issues/249)。按维护者建议分三步评审；以下接口边界仍待维护方确认。

## 三步交付

| 顺序 | 分支 | 本步内容 | 验收入口 |
|---|---|---|---|
| 1 | `ios/duo-layout-policy` | 区域计算、分屏三态与独立方向策略 | `make native-test-play_layout` |
| 2 | `ios/duo-output-area` | 两条出图路径读取统一游戏区域；固定补丁热切保护 | 上一步检查与 `make native-test-widen_ios_screen` |
| 3 | `ios/duo-touch-layout` | 接入窗口生命周期、设置、下区按键与编辑存储 | 区域、按键、存储、方向及 Swift 检查 |

后一步以先前分支为基线。前两步准备接口，第三步一起接通设置、窗口与输入，避免分屏只接了一半时影响游戏操作。

## 第一步接口

区域计算放在 iOS 平台壳的 `ios/play_layout.*`；不加入游戏专用配置。它不调用 UIKit、不获取铰链状态，输入由后续窗口适配层提供。

- `S2APlaySplitEnabled`：自动仅半折开启，开启始终开启，关闭始终关闭。竖屏与折痕矩形本身都不代表半折。
- `S2APlayPortrait`：自动随分屏请求竖屏或横屏；手动方向独立于分屏。
- `S2APlayLayoutMake`：返回游戏目标区、按键区和折痕保留区。横向折痕按上下边界分隔，否则按窗口中线；上下区分别扣除安全区。竖向折痕保留给按键避让使用。
- `S2APlayControlsRect`：在按键区保留左右至少 16 点、底部至少 8 点。
- `S2APlayTargetSize`：由游戏目标区的宽高比计算目标画布，只扩展一边、保持偶数像素并沿用尺寸上限。目标区不同于已经按比例放入的实际出图矩形。

两项偏好通过 `NSUserDefaults` 读取：`S2ASplitScreen=auto/on/off`、`S2AScreenOrientation=auto/landscape/portrait`；缺省或错误类型均按自动处理。这一步不开放设置入口，现有游戏壳和按键行为保持原状。

## 可复跑检查

`runtime/tests/t_play_layout.m` 使用手算期望，覆盖 21 项：三态、方向、横竖折痕、非零原点、无效折痕、目标比例及偏好值读取。检查使用合成数据，无商业资源，不构成 Duo 真机或游戏画面验收。

后续固定比例路径提示重启；普通与分屏几何分别存储、继续共用按键 / 触屏模式。具体实现随第二、三步提交，本步不预先声称已接通。
