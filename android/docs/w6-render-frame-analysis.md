# W6 渲染帧解剖：工作路径、CPU 账、GPU 账

> 对象：Diablo III（W6）direct 模式，NVN → Vulkan（nvn_vk 后端），Adreno 730 / Android 16。
> 分支：`android/w6-tex-lifecycle`；读数取自 2026-10-31 真机（Step 1 构建，wiring 包）。
> 口径：guest 3D 1280×720，合成 1600×900，swapchain 2712×1220；`debug.s2a.present_defer=1`；
> 逐笔打点只在 `debug.s2a.perf_timing=1` 时开（正常游玩关闭）。热漂移 ±1.5 ms，只有相邻 A/B 可信。

---

## 1. 一帧的总账

世界稳定段（1280×720，静止/低交互）：

| 项 | 读数 | 说明 |
|---|---|---|
| gap（帧间隔） | **24.2–25.1 ms** | p50 24.3，p95 25.6 |
| exec（我们录命令 + 提交） | **17.1–18.5 ms** | 场景/热状态不同有 ±1.5 ms |
| present（present 路径） | **0.8–1.2 ms** | 延迟 present |
| other（游戏自己的 CPU） | **5.5–6.1 ms** | 客机逻辑/JIT/音频/输入，不在 NVN 路径里 |
| fps | **39–43** | 典型 41 |
| 每帧命令数 | **3300–3900** | 其中 draw 约 470–520 笔 |
| 每帧 pass 数 | **37–46** | 两个命令池轮换 |

结论先行：**CPU 腿 23–24 ms，GPU 19.5 ms → 现在绑帧的是 CPU**。GPU 从 19.5 砍到 15 也不会涨帧，
除非 CPU 同时往下走；反之 CPU 每降 1 ms，帧率约 +1.7 fps（到 GPU 天花板 ~48 fps 为止）。

---

## 2. 工作路径：一帧从游戏到屏幕

### 2.1 模块路径（native 侧）

```
游戏线程（客机 CPU / AOT）
  └─ NVN 调用（DrawArrays/DrawElements/SetTexture/BindTexture…）
      └─ mtl_vk_shim.c        命令入口：参数转换、执行链、文本/统计
          └─ mtl_vk_adapter.c 执行器：owner 线程、opcode 分发、session、
          │                   纹理注册表（s2a_vk_adapter_tex_by_id）、
          │                   内容所有权钩子（tex_cpu_written / tex_gpu_owned）
          └─ nvn_vk_first_draw.c  first draw：状态解码、程序查找、pass 管理、
          │                     资源解析、描述符、VB/IB、命令缓冲记录
          └─ nvn_vk_draw.c        逐笔绘制记录（vkCmdBind*/Draw*）
          └─ nvn_vk_texcache.c    纹理寿命/内容（页级脏、复用、退役）
          └─ nvn_vk_session.c     帧边界、present 收尾、GPU 内容所有权
      └─ 提交：每 8 个 pass 一批 vkQueueSubmit；帧末 present（延迟）
          └─ swapchain blit 1600×900 → 2712×1220 → SurfaceFlinger
```

### 2.2 每帧时序

1. **录命令**（游戏线程，17 ms 内完成）：游戏逐条调用 NVN；我们的 shim 把 draw 解码成
   `nvn_vk_first_draw` 的输入，直接在 CPU 上把 Vulkan 命令写进命令缓冲。
2. **分批提交**：每 8 个 pass 一次 `vkQueueSubmit`（一个 fence 管一批），帧内约 5–6 次提交。
3. **present（延迟）**：帧末不立即 present，下一帧开头再提交 present；`present_defer=1` 时
   队列里最多压一帧，等 GPU 画完才 present。
4. **帧队列**：每个批次的命令缓冲/描述符池/临时 framebuffer 在 fence 完成后回收；纹理按
   游戏 create/Finalize 走生命周期，页级写跟踪决定是否重传。

### 2.3 线程模型

- 游戏线程：录 NVN 命令（单线程）。
- owner 线程：adapter 的执行链消费者（`provider.poll` 驱动），负责 session/纹理注册表/清理。
- 编译 worker：按需编译着色器（一帧内最多一个 demand slot）。
- 我们不开独立的 render 线程；Vulkan 记录在游戏线程上完成（这是 exec 17 ms 的来源）。

---

## 3. CPU 完整消耗路径

### 3.1 总账（exec 17.1–18.5 ms）

| 段 | 时间 | 备注 |
|---|---|---|
| **draw 记录（op=26）** | **12.5–15.6 ms** | 470–520 笔 × 23–31 µs |
| 非 draw 命令（clear/copy/event/buffer/绑定等） | ~2.5–3.5 ms | 3300 条中非 draw 约 2800–3400 条，单条 0.5–1 µs |
| 提交/等待（vkQueueSubmit、fence 检查） | ~0.5–1 ms | 含在 exec 内 |
| present（单列） | 0.8–1.2 ms | 见 3.5 |

### 3.2 逐笔 draw 的分段（perf_timing=1，256 笔窗口）

| 段 | 典型值 | 内容 |
|---|---|---|
| entry | 1–2 µs | 参数校验、状态解码、`fd_draw_state` 组装 |
| 程序查找 | **5–6 µs** | 身份编码 + 备忘（128 槽环，命中 55–56%）+ 程序对象（sha[0] 直接索引） |
| pass 块 | **1–12 µs** | 反馈采样检测（有反馈时 8–12）+ pass 复用判断；**pass open 30 µs/次**，37–46 次/帧 |
| resource | 2–9 µs | 纹理解析（`resT` 6 µs：绑定纹理逐笔取视图/注册表查找） |
| vbuf | 0–2 µs | 顶点/索引数据拷贝进本帧 arena |
| desc | **3 µs** | 描述符集分配 + 写入（1 个 pool，2 个池轮换） |
| cmd | 0–1 µs | 纯 vkCmd* 记录（不占大头） |
| **合计** | **23–31 µs** | |

关键固定开销：
- **pass open 30 µs/次**（cget 17–18 + bcb 5 + rest 7）：37–46 次/帧 → **1.1–1.4 ms**。
  `vkResetCommandBuffer` 占大头（cget），d2r 的每槽命令池是唯一能砍它的通用办法。
- **程序查找 5–6 µs/笔**：备忘已从 64 槽改成 128 槽环（命中 34%→56%，查找 10→7 µs），
  剩下是身份编码与缓存扫描。
- 描述符每笔 3 µs：set 复用/模板批分配试过，真机 SIGSEGV 或负收益，未并入。

### 3.3 非 draw 命令（~3 ms）

约 3300 条/帧，主要是：`ClearDepthStencil`、`CopyImage`、`SetTexture` 系列、绑定、事件/信号、
buffer 更新。单条 <1 µs，整体不到固定开销的 20%。

### 3.4 客机 GPU 模拟侧的固定成本（已做过的 Step 1）

- 时钟：CNTVCT_EL0 直读，去掉了 4 次 clock_gettime/命令；
- 原子：busy 镜像改 relaxed；
- 唤醒：执行链等待条件化广播（`g_exec_waiters`）；
- TLS：resolver/draw builder 按线程+会话代际懒注册，不再每命令查 TLS。
- 合计世界 **37.6→41.0 fps**（exec 19.0→17.1 ms）。

### 3.5 present 路径（0.8–1.2 ms）

```
等GPU画完=0 us（延迟 present） | acquire=29–37 us | 录blit+提交=66–87 us | present+vsync=170–218 us
```

- acquire：`vkAcquireNextImageKHR`（swapchain 3 图）。
- 录 blit+提交：1600×900 → 2712×1220 的 blit 记录 + `vkQueueSubmit`。
- present+vsync：`vkQueuePresentKHR`，受 120 Hz panel 的 vsync 间隔影响。

### 3.6 other 5.5–6.1 ms（不属于我们）

客机 CPU：游戏逻辑、AOT 代码、音频混音、输入/HID、文件 IO。这部分在 Ryujinx 客机侧，
不在 NVN→Vulkan 的直连路径里；除非改客机/JIT，否则动不了。

---

## 4. GPU 完整消耗路径

### 4.1 总账

| 项 | 读数 | 方法 |
|---|---|---|
| GPU busy | **19.1–19.6 ms** | `debug.s2a.gpu_time=1` |
| 片元 | **16.3 ms** | 1×1 viewport 诊断（只跑顶点/建立） |
| 顶点/建立 | **3.2 ms** | 同上，差值得出 |
| pass 数 | 37–46 | pass 表 |
| draw 数 | 470–520 | draw window |
| 顶点数 | #7 单 pass 33.8 万 | 逐 pass 表 |

### 4.2 逐 pass 表（世界静止帧，GPU 19.5 ms 口径）

| # | 目标 | 时间 | draw | 顶点 | 特征 |
|---|---|---|---|---|---|
| 7 | 1280×720 BGRA8 | **5.45 ms** | 175 | 338k | 主场景；约 1.2 ms 顶点 + **4.2 ms 片元** |
| 21 | 1280×720 | **2.80 ms** | 60 | — | 50 笔 blended（半透明 overdraw） |
| — | 1024×1024 RGBA16F | **1.18 ms** | 1 | 3 | 4 次采样后处理 |
| 36 | 1280×720 全屏 | **1.00 ms** | 1 | 3 | 9 次采样后处理 |
| 42 | 1280×720 全屏 | **1.00 ms** | 1 | 3 | 9 次采样后处理 |
| 17 | 1280×720 | **0.85 ms** | 49 | — | 39 笔 blended |
| 其余 ~40 个 | — | ~7.2 ms | — | — | UI/阴影/小 pass |

口径说明：`gpu_time` 的 19.5 ms 是整帧；vp1 诊断把 viewport/scissor 压到 1×1 后 GPU 只剩
3.2 ms（顶点/建立），差值 16.3 ms 是纯片元。**84% 的 GPU 时间在片元。**

### 4.3 两个 720p 全屏 pass 的真相（9 tap，不是翻译放大）

用 `dump_progs` + `draw_prog` 把程序落盘并反汇编：

| 目标 | 程序 | FS | image op | 循环 |
|---|---|---|---|---|
| 1280×720 全屏 | `8f3b74c0` | 28.3 KB / 1747 行 | **9** | 0 |
| 1024² RGBA16F | `069ca307` | 11.1 KB / 694 行 | 4 | 0 |
| 1600×900 | `247de23d` | 6.5 KB / 406 行 | 1 | 0 |

没有 `OpLoopMerge`，指令数与采样数吻合：720p 的 1.0 ms 是 **921k 像素 × 9 次采样**的真实成本，
不是翻译成循环/冗余指令。同为全屏、1 次采样的 1600×900 pass 只要 0.3–0.4 ms，量级自洽。

### 4.4 片元成本分解（16.3 ms）

| 来源 | 估算 | 驱动因素 |
|---|---|---|
| 主场景 #7 | **4.2 ms** | 场景着色 + overdraw；depth-only pass 已有（~11–20 笔/帧） |
| 半透明/blend（#21、#17 等） | **3.6 ms** | 50+39 笔 blended，overdraw 无法 early-z |
| 后处理（9 tap ×2、4 tap ×1） | **3.2 ms** | 全屏多 tap；分辨率 720p / 1 MP |
| 其余 pass（阴影/UI/小目标） | ~5.3 ms | 约 40 个 pass 的固定片元 |

没有 MSAA（所有附件 1×）；中间格式 RGBA16F（1024²）与 BGRA8；没有发现翻译层引入的
全屏 pass 或额外采样。

### 4.5 顶点/建立（3.2 ms）

- #7 单 pass 33.8 万顶点 ≈ 1.2 ms（顶点取数 + 着色 + 建立）。
- 其余 pass 合计约 2 ms。
- 顶点格式按 NVN→VkFormat 原样映射，没有发现被扩宽到 32 位的属性；顶点不是瓶颈。

---

## 5. 瓶颈判断与可动的杠杆

### 5.1 现在是谁在绑帧

- CPU：exec 17.1–18.5 + present 0.8–1.2 + other 5.5–6.1 = **23.2–25.1 ms**
- GPU：**19.1–19.6 ms**（在 CPU 下面重叠）

CPU 腿更长 → **CPU-bound**。GPU 单方面优化不会涨帧；CPU 每降 1 ms ≈ +1.7 fps（到 GPU 天花板
~48 fps 为止），两条腿都降到 16.7 ms 才够 60 fps。

### 5.2 CPU 侧已试过的（相邻 A/B，世界口径）

| 项 | 结果 | 结论 |
|---|---|---|
| Step 1 固定开销（时钟/原子/唤醒/TLS） | 37.6→41.0 fps | **已并入** |
| 程序对象/备忘直接索引 + 统计默认关 | 36.2→38.4 fps（相邻） | **已并入** |
| 备忘 128 槽环 + 64 位摘要 | 命中 34→56%，查找 10→7 µs | **已并入** |
| VB/IB/描述符绑定影子 | 18.2 vs 18.0 ms | 无收益 |
| 整池 `vkResetCommandPool` | 18.3 vs 17.8 ms | 更差 |
| 描述符 set 批分配/复用 | 真机 SIGSEGV（layout/在途） | 不安全 |
| 反馈快照图像复用池 | 18.6 vs 18.3 ms | 无收益 |

剩下的 CPU 结构项：每槽命令池（砍 pass open 的 cget，约 0.5–1.5 ms）、反馈检测缓存
（0.3–0.5 ms）。都是通用改动，但收益在噪声边缘。

### 5.3 GPU 侧可动的（需产品取舍）

| 方向 | 通用 | 收益 | 代价 |
|---|---|---|---|
| 后处理半分辨率 | 是 | ~2.5–3 ms | 画质轻微下降；违反“不低于 720p”的现行约束 |
| VRS 2×2（主场景） | 是（需 Adreno 730 支持） | 主场景片元最多 ~3 ms | 画质取舍 + 驱动依赖 |
| 深度预 pass | 是 | 预期 0（early-z 已生效） | 多 ~1.2 ms 顶点 |
| 翻译级 FS 优化 | 是 | 未知（当前 SPIR-V 无循环/明显浪费） | 改翻译器，跨游戏回归 |

在“不舍弃画质、不降 720p”的约束下，GPU 侧没有能直接落地的项；CPU 侧只能靠结构级改动
（每槽命令池）再挤 1–2 fps。

---

## 6. 复现方法

```bash
# 世界读数（Steps）
adb shell setprop debug.s2a.gpu_time 1          # GPU busy
adb shell setprop debug.s2a.present_defer 1     # 逐 pass 表 + 延迟 present
adb shell setprop debug.s2a.perf_timing 1       # 逐笔分段（默认关）
adb shell setprop debug.s2a.frame_log 1         # 逐帧帧时间（默认关；局末转储，见下）

# 抓取
adb logcat -d | grep -E "frame timing|draw window|open window|draw timing|present 拆分|逐 pass"
```

逐 pass 表在 `debug.s2a.gpu_time=1` 时每个统计窗口打印一次；vp1 诊断（1×1 viewport）只用于
拆顶点/片元，测试代码不在产品分支。

### 6.1 逐帧帧时间（整窗 p50/p95/p99/1% low 口径，direct/generic 同一份）

`frame timing(近N帧)` 每 16 帧一行窗口聚合，算不了整窗分位与精确慢帧计数；`debug.s2a.frame_log=1`
在**每个成功 present 点**记一条 24B 记录进 32768 帧环形缓冲（≈60fps 9.1 分钟；记满覆盖最旧，
丢弃数在转储里可见），会话收尾同时写应用私有文件并经 logcat 分片转储；debug 包可通过受管工具只读取回文件。开关要过两道调试门（调试构建 + `debug.s2a.debug_env=1`，
见下），关态每帧/每次 fence 等待只读一次缓存标志，无任何 I/O。

- direct：在 `mtl_present` 成功返回点记 `CLOCK_BOOTTIME` µs 戳；记录另带**每帧 fence 等待**——
  直连 `vk_record.c` submit 与 `vk_clear.c` clr_submit 两处 `vkWaitForFences` 的等待次数与
  总时长（µs）累计进帧内账，present 时原子快照进该帧记录并清零（仍在飞的等待归下一帧）。
  转储触发：adapter shutdown（帧队列结算后）。
- generic：在 `AndroidWindow.Present` 的 `QueuePresent` 被接受后记同一个环形缓冲。fence 统计
  `FenceHelper` 和 `CompletePendingCommands` 的阻塞 `vkWaitForFences` 调用，timeout=0 的探测不计；
  另记本帧 `AcquireNextImage` 和 `QueuePresent` 的 CPU 墙钟时间（acquire 重试只累计调用时间）。
  fence 记录为调用完成后按到达顺序归入当前 present 的累计账；多线程等待可以重叠，不能当成单线程关键路径。
  转储触发：`AndroidGameRuntime.Cleanup` 的 `StopGpu` 之后。

```bash
adb shell setprop debug.s2a.debug_env 1     # 调试入口总开关，只在调试构建有效
                                          # （正式构建编译期就关死，设了也没用）
adb shell setprop debug.s2a.frame_log 1     # 起游戏前设（首次 present 时一次性读入缓存）
adb logcat -G 16M                           # 起局前放大 logcat main 缓冲：缺省约 256KB，
                                            # 局末一次性约 1000 行转储会把前面的分片挤掉；
                                            # 或者起局起全程 adb logcat > run.logcat 实时抓
# …跑完一局，正常退到 shutdown…
adb logcat -d > run.logcat
python3 android/direct_framelog.py run.logcat
```

真机第一局读数贴回时，把 `meta` 行和 `end` 行原样带上（核 recorded/presents/chunks 与
sha256 是否一致、丢了多少片）。

转储行形如 `direct frame-log meta:`（v=3、rec=24；解析器也接受 v2、rec=16）+ `direct frame-log[i/n]:<base64>` +
`direct frame-log end:`。解析器按序号拼回、核 sha256 与计数自洽，**缺片/重复/乱序/哈希不符/
v 与 rec 不符直接拒绝统计**（报 FAIL），通过后输出间隔样本的 p50/p95/p99、1% low、
>50ms/>100ms 次数、最长帧与所在帧号，fence 等待的总次数/总时长/有等待帧数/单帧最长，并与
同日志里采样的 `frame timing(近16帧…)` 聚合行逐窗对拍（nearest-rank 同式，容差 0.15ms）。
口径：间隔 = 相邻成功 present 的返回点差，即“上屏节奏”，不是 GPU 帧执行时长；
fence 列 = 已接入的 CPU 侧等待调用墙钟总和，不是 GPU 执行时长；acquire/present 是对应 CPU 调用墙钟，不计锁等待。v2 没有这两列，v3 的未采集或饱和字段不能当零。
