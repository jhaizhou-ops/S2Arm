# D1 基准：采集与对比框架

D1 的目标是固定「最新 main + 同一台 Mac + 同一款游戏同一段存档」，保存 Apple 旧实现的
**像素、帧时、上传和资源读数**，并先证明基准本身可重复。这里只做采集/对比的脚本框架：
跑局仍然由 `runtime/run_mac.sh` 在 Mac 上完成，本仓库不生成也不伪造读数。

## 文件

| 文件 | 作用 |
|---|---|
| `capture.sh` | Mac 入口：跑一局 + 调 `capture.py` 生成局目录下的 `d1.json`；非 macOS 退出 2 |
| `capture.py` | 只读归一化：`frames.tsv` / `host.log` / `shots/*.png` → `d1.json`；可在 Linux 上跑 |
| `compare.py` | 重复性 / A/B 对比；退出 0 通过、1 不过、2 输入或环境不合法 |
| `tests/test_d1.py` | 合成数据自测（不需要 Mac / GPU）：`python3 graphics/nvn/tools/d1/tests/test_d1.py` |

## 采集协议（基线必须可重复）

1. 固定提交（工作区干净）、同一台 Mac / 同一 Metal 档（3 或 4）、同一款游戏同一段存档与镜头；
   自动玩家脚本、`S2A_*` / `DM_NVN_*` 配置、着色器缓存冷热状态两次保持一致。
2. 同一份二进制连跑两次，各生成一个局目录：
   ```bash
   S2A_IN=<产物根快照> bash graphics/nvn/tools/d1/capture.sh <款> run/a 120
   S2A_IN=<产物根快照> bash graphics/nvn/tools/d1/capture.sh <款> run/b 120
   ```
3. 先跑重复性；不过的这一对不能当基线：
   ```bash
   python3 graphics/nvn/tools/d1/compare.py --mode repeatability \
       --base run/a/d1.json --cand run/b/d1.json
   ```
4. A/B（改前 / 改后）：
   ```bash
   python3 graphics/nvn/tools/d1/compare.py --mode ab \
       --base run/base/d1.json --cand run/cand/d1.json
   ```

局目录、截图像素和游戏数据都不进仓库；`d1.json` 只记哈希、计数和固定的环境字段。

## 判定口径

- **重复性**：同一提交、同机、同档；像素逐张哈希一致；帧时中位 ±5%、p95 ±10%、慢帧占比 ±1pp；
  各项 per-frame 计数（上传 / 读回 / 绘制 / 通道 / 缺着色器 / 现建管线 / 反压）±2%。
- **A/B**：方向性判红——候选的帧时中位 / p95 / 慢帧占比不得高于基线对应阈值；计数漂移同样 ±2%
  （计数变了说明行为变了，不能只当性能差）。像素默认必须一致；只有确认是预期视觉变化时才加
  `--allow-pixels-diff`，并在 PR / 记录里写明原因。
- 慢帧阈值缺省 `2 × 中位帧时`，可用 `capture.py --slow-us` 覆盖；阈值都可在 `compare.py` 上调。

## 读数来源

- 帧时、上传、读回、绘制 / 通道、缺着色器、现建管线、反压：`frames.tsv` 的同名列，见
  `graphics/metal/cs/NxFrames.cs` 表头与 `docs/测试报告与诊断收集.md`。
- 像素：自动玩家 / 截图路径写出的 `shots/*.png`；只哈希 `IHDR+IDAT`，忽略 PNG 元数据。
- 缺列（旧二进制）按 0 记；跨版本比较前先确认两边 `frames.tsv` 表头一致。

## 限制

- 本框架不跑游戏、不采真机读数；D1 的读数必须由 Mac 真机/直连线跑出来。
- Metal 3 与 Metal 4 是两套基准，不能混比；不同设备也不能硬比（`compare.py` 直接判输入不合法）。
- 温度、充电、后台进程会污染帧时；基线记录里必须写明热状态与并发现场，重复性不过先查环境。
- 这是 D1 的框架，不是性能结论；像素 / 帧时的验收仍以直连线在 Mac 上的复核为准。
