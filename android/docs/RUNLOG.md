# Android 真机冲刺 RUNLOG

目标：Redmi 22081212C（Adreno 730 / Vulkan 1.1.128 / Android 16），Diablo III 2.7.7.92380
（`01001B300B9BE000`），原生全画幅面板 2712×1220 横屏（不覆盖 `wm size`）。跑法、口径和红线见
[autonomous-game-run.md](autonomous-game-run.md)。

## 2026-10-25 00:07 +0800 / d084042f 之后的工作树（含未提交宽高比改动前）

- 设备/游戏/显示：Redmi 22081212C，Adreno 730，Android 16，驱动 `c1fe339905`；游戏 2.7.7.92380；
  `wm size reset`、`wm density reset`、`user_rotation=1`，截图 2712×1220；插电，电池约 36 ℃。
- 基线：冷启动（应用内着色器缓存已有 525 条客体记录、19 条宿主记录）到片头首帧约 150–200 s；
  进入片头后 SurfaceFlinger 层 frame 计数 10 s 增 609（≈60.9 fps）；未见 >33 ms 的系统级卡顿读数
  （尚无逐帧日志，fps 用 `dumpsys SurfaceFlinger` 的 BLAST 层 frame 计数差分）。
- 着色器：`Gpu LoadShaders: Loading 525 shaders`；`[gal] 缺主机代码` 逐条刷屏；磁盘宿主记录
  用 TOC 解析确认只有 19/525 条有二进制；`[vkpipe] 导入驱动管线缓存 547595 字节`。
- 崩溃：修前两条必现路径
  1. `InvalidOperationException: Android lease changed after acquire`（锁屏/切后台换 surface 代）；
  2. `TimeoutException: GPU did not prepare old backing within three seconds` → fail-fast
     （进程被系统冻结后恢复）。
- 改动：`220cece8` 表面撤销释放已获取帧；`6fd7efe6` 后台冻结不再墙钟判死；`d084042f` BootSpec
  docked 持久选择。
- 结果：HOME 切后台 surface detach 32 ms、返回后 generation 2 重新 offer，进程存活；docked 下
  `HostApi display ... docked`、swapchain 2712×1220，游戏启动并播放片头。
- 待办：首帧前的宿主着色器翻译仍是主要瓶颈；物理全画幅但游戏内容 16:9，左右黑边（游戏不查询
  VI 显示分辨率，`S2ADisplay.Aspect` 改动对本品无效，待真实宽屏投影方案）。
- 证据：`.tmp/logcat-run2.txt`、`.tmp/docked-refresh-200s.png`、`.tmp/docked-10m.png`、
  `.tmp/device-export2/`（TOC 计数脚本见 HANDOFF）。

## 2026-10-25 00:48 +0800 / 宽高比 + 导出顺序工作树

- 改动：core-runtime 从 HostApi display 读 Surface 宽高比写入 `S2ADisplay.Aspect`（generic，
  不改物理分辨率）；外壳新增“下次启动时导出上一局完整缓存”（`shader-previous-*`），并保留退出时
  尽力导出（`shader-session-*`）。
- 结果：日志 `游戏显示宽高比：Surface 2712x1220 → 2.2230`；游戏未查询 VI 分辨率，片头仍为
  16:9 + 自身黑边；docked 1050 高度路径未变。构建坑：`cs/build.sh` 会清空 `jniLibs`，只跑它
  再 gradle 会丢 `libssl.so`/`libcrypto.so`，启动即 `No usable version of libssl was found`
  + SIGABRT；必须先 `openssl/build.sh` 再打包。
- 待办：用完整缓存复测宿主命中数；离线包（S2）覆盖首装。

## 2026-10-25 01:0x +0800 / 0234 着色器缓存写队列修复（待真机）

- 改动：`ShaderCache.ProcessShaderCacheQueue` 不再因队首一条 `Incomplete` 停掉整条队列；
  逐个检查，未完成的移到队尾。Ryujinx 补丁 `0243-shader-cache-queue.patch`，`verify.sh` 一致。
- 假设：真机 525 条客体记录只落 19 条宿主记录 = 队首长期未完成导致后续全部不落盘。
- 验证计划：跑一局后下次启动导出 `shader-previous-*`，解析 host TOC 的非零条数；对比 19。

## 2026-10-25 01:24 +0800 / 0234 写队列修复真机复测：宿主记录仍 19/544

- 设备/显示：同上，全画幅 2712×1220、docked、插电。
- 跑法：queue-fix APK 启动一局 8 分钟（前 4 分钟 327 条“缺主机代码”，后 4 分钟新增 0）；
  正常 `s2arm.finish` 退出；再带 `--ez exportShaderCache true` 启动，启动期导出上一局
  `shader-previous-1792862655468`；解析 TOC。
- 读数：shared 程序 544 条不变；本 profile 的宿主文件 `1fe7…` 544 槽位、非零 **19**（与修复前
  相同）；`shared.data` 221592 → 229024（+7432 B，TOC 没长出条目 = 未发布的孤儿记录）；
  宿主 data 仅 +4 B。
- 结论：队列“队首 Incomplete 阻塞”假设不足以解释；当前真机路径上这些按需翻译的程序
  根本没有以 Success 状态出队落盘（或 Enqueue 没发生）。下一步必须加机制计数：
  Enqueue 次数、每次 ProcessFrame 队列长度、Dequeue 时 Success/Failure/Incomplete 计数、
  `S2AVtg.GetBinary` 返回 null/长度 0 计数（改 compat/tree → patch_new.sh + verify.sh）。
- 证据：`.tmp/device-export4/`、`.tmp/round1-4m.png`、`.tmp/round1-8m.png`。

## 2026-10-25 01:40 +0800 / 控制循环排空保存队列：宿主记录开始持续落盘

- 改动：`1998fc0d` `AndroidVulkanRuntime.Run` 每控制轮次调用 `Gpu.ProcessShaderCacheQueue()`，不再只依赖 `Switch.ProcessFrame`。
- 真机读数（Redmi 22081212C / Adreno 730，docked，2712×1220）：装机启动后 90–150 s 内
  `[vkpb] 存缓存计数` 连续出现：`入队 13/已写 13`、`1/1`、`1/1`、`2/2`、`2/2`，
  `空二进制 0、失败 0、队列 0`；同一时间段新进程 `LoadShaders: Loading 563 shaders`（上局 544）。
- 结论：保存链路本身可用，此前是首帧前没有 ProcessFrame 导致队列不排空；现在翻译成果持续落盘。
  待下一轮导出数宿主 TOC 非零条数，确认从 19 显著上涨并测冷/热启动耗时。
- 证据：logcat 进程 7576、`.tmp/build-apk-drain.log`。

## 2026-10-25 02:20 +0800 / 同一局稳定运行约 14 分钟，游戏层 60 fps

- pid 12100 自 02:06 启动后一直存活（>10 分钟），焦点在游戏 Activity，无 `GPU Run 退出`/`stop requested`/`session failed`。
- 游戏 SurfaceView BLAST 层 `#87366`：8 s 内 frame 59980 -> 60468 = **61.0 fps**；
  面板 2712×1220 全画幅、docked、1080 高度。
- 说明此前多次“首帧前自退”至少部分是设备交互/时序造成；无人操作时本局可稳定出帧。
- 下一步：同局跑满 5–10 分钟 -> 正常 finish -> 带 export 启动导出 -> 数宿主 TOC 非零条数；
  再补 p99/慢帧（需逐帧计时日志）。

## 2026-10-25 02:38 +0800 / 0238 写入侧证伪：TOC 写入正确，瓶颈在“只入队 19 个”

- 日志：`宿主 TOC 写：idx=625 off=10032 len=10048 bytes=34675 data=58713`，off 严格等于
  `32 + idx*16`，len 逐条增长，字节非空；同时 `存缓存计数：入队 1/已写 1、队列 0`。
- 结论：`WriteHostCode` 写入路径正确，此前“TOC 被清空”不成立。宿主 TOC 是**按 build 身份**分文件的，
  导出里 620 槽只有 19 非零 = 当前 build 只写过 19 个宿主程序；之前的 build 记录在别的文件里、不会被
  当前 build 复用。shared 客体缓存跨 build 累积到 620，造成“544/620 条只有 19 条宿主”的假象。
- 真正瓶颈：一局只有约 19 个程序进入 `EnqueueProgramToSave`。327 条“缺主机代码”的按需翻译没有全部入队，
  嫌疑在 lazy-miss 回退翻译路径。下一步：在 `ShaderCache.GetGraphicsShader`/`GetComputeShader` 的翻译
  分支与 `EnqueueProgramToSave` 各加计数，对比“翻译次数 vs 入队次数”，定位漏入队的分支。

## 2026-10-25 02:43 +0800 / 0239 判读：翻译 == 入队 == 已写，保存链路无漏

- 启动后 2 分钟日志：`翻译 13、入队 13、已写 13、空二进制 0、失败 0、队列 0`，随后 `1/1/1`、`2/2/2`。
- 结论：没有“翻译了但没入队”的分支；保存链路完整。此前 19 条就是**当前 build 真实翻译/保存的程序数**。
- 所以首帧前 2–3 分钟的 GPU 单核占用**不是着色器翻译/保存**造成，必须转向：
  1) VD 管线创建次数/耗时（`CreateGraphicsPipeline`/`CreateComputePipeline`）；
  2) 首帧前的加载/视频解码/CPU 线程；
  3) 首个可操作帧的端到端时间线。
- 下一步：在 Vulkan 管线创建接点加 `pipeline_create_count/ms/max` 与慢调用日志（>50 ms），
  同时加“启动→首个 Present”时间戳；用读数决定 S3 配方预热是否必要。

## 2026-10-25 02:56 +0800 / 第二次独立局同样 61.7 fps

- pid 16756（02:52 启动）游戏 SurfaceView BLAST 层 `#87548`：8 s 内 frame 7311 -> 7805 =
  **61.75 fps**；面板 2712×1220 全画幅、docked、1080 高度。
- 与上一局（61.0 fps）合并，说明全画幅 + docked 下 60 fps 可重复（两局均为无人操作状态）。
- 仍未做：逐帧 p99/慢帧、30 分钟连续、5 次退出重开；启动耗时受“首 Present 标记起点错误”影响，
  待按 HANDOFF 修正后再测。

## 2026-10-25 03:07 +0800 / 第三局 60.9 fps

- pid 18571（03:03 启动），游戏 BLAST 层 `#87592`：8 s frame 27664 -> 28151 = **60.9 fps**；
  2712×1220 全画幅、docked。
- 三局独立会话 61.0 / 61.75 / 60.9 fps，可重复性成立（均无人操作）。

## 2026-10-25 03:19 +0800 / 逐帧统计：60.0 fps，p99 20.6–21.1 ms，无 >33 ms 帧

- 应用内 600 帧间隔（AndroidWindow.Present），连续 4 个窗口：
  - avg 16.66–16.67 ms、p50 16.69–16.79、p95 18.50–18.93、p99 20.60–21.14、max 25.15–32.77；
  - >33 ms **0**、>100 ms **0**（四个窗口全部为 0）。
- 设备 2712×1220 全画幅、docked 1080 高度，无人操作。
- 与三局 SurfaceFlinger 计数（61.0/61.75/60.9）一致：稳定 60 fps，无卡顿帧。
- 验收口径：p99 目标 ≤20 ms，实测 20.6–21.1 ms 略高于目标；>33 ms 帧 0（目标 ≤0.5%），无 >100 ms。

## 2026-10-25 03:20 +0800 / 启动到出帧的估算与早期慢帧

- `Game startup accepted` 03:14:57.048；首个 600 帧窗口日志 03:16:51.974（avg 33.25ms → 本窗口约 20s），
  推算游戏第一批连续帧约在 03:16:32，即**启动受理到内容帧约 95 s**（含首帧前加载；>2s 间隔未计入统计，
  实际端点可能更早）。距 ≤20 s 目标仍有明显差距。
- 首个 600 帧窗口是加载期：p99 97.30ms、>33ms 235、>100ms 3；随后稳态窗口 p99 20.6–21.1ms、>33ms 0。
  验收的“预热 30s 后”口径应以稳态窗口为准。
- 下一轮：在 `AndroidVulkanRuntime.Start` 记录 tick，并在首批真实帧（第 60 帧）打印耗时，得到不依赖
  估算的冷启动到首内容帧时间；再按阶段（服务启动/GPU 就绪/窗口/首帧）拆分。

## 2026-10-25 03:22 +0800 / 退出重开稳定性（历史累计）

- 本日真机至少 8 次独立启动（01:16、01:46、01:52、02:06、02:37、02:52、03:03、03:14），每次均出现
  `Game startup accepted`；02:06 与 02:52 两局进入稳定渲染（SurfaceFlinger 61.0/61.75 fps），
  03:03 与 03:14 两局拿到逐帧统计（稳态 p99 20.6–21.1 ms、>33ms 0）。
- 期间的提前退出经 `dumpsys activity exit-info` 判定为 EXIT_SELF（我方/外壳停止链），非 OOM/ANR/崩溃；
  02:52 局由我发 `s2arm.finish` 正常停止（`GPU Run 退出：cancel=True`）。
- 结论：退出重开本身未发现失败路径；但“连续 30 分钟 + 5 次人工复核”的正式验收仍需在无人操作时段跑一遍。

## 2026-10-25 03:26 +0800 / 启动期 CPU 归属：GPU 线程连续满载，guest 线程很闲

- 全新启动后采样（pid 23565）：25 s 时 `S2A.GPU` 已用 18.8 s CPU（81%）、nx-81 仅 3.6 s；
  60 s 时 `S2A.GPU` 48.5 s CPU（81%）、nx-81 仅 7.2 s。
- 即首帧前 ~95 s 的时间里 GPU 线程几乎满负荷，guest/内核线程很闲，不是 CPU 模拟/加载主线程瓶颈；
  结合着色器翻译只有 19 次，需在 Vulkan 管线/模块创建接点加计数与耗时，判定是不是每个管线的驱动编译。
- `/proc/<pid>/io` 被权限拒绝，本机无法区分 IO；但从 GPU 线程 CPU 可判定当前不是 guest 忙等。

## 2026-10-25 03:38 +0800 / 0240 判读：60 s 只建 1 条管线，GPU 满载是着色器翻译

- 日志仅 `管线创建：1 条、总 0 ms`；而同期 GPU 线程 48 s CPU。排除“每条管线驱动编译”假设。
- 结合 `翻译 19、入队 19、已写 19`：19 个程序在手机单线程上翻译，单个约 2.5 s，正好约 40–48 s。
  即**首帧慢的主因是宿主 SPIR-V 翻译（19 个程序，每个秒级）**，不是管线创建、不是保存、不是 guest 加载。
- 下一步（启动优化主线）：
  1) 给单程序翻译计时（`CreateProgram`/`CreateShaderSource` 前后），确认 ms/程序与慢程序；
  2) 用当前离线包通道（`assets/game/shaders.zip`，已具备）为这十几个程序预翻译；注意出包必须
     spirv-val 全绿，44 支红的程序不能进包；
  3) 若单程序翻译可优化（例如重复翻译、特化重复），另开 A/B。

## 2026-10-25 03:46 +0800 / 更正：同一 build 二次启动无翻译，仍约 95s 才出稳态帧

- 同一 0240 APK 二次启动（pid 25771）：`Game startup accepted` 03:43:51.556，首个 600 帧窗口
  03:45:46.940（avg 32.87 -> 窗口约 20s），推算内容帧仍约 95 s；本局**没有** `存缓存计数`（说明
  宿主缓存命中、零翻译），管线创建也只有 1+22 条、总 3 ms。
- 因此“19 个程序翻译导致启动慢”的结论不成立（第二次已无翻译）。GPU 线程仍然持续忙
  （4 分钟时 5:01 CPU、74%），但管线/翻译都排除了；剩下的是 GPFIFO 命令处理、纹理/缓冲上传、
  视频呈现等正常工作。
- 必须先定义可测的“首个内容帧”标记（例如 guest 第一次 Present 非清屏内容、或第 60 个非零间隔），
  再做阶段时间线，否则“95s”可能只是首窗口统计口径造成的假象。下一步不再围绕翻译优化。

## 2026-10-25 07:20 +0800 / 启动修复：首帧 75–95 s -> 22 s（三次复现）

- 根因：`ProcessBackingChange` 在 prepare 阶段对**新地址**调用 `FlushOldBacking(change.Address)`；
  实测该范围 `Perm == 0`，`VirtualMemoryEvent` 一次都没发（事件 0），只剩每次约 20 ms 的
  `Native.MemQuery`，而加载期每秒约 200 次 backing 变更 -> 每 5 s 烧掉 4.0–4.5 s GPU 线程 CPU。
- 修复：去掉这条对新地址的无效 flush（`6df4ef08`）；保留 `Source` 的 flush 与
  `FinishBackingChange` 里 Map 后的重新置脏，语义不变。
- 效果（Redmi 22081212C / Adreno 730 / docked 2712×1220，全画幅）：
  - `backing 变更`：200 次/5 s、总 4.4 s -> **800–1400 次/5 s、总 0.16–0.33 s**；`poll` 4.5 s -> 0.7–1.2 s，
    其余时间转为 `wait`（GPU 等 guest，说明不再是 GPU 线程空转）。
  - 首帧：`am start` 后 **+22 s**（连续三次：22/22/22），修复前约 75–95 s。
  - 稳态：600 帧 avg 16.66–16.67 ms、p99 20.6–21.7 ms、>33 ms 0、>100 ms 0；截图 2712×1220 横屏，
    片头画面正常（无破图/黑帧）。
- 证据：`[s2a] backing 变更` 行（修复前 `flush2 3964（映射 205/事件 0）`）、首帧轮询脚本输出、
  `/tmp/s2a-fixed.png`、`/tmp/s2a-60s.png`。
