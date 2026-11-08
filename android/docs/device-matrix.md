# Android 真机矩阵（W10）

记录 `qa.sh` 覆盖不到的那部分：安装 / 升级 / 资源包激活拒绝 / 设备身份 / 输入。
每条都写明**证据从哪来**（logcat 原文、`current.json`、目录结构），不写"应该没问题"。

判据口径与 `android/docs/STATUS.md` §3 一致：只有真机上跑出来的才算证据；
合成包能覆盖的标注「合成」，需要真实游戏的标注「需真游戏」。

## 1. 设备身份

| 项 | Redmi K40 |
|---|---|
| 序列号 | `<device-serial>` |
| 型号 / 代号 | M2012K11AC / `alioth` |
| 系统 | LineageOS 23.2，Android 16（SDK 36.1），`lineage_alioth-userdebug` |
| Build / 补丁 | `BP4A.251205.006` / 2026-08-01 |
| SoC | `kona`（骁龙 870） |
| GPU / 驱动 | Adreno 650，`OpenGL ES 3.2 V@0502.0`，驱动构建 `10/04/21`；Vulkan `Adreno (TM) 650 (1.1)` |
| **页大小** | **4096 B（4 KB）** |
| 内存 / CPU | 11.8 GiB；`nproc` 报 6，`cpus=8`（cpuset 限制） |
| 屏幕 | 1080×2400 @440 dpi；60 / 90 / 120 Hz |

采集命令：

```sh
adb shell getprop | grep -E 'ro.product.(model|device)|ro.build.version|ro.hardware.egl'
adb shell 'getconf PAGE_SIZE; head -1 /proc/meminfo; wm size; wm density'
adb shell dumpsys SurfaceFlinger | grep -iE 'GLES:|Vulkan'
```

## 2. 用例矩阵

| # | 用例 | 状态 | 证据 |
|---|---|---|---|
| 1 | APK 安装 / 启动 / 原生库加载 | ✅ 合成 | `install -r` Success；`am start -W` ok 49 ms；`libs2arm_android.so loaded in 4 ms`；0 FATAL/ANR |
| 2 | Vulkan 诊断呈现 | ✅ 合成 | `swapchain 1080x2400, format 37, 4 images, FIFO, transform 0x1`；`interval avg 16.53 ms max 17.19 ms over 121, 0 acquire timeouts`，连续 17000+ 帧 |
| 3 | 横竖屏切换 | ✅ 合成 | `user_rotation 1` → `surface generation 6: 2400 × 1080, rotation 90°`；present `transform 0x2`，7 次 build，0 超时，无崩溃；HostApi display 同步 `rotation 1` |
| 4 | 安装（A0 全链路） | ✅ 合成 | `Game installed: S2Arm synthetic 0.1 [0100000000ABCDEF] -> sha256-b6fe9ec72d6f; stored 0.1 MiB ... from import/synth` |
| 5 | 模块映射 | ✅ 合成 | `modules .../main.patched.bin map R\|X (TARGET android, 80 KiB)` |
| 6 | BootSpec | ✅ 合成 | `BootSpec 0100000000ABCDEF: language en-US, region US, time zone Asia/Shanghai, screen 2400x1080 440 dpi 60 Hz, mode diagnostic` |
| 7 | 升级（同 titleId 新 contentRoot） | ✅ 合成 | `-> sha256-c8ce225a659c; stored 0.0 MiB, shared 0.1 MiB with installed versions; previous sha256-b6fe9ec72d6f kept`；`revisions/` 下两版并存，`current.json` 指向新版 |
| 8 | 重复导入（同 contentRoot） | ✅ 合成 | `Game already installed: ... from import/synth3` |
| 9 | 拒绝：包内缺文件 | ✅ 合成 | `Game import of import/synth3b refused: package has no romfs/missing.bin`；`current.json` 仍是旧版；import 目录保留未消费 |
| 10 | 真机改写自测 | ✅ | `Rewrite self-test (S2A_TARGET=android): 6 rewrite kinds x 2 guest threads ok, key table 0; guest mask blocked 0 non-SA_ONSTACK signals, libc kept unblocked: 34 36 38` |
| 11 | 平台能力探针 | ✅ | `Page size 4096`；`Shared-memory alias: available`；`39-bit / 64 GiB address window: available`；`Bionic key table: offset 0x0, thread-isolated`；`C# NativeAOT ok 56 ms`；`HostApi v1 capabilities 0x4f` |
| 12 | 蓝牙手柄输入 | ✅ | GameSir Nova 2 Lite（蓝牙）；17 个按键/4 轴逐项实测，见 §4 |
| 13 | 真实游戏启动 / 渲染 / 音频 / 存档 | ⬜ 需真游戏 | 合成包不含游戏数据；属 W13 |

## 3. 复现

合成包（不需要游戏与密钥）：

```sh
PY=<有 capstone + lz4 的 python>
"$PY" android/tools/make_pack.py build/synth --synthetic
adb push build/synth/. /storage/emulated/0/Android/data/org.s2arm.android/files/import/synth/
adb shell am start -S -W -n org.s2arm.android/.LibraryActivity --es org.s2arm.android.IMPORT_STAGING /storage/emulated/0/Android/data/org.s2arm.android/files/import/synth
adb logcat -d -s S2Arm:*
```

升级用例：改包内任一文件后重算 `index.tsv` / `manifest.json` / `game-build-artifact.json` 的
`contentRoot`，另建一个 import 子目录推上去，日志应出现 `previous sha256-… kept`。

拒绝用例：在 `index.tsv` 里加一条实际不存在的文件（`contentRoot` 随之变化，不会命中"已安装"分支），
安装应 `refused: package has no <path>`，且 `current.json` 不变。

真机改写自测：

```sh
SERIAL=<serial> PY=<有 capstone + lz4 的 python> bash android/tools/device_selftest.sh
```

## 4. 环境注意

- Windows Git Bash 下 adb 必须 `MSYS_NO_PATHCONV=1`，否则 `/storage/emulated/0/...` 会被改写成 `D:/App/...`；
  同时 `adb push` 的**源路径要写 Windows 形式**（`C:/...`）。
- `adb shell "run-as <pkg> ls ..."` 要把整条设备命令放进一个引号里，分开传参会被本机 shell 吃掉引号。
- 设备锁屏（`mWakefulness=Dozing`）时截图全黑，但应用仍在出帧——渲染类证据不依赖解锁，UI 类才需要。
- 安装成功会**消费掉** `import/<name>/`，失败则保留，可用这一点区分两种结局。

## 4. 手柄输入（GameSir Nova 2 Lite，蓝牙）

设备身份：

```
Classes: KEYBOARD | GAMEPAD | JOYSTICK | EXTERNAL
bus=0x0005 vendor=0x3537 product=0x100e version=0x011b
MAC `<controller-mac>`   ControllerNumber 1   /dev/input/event10
按键：BTN_GAMEPAD/EAST/WEST/NORTH、BTN_TL/TR/TL2/TR2、BTN_START、BTN_MODE、BTN_THUMBL/THUMBR
轴：ABS_X/Y/Z/RZ、ABS_GAS/BRAKE、ABS_HAT0X/Y
```

**没有 `ABS_RX/ABS_RY`**：右摇杆走 `ABS_Z/ABS_RZ`，应用的 `onGenericMotionEvent` 正好按
`AXIS_Z/AXIS_RZ` 读右摇杆，所以能对上。

实测映射（应用是**位置映射**，语义对齐 Switch）：

| 物理位置 | Xbox 标签 | evdev | Android | 应用 bit | 实测值 |
|---|---|---|---|---|---|
| 下 | A | `BTN_GAMEPAD` | `BUTTON_A` | bit1 | `0x0002` |
| 右 | B | `BTN_EAST` | `BUTTON_B` | bit0 | `0x0001` |
| 左 | X | `BTN_WEST` | `BUTTON_Y` | bit2 | `0x0004` |
| 上 | Y | `BTN_NORTH` | `BUTTON_X` | bit3 | `0x0008` |
| LB | LB | `BTN_TL` | `BUTTON_L1` | bit6 | `0x0040` |
| RB | RB | `BTN_TR` | `BUTTON_R1` | bit7 | `0x0080` |
| LT | LT | `BTN_TL2` | `BUTTON_L2` | bit8 | `0x0100` |
| RT | RT | `BTN_TR2` | `BUTTON_R2` | bit9 | `0x0200` |
| Menu | Menu | `BTN_START` | `BUTTON_START` | bit10 | `0x0400` |
| View | View | `BTN_SELECT` | `BUTTON_SELECT` | bit11 | 未观测到 |
| 十字上/下/左/右 | 同 | `ABS_HAT0Y=-1/+1`、`ABS_HAT0X=-1/+1` | `DPAD_*` | bit13/15/12/14 | `0x2000`/`0x8000`/`0x1000`/`0x4000` |
| L3 / R3 | 同 | `BTN_THUMBL` / `BTN_THUMBR` | `BUTTON_THUMBL/R` | bit4 / bit5 | `0x0010` / `0x0020` |
| 左摇杆 | 同 | `ABS_X` / `ABS_Y` | `AXIS_X` / `AXIS_Y` | `L=(x,y)` | 右 `(32767,0)`、上 `(0,32767)` |
| 右摇杆 | 同 | `ABS_Z` / `ABS_RZ` | `AXIS_Z` / `AXIS_RZ` | `R=(x,y)` | 右 `(32767,0)`、上 `(0,32767)` |
| HOME | 同 | `BTN_MODE` | `BUTTON_MODE` | 未映射，交系统 | 观测到事件 |
| 背键 | — | **无 evdev 事件** | — | — | 该模式下不上报 |

### 已知行为：Xbox 布局手柄的 A/B、X/Y 与标签互换

位置映射让物理下方的 A 落在 `bit1`，而 `bit1` 在 Switch 语义里是 **B**——所以用 Xbox 手柄时，
游戏内确认/取消与手柄标签相反（X/Y 同理）。这是代码里写明的设计
（`MainActivity.dispatchKeyEvent`：`// Positional layout: Android's bottom A button is Switch B.`），
原始读数属于缺省 `position` 模式。现在可显式选择 `s2arm.gamemap=label`，合法选择按应用安装
持久保存，后续无参数启动恢复该值；首次安装不传参数仍为 `position`。切回用
`s2arm.gamemap=position`。以下是 Android 键码期望，不把既有实体手柄位置读数改记成标签模式实测。

| Android 键码 | `position` 期望 | `label` 期望 |
|---|---|---|
| `BUTTON_A` | `0x0002` | `0x0001` |
| `BUTTON_B` | `0x0001` | `0x0002` |
| `BUTTON_X` | `0x0008` | `0x0004` |
| `BUTTON_Y` | `0x0004` | `0x0008` |

需用户实体手柄验收：GameSir / Xbox 布局的两模式逐键、持键切换后释放、冷启动恢复。
尤其本页旧 GameSir 的 `BTN_WEST → BUTTON_Y`、`BTN_NORTH → BUTTON_X`，软件注入
`BUTTON_X/Y` 不能证明该实体手柄印刷标签的最终语义。


### 10-26 维护侧软件输入复验（承接 #219）

- 设备：联想 TB322FC / Snapdragon 8 Elite（Adreno 830），Android 16 / SDK 36；
  Thermal 0、电池 40.9°C。此为一次短输入功能验证，不作性能/能耗读数。
- 源码：`236a204f1`；普通 diagnostic/services=0 APK SHA-256
  `6aa5090e1478e8c6595e3daae4ea578dadf0b7f8dd1381c217e51c5a6c1eb61b`。
- 经设备租约，用 `input gamepad keyevent --duration 150 KEYCODE_BUTTON_A/B/X/Y` 逐键注入；
  `position` 真结果为 `0x2/0x1/0x8/0x4`，`label` 为 `0x1/0x2/0x4/0x8`，全部与上表期望一致，松开后均为0。
- 在 label 下 force-stop 应用，确认进程已退出，再不带 gamemap 冷启动；PID 从16002变为16178，
  A/X 注入得到 `0x1/0x4`，松开归0，私有 `s2a.xml` 仍保存 `gamepadMapping=label`。
- 该轮新增 instrumentation 的“真实 Intent 后持键应保留”断言失败：Activity 正常 `onPause` 会先清键。
  测试按此生命周期修正；以上 shell 注入与进程重启证据独立通过，未把该断言失败记为整套通过。
- 收尾：诊断进程已 force-stop；Wonder 恢复基线 b2（SHA `1734f10a…`）及其 artifact-refresh；
  游戏进程与 screenrecord 均为空后释放租约。原始日志在维护侧任务证据目录，未上传。
- 9000 复验：OPD2201 / Dimensity 9000（Mali-G710），Android 16 / SDK 36；自然降温至
  Thermal 1 / 电池34.8°C。相同主 APK 再跑 position/label 的 A/B/X/Y 与释放，得到相同期望；
  force-stop 后 PID 7638→7906，无 gamemap 启动 A/X 为 `0x1/0x4`，保存值仍为 label。
- 最终测试源码 `ba256745`，具名 AndroidTest APK SHA-256
  `55f4b616d81484f6bcabd9d2abf6ae6be8c7957ed62dc90a954c81d56adb1e7d`。
  9000 的 `am instrument -w -r` 报 `passed=true`、`62 checks passed`、code -1，覆盖首次缺省、两模式、
  真实 Intent 的暂停清键/新映射、非法字符串/类型不落盘、启动 Intent 更新、Activity 重建与无参数恢复。
  收尾同样恢复 Wonder b2+refresh，游戏/录屏进程均空后释放租约。
- 软件事件只验证 Android KeyEvent → 应用输入位和设置恢复；**需用户实体手柄验收**，没有验证蓝牙、
  实体印刷标签或游戏内最终 Npad。

顺带一个 Android 的坑：`Generic.kl` 里 `BTN_WEST→BUTTON_Y`、`BTN_NORTH→BUTTON_X`（按位置映射，
不按 Xbox 标签），正好与上面的位置语义抵消，所以 `bit2/bit3` 仍对应"左/上"。

采集方式：`adb shell am start -n org.s2arm.android/.MainActivity --es s2arm.touchlog on`，
应用会在每次输入变化时打 `input: buttons=0x%04x L=(x,y) R=(x,y)`；原始键码用
`adb shell getevent -lt /dev/input/event10` 对照。

## 5. 未覆盖

- 16 KB 页设备：本机是 4 KB 页，16 KB 页需单独设备。
- 真实游戏的图形/音频/输入/存档闭环：属 W13。
