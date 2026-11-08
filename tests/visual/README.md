# tests/visual — 画面正确性（画幅线）

| 目录 | 做什么 | 跑法 |
|---|---|---|
| `widen_unit/` | graphics/widen 单元测试：识别 / 改写 / 界面层 / 写回原值 / 视口换算 / SPIR-V 读取分析 / 稳态零分配，期望值全手算 | `dotnet run -c Release --project tests/visual/widen_unit`，退出码 = 失败项数 |
| `refvk/` | 参照渲染器：Ryujinx 自带 Vulkan 后端（compat/tree 原样）无窗口跑在本机 MoltenVK 上，自旧库 497552d 迁入 | 被 galplay `--ref` 引用；MoltenVK 路径 `REFVK_MOLTENVK`（缺省 /opt/homebrew/lib/libMoltenVK.dylib） |
| `galrec/` | GAL 调用流录像（S2AGAL01）读写与最小回放器，自旧库 S2A 497552d 原样迁入，对仓内锁版本 GAL 编；S2Arm 运行时已接（services/aot/Compose.cs，套在宽屏包装层外、录游戏原始调用） | 真局录：`S2A_GALREC=<目录>`（写 <目录>/gal.rec）、`S2A_GALREC_MAX_MB`（缺省 2048）、`S2A_GALREC_FRAMES=a-b`（只录第 a..b 次上屏）；不设零开销。录前清掉该游戏的 Ryujinx 着色器缓存（或用私有 S2A_RYU_DATA），否则按二进制建的程序录不到 SPIR-V |
| `galplay/` | 录像回放进我方 Metal 渲染器（可选 `--widen <宽高比>` 套宽屏包装层），指定上屏帧存 PNG，报回放错误与宽屏红计数（序章补内容单列） | 先 `make -C graphics/metal`；`dotnet build tests/visual/galplay` 带 artifacts-path、`-p:OutDir=<目录>`、`-p:RyuGpu=<仓库>/ryujinx/tree`，把 build/gal/libnxgal.dylib 拷进 OutDir；`galplay <gal.rec> <输出> [--widen 2.1727 [--game-wide]] [--frames 10,30] [--probe 帧:贴图号:x,y] [--depth 帧] [--ref] [--time 宽x高@a-b] [--until N]`（--game-wide：同产品「游戏自己出宽图」只管界面层；每张存图旁写 present_<帧>.json（raw = 录像原始裁剪、out = 交给出图层的裁剪），报告记「录像出图参数变化 N 次」（只读录像算）；--time：第 a..b 帧里画到该尺寸目标（0x0 任意）的每次绘制前后各读回一次，记程序各阶段键 / 目标 / 绘制数 / 拓扑 / 毫秒到 time.tsv；毫秒含读回与排队中的上传 / 同步，只能判「明显重不重」、量不准真实 GPU 时长；--ref：同步回放进 Vulkan 参照、指定帧上屏图逐像素比，出 ref_ / diff_ 图与差异像素占比、PSNR；--depth：导出该帧场景深度；探针：该帧每次画到该贴图后读一个客体坐标像素，基线 / 加宽对齐找第一处分歧的绘制） |
| 逐绘制对拍（`galplay/DrawDiff.cs`、`drawdiff.py`、`diff_rec.sh`、`diff_store.sh`、`diff_list.tsv`） | 双后端逐绘制对拍（画面·着色器线 10-21，画面根因第 ⑤ 类总兜底）：同一录像同步回放进我方 Metal 与参照 Vulkan@MoltenVK，**每个渲染通道结束**（换目标 / 上屏前）两边读回全部颜色目标与深度（数组逐层）逐像素比，报第一处分歧（记录、帧、程序、目标、差异像素、最大差、差异框）；`--diff-draw a-b` 在第 a..b 条记录里每次绘制后都比，定位通道里第一处分歧的那次绘制，并存现场 `diff_state_<k>.txt`（各阶段绑定的贴图格式 / 采样器建法）。差的单位「级」= 存储格式 ULP（unorm8 码值、半精度 / R11G11B10 编码距离，浮点再与 8 位绝对差取小，fp32 / unorm16 折算到 10 位、深度折算到 16 位），容差 1 级（同后端两遍回放逐比对哈希全同、两后端字节不同但在 1 级内的都是舍入翻转，依据见下）。**重同步**（缺省开）：任一比对字节不同就把参照那份写回我方，每处分歧只算在引入它的通道上。绑着当前附件采样（反馈环）的绘制在 diff.tsv「反馈环」列标出。参照 D24 系深度读回不准（MoltenVK 没有 D24S8，Ryujinx 把分平面拷出的深度 / 模板当交错转换），不比 | `galplay <rec> <出> --ref --diff [a-b] [--diff-draw a-b] [--diff-all] [--diff-nosync] [--diff-split] [--break-shader [程序号]]`（有分歧退出码 4）；两遍定性：`drawdiff.py <遍1> <遍2>`（同 / 确定分歧 / 不确定·我方 / 不确定·参照）；录像：`DIFF_MAIN_TREE=<干净 main 树> tests/visual/diff_rec.sh <款> <局目录>`（程序全部以 SPIR-V 建：私有数据根 + 去掉 shcache 的私有着色器包；MARK 后 +30 起录 90 帧，200 秒没 MARK 照样开窗）；入库 `diff_store.sh <gal.rec> <款>`；门禁清单 `diff_list.tsv`（录像、帧段、期望比对次数、已知分歧、说明） |
| `gate.sh` | 门禁钩子（tools/gate.sh 自动发现）：单测每次跑；改到 graphics/ compat/ tests/visual/ 时用参考录像（`~/.s2arm/run/s2arm/visual/recs/list.tsv`）同库出基线与加宽图，按 widen_cmp 判；在真值检查点录的录像另判 Windows 真值 | `bash tests/visual/gate.sh`（仓库根）；10-19 实测 29–52 秒：单测 94/94、出图 5/5、真值 2/2 |
| `truth_cmp.py` / `truth_pick.py` | Windows Ryujinx 真值比对（8×6 分格 SSIM + 亮度 + 锐度、同时刻多局剔除、窗内最优帧）与真值挑帧，自旧库 497552d 迁入；真值根目录 `S2A_TRUTH`（缺省 `~/.s2arm/run/s2arm/visual/truth/<游戏>/<检查点>`，已从旧库克隆 9 款 208 MB）；`--center16x9`：加宽图先取中间 16:9 再比（过渡判据：亮度只判中间 1/2 宽度）；宽屏真值（检查点 `_w<W>`）自动整帧比 | `truth_cmp.py acnh tent <我方.png> [--center16x9]` |
| `truth_table.py` | 画面格真值表（给 tools/score_cells.py --truth）：局目录 `shots/<检查点>.png`（或逐秒序列目录）逐张对 Windows 真值，加宽图自动取中间 16:9；写 `<局目录>/truth.tsv`（款 / 检查点 / 总判 / 说明） | `truth_table.py <局目录> <款>`；退出码 0 全过、1 有不过或无真值、3 没截图（记分板记未测） |
| `widen_holes.py` | 宽屏露空量化：读 `galplay --depth <帧>` 导出的场景深度，按行比两侧与中间「没画」（深度 = 清屏值）比例，出露空占比与标红图 | `widen_holes.py depth_N.json [--img 加宽图 --mark 标红图]`；10-19：马车8 0、动森岛户外 29.7%（占两侧带） |
| `proj_aspect.py` | 录像里游戏透视投影的宽高比分布与最大渲染目标尺寸（判「游戏镜头是否已按屏幕比算」；认标准与 RE 引擎两种投影形状，P00 / P11 越出 0.05–50 的不算，认不出报 None；单测 tests/proj_aspect_test.sh） | `proj_aspect.py <gal.rec> [--target 2346/1080]` |
| `widen_cmp.py` | 宽屏出图判据：加宽图中间区对原图 PSNR、两侧带有画面 | `widen_cmp.py <原图> <加宽图>` |
| `widen_mid.py` | 中间区逐像素：按 galplay 旁注的出图区取加宽图中间（偏移 = 宽差 / 2，奇数宽差取两列平均并标出）对原图出图区，出差异像素数 / 通道差总和 / 最大差 | `widen_mid.py <原图目录> <加宽图目录> <帧>` |
| `widen_gate.sh` + `widen_gate.tsv` | 宽屏门禁（gate.sh 调用）：九款 GAL 金样录像（`~/.s2arm/run/s2arm/replay/gal`）不放宽 / 放宽（按启用表定产品模式 W 或 G）各放到表里的早帧，中间区差异 ≤ 登记 + 噪声、出图参数变化 ≤ 录像原始 + 登记、回放无错；登记差异的根因写在表头。录像解压与离线着色器库缓存在 `~/.s2arm/run/s2arm/cache/widen_gate`（运行时现编在低优先级线程上，高负载时慢 20 倍） | `bash tests/visual/widen_gate.sh [<galplay 目录> <libnxgal 构建目录>]`；10-21 实测热缓存回放 + 判 11–21 秒（本机负载 90–110） |
| `galrec_widen/` | 在 GAL 录像上跑宽屏识别与判定（只算不画、不用 GPU、秒级）：放宽贴图、改写命中逐值明细、界面层判定、会被拉伸的透视绘制、非放宽目标写回 | `dotnet run -c Release --project tests/visual/galrec_widen -- <gal.rec> [宽高比] [明细目录]`；`GW_DEBUG=1` 打界面层与拉伸绘制明细，`GW_DUMP_PROG=<程序号,…>` 导出该程序 SPIR-V 到明细目录 |
| `widen_scanbench/` | 宽屏包装层 CPU 回放基准（10-21 起；只算不画、不用 GPU）：整份 WidenRenderer 套在空渲染器上回放录像前 N 帧，A = 空渲染器、B = 包装层 + 空渲染器交替各几遍，(B − A) ÷ 帧数取最小，按进程 CPU 时间（本机负载高时墙钟不可比）；同一份源码可对改前代码编（没有 CbufShadow.cs 时不编影子对照）。`--check` 另跑一遍挂影子对照（WidenOldModel：旧「上传即整段改写」模型），读到的矩阵漏改 ≠ 0 退出码 1 | `dotnet run -c Release --project tests/visual/widen_scanbench -- <gal.rec> [--until 300] [--warm 60] [--passes 3] [--game-wide] [--check]`；读数见 graphics/widen/README.md「常量改写：只扫变了的」 |

真值生成脚本：compat/truth/run_truth.sh（服务接入线；读我方起局同一份测试资产，按时间表跑，SHOT:<名> 截图写 <输出目录>/shots/）。满屏判据（「【红】出图未满屏」）已随渲染器在 graphics/metal/gal_present.m，真局日志判；回放器无屏幕图层不触发。
dotnet 工程都引用仓内 compat/tree，构建一律加 `--artifacts-path <仓外目录>`，免得往 compat/tree 写 obj。双后端对拍：10-19 三份参考录像 5 帧差异像素全 0.00%（马车8 72–74 dB、动森岛 82 dB、帐篷逐像素相同）；反向对照（参照第 10 帧对我方第 30 帧）12 dB。录像与游戏数据不进仓库。

宽屏真值（10-20，总指挥拍板「同样的输入比同样的输出」）：真值 Ryujinx 也打同一组宽屏补丁出同分辨率宽图，整帧比——
① 游戏侧第二层：`graphics/widen/scan/truth_nso.py <原 NSO> main <产物根> <W> <输出>` 按原生层同一规则把启用点静态打进 NSO（movz 改立即数、f32 改表、aspdiv 走代码段末跳板，capstone 自检），放进宽屏卡带（`~/.s2arm/run/ryu/cart_<款>_w<W>`，main 换成补丁版、其余软链原版）；
② 界面层第三层：`TRUTH_WIDE=1 bash compat/truth/build_truth.sh` 再打 `compat/truth/truth-wide.patch`，把 graphics/widen 包装层源码编进真值 Ryujinx（SupportBuffer 补 s2a_flags / s2a_widen 与我方同布局、着色器翻译口径 8354 让旧缓存作废），起局 `S2A_TRUTH_SCREEN_W=<W>` 套包装层（游戏已宽模式）；
③（10-31 作废：手录路线 tests/routes/ 随自动玩家改 AI 看屏驾驶删除，真值局改 S2A_TRUTH_AUTOPLAY=1 由驾驶员进局）起局 `S2A_ROUTE=tests/routes/<款>_points.ctl RYU_BIN=<编出的 bin/Ryujinx> RYU_CART=<宽屏卡带> RYU_ROOT=<宽屏数据根>`，时间表给空文件：真值里跑我方同一份自动玩家与同一份路线
   （按游戏状态取锚、按锚后帧数按键 / 截检查点图，tests/autoplay/ap_route.h；不按墙钟——10-20 本机负载 60～115 时按时间表的 3 局有 2 局停在标题 / 读盘）；
   数据根的着色器缓存目录软链到常驻目录、先预热一局（全量重翻会拖慢起局）；出完必跑 `--self` 看留格；
④ 真值目录 `<款>/<检查点>_w<W>/ryu_<局>.png`（我方同一份路线局的 `shots/<检查点>.png` 比它），`truth_cmp.py` 见宽图真值自动按其宽高比整帧比（格数同比加宽，我方图宽高比不一致报错），不取中间 16:9、过渡判据不用。
动森宽屏真值（10-20 路线版，tests/routes/acnh_points.ctl，3 局 a/b/c 起局 44–67 秒、锚后各步落在同一帧偏移）：自比留格 island 83% / pocket 90% / tent 98%（按墙钟时间表那版 island 只留 67%）。
我方 Mac 路线局（同一份路线）整帧比：亮度全部 ≤ 1.9 级（island / pocket）；剩下的是叶子 / 远景格结构与锐度（island 结构 8 格 0.90–0.95）与 tent 室内亮度（Mac 版 Ryujinx 帐篷内偏暗，10-19 已裁定属参照错误、Windows 仲裁），原因未定，见画幅线报告。
判据（Windows 真值）：动森帐篷录像第 1 帧，基线与加宽图中间 16:9 都过 truth_cmp（10-19 实测最低格 SSIM 0.997 / 0.986；不取中间的对照 18 格不过）。
判据（出图）：马车8 第 10 / 30 / 60 帧中间区 PSNR ≥ 30 dB、两侧非黑 ≥ 0.9（10-19 实测 40.3–42.2 dB）；动森帐篷 51.2 dB、动森岛 32.1 dB 过。
判据（录像核对）：会被拉伸的透视绘制 = 0；放宽贴图被 CPU 读回 / 上传（游戏行为）= 0；界面层判定与人工核对一致（马车8 每帧 28 次 / 程序 {6,7,770,775,11909}）。
