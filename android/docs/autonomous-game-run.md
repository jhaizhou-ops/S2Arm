# 安卓端“游戏可正常玩”自主冲刺计划

日期：2026-10-24。用途：新开 session 后，把下面 §0 的指令交给 AI，按本文件持续执行，不再逐项询问用户。

## 0. 给新 session 的直接指令

```text
你全权负责 S2Arm 安卓端 Vulkan 游戏的实际可玩性，直到目标游戏在 1080p 全屏下
正常游玩、启动快、不卡顿、稳定至少 60fps。不要问我要不要做、不要停在中间汇报，
自己测量、自己改代码、自己构建/装机/跑游戏/看日志、自己提交。

先读：
- 本文件 android/docs/autonomous-game-run.md
- 工作树 HANDOFF.md（如果存在）
- docs/协作循环.md、docs/贡献指南.md、docs/坑记录.md、
  docs/性能与开发测试经验.md
- .worktrees/android-shader-plan/platforms/android/docs/shader-plan.md

硬约束：
- 只动 Android 专属路径；不改变 Apple/Metal 的判据、产物或行为。
- 不写死游戏地址/函数名/名字特判；未实现的能力报红，不返回成功兜底。
- 不提交游戏文件、密钥、存档、资源包、.tmp/ 大文件；不推 main。
- 每轮一个逻辑改动，一个提交；改 Ryujinx 树必须重新生成补丁并跑 verify.sh。
- 遇到不确定就按“最小、可回退、可测量”的方案做，并从设备读数/日志/A-B 决定。
- 只有设备/游戏数据物理上不可用、连续 3 轮无法推进时才写 BLOCKED.md 并结束；
  其他情况继续。
```

## 1. 固定环境与目标

- 工作树：`/home/vick/Documents/dev/personal/S2Arm/.worktrees/shader-cache`
- 分支：`android/shader-cache`；基线：`android/integration`
- 设备：Redmi 22081212C（Adreno 730，Vulkan 1.1.128，Android 16，无线 adb）
- 目标游戏：当前测试机已装的 Diablo III 2.7.7.92380（title `01001B300B9BE000`）。
  如果实际目标不是它，用 `adb shell pm list packages | grep s2arm` 和已装资源包确认；
  流程不变，只是替换 title/包名/资源包。
- 默认测试画面：**横屏 1920×1080 全屏**。设置与确认：
  ```sh
  adb shell wm size 1080x1920      # 竖屏逻辑尺寸，游戏横屏后 surface 1920x1080
  adb shell wm density 420
  adb shell settings put system accelerometer_rotation 0
  adb shell settings put system user_rotation 1
  adb shell dumpsys window | grep -E 'mCurrentFocus|cur='
  adb exec-out screencap -p > run/1080p.png
  ```
  截图必须是 1920×1080（或至少横向 1080 像素高），游戏铺满、无黑边/拉伸。
  记录游戏内部实际渲染分辨率；如果内部仍是 720p/动态分辨率，最终报告必须写明，
  不能把“输出放大到 1080p”算成 1080p 原生。测试结束恢复：
  `adb shell wm size reset && adb shell wm density reset`。

## 2. 验收标准（全部满足才算完成）

| 项目 | 判据 | 测量 |
|---|---|---|
| 全屏 1080p | 输出 1920×1080，铺满，无黑边；内部渲染分辨率有记录 | 截图 + `dumpsys SurfaceFlinger`/日志 |
| 帧率 | 稳定段平均 ≥ 59.0 fps；目标游戏若锁 30/60 先证明其刷新目标 | SurfaceFlinger latency / 帧计时日志，3 次 60s |
| 不卡顿 | p99 ≤ 20 ms；>33 ms 帧 ≤ 0.5%；无 >100 ms 卡顿（预热 30s 后） | 同上 + Perfetto（必要时） |
| 启动快 | 冷启动到首个可操作帧 ≤ 0.7×当前基线，且 ≤ 20s；热启动 ≤ 10s | logcat 时间戳 / `am start -W` + 首个可操作日志 |
| 着色器 | 冷缓存+离线包：VKPB `host_hit` 命中；覆盖程序不再 on-demand 翻译；driver cache 真实内容跨进程复用 > 0 | `[vkpb]`/`[vkpipe]`/`[gal]` 日志 |
| 稳定性 | 连续 30 分钟无 crash/ANR/WSI 退休失败；5 次退出重开正常 | logcat/`dumpsys`/进程检查 |
| 游戏功能 | 主菜单、读档、战斗 10 分钟、音频、过场、输入、存档、正常退出 | 录屏/截图 + 日志 |
| Apple 保护 | 改共用代码后 `tools/gate_ios.sh` 或对应 Mac/iOS 构建/录像不回归 | 维护者第二层；PR 写清 |

“完美”以本表为准，不以“能进标题画面”“管线创建很快”代替。若游戏本身锁 30fps，
先证明并记录为外部限制，继续把帧时间/启动/稳定性做到最优，最终报告不得虚报 60。

## 3. 每轮固定循环（必须执行）

1. **测量**：当前 HEAD、构建号、1080p 设置、温度/充电、冷/热、3 次取中位。
2. **选瓶颈**：按数据选一个最大项；不要同时改三个方向。
3. **最小改动**：先写测试/读数，再改代码；保留回退点。
4. **验证**：
   - 宿主：`compat/verify.sh`、`graphics/vulkan/cache/tests/run_host.py`、
     `graphics/vulkan/core/cache-tests`、backing control；
   - 构建：`bash android/host/build.sh`（或至少 `:app:assembleDebug`）；
   - 装机：`adb install -r app-debug.apk`；只清着色器缓存，绝不清存档；
   - 真机：按 §4/§5 跑同一路线，保存日志/截图/读数。
5. **记录**：追加 `android/docs/RUNLOG.md`（HEAD、指标、瓶颈、改动、结果、
   证据路径、下一步）。
6. **提交**：一个逻辑改动一个中文提交；Ryujinx 改动跑 `patch_new.sh` + `verify.sh`。
7. **反退化**：连续 3 轮无改善 → 回退或换假设；不要堆无效改动。
8. **上下文**：超过约 65% 或明显变慢 → 写 `HANDOFF.md`，提交，结束并给新 session
   开场白；新 session 从 HANDOFF 继续。

时间盒：单轮 20–40 分钟；单日没进展时先回到 §5 重新测量，不猜。

## 4. 阶段路线

### P0 收尾与基线（先做，不改性能代码）
- `git status`：当前有 5 个未提交文件（软件键盘/全屏/`exportShaderCache`）。
  先审查、构建、验证；能过就单独提交，不能过就保留并在 HANDOFF 说明，禁止覆盖或丢弃。
- 记录当前基线：冷/热启动、1080p 帧率、p99、着色器命中、driver cache 字节、崩溃。
- 确认 `.tmp/` 2.7GB 只是日志/bench，不提交；需要时只清理明确可删的副本。

### P1 S1 真机验收
- VKPB 跨进程 `host_hit`：坏记录必须拒绝，覆盖程序不再翻译。
- driver cache：内容 > 32 字节（真实管线数据），跨进程复用；profile/UUID/截断负例。
- VTG/V→compute、原生 GS/Tess、TF 的程序记录 round-trip；不支持的明确报红。
- 慢编译 2s + Surface detach：壳层 1000ms 内 ACK；无退休证明仍拒绝 ACK。
- Stop/重启：worker 停住、迟到结果不发布、driver cache 不破坏。

### P2 S2 端到端闭环（首装快的核心）
1. 解决设备导出入口：profile 用显式 debug intent 或 `wrap.<pkg>` 设置
   `S2A_SHADER_PROFILE_OUT`；参考缓存用已提交/待提交的 `exportShaderCache`
   （只导出 cache，不动存档）。
2. 真机跑一局产生参考缓存 → 拉回 `<state>/games/<title>/cache/shader`。
3. 用现有抽取器 + `S2A.ShBake bake <抽出目录> <输出根> --title 01001B300B9BE000
   --ref <参考缓存> --vulkan-profile <profile.json> --content-root <sha256-…>
   --spirv-val $(command -v spirv-val)` 出包。
4. `android/tools/attach_shaders.py <资源包> <per-profile 包目录>` 挂包；
   或走 `assets/game/shaders.zip` 资产通道。
5. 重装/导入，只清着色器缓存，冷启动验证：
   - `[vkpb]` host 命中、覆盖程序 on-demand 翻译为 0；
   - 包校验失败必须 🔴 并按需翻译，不能伪成功；
   - 对比带包/不带包的冷启动、首局卡顿。
6. 包版本/内容更新/旧包不覆盖学习结果/Apple 回归。

### P3 S3 只在数据证明需要时做
先量首局 `first_use_wait_ms`、管线创建次数/耗时、未覆盖配方数：
- 若 S1/S2 后仍有明显编译停顿，再做完整配方录制、warm 列表、单 worker 预热、
  `PipelineReadyCache`、引用释放、Stop 顺序；
- 若数据表明瓶颈在 GPU/CPU/带宽而不是编译，跳到 P4，不为了“做完 S3”而做。

### P4 1080p 60fps 运行时优化
按数据选，不猜：
- render pass 数/带宽、loadOp/storeOp、附件解析；
- 读回/同步、命令缓冲上限、队列提交；
- 纹理格式/带宽、BC/ASTC、mip、过度绘制；
- CPU 每帧分配/GC、翻译/查表、输入/音频线程；
- 温度/频率/充电状态，避免把降频当成代码退化；
- 游戏内 docked/1080p 设置与内部渲染分辨率。
每项 A/B 只差一个变量；同一路线 3 局取中位；不跳过绘制、不降分辨率冒充。

### P5 稳定性与回归
- 30 分钟连续、5 次退出重开、旋转/后台/通知栏/锁屏、存档读写；
- 无 crash/ANR/WSI 退休失败/残留进程；
- Apple 路径回归：纯 Vulkan 代码不改 NxGal/GALP，共用改动提供 iOS/Mac 证据；
- 最终报告：指标表、截图/日志路径、已知限制、未验证项。

## 5. 测量命令与口径

```sh
# 进程/包名
adb shell pm list packages | grep -i s2arm

# 每次测试前
adb shell am force-stop <pkg>
adb logcat -c
adb shell dumpsys thermalservice | head -60
adb shell dumpsys battery | grep -E 'temperature|status|level'

# 启动
adb shell am start -W -n <pkg>/.MainActivity
# 或带显式调试开关（导出/面板）
adb shell am start -W -n <pkg>/.MainActivity --ez exportShaderCache true

# 日志
adb logcat -v time | grep -E '\[s2a\]|\[vkpb\]|\[vkpipe\]|\[wsi\]|\[gal\]|【红】|FATAL|ANR'

# 帧
adb shell dumpsys SurfaceFlinger --list | grep -i surfaceview
adb shell dumpsys SurfaceFlinger --latency '<layer>'
adb shell dumpsys gfxinfo <pkg> reset
# 跑固定路线后
adb shell dumpsys gfxinfo <pkg>

# 内存/温度
adb shell dumpsys meminfo <pkg>
adb shell dumpsys thermalservice
```

口径：
- 同设备、同包、同路线、同 1080p、同充电/温度状态；每次至少 3 局取中位。
- 启动分“冷缓存（删应用着色器缓存，不删存档）”和“热缓存”两组。
- 帧率以 SurfaceFlinger 呈现时间/真实 present 为准；管线创建快、日志计数多不算帧率证据。
- 记录 p50/p95/p99、>33ms 帧数、>100ms 卡顿、平均 fps、温度、频率。
- 任何“优化”必须给前后同条件读数；没有读数不写进结论。

## 5.5 用 TouchPad 操作游戏界面（真机点按坐标）

游戏画面上的手柄是**应用内自绘的 TouchPad**，不是系统输入法；用 `adb shell input` 点它即可，
不需要额外 HID。屏幕坐标系 = `screencap` 像素坐标（测试机 2712×1220）。

```sh
S=192.168.31.222:5555; P=org.s2arm.game.t01001b300b9be000
tap() { adb -s $S shell input touchscreen swipe "$1" "$2" "$1" "$2" 150; }   # 原地按下+抬起 150ms

adb -s $S shell am force-stop $P; sleep 1
adb -s $S shell am start -n $P/org.s2arm.android.MainActivity --es s2arm.graphics_mode direct
sleep 55;  tap 2586 705      # 标题页 → 「继续」
sleep 10;  tap 2586 705      # 选人 → 进入世界
sleep 40                     # 加载 25–35 s
tap 1195 110                 # 「−」打开暂停/人物菜单
tap 2210 560                 # 「B」关闭菜单
adb -s $S shell pidof $P     # 空 = 已崩
```

坐标（2712×1220，**本会话 adb 实测有效**）：

| 画面上 | 坐标 | 实测作用 |
|---|---|---|
| **A** | `2586 705` | 确认/继续；标题→「继续」→世界、菜单项「接受」都靠它 |
| **−** | `1195 110` | 打开暂停/人物菜单（D3 显示「游戏已暂停」+ 角色模型） |
| **+** | `1580 110` | 另一个菜单入口（同样会触发菜单渲染路径） |
| **B** | `2210 560` | 关闭菜单（回到游戏） |
| **X** | `2360 700` | 按下不崩（作用视游戏而定） |

HUD 其余按键（从截图量取，未逐一 adb 验证）：ZL≈`205 120`、L≈`390 125`、R≈`1690 120`、
ZR≈`1905 120`、LS≈`490 380`、RS≈`1350 605`、左摇杆≈`275 490`、十字键中心≈`575 745`、Y≈`1660 460`。

判定与取证：
- 存活：`pidof` 非空；死亡后 `files/exit.log` 首行是 `_exit(<码>)`（134=128+6, 139=128+11）。
- 崩溃取证开关：`debug.s2a.exitlog=<路径>`（退出码/回溯）、`debug.s2a.callring=1`（最近 64 次
  Vulkan 调用 + 资源创建/销毁，崩溃时随 exit.log 落盘）。
- 设备 IP 会变：先 `adb connect <ip>:5555`，`adb devices` 里挑装着本包的那台。

时间预算：起局 ~55–60 s，进世界再 25–35 s；一轮完整“起局→进世界→开菜单”约 2.5 分钟，
所以脚本里别用短 sleep 判失败。

### 5.5.1 注入失败的排查（2026-10-31）

`adb shell input touchscreen swipe/tap` 在本机（旋转 3、逻辑 2712×1220）会**静默落到空处**：
TouchPad 一条 `input: buttons=` 都不打，截图却显示按钮就在坐标上。用 `input motionevent DOWN <x> <y>`
→ 等 0.3–0.5 s → `input motionevent UP <x> <y>` 可以稳定命中（同坐标实测按钮位变化）。
排查顺序：先看 `adb logcat | grep "input: buttons"` 有没有状态变化——没有变化就是没送到，不要按“游戏没响应”处理；
再看 `dumpsys window windows` 有没有可见的 accessibility/悬浮窗盖在上面（本机曾出现 `li.songe.gkd`、
`io.chaldeaprjkt.gamespace`），必要时先停掉再注入。每次注入前确认前台是 GameActivity。

## 6. 记录与交接

- `android/docs/RUNLOG.md`：每轮追加，格式：
  ```text
  ## <时间> <HEAD> <构建号>
  - 设备/游戏/1080p/温度/充电：
  - 基线：冷启动 __s，热启动 __s，fps __，p99 __，>33ms __，崩溃 __
  - 着色器：host_hit __，on-demand __，driver cache __B
  - 瓶颈：
  - 改动：
  - 结果：前 __ → 后 __
  - 证据：日志/截图路径
  - 下一步：
  ```
- `HANDOFF.md`：上下文将满或换 session 时写：
  - HEAD、工作树、未提交文件、设备/游戏、当前 1080p 设置；
  - 最近 3 轮读数、已否决的方案及原因；
  - 下一个最小任务和精确命令；
  - 新 session 开场白（读本文件 + HANDOFF，继续跑）。
- 大日志/截图放 `.tmp/` 或 `build/`，不提交；只把摘要写进 RUNLOG。

## 7. 红线

- 不提交游戏文件、密钥、存档、资源包、`.tmp/`、`build/` 大产物。
- 不推 `main`，不改别人的分支/工作树，不删共享产物。
- 通用层零专用配置：不按游戏名/地址/函数名特判；单款逻辑只能放显式开关且默认关。
- 未实现/不支持必须 🔴，不能返回成功、跳过绘制、静默降级或伪造缓存命中。
- 分辨率/帧率不能靠改截图、改日志、降低内部渲染冒充；测什么写什么。
- 改 Ryujinx 树必须同步补丁、series、改动清单，`compat/verify.sh --rev HEAD` 绿。
- Apple/Metal 路径不动；共用改动必须有“Apple 不受影响”的证明。

## 8. 首轮任务清单（新 session 直接按顺序做）

1. `git status`、`git log --oneline -10`、`compat/verify.sh`、host harness 基线。
2. 审查 5 个未提交文件；构建/验证，能过则单独提交，不能过保留并记录。
3. 设 1080p、锁横屏、关充电、冷却到体温；跑 3 次基线，写 RUNLOG。
4. 按 P1 补 S1 真机证据；没有 `[vkpb]` host_hit 就先修导出/命中日志。
5. 按 P2 导出参考缓存 → 出包 → 装包 → 冷启动对比；这是“首装快”的关键。
6. 若仍卡顿，按 P3/P4 数据决定 S3 或运行时优化；每轮一个改动、一个提交。
7. 全部验收项绿后，写最终报告 + 截图/日志/读数，给出可复现命令。

## 9. 完成后的交付物

- `RUNLOG.md`：完整基线/每轮前后读数。
- 最终报告：1080p 截图、fps/p99/启动/内存/温度、着色器命中、包版本、已知限制。
- 绿：host tests、`compat/verify.sh`、Android test、Apple 回归（维护者第二层）。
- 代码提交在 `android/shader-cache`；不合并 main，等维护者验收。
