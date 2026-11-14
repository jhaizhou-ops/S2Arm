# 真机 A/B 验收清单：首用管线异步（debug.s2a.nvk_pipe_async）

目标：验证「后台建管线 + 有界等待 + 可恢复的首次缺画」在真机上**降低首次使用长帧、且不引入持续缺画/黑块**。
默认关；本清单用于验收前置的 A/B，读数达标前不得默认打开。

## 0. 前置约束（很关键）

- 开关 `debug.s2a.nvk_pipe_async` 走 `nvn_plat_flag` → 需要 `s2a_debug_entries_open()`：**CMake Debug 配置**且 `adb shell setprop debug.s2a.debug_env 1`。
- 正式包（Release）编译期就把调试门关掉，**Release 包无法运行时切换本开关**。因此：
  - 想用运行时属性做 A/B：只能出 **Debug** 包（CMake Debug 通常是 -O0，性能不代表正式）。
  - 想用**正式性能**做 A/B：出新旧两版 Release 包，**测量版**把 `nvn_vk_pipe_demand_on()` 临时改为 `return 1`（或加一个只在测量构建里生效的强制开），**仅此一处差异**；两包同一 route 各跑 3 局。测完把该临时改动撤掉、不开进正式包。

## 1. 出包（两条路任选其一）

A. 运行时属性路（Debug，验证语义/画面，不用于性能数值）：
```
S2ARM_ANDROID_CS_SERVICES=static S2ARM_ANDROID_GAME_DIR=build/android-game/input \
S2ARM_ANDROID_VK_ENGINE=1 S2ARM_ANDROID_VK_BACKEND=nvk \
  bash android/docker/build.sh -Ps2arm.nativeMode=game :app:assembleDebug
```
装包后：`adb shell setprop debug.s2a.debug_env 1`；A 组 `adb shell setprop debug.s2a.nvk_pipe_async 0`；B 组 `... 1`。

B. 正式性能路（Release，测量版强制开）：
- OFF 包：`bash build/measure/build.sh`（现状，默认关）。
- ON 包：临时把 `android/native/nvn/nvn_vk_pipe_demand.c:nvn_vk_pipe_demand_on()` 首行改 `return 1;`，再 `bash build/measure/build.sh`；装另一台/另一轮。
- 每组前 `adb shell am force-stop org.s2arm.game.t0100f2c0115b6000`。

## 2. 跑分（同机、同存档、同路线；一次只差一个变量）

```
bash build/measure/bench.sh 40 build/measure/ab-<组>-<轮>   # 每组 3 局取中位
```
记录热状态 / 是否充电（AGENTS 要求）。

## 3. 记录指标（期望 → 真结果 对位）

- 首窗「取程序」「开通道与取管线」ms/帧（对照 PR #996 冷进场 255→9.9 / 173.6→~11 的基线）
- 该窗 fps；稳态 fps / p99 / >33ms 帧 / 窗口 max
- 跳过分账：日志「首用跳过累计 …（budget/late/stuck）」与「首用后台建管线：提交/合并/建成/失败/超时」
- 红行数、未接数、`c1_segment_not_captured`（必须 0，否则火把/粒子光照会被跳）
- 画面：塞尔达类**时域历史 / 曝光 / 阴影 / 遮挡查询**是否出现持续缺画、闪烁超出「首帧」、黑块

## 4. 通过判据

- 无新增红行、无 `c1_segment_not_captured`；跳过只影响首次使用期间短暂少画，恢复后逐像素正确。
- 首窗长帧显著下降；稳态 fps/p99 无回归（在噪声内）。
- 若「不可跳」项持续超上限导致长时间缺画 → 属降级，必须记录并评估是否收紧 skip_safe 或关闭默认。

## 5. 回滚

`adb shell setprop debug.s2a.nvk_pipe_async 0`（Debug 包）或装回 OFF 包即回到现状；代码默认关，无需其他动作。
