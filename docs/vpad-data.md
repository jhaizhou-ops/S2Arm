# 虚拟手柄数据包（vpad-data）

`ios/vpad-data/` 随 App 打包（`runtime/build.mk` 把整目录拷进 `.app/vpad-data`），放三类**按游戏**的数据。
通用层不写死任何一款游戏的数字：布局、皮肤、探针的游戏相关内容全在这里，代码只实现机制。
读取口：`ios/vpad_data.h`（按相对路径取包内文件，取不到一律 nil，调用方回退）。

## 1. 出厂布局预设 `layouts/<程序号>.json`

F01 布局格式（`ios/layouts/layout.schema.json`）原样一份，id 为 `preset.<程序号小写>`。
玩家从没给这款选过方案时，预设就是初始选择（`S2AVPadLayoutStore.adoptPresetIfNoSelection`）；
之后玩家的选择记录优先。预设只读、不落盘：玩家在编辑器里改动存的是「我的布局」（mine）。

编辑器（游戏库 `S2ArmTouchEditorView` 与游戏内拖动编辑）支持**每键缩放**：倍率 0.6–1.6，
经 `layoutWithButtonCenters:scales:` 写进 width / height / cornerRadius，仍过 F01 生产校验。

首批内容（座位照移植来源的定版）：

| 程序号 | 游戏 | 座位来源 |
| --- | --- | --- |
| 010013C00E930000 | Hollow Knight: Silksong | nxnative 丝之歌 v5 定版座位（十字键按摇杆盘中心重构） |
| 0100A00019DE0000 | Hades II | nxnative 哈迪斯扇形布局（DmPadCustomHades 座位表） |
| 010021C000B6A000 | The Binding of Isaac: Repentance（AB+） | nxnative 以撒 v11 布局 + R/ZR 右缘竖排座位 |

## 2. 按键皮肤包 `skins/<皮肤 id>/skin.json`

```json
{ "schemaVersion": 1, "id": "silksong-thorn", "name": "丝之歌 · 荆棘",
  "games": ["010013C00E930000"],
  "buttons": { "A": {"normal": "a.png", "pressed": "a_p.png"}, "..." : {} },
  "stick":   { "base": "stick.png", "knob": "knob.png" } }
```

- `pressed` 可缺：缺的键按下态由渲染方用常态图 + 整键缩到 0.93 表示（哈迪斯两套就是这种）。
- `stick` 可缺：缺了摇杆保持内置石墨样式。
- 选择按游戏存：偏好 suite `S2AGame.<程序号>` 的键 `S2AVPadSkin`；游戏库设置页写、游戏内 vpad 读同一处。
  没选 = 内置描线样式。游戏内 vpad 与游戏库编辑器预览按同一份图渲染。
- 首批内容取自 nxnative 已定版素材（不重绘）：丝之歌三套图包（荆棘 / 角标 / 黑铁；nxn 的第四档「玻璃」
  是代码描线，在 S2Arm 里对应内置描线，不做图包）、哈迪斯两套图包（月亮 / 月亮角标；同理「玻璃」= 内置描线）。
  入包图片统一缩到长边 256 px（原图共 81 MB → 约 9.7 MB）。

## 3. 页值显隐探针 `visibility/<程序号>.json`

探针 10 Hz 读游戏状态派生「页面模式」，vpad 按模式换键集：

- 读数器两种：`il2cpp-singletons`（类槽 → statics → 实例 → 字段偏移，链路常量是 IL2CPP 类布局）、
  `module-data-fields`（模块数据段指针 → 结构体字段）。链路数字全在配置里。
- 模式语义：丝之歌照 nxnative slim-139 定版（UM 页值表 + gs/us 派生顺序 + mode 5/6/7 键集与座位），
  配置 `modes` 给每模式的键集与座位覆盖；以撒照 175 线 RE（日记词 / 暂停词任一非 0 → 布局 C）。
- **验证状态（诚实标注）**：配置里的槽位 / 偏移是对**原版** NSO / NRO 逆的，S2Arm 的游戏是重写后的代码，
  截至本文件写入时**未经真机实证**，两份配置 status 均为 `unverified`（statusNote 写明了实证判据）。
  探针读不到 / 不合规时不发布模式，vpad 保持战斗布局全键——探针失效不丢键。
  构建门控：丝之歌配置带 buildID，构建号对不上不发布；以撒按模块名子串 + 数据段长度认模块。
  真机验证 = 看日志里 `[pad] state gs=… us=… page=…` / `[pad] diary=… pause=…` 与页面实际切换是否对得上；
  对上后把配置 status 改 `verified`。
