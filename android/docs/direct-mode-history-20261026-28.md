# Android 直连历史证据归档（2026-10-26—28）

**本文件只保留历史证据，不是实施方案、任务表或交接指令。当前唯一执行入口是[统一方案 §11](fast-generic-v3.md#android-main-w236-plan)。**

原文中的“当前”“下一步”、F0–F5/G0/旧性能编号、两小时/三小时时间表和修改 shim 的做法都只对应当时候选，不再执行。这里保留提交/设备/APK 身份、独立期望、原始读数、反例和验证限制；不新增通过结论，不覆盖 D0/W1 属主或接口。

迁入范围为原统一方案的 §3.1 执行记录、§4.1.1 抽取记录、§4.2.1 部署记录、§7–8 完整归档及旧 §10 构建/探针入口。文件相对路径不变；指向现行章节的站内链接改为回链，证据正文不删改。历史实现中确认错误的语义仅用于追溯，不能作为未来实现依据。

<a id="history-xgs-migration"></a>

## 2026-10-26 统一结果链迁移执行记录

**执行记录（2026-10-26，`android/direct-mode-d2r`）**

- 生成端：`DirectBundle.Build` 不再组 XGS，只按阶段给出 (control 键, 完整 program 结果)；CLI 写
  `<key>.program.json`；运行时 `AndroidDirectBundle` 写同一契约；`DshVk` 的 XGS `Pack` 已删除。
- 消费端：`nvn_vk_program` 重写为只读 `s2a-direct-program-v1`（`content.stages[]`），取
  真实 set/binding 反射、`attributeReadMask`、整份文件 SHA-256 身份；无 `.xgs` 解析、无扩展名探测、
  无失败回退。
- 真机（Adreno 730，显式 direct）：运行时补编对 interlock PS 明确报
  `unsupported: fragment shader interlock ...`；第一条绘制报
  `draw: program result load failed: nvn stage 1 key a566892b88596132.program.json: cannot open ...`
  —— 新后端只认新契约、不回退旧产物。
- 旧产物隔离：survey 遇到 `<key>.xgs` / `<key>.stripped.xgs` 时改名到 `<dir>/legacy-xgs/` 并打日志，
  不进新程序缓存。真机复跑（`22254`，活跃 revision `sha256-9fca…`）扫描计数为 0——该 revision 目录里
  已没有旧 XGS 文件（此前 strip 关闭时已改名，随后 revision 切换），隔离逻辑保留但本次无对象。
- 统一入口可达性：新增 `s2a_direct_bound_compile_any()`，运行时补编在真机上确认
  `direct 统一编译入口：已绑定（s2a_direct_compile_fn）`；provider 侧 `g_active_context`
  可能与补编时机不一致（曾出现 activate 时 bound、后续 unbound），因此判断“是否就绪”用任意已登记入口。
- 伪造结果已删除：运行时补编不再把 `DshVk` 的 res.json 套 schema 名写成统一结果；`s2a_direct_bundle_v1`
  现在明确返回“统一生产链待接（compile_fn 请求构造未实现，未写任何产物）”，真机日志逐条可查。
- 输入侧已就位：`nvnProgramSetShaders` 通过弱符号保存有界自有的 code/control 快照
  （`source_store.c`，256 条 / 24 MiB 上限、最旧淘汰；数组序号即真实 SetShaders 顺序，
  阶段身份留到 Draw 快照按真实掩码确定）。真机：`direct 源快照：256 条 / 938 KiB（淘汰 1202）`。
- Draw 快照已接：`s2a_record_draw_state` 携带真实绑定/附件/顶点流/视口/绘制参数（RT 的 VkFormat
  与尺寸来自纹理解析器），绘制入口在加载程序前就能报出。真机第一条绘制：
  `key0=a566892b88596132 stages=0x2 indexed=1 count=3 first=0 instances=1 rt=1(rt0 fmt=97 1024x1024)
  vp=1 scissor=0,0,0,0 tex=1@23 ubo=2:103f740300+6192 vb=3`
  —— 这是一次 **只有 FS（bit1=0x2）** 的 3 顶点全屏绘制，RT 为 R32G32B32A32_SFLOAT 1024×1024。
- profile 来源已查明：`s2a_direct_profile_v1` 在本候选（`nvn_vk`，不链接旧引擎）里没有实现，
  链接期即 undefined——编译请求要用的 enabled profile 必须由新后端按自己的
  `s2a_vk_device` 能力/limits 生成（同一份数据既给请求也给管线校验），不能复用旧引擎的导出。
- profile 合成归属：`DirectProfile.Parse` 要求 `supportLayout.hash == SupportLayout.Compile().Hash`、
  `runtimeCompilerABI == CompilerAbi`、`profileHash` 形如 `sha256-<64hex>`——这三项只有编译器程序集能算，
  `capabilities/limits` 只有设备侧有。因此 enabled profile 由两半合成：managed 用编译器算 layout/ABI/哈希，
  native 提供 `s2a_vk_device` 的真实能力；建议加一个 managed 导出（如 `s2a_direct_profile_json_v1(caps, emit)`）
  把合成结果交回 native，原样放进编译请求；不新增产物格式。
- 设备能力已可产出：新增 `device_caps.c`，从 `s2a_vk_device` 的 properties/limits/features/memory
  生成 `s2a-device-caps-v1` JSON；真机（Adreno 730）输出 1208 B，含 apiVersion 1.1.128、vendor 0x5143、
  limits/features/memory。它是 enabled profile 的 native 半边输入。
- profile 合成已落地（managed 导出）：`s2a_direct_profile_json_v1(caps, closure, emit, sink)` 以 native 实测
  `s2a-device-caps-v1` 为输入，用编译器程序集算 `supportLayout.hash`/`runtimeCompilerABI`/`profileHash`，输出完整
  `s2a-direct-profile-v1`。native Prepare 阶段调用它，`profileHash` 直接作为 effective profile（不再拿描述符里
  离线目标的 hash 冒充）；`s2a_direct.h` 只加这一个导出，不新增产物格式。profileHash = 对"去掉 profileHash 的
  规范化 JSON"做 SHA-256，出包侧 CLI（`profile --caps … --closure …`）与设备用同一函数、同一份 caps。
  主机用真机 caps（Adreno 730，1571 B）复算：profile 2417 B、sha256 `ad8dab5f…`、`profileHash sha256-9d77fed2…`；
  `synthetic-closure-v1` 的测试覆盖确定性、布局哈希、硬件支持≠enabled、重复键/缺字段/坏 closure 负例。
- 真机第一次合成报 `profile compose rejected (rc=-1)`：caps 解析的 limits allowlist 漏了 `maxImageDimension*`，
  且真机 `maxPerStageDescriptor*` 是 524288（原上限 65536），caps 的布尔字段也被写成 0/1。已改为完整 allowlist、
  放开 descriptor 上限（按布局 18/16/64/16 封顶）并让 native 输出 JSON 布尔；主机用同一份真机 caps 已复算通过，
  真机复跑已通过：同一份真机 caps（1657 B）与描述符 closure `d2r-1.0+nvn-2d9c7704`，设备 Prepare 与主机 CLI
  都得到 **2422 B、sha256 `c7eeef57…`、`profileHash sha256-8ff135af…`，逐字节相同**（真机 15568 会话）。
  logcat 单条约 1 KiB 会截断，caps 与 profile 都按 `[i/n]` 分片输出，主机按序拼回。
- 分阶段 BindProgram 已按 NVN 语义合并（`80f3447e`）：`p_bind_program` 增加 `stage_of[6]`（绑定当时从
  code/control 读定的 sd[] 阶段身份），Android 回放按阶段合并最近一次绑定，draw 用合并后的掩码与按阶段排序的 key。
  真机（暗黑3，12:37:54）第一条 draw：`key0=18f2aadcec113d49 key1=a566892b88596132 stages=0x3`
  —— 之前只有 `stages=0x2`（丢掉了更早绑定的 VS）。Apple 路径未使用新字段。
- 起局崩溃根因已查清并修复：重编 AOT 后漏跑 `android/openssl/build.sh`，APK 缺 `libssl.so`/`libcrypto.so`，
  暗黑3 初始化用到 `RandomNumberGenerator` → OpenSSL shim `on_crash` → `_exit(134)`；细节与 unwind 证据见
  [坑记录](../../docs/坑记录.md)。修好后 17 秒到达第一条真实绘制。
- 首绘的源快照已齐（`9f31efc8`）：BindProgram 时补存 code/control（SetShaders 时未映射进内存池的
  阶段原来收不到），source_store 增加按 key 查（同一 key = 同一份 control‖code，与数组序号无关），
  容量 256→4096 / 24→64 MiB。真机（暗黑3，12:46:17）第一条 draw：VS `18f2aadcec113d49` code=1024 /
  FS `a566892b88596132` code=512，control 各 2176 B，`complete=1`；源快照 1308 条 / 5688 KiB、淘汰 0。
- 生产请求已接：新增 `runtime/direct/compile_request.c/h`，是 native 侧唯一的请求生产者，直接从
  真实快照拼 `s2a-direct-compile-v1` 并经 `s2a_direct_bound_compile_any()` 调已绑定的 `compile_fn`；
  emit 结果在回调里立即复制到 malloc 的后端自有内存，不先写文件。首笔真实 Draw 在
  `nvk_draw_builder` 里触发（`nvk_first_compile_request`，快照变化才重发、最多 8 次）。
  请求另存到 revision 的 `<vs><fs>.compile-request.json`，并可用 `debug.s2a.dump_fail=<外部目录>`
  把真实请求与结果 dump 出来供桌面 CLI 逐字节复跑。
  各字段的真实来源：session/generation/`directABI`/`translatorClosure`/enabled profile 原文来自
  provider Prepare（`s2a_direct_provider_compile_context`）；`stage/code/control` 来自 source_store
  按 key 查；`constantBufferUse` 来自该阶段真实 UBO 绑定掩码；`topology` 来自 `p_draw.prim`；
  `tessCw/tessPatchType/tessSpacing` 来自该阶段控制段 +0x744；`attributeTypes[32]` 来自
  `OP_BIND_VATTR` 的 NVN 顶点属性格式；`fragmentOutputTypes[8]` 来自颜色附件 VkFormat；
  `samplerArrayLength/textureArrayLength` 来自 `OP_SET_TEX_POOL/OP_SET_SAMP_POOL` 的真实池容量；
  `transformFeedbackEnabled` 来自 `OP_TF_STATE`；`requestId` = 两个真实 stage key。
- **首笔真实请求已经成功编译（真机 + 桌面逐字节一致）**。2026-10-26 13:41 与 13:44 两次冷启动
  （冻结 APK `ca1f3c81…`，部署回执在 `build/android-deploy/01001B300B9BE000-8bszwlbw/`），
  暗黑3、Adreno 730、显式 direct：
  `draw 快照：key0=18f2aadcec113d49 key1=a566892b88596132 stages=0x3 indexed=1 count=3 first=0 instances=1 rt=1(rt0 fmt=97 1024x1024)`
  → `compile request: 11555 B sha256=e906f01e…`
  → `compile outcome: compile_fn ok 结果=53016B schema=s2a-direct-program-v1 contentHash=sha256-6855e02e…`
  → 结果由 emit 复制进后端自有内存，并 dump 到诊断目录（53016/53016 B）。
  内容：`vs` SPIR-V 13508 B、`fs` SPIR-V 11064 B、supportLayout 2608 B / `sha256-546b6a11…`、
  96 条 dependencies、3 个 bindings、fs 反射 1 个 texture。桌面 CLI 用同一份真实请求（`compile --request`）
  得到 **53016 B、sha256 `e4bfaa20…`，与真机结果逐字节相同**（`cmp` 通过）。
- 之前卡住的 `TRANSLATION_DIAGNOSTIC: Invalid instruction at 0x000008` 根因是代码区框架，不是着色器语义：
  NVN 图形代码区 = 0x30 字节 NVN 前缀 + 0x50 字节 SPH + 指令，而统一编译器/离线路径吃的是从 SPH 开始的
  字节（`dmsh_build` 同一约定）。请求生产者只去掉 0x30 前缀（不改任何指令），同一份请求随即编译成功；
  属性的 `MISSING_FACT` 也不再出现。这条转换与阶段判定（`dsh_stage` 读 +0x30）同一来源，不是新格式。
- 首绘前 `state binds blend=1 color=1 chmask=1 ms=0 poly=1 ds=1 seen=0x37`：D3 首笔画从未绑定
  `NVNmultisampleState`，NVN 也没有定义“未绑定时的值”。本轮采用**前端既有模型**（Metal 回放的状态结构
  同样从零值起步）：未绑定 ms → a2c/dither 关；未绑定 color → alpha test 关闭（Always）；未绑定 blend →
  无双源因子；点大小按前端既有语义“来自着色器”（`programPointSizeEnable=true`；S2A 运行时从支持缓冲读，
  常量不参与生成）；alpha 参考值暂取 0——注意 `nvnCommandBufferSetAlphaRef` 入口**已存在**（hle_nvn.c 目前只记日志），
  本笔尚未记录真实调用，取 0 是前端模型而不是 guest 事实，须在下一轮捕获该调用；本笔未绑 SSBO 才断言 `hasUnalignedStorageBuffer=false`。
  这些是**前端对未定义 guest 状态的处理模型**，已在代码注释与 `compile request 来源缺口` 日志中标明来源，
  待评审；不是把缺失 guest 事实当成已知值。
- 其余仍未接的真实来源（不影响本笔编译，影响后续消费/其它着色器）：`program.stages[].c1`
  （控制段前 0x100 字节，仅 BRX 跳转表需要；本笔编译未读 C1）、`program.textures[]`
  （各 stage 真实 handle + texture/view 描述；本笔 fs 反射出 1 个 texture，但翻译期未查询其类型/格式，
  所以没触发 MISSING_FACT；消费阶段必须补齐）。`pointSize`/`alphaTestReference` 等按上一段的前端模型给出。
- 源快照稳定性：新增 `tests/direct_source_store_test.c`（主机 + ARM64 探针）：SetShaders 后重写源内存，
  快照字节不变；按 key 查与 SetShaders 数组序号无关（VS/FS 分开绑定、数组顺序不同的基础）；
  错误序号不会伪造阶段；字节预算按两份快照计。
- 部署/起局方式（避免 APK 与资源绑定失配）：统一走 `tools/deploy_game.py`。本次 `--refresh-existing`
  部署（同一 contentRoot `sha256-9fca…`）后 App 报 `Game startup accepted`；回执记录冻结 APK
  sha256 `a4a09e5a…`、设备序列号与 direct 模式。**不要再 `adb install -r` 后直接起局**。
- 仍未做：结果消费（把 program 级 `s2a-direct-program-v1` 变成各阶段模块并入 program/pipeline 缓存）、
  纹理/sampler 事实与描述符、管线与真实绘制；C1 捕获（BRX 着色器）。interlock 需求逐支核对 guest 语义与
  enabled profile；本笔成功产物未声明 interlock capability，也无相应 SPIR-V 指令，不能预设首绘必须先做 interlock 等价实现。

<a id="history-common-extract"></a>

## 2026-10-26 公共抽取合流证据

### 4.1.1 公共抽取阶段已并入本分支（2026-10-26，吸收 main 的「抽着色器只做一次」）

- `graphics/tools/direct/extract.sh`：一次抽 Unreal 存档（`pack/ue_pak.py`）+ the reference port `shader_split` + S2Arm
  `nxsh_extract`（含 `aoc/<序号>` 追加内容），产物 `pkg/ split/{shader_map,shader_facts,shader_pairs}.tsv s2x/`
  与 `ok` 时间表；两个抽取器都按 J 开路。
- `pack/stage_extract.sh`：按「游戏输入 + 抽取代码对象号 + Python/解包库版本 + 配置档内容键」出到
  `<产物根>/extract/`，同键跳过；`pack/refresh.sh` 在 romfsidx 之后、通用/直连之前调用它；
  `pack/stage_direct.sh` 的键带上 `.stage_extract`，`graphics/tools/direct/direct_lib.sh` 有 `extract/ok` 就整份
  拷来用、没有就当场跑同一份 `extract.sh`（不再每次出库从头抽两遍）。
- 抽取失败只出通用（刷新报黄、直连库不出），不把半份抽取当直连输入。
- 宿主可移植（本分支在 Linux 上跑回归）：`tools/clonedir.py` 没有 `clonefile` 时退回普通拷贝；
  `pack/roots.sh` 的 `cp -cR`/`mv -fh` 换成 `cp_cr`/`os.replace`；核数用 `nproc`、哈希用 `sha256sum` 兜底。
- 验证：`bash tests/stage_extract_test.sh` 全通（首次/同键跳过/输入变/配置档变/pak/失败回滚/Vulkan 跳过）；
  `python3 graphics/tools/direct/tests/t_merge_extract.py` 20/20。**真实游戏抽取未跑**：本机没有 `romfs/`+`exefs/main`
  原始输入，这一步只能标待验。
- Android 仍缺（下一步）：把抽取结果（code/control、阶段配对、计算着色器线程组、真实绑定事实）转成
  `s2a-direct-compile-v1` 批量请求，以及把产出的 `s2a-direct-program-v1` 装进 Android 资源 revision 的入口；
  本次合并不宣称这两项完成，也不改变「运行时按真实 Draw 状态补编」的验收口径。

<a id="history-deploy"></a>

## 2026-10-26 部署接口与设备证据

### 4.2.1 构建后的统一部署入口：避免 APK 与资源绑定失配

最终 APK 构建、签名完成后，统一调用 [deploy_game.py](../tools/deploy_game.py)。它消费已有 APK，不负责重编 AOT/原生库，也不替代前面的离线着色器生产。不要再只执行 `adb install -r` 后直接起局：APK 任意字节改变都会改变 `artifact.apk.sha256`，旧资源绑定会被正确拒绝。

```sh
# PACK 是 make_pack.py 的完整输出（含 modules/、manifest/index/artifact）。
# APK 是本次最终签名的 per-game APK，SERIAL 显式指定目标设备。
python3 android/tools/deploy_game.py \
    --pack "$PACK" --apk "$APK" --serial "$SERIAL" --mode direct

# 已激活相同资源 contentRoot，只有 APK 重编：走现有安装器的 artifact refresh 事务。
# 只传 manifest/index/artifact 和 control.nacp，不重传 RomFS；模块仍须与源包逐项匹配。
python3 android/tools/deploy_game.py \
    --pack "$PACK" --apk "$APK" --serial "$SERIAL" --mode direct --refresh-existing
```

部署顺序固定：复制并冻结 APK → 校验 APK 模块与源包索引 → 生成绑定冻结 APK 的资源输入 → `adb install -r` → 核对设备已安装 APK 全量 SHA-256 → 推送到本次独立临时目录，完成后移入 import → 正常导入事务 → 确认本次导入后出现本款 `Game startup accepted` → 再核 APK 哈希并写回执。构建可继续改写原输出路径，部署始终使用冻结副本。设备被其他安装替换时明确失败。

- 默认完整部署适用于首次安装及资源变化。`--refresh-existing` 仅用于设备已激活同一 contentRoot；无对应资源时明确拒绝，去掉该选项完整部署，不修改旧 revision 的文件来绕过校验。
- 不卸载、不清应用数据/存档/attempt，不清其他导入目录，不关闭签名、模块和资源校验。传入其他游戏/旧模块 APK 在安装前失败。
- 输出位于本地 `build/android-deploy/<title>-<本次随机目录>/`，包含冻结 `game.apk`、`resources/`、`deploy.log`；只有确认部署成功才生成 `deployment.json`，记录设备、APK 哈希、contentRoot、请求模式和启动接受状态。私有产物不进仓库。
- 默认等待 180 秒，可用 `--timeout` 调整。身份校验及接受启动通过，只证明部署与准入完成；实际选择模式、编译结果、首帧和可操作性仍按 §9 验收。
- 主机回归：`python3 android/tests/deploy_game_test.py`。安装器 Java 回归同时覆盖仅元数据刷新与首次安装拒绝；真机结果另记，不能把模拟 adb 用例当真机证据。
- 实际验证（2026-10-26，Redmi K50 Ultra）：8 项主机回归与 `GameInstallTest` 通过；同资源升级仅传 95,113 B 元数据（索引 639 文件），App 报 `Game build artifact updated (same files)`，随后 `Game startup accepted`。冻结/安装后/接受启动后的 APK SHA-256 一致（`b5ff78e4…`），本地生成部署回执。该证据只验部署身份闭环，不代表直连首帧或可玩性通过。

<a id="history-nvn-evidence"></a>

## 原 §7–8：旧分支功能、性能与合流证据

<a id="android-legacy-evidence"></a>

<details>
<summary>历史归档：§7–8 的旧分支事实、反例、排期和验收证据（不作为本轮任务指令）</summary>

**归档规则（2026-10-29）**：以下原记录中的“当前”“下一步”和 shim 修改落点均限定在各自旧候选；它们不覆盖 §11，也不授权继续扩展伪装层。原始提交、读数、错误与通过范围全部保留。引用本归档时写出候选身份；正式新 PR 只以含 #868 修复的 main 为接收基线。

## 7. 历史事实、C0–C8 验收与偏航纠正

原独立 C0–C7 验收表已并入本节。§7.2、§7.4 保留 10-25/10-26 历史基线，最新进度以 §7.0、§8 当前执行顺序和实际冻结候选为准；不得把旧表的“未接窗口/无游戏帧”当现状，也不能把已接线或某个微例当整项验收通过。

<a id="android-current-progress"></a>

### 7.0 旧分支总体进度（2026-10-28，按已验证候选分项汇总）

**日志/执行审计基线：`8772cf94`；P1 反例版本：`a922d636`；本轮修订至 `82bb6a6a`（`5ac9696f`/`dd084536`/`8880778d`/`bc40b026`/`930e7cee`/`dce71736`/`f6adde9a`/`2b3e7bdb`/`be5bbabe`/`0fa623ae`；真机复验与 attempt 键修复见 §7.0 修复记录）。** 首款 NVN 游戏已进入世界、接受输入；编译事实/身份/worker 和跨局缓存已有交付。当前仍是开发候选，首款完整产品、性能/能耗、多游戏和三前端未整体验收。下表把历史成果、当前缺口与后续验收分开；不按任务编号折算完成百分比。

| 工作组 / 既有编号 | 已有实现与证据 | 还缺什么 |
|---|---|---|
| 完成与画面 / F0–F3、G0 | F0.1–F0.9、F1/F2 选定能力、F3.1/F3.2 有分项记录；查询跨完成点累计已有 `4a24005c` 修复提交 | §6.1 的呈现退休/等待差异；查询发布与读取时序；同候选人物/装备/HUD/转场、格式/view 扩面、MRT、timestamp 等分别验证。旧通过记录不等于当前全量通过 |
| 编译事实与缓存 / F4、F5.1 | F4.1、F4.2A/B、F4.3、F4.4 均有分项交付；`1494f8f4` 有同 APK 次局 46 次磁盘命中/0 次编译记录；`5ac9696f` 修完 F4.2A 多代引用与 F4.3 完整源身份反例，并有生产接缝宿主回归 | 修订后尚未在设备上重跑（密钥/磁盘键已改版，旧条目按设计不命中）；未映射事实、其他阶段/Dispatch、安全热命中分别验。F4.4 仍缺 owner 循环（managed 无 poll 调用者）与 driver 管线转交；有界 Stop 已有代码/宿主用例，长编译真机预算未验 |
| 自动离线生产 / F5.2、F5.3 | 共用抽取、打包、APK/资源绑定与现场补编已有基础 | 自动批编→库/索引/描述符→首装真实消费→故意漏项补编→次局命中；首包不依赖该游戏历史运行缓存 |
| 整局安全网与输入法 / F5.4、F5.5 | selection/attempt、generic、IME broker/preview、正常 Stop 有接点或分项证据；2026-10-28 真机：SIGKILL（am force-stop）后 AUTO 实际走 generic 且 `first_draw=0`（同存档），正常 Stop 清两把 attempt 键后 AUTO 回 direct；preview IME `confirm/cancel/stop` 三例通过（Gboard 中文，不记录文本） | 真实失败/SIGKILL 后下局 AUTO generic 同存档；正常退出不误退；两轨真实 IME；升级、窗口撤销/旋转与停止矩阵 |
| CPU 热路径 / §8.5 | arena、draw 合批/open pass、program/pipeline 对象、事实映射缓存已有；S1 `25527855`、池复用/轮换 `28e70079`/`8831af5f`、整幅 loadOp 清理 `545e55af` 已落地；P1 备忘键在 `5ac9696f` 补齐（顶点属性/附件/SSBO/closure/源代际），反例转绿 | P1 设备上已有真实命中：备忘命中 16%（`命中 4079/24576` 等窗口），`debug.s2a.id_verify=1` 下 `20868 次命中重算、0 次身份不同`；未做同场景 A/B，整帧收益仍不下结论。源内容代际在“同内容重登记”时不推进（避免每帧 SetShaders 作废备忘），实际命中分布按上述窗口观察。D1 批量分配余项、D2 描述符 memo/动态 UBO、D3 上传内容复用按实际热点选取；未承诺现有 FPS 数字的收益 |
| 流水与首遇 / §6、§8.5.11 | 图形线程和命令拍平有实验，默认模式仍为 0；有进程内 `VkPipelineCache`；`5ac9696f`/`dd084536` 给需求编译 worker 补了有界 Stop 与 owner 控制片（poll 返回在途 PENDING），guest fence 改为按提交追踪完成 | Present/Acquire/完成与资源退休配套、有界在途批次及 Stop；managed owner 循环实际调用 poll、挂起/恢复执行包；driver pipeline 转交 worker；完整管线身份/碰撞核验、driver cache 落盘与配方预热。线程实验未测出收益，不等于完整流水已经验证无用 |
| 首款产品验收 / §9.1 | 暗黑3标题/过场/菜单/世界与输入有证据 | 冻结同候选，完成战斗/转场/存档重进、视频/声音、冷暖局、真实显示帧时与能耗验收；截图观察与诊断窗口不代替全路线 |
| 通用扩展 / §9 | 首款 NVN 样本走同一链 | 第二款不同引擎、Switch Vulkan、OpenGL、更多 GPU/页大小分别交付，不按标题补规则 |

**本轮方案审核（源码至 `edd436f8`，不追加真机通过结论）**：下面四条是 `5ac9696f` 之前的缺口原文，保留以便对照修复范围；修复状态见紧随其后的“修复记录”。

- F4.3 的“完整规范输入”尚未满足 §5.3：仅变源 code、强制同短 stage key 时，生产请求不同而规范编码仍相同；普通路径和磁盘身份也受影响，不能只关 P1 就认定完整身份已正确。完整源摘要应在捕获时计算并随快照复用，修订内存/磁盘身份及版本，避免逐 draw 重哈希。见[源身份反例](../../docs/坑记录.md#android-source-identity-review)。
- F4.2A 的 pin 不是全部完成：同 key/同内容重登记后，`release(key)` 找最新条目而非被 acquire 的旧代；配对 release 后 clear 仍保留 2432 B，控制例为 0 B。需明确快照引用/代际及所有消费者，再开展依赖它的快命中。见[引用反例](../../docs/坑记录.md#android-source-pin-review)。
- F4.4 的已交付范围是 CPU 需求编译、执行包独占与部分 Stop 用例。当前 `provider.poll` 空实现、`compile_worker_stop` 无 deadline 的 join，driver pipeline 仍在 draw 线程创建，与实施契约 §4.3 的完整调度有差距；正常 0.36 s Stop 不证明长编译/卡住时仍满足收尾预算。补 owner 控制轮询、管线转交与超时保活/失败协议，各自验收。
- `edd436f8` 已提交调试开关快照、纹理事实缓存、C1 复用及重编统计修正；保留其源码成果，不从提交标题的“17→20 fps”直接新增性能验收。上述两个反例相关生产文件未随该提交改变，原候选通过范围继续保留。

**修复记录（2026-10-28，`5ac9696f`/`dd084536`/`8880778d`；只记代码与宿主回归，不新增设备/画面结论）**

- F4.3 完整源身份：`source_store` 在捕获时算一次完整 SHA-256(control‖code)（与前端短 key 同一摘要）、随快照保存；`keep` 只接受“短 key = 摘要前 8 字节”的输入，同 key 不同内容不覆盖、不取最新，该 key 被标成歧义并推进内容代际，按它的查找一律失败。`input_identity` 升到 S2AI1 v3，编码各阶段完整摘要与真实 code/control 长度；缺任一阶段完整源证明即编码失败（不退回短 key）。`program_cache` 版本 1→2，旧条目不认。编译前再用被 pin 的同一份快照核对摘要/长度，请求只从这份字节生成。见[源身份反例](../../docs/坑记录.md#android-source-identity-review)的修复段。
- F4.2A 引用代际：`acquire` 返回令牌，`release(token)` 只释放被 acquire 的那一代；同 key 重登记得到新令牌。`direct_source_store_test` 的反例（A → acquire → 同 key 同内容再登记 → release 旧令牌 → clear）现在 0 B，控制例仍 0 B。见[引用反例](../../docs/坑记录.md#android-source-pin-review)。
- P1 备忘：键补齐 `vattr_fmt[32]`、颜色附件槽（key/format/nvn_format/obj_magic）、SSBO 是否绑定、closure 哈希、shaderDrawParameters 与源内容代际；`a922d636` 的顶点类型反例（0x1→0x3）现在身份与备忘键都不同。为避免每帧重复 SetShaders 把备忘刷掉，源代际只在“key→内容的可证明性变化”时推进（新 key、淘汰、分配失败、冲突/拒绝；同内容且同长度的重登记不推进）。Draw 快照→事实/身份/备忘键抽到 `nvn_vk_compile_facts.c`，`direct_nvn_compile_facts_test` 原样链接生产实现做逐事实反例。
- F4.4 收尾：`compile_worker` 增加有界 Stop（预算内未退出就如实报错、迟到结果丢弃、未退出前拒绝重启、下一次 Stop 回收）与 `pump` 控制片（最多 10 ms，返回是否仍有在途需求）；`provider.poll` 不再空实现，按契约返回 OK/PENDING/STOPPED，不再假装“无事可做”；adapter Stop 改用 1 s 预算。**仍未交付**：managed owner 循环实际调用 poll 并挂起/恢复执行包、driver pipeline 由 worker 创建后转交 owner，以及长编译/卡住时的真机收尾预算。
- §6.1 完成语义（`dd084536`）：`mtl_wait` 不再只 drain 后返回成功，改为消费帧队列的真实完成证明（提交成功且 fence 已 signal）。新增带预算入口 `nvn_vk_first_draw_flush_ready(budget)`：`budget=0` 是纯轮询（不关 pass、不提交，只对已提交 fence 做 `vkGetFenceStatus`；有未提交前缀就算未完成），`>0` 最多等这么久（必要时关 pass、提交前缀）；返回 1 表示“已提交但未完成”，不是失败，资源/fence/命令全部保留，下一次继续等；内部分配用的完成点仍是 5 s 上限且超时为终态。为了不在旧 fence 仍 in-flight 时 `vkResetFences`（Vulkan 禁止），再次提交前把旧 fence 降级进早批次表、本次用新 fence；批次表满时准确失败并保留。**未在真机重跑 F0/G0 用例**，F0.2 原通过范围不外推到这条新路径。
- 观测校正（`dd084536`）：`frame timing(近N帧)` 现在给真实 `p50/p95/max` 与样本数 `n`（近 16 帧窗口的 nearest-rank），不再把窗口最大值写成“p90峰值”；`depth-only` 每笔明细只在 `debug.s2a.draw_log` 打开时打印，默认由 present 窗口打印一行 `draw window: draws=… depthOnly=…`，它与 pass 关闭计数分开。日志量/降噪收益本轮未测。
- 拍平失败语义（`8880778d`）：命令链拍平失败（畸形记录/OOM）原来只打红日志，`mtl_sub_commit` 仍然 `++g_fence` 返回，guest 可能等一个从未提交的提交。现在失败提交不交给翻译线程、登记 `g_lost_from_fence`：`mtl_wait` 对它返回“无完成证明”、`mtl_present` 拒绝上屏残缺内容、`mtl_finish` 准确报未完成；新会话 `mtl_init` 清标记。**未在设备上注入 OOM/畸形链验证**。
- P3 派发成本口径（`8880778d`，2026-10-28 真机复核修正）：`s2a_record_exec_one` 的“打包”曾把终点放到 replay 之后，读数实际含整笔 draw builder（39–114 us/笔）；拆开后真机为 `打包(malloc+copy) 0.09 + free 0.09 us/笔，replay 36.5 us/笔`，打包不是热点，CPU 在 replay/builder（`draw timing avg=33us：pass 8、res 9、desc 4…`）。旧“打包 72–114us”不能再用；新增 adapter 窗口统计 `adapter exec: lockWait=… us/笔 (n=…) 本窗合计 … ms`（等 g_mu / 等执行包让出，读取即清零）。这些是观测补齐，**不是新的性能结论**；真实派发成本和是否批次化仍要按新读数决定。
- P4 缺事实诊断（`8880778d`）：纹理格式/目标未映射的日志现在带原始事实（`nvn_fmt/target/layers/levels/samples/reggen`），能和 `reg_tex/tex_release` 的代际对账；仍不推断“只有几种格式”，也不补默认映射。
- 独立复核后的收口（2026-10-28，Codex 复核 6 项，均在提交前修）：①带预算的 flush 返回“未完成”后 `ncmd==submitted_n`、`nbatch_fence==0` 但 `g_fq.fence` 仍在途，`pass_break(sync)`/`finish` 的“有无在途”判断漏掉它 → 新增 `fd_fq_has_inflight()`（含后缀 fence），完成证明边界统一用它；②`mtl_wait(fence)` 原来 flush 整个队列并忽略具体 fence，已完成的 A 会被后提交的 B 拖成超时 → 记录已证明的提交上界 `g_completed_fence`，`fence <= 上界` 直接成功，flush 成功后只把调用方的 fence 记为已证明（多线程下不拿 `g_fence` 反推）；③轮询/有限超时原来会先无界 drain 再阻塞取 `g_mu` → 新增有界 `shim_drain_budget` 与 adapter 的带预算取锁（`trylock`/`timedlock`+回退），预算覆盖整个调用；④`source_store.keep` 的“同内容”只比拼接摘要、不比长度，同摘要不同 control/code 切分会替换快照却不推进代际（完整身份不同、P1 仍命中）→ 同内容必须连真实长度一起相等，否则按冲突拒绝并 poison；⑤淘汰不推进内容代际，P1 可绕过“源已淘汰 ⇒ 完整路径缺源” → 淘汰/分配失败都推进代际；⑥提交包装对象 malloc 失败仍返回可等待的 fence（基线已有）→ 统一走“未完整入队”出口，不发布完成。回归新增：同拼接不同切分被拒、淘汰推进代际且旧 key 不再可解析。
- §8.5.11 管线身份（`f6adde9a` 后）：`fd_pipe_key` 的 64 位 hash 不再单独命中。新增 `nvn_vk_pipe_recipe`：覆盖构建管线真正读取的输入（程序内容 SHA-256、request_id、VkDevice、布局策略版本、已绑定状态对象原文、32 槽顶点属性/16 路流、prim、颜色/深度格式、has_depth、depth_only、rt_count），命中 = hash 相等 **且** 整份配方逐字节相等；槽位保存配方，`release_device` 清空。宿主回归 `direct_nvn_pipe_recipe_test` 逐项断言输入变化同时改 hash 与配方，并直接把同一 hash 喂给两个不同配方、要求 `nvk_pipe_recipe_hit` 拒绝（碰撞反例）。未在设备上量命中率，也未复跑画面；布局策略/驱动缓存/退休仍各自验收。
- 第二轮复核（同日，`930e7cee` 之后）：①零预算探测只看 `g_fq`、漏掉“已录进 open pass 但未关闭”的命令，会把尚未提交的绘制判成完成 → 探测把 `g_op.open` 算作在途；同时把 `mtl_wait(timeout=0)` 改成不调用 flush 的纯查表（无副作用）；②`g_gfx_tid_valid` 原来由 worker 自己置位，存在“作业已入队、worker 还没被调度”时 drain 跳过并错误推进完成上界的窗口 → 改由创建方在 `pthread_create` 成功后立即置位；③完成上界改为按提交追踪：fence 在入队前分配，`job_flat` 回放完成时推进 `g_replayed_fence`；一次成功 flush 只证明“已回放”范围，`g_completed_fence` 只按调用方传入的 fence 推进，`mtl_present`/`mtl_finish` 成功也推进已回放上界（轮询本身不再提交、不关 pass）；④`build_c1` 分配失败原来返回 NULL 并继续登记，会把同 key 条目的有效 C1 换成缺失（请求输入已变）却不推进代际 → 改为拒绝这次登记；⑤poison 环溢出后，同内容重登记会清掉 `ambiguous` 且不推进代际 → `ambiguous` 也按冲突拒绝，poison 表 256→1024，并新增“歧义 key 不能靠重登记原始内容复活”的回归。
- 真机复验（2026-10-28，Redmi 22081212C/Android 16/Adreno 730，无线 adb；`2b3e7bdb` 之后的 native 重新出包 + 资源 revision 元数据刷新部署）：①C1 ARM64 探针全绿（新增 `sources/facts/recipe/identity/progcache/worker` 与 `profile-mismatch`）；②direct 实机：`源快照：拒绝 0、身份不可用 0`，`program cache 跨局 disk_hits=46 disk_stores=0`（旧版本磁盘条目不命中、新键次局命中），`pipes hit/miss` 正常，`adapter exec lockWait=0.1 us/笔`，新 `frame timing` 输出真实 p50/p95/max，世界场景 `fps=58.9`（p50 17.9 ms）；③`debug.s2a.id_verify=1` 下 P1 自检 `20868 次命中重算，0 次身份不同`；④attempt 矩阵：正常收尾清两把键（离线别名 + live）→ AUTO 直接 direct；`am force-stop` 后预检 `->1` → AUTO generic 且不创建设备；⑤BACK/`surfaceDestroyed` 的 `_exit(134)` 在旧/新 APK 上都复现，是既有收尾问题（窗口撤销矩阵另记，不算本轮引入）；⑥窗口销毁：direct 会话 BACK 时 `Surface generation 1 detached in 20–26 ms`（修前必等满 1 s 后 `_exit(134)`），present 跳过而不 abort、进程 `_exit(0)`；HOME 后台仍在 ~0.4 s 后于 commit 路径 `_exit(134)`，同会话恢复未通过（另行跟进）。⑦同存档同热状态对照（先后各一局，60 fps 上限）：generic `帧间隔 600 帧 avg 16.67 ms、p50 16.64、p95 17.91、p99 18.98、max 22.88`；direct `近16帧 p50 15.0–16.7、p95 25.4–27.0、max 26.4–27.0、fps 59.6–60.7`（both capped 60；direct 尾部更高，场景较轻、未做重载/长路线对照，不作收益结论）⑧**真实游戏内（TouchPad A→继续→进入世界，第一幕·眺望之路，commands≈3500–3800/窗口）**：direct `p50≈51–57 ms、p95≈57–67、max≈79、fps≈17–19`（清屏修复后复测 `p50≈51.0、p95≈57.0、fps≈19.6`，`draw timing avg≈21–28us`、pass 3，无回归；驱动缓存每局 loaded 1,257,119 B）、`exec≈24–28 ms`、`present≈17–19 ms`；标题/动画/菜单页 `commands≈94–199` 时 58–60 fps，不能把那里的读数当游戏内性能。generic 在同一存档进入世界后画面正常（早先记成“generic 紫/绿”的那一局实际是直连会话，已作废）；generic 游戏内帧率未在同窗口取样，暂无可比读数（`present` 等 GPU 完成 27-34 ms，`commands=1045..1860`）；没有做同场景旧/新包 A/B，旧包首局还要按 v1 键重编、且日志级别不同，这些数字只作观测不作收益/回归结论。设备复验只看行为与计数，不是性能验收。
- 驱动管线缓存（`93fe941d` + 本提交）：新增 `nvn_vk_driver_cache`。文件名带 `pipelineCacheUUID` 与格式版本，头含 magic/version/size/SHA-256，先写临时文件 fsync 再 rename；损坏/短读/超限/版本不符一律拒绝并按空缓存启动；驱动拒绝 initialData 时按规范重试空缓存。`nvn_vk_first_draw` 在创建 pipeline cache 时读 `<S2A_DIRECT_CACHE_DIR>/<uuid>-v1.bin`，`release_device` 在设备销毁前 `vkGetPipelineCacheData` 写回。真机（Redmi 22081212C/Android 16）：正常收局 `stored 1257119 bytes for UUID 39e31f0c…`，下一局 `loaded 1257119 bytes` 同 UUID；宿主/ARM64 新增 `driver cache test`（round-trip/UUID 隔离/损坏拒绝/原子覆盖）通过。未量驱动缓存对首帧/管线编译时间的收益。
- 回归：宿主 CTest `android_direct_source_store`、`android_direct_input_identity`、`android_direct_nvn_compile_facts`、`android_direct_compile_worker` 全过（GCC 16.2.1，Linux x86_64）；ARM64 探针新增 `facts`（`direct_c1_probe.sh`），本机只有 x86_64 模拟器，未执行 ARM64/真机。未安装 APK、未跑游戏，因此不改写任何设备通过结论。
- 新增诊断与证据（2026-10-28 11:20，源码未提交前复核）：`nvn_vk_first_draw` 增加 `debug.s2a.pass_probe=1`（每个 render pass 收尾读回颜色目标 5 点，flush 逐 pass 打印，默认关），并在 `vk_record` 的整图 T2T/T2B 拷贝上保留最多 64 条尺寸/格式面包屑。真机复现（Redmi 22081212C/Android 16，`11:07` 局，`debug.s2a.pass_probe=1`）：进世界第一帧场景 pass 输出正常 `(77,69,54)`，场景后的合成 pass 输出 `(61,0,64)`/`(69,0,72)`（G=0），约 110 帧内衰减；对照 10:38 的干净局同样窗口场景中心正常、无 G=0 pass。结论只写到“偏色由场景后的合成 pass 引入，不是场景着色/纹理/清屏”，未确认具体 shader；`req=disk-cache` 表明世界程序都走磁盘采纳，下一轮需在探针里带程序内容前缀/真实采样视图。载入页 `!!Missing!! - 52004:HPBar` 经二进制/包内容核对是游戏的 `H2OLayout` StringList 本地化字符串缺失兜底（group 42），不是缺贴图或 GPU 能力换资产；未做 generic 同屏对照。同一批日志还证明产品默认 deferred query 写回在真机工作（`samples-passed` resets/reports 持续增长、fails=0、无写回失败）。详见[坑记录](../../docs/坑记录.md#android-direct-world-tint)。F5.2/F5.3 复核：只读离线库没有运行时消费者（安装 revision 的 `shaders/vulkan/direct` 仅在不可达分支被读；`graphics.v1.json` 的 `files[]` 无人消费），且设备磁盘键是 S2AI1 v3 完整身份，主机无法仅凭 request 复算；下一步必须先在“导出设备身份”和“条目自带 request”两条路线中选一条并写进合同，不能只加开关。本轮未改这两条路线的实现。

- 新增根因与修复（2026-10-28 13:30，源码未提交前复核）：进世界紫/绿的合成 draw 把自己的 1600x900 颜色目标同时当采样纹理（NVN 反馈采样；`trace: tex id=270 feedback=1 serial=15`），Vulkan 下同一 image 既当附件又当采样源是未定义；Adreno 730 在首帧读到清屏后的纯色 `(74,83,111,0)` 与全零 400x225 RGBA16F bloom，fade 着色器因此输出 `(61,0,64)` 一类 G=0 颜色，之后帧未定义读恰好读到上一帧世界，故只闪约 110 帧。清屏颜色日志（`debug.s2a.clear_log=1`）证明 alpha=0 是游戏自己传的，不是后端丢的；BC1/UI 纹理与 HPBar 均已排除。修复：`nvn_vk_first_draw.c` 在开 pass 前检测“采样 image == 当前颜色 RT”，命中时先收尾复用 pass，再在 `vkCmdBeginRenderPass` 之前把附件拷进帧队列持有的单级单层快照并把绑定换成快照 view（`fd_feedback_tex`/`fd_feedback_snapshot`），快照等完成证明后释放；`debug.s2a.no_feedback_fix=1` 回退做 A/B。真机（Redmi 22081212C/Adreno 730，direct，D3）：世界/角色/HUD 正常，40 s 录屏 917 帧洋红比例 0.0（修复前同口径最高 0.616、113–140 帧热），fps 18.1–19.0 与修复前同量级；宿主 `ctest -R direct_` 15/15。边界：紫/绿间歇复现，修复后这轮未复现，关修复的 A/B 也未卡进录屏窗口，因此因果证据是 feedback=1 + 首帧纯色/全零输入 + 洋红 pass 三点；修复对所有检测到的反馈采样生效（约 80 s 内 3418 次），每次整幅拷贝，其他游戏/view 覆盖/长时性能未验；格式或 view 覆盖与快照不一致时明确失败。

- F5.2 生产端真实捕获验证（2026-10-28 13:20）：用 `debug.s2a.dump_fail=<外部目录>` + `debug.s2a.no_disk_cache=1` 在真机强制重编，`nvn_vk_draw.c` 的 dump 改成 `<ident>-<64hex input_sha>.{compile-request,program}.json` 后抓到 100 对 request/result；`tools/direct_library.py build` 生成 100 个 `.program`（7.78 MB）与 `graphics.v1.json`，`verify --lib` 通过；把其中一个条目截断 8 B 后 verify 报 `204707 bytes on disk, descriptor says 204715`。宿主回归：`direct_library_test`、`direct_pack` 6/6、`deploy_game`、`ctest -R '^android_direct'` 15/15。**F5.3 仍未完成**：运行时消费模块（`runtime/direct/offline_library.c`，宿主假目录用例覆盖命中/缺失/改名/截断/链接/只读 revision）已实现但未接进 `nvn_vk_draw.c`/provider，也没装进 revision；真机首装 `offline_hit`、故意漏项补编、次局命中都还没有读数。库变化必须走新 index/artifact/revision，不能 `--refresh-existing`。2026-10-28 14:2x 起 F5.3 消费端已接进 `nvn_vk_draw.c`：私有缓存 miss 后按“完整身份 + 本局 profile + revision 根”查只读库，命中按 `offline-lib` 采纳、拒绝带原因回落编译，`offline_hit/miss/reject` 进入跨局统计；`no_disk_cache=1` 只跳过私有缓存，要连离线库一起跳过用 `debug.s2a.no_offline=1`。真机（未提交候选 5195dea4）：强制 miss 的一局 `offline_hits=0 offline_misses=212 offline_rejects=0`，212 次回落到编译、进程存活——证明消费路径真的被走到；库本身还没装进 revision，所以命中/漏项补编/次局命中仍无设备读数。2026-10-28 14:5x 用诊断根 `debug.s2a.offline_root=<外部目录>`（把捕获生成的 100 条库推到 app 外部目录，不产生新 revision）补齐：首局强制跳过私有缓存 `offline_hits=9 offline_misses=7 offline_rejects=0`（9 条真实消费库、7 条按“漏项”回落编译）；次局不跳私有缓存 `disk_hits=77 offline_hits=0`（私有缓存优先，全部命中），两局 0 reject、进程存活。产品路径仍是 revision 内只读库，装库验证要等新 index/artifact。**2026-10-28 15:0x 尝试装库时发现部署侧阻塞**：用与已装 revision romfs 哈希一致的源重建 `make_pack --direct-graphics` 成功（165 文件/22.8 GB，102 条 `shaders/` 行）；描述里的 `gameContentRoot` 必须用**新包 index** 重跑 `direct_library.py build`（两遍流程），不能沿用旧 stub 推导值。源目录差异：`/var/tmp/s2a-game` 没有已装包里的 599 条 `systemdata/`（`010000000000080E`），`/var/tmp/s2a-d3` 有 600 条且 `binaryList.txt` 哈希与旧包一致、romfs 也一致，但多 17 条 `aoc/`。整包推新 revision 会替换 game 的 systemdata/aoc，是否触碰玩家存档取决于导入语义，**未确认前不部署**；已建产物已删，设备未动。下一轮装库前先确认“新 revision 导入是否保留存档”和 aoc/多出的 1 条 systemdata 的取舍，再用两遍流程出包。

- 装库实测（2026-10-28 15:37–16:20）：两遍流程出包（基础包 663 文件 → 用其 index 生成 descriptor → 含库的 765 文件/22.8 GB 包），`verify --pack` 通过；`deploy_game --push-timeout 5400` 整包推入后 **新 revision 导入成功**（`accepted startup`，758 文件资源包），存档目录 `files/user/0/saves/01001B300B9BE000` 仍在（存档不在 revision 内）。随后 APK-only `--refresh-existing`（旧 stub 包）把活动 revision 切回旧的 `sha256-9fca…`（无库），运行日志 `offline library: miss root=…/revisions/sha256-9fca…` 确认。新 revision 激活期间 `no_disk_cache=1` 一局统计为 `offline_hits=0 offline_misses=35 offline_rejects=40`——运行时**找到了 revision 里的条目但校验拒绝**（当时 reject 日志受 draw_log 门控，未留原因）。把同一份 `libout3` 库推到外部诊断根后：**`offline_hits=40 offline_misses=35 offline_rejects=0`**，证明消费端与库字节都正确；revision 内副本的拒绝原因待查（下一轮先带无条件 reject 日志重新激活该 revision，或对比导入前后文件 SHA-256）。APK 已加前 4 条 reject 无条件日志（`offline library: rejected entry identity=… root=… (原因)`）。**16:32 复现拿到原因**：reject 全部是“离线库条目是符号链接（只读库不接受链接）”——App 的导入器把 revision 资源存成指向内容库的符号链接，而 `offline_library.c` 对条目用 `O_NOFOLLOW`。修法：目录组件仍逐级 `O_NOFOLLOW`，只有条目本身允许链接；链接目标按 `realpath` 打开后仍走容器身份/长度/摘要校验，指向别的程序或非法文件会按内容拒绝。真机产品路径随即通过：新 revision（`sha256-c088…`）上 `no_disk_cache=1` 一局 **`offline_hits=9 offline_misses=7 offline_rejects=0`**；不跳私有缓存的次局 `offline=0/0/0`（私有缓存优先）。同步补了“链接指向 revision 内/外但容器有效=命中、链接到非容器=按内容拒绝”的单元测试。

- §6.1 真机矩阵补测（2026-10-28 14:49，集成候选 b7bcd67b，Redmi 22081212C/Adreno 730，direct）：世界内连续两次 HOME→恢复——首次 `generation 1 detached in 8 ms`（在途 surfaceDestroyed，无 abort）、恢复 `gen=2 2712x1220`、再次 HOME/恢复 `gen=3 2712x1220`，同一 pid 11173，无 EBUSY/失败；恢复后 fps 19.7–21.9。产品默认 deferred query 同段继续工作：`samples-passed: window resets=15045 reports=15040 zero=38 before_reset=0`（无写回失败）。空转后 BACK 退出：`present lifecycle submitted=585 retired=585 pending=0 retained=0`、`stop_game reason=activity destroyed`、`frame queue finish rc=0`、`session closed stop=0 destroy=0`，进程退到桌面。13:37 首次恢复日志里的 `window attached gen=3, 0x0` 本轮未复现（后续 attach 都带 2712x1220），仍记作待查的首次 attach 尺寸日志。

- B4/B9 与清理状态（2026-10-28 14:57，提交 `74865660c`）：request_stop 的锁内只发布 revoking/stopping_engine，adapter shutdown 移到锁外；release_window 在 stopping_engine 时不并发 detach/ACK，on_window_offered 在 Stop 收尾期间不接新 surface；adapter shutdown 只在 frame queue finish rc==0 时释放 first_draw 设备缓存。真机 cc192dbf 复验：HOME detach 1 ms、恢复 attach gen2 2712x1220、BACK release gen2 detach 45 ms、frame queue finish rc=0、session closed stop=0 destroy=0。B7 现在 swapchain pending+retained 共用一个 500 ms 预算，adapter detach 等锁 400 ms，落在 window revoke 的 1 s 内（≈900 ms）；present 直接路径 acquire 100 ms 有界。清理：direct 候选的 APK 不含 `xbg_*`/d2r 引擎符号（nvn_vk 分支只链共享前端+自有后端），旧引擎只在显式 engine 分支链接；`S2ARM_ANDROID_VK_ENGINE` 选项名仍是旧名（改名是纯机械改动，未做以免打断已验证构建）。失败/竞态路径（release 与 Stop 真正重叠、长编译 Stop 超预算）仍未真机注入。2026-10-28 17:03 加 `debug.s2a.stop_delay_ms`（shutdown 入口睡 N ms，≤10 s）做注入：世界内 BACK→1.5 s 后 HOME，日志顺序是 `releasing window generation 1`/`detached 5 ms` → `stop_game` → `adapter shutdown: injecting 3000 ms`，窗口 release 仍在 shutdown 之前完成，`stopping_engine` 并行门未被触发；3 s 延迟内进程被系统结束，收尾日志未再出现（无 FATAL）。也就是说 activity-destroy 路径天然先拆 surface 再停引擎，B4 的并行门目前只是防御性保护；要真正走到它需要“Stop 不由 activity destroy 触发”的另一条入口，未找到可注入点。

- 呈现/窗口生命周期现状（2026-10-28 13:37–13:41，Redmi 22081212C/Adreno 730，未提交 B 线候选）：进世界后 HOME→恢复→再进世界，`present lifecycle submitted/draw_completed/presentation_retired` 全相等（25354/25354/25354，pending=0 retained=0 acquire_timeout=0），`releasing window generation 2` 后 `Surface generation 2 detached in 3 ms`，恢复 `window attached gen=3`（日志里尺寸是 `0x0`，待查）、同 pid、世界/HUD 继续出帧；游戏内 BACK 退出触发 `stop_game reason=activity destroyed`，`adapter shutdown frame queue finish rc=0`、`session destroy settlement record=0`、`direct session closed: stop=0 destroy=0`，进程退出到桌面。独立审查（F 线）同时给出 **6 个阻塞项**：Stop 失败后 detach 仍返回成功、session destroy 在 swapchain 失败后仍销毁子资源、`mtl_present` 检查窗口与真正 present 之间有竞态、Stop 持窗口锁做长收尾、destroy 丢掉 request_stop 的 Retirement 失败、Stop 非持久终态可被迟到 present 重新 init；另有 present 退休总预算 >1 s、`clear_present/draw_present` 仍用无界 acquire、adapter probe 缺 `nvn_vk_exec_owner.c`。这些失败/竞态路径**未修、未真机验**，不能按“呈现/生命周期已正确”验收；正常 HOME/恢复/Stop 路径已有上述读数。

- 集成状态（2026-10-28 14:2x，提交 `0d65e7563`）：B 线的 B2（session destroy 在 swapchain 失败时立即返回并保留子对象）、B3（present 期间窗口撤销按跳过收尾）、B7（pending/retained 共用一个退休预算）、B8（probe 的 clear/draw present 改用有界 acquire）；B1（Stop 失败后 detach 返回 -1，不 ACK 租约）、B6（adapter 持久 stopped 态，迟到 present/require 不能重开，只有 provider activate 的 new_session 清除）、B5（destroy 继承 Stop 的 Retirement 失败并保留 ctx/device，D 线已改）已落地。**仍未修**：B4（request_stop 持 g_window_mu 做整个 shutdown，UI release 最多被拖过 1 s；改它需要把 detach 决策与长收尾拆开，当前保留）、B9（session destroy 失败时 first_draw_release_device 早于 destroy）、present 总预算仍可能 >1 s。宿主 37 项 CTest 里 36 项过（唯一失败是本机 binutils 2.47 的 AOT 链接断言），direct_ 15 + nvn_vk_lifecycle/swapchain_host/exec_owner/pipe_worker/offline 全过；managed `direct-abi-tests` 65 checks。

#### 7.0.1 本轮日志审计：按进程和窗口限定结论

日志/执行审计基线为 `8772cf94`，P1 反例版本为 `a922d636`；用户提供 `/tmp/s2a-watch/live.log` 持续抓取文件。本轮未安装/重启/注入输入，未复核日志对应 APK/ELF 与该源码的逐字节身份；另对 P1 版本做了隔离 CPU 反例（见 §8.5.10），不计为 GPU/游戏验收。用户报告设备为 Redmi K50 Ultra，日志 caps 为 Adreno 730；截图“正常”属用户观察，不是本轮新增画面对拍。完整结论还需冻结包/profile/设置、标注场景与温度/充电状态。

- **实际线程模式**：排除其他 PID 与 `prev|` 后，PID 27125 于 22:36:14.240/241 明确输出 `gfx_async=2` 与 `translation thread started (mode=2)`。`shim_async_mode` 首读后缓存；设备属性随后设 0 不会改变此进程，不能把本局当模式 0 的对照。模式切换验收必须重启并核新 PID 的启动回执。
- **固定观察窗**：2026-10-27 22:49:45.000 ≤ t < 22:50:45.000（UTC+8），仅 PID 27125。局部快照 `/tmp/s2a-watch/pid27125-224945-225045.log` 为 2,232,470 字节/13,026 行，SHA-256 `cf43890ba08591d321e8e0353274aee501f659b9147ce2457cb98d3890748133`。临时路径不作为长期门禁凭据，正式验收按 §9.1 留存去敏回执。

| 观察项 | 原始输出及口径 |
|---|---|
| 帧账 | 64 条“近 16 帧”日志，各列中位数：gap 58.45 ms、exec 31.95 ms、present 13.15 ms、other 13.20 ms、commands 3625；日志返回节拍中位 17.1 次/秒。不是原始逐帧分位数或屏幕显示 FPS |
| present 拆分 | 32 条“近 32 次”日志，各列中位数：flush 等待 11.612 ms、acquire 0.114 ms、录 blit+提交 0.481 ms、present+提交 fence 等待 0.859 ms。不能把 flush 等待当完整 GPU 时间，也不能将不同窗口的中位数相加 |
| draw / 查找 | 1970 条“近 256 笔”日志，avg 列中位 31 us、res 4 us、pass 6 us、desc 5 us；985 条查找日志的整局累计 avg 列中位 12 us（纹理事实 5、编码 3、扫描 0、其余 3，整数截断）。这些窗口不同，不能相减得到 P3 的 10 us 或固定套用旧 res 41–71 us |
| 缓存 | 窗末 lookups 6,064,128、hits 6,063,941、misses 187、evicts 59；disk_hits 187、stores/failures 0。PID 内未见 compile request/worker compile ok；支持本局未现场编译，不证明完整离线生产已交付。program evicts 与 pipeline evict 是不同计数 |
| 日志与缺事实 | 窗内 depth-only 6149 行；未见红标/失败关键词。PID 内未映射提示包含 id 318、2380、344，日志缺原始 format/target/view；并非已确认“只有两种格式”或“各一次”。不能据此编造映射值或宣称实际必需事实被忽略 |

**23:17–23:18 追加核对（PID 31117，仍未冻结 APK/ELF 身份）**：同一日志按 2026-10-27 23:17:00.000 ≤ t < 23:18:00.000（UTC+8）过滤，64 条 16 帧窗口的列均值为 gap 58.856 ms、exec 31.606 ms、present 15.886 ms、other 11.367 ms、commands 3650.688；原始逐帧与显示帧率仍未测。19,191 行中 depth-only 8114、draw timing 2023；窗末 disk_hits=218、stores/failures/identical_recompiles=0，PID 未见现场编译日志。查找累计 avg 在窗末为 7 us，备忘累计 520316/1159680（44.87%），不与上一 PID 作收益 A/B。新增落点日志为复制打包约 0.07 us、回放入口到 builder 约 1.22 us；源码计时从 malloc 之后开始，未含 free、adapter 锁等待及函数收尾，不能据此判定全部派发成本已小，也不能继续沿用旧 P3 约 10 us 的残差估算。此 PID 未检索到 gfx_async 启用回执，模式仍待明确的启动记录；设备 simpleperf 事件权限被拒是用户报告的实际限制，不因 manifest 可配置就宣布设备能采样。局部快照 `/tmp/s2a-watch/pid31117-231700-231800.log` 为 3,064,291 B，SHA-256 `85c609086d4ba87b6ddaea8bc8b2eca0bcbab86b409d6931ceba01482b85cba6`；该窗口只更新观测，不新增性能或 P1 正确性通过结论。

**解释边界**：`exec` 是回放区间墙钟，不是该线程 CPU 运行时间；`other=gap-exec-present` 是残差，在异步下可能含 drain、拍平/排队、调度及日志，不能直接叫“游戏自身 CPU”。源码 `g_win_gap_max` 打印成“p90峰值”，实际是窗口最大值。现有数据支持优先调查 CPU 路径，不支持“CPU 是 GPU 的 3.4 倍”“降低 GPU 成本无用”或“P1 必达 19 FPS”。§8.5.9 列出本轮唯一下一交付顺序。

本表依据下面各候选及 §8.0 的分项证据整理；不同候选的通过范围不能拼成“同一候选已完整通过”。阶段不等权，不能按 F 编号或章节数换算完成百分比；未提交草稿、未执行回归均不计通过。

<details>
<summary>展开候选证据与旧总表：14:45 基线、17:0x F3、18:0x–18:5x F4；保留各自身份与当时限制</summary>

#### 7.0 当前总体进度（2026-10-27 14:45，代码与证据分层）

以下“下一步/未完成”按该候选的时间阅读；当前汇总以上面的展开表为准，详细合同和通过范围在 §8.0。

**身份与限制**：复核时分支 `android/direct-mode-d2r`，本地 HEAD 含 G0、F1/F2 与 present 颜色修复提交；主线对照固定 `main@6590ba40`，尚未合入当前 Android 分支。15:1x 设备（192.168.31.198:5555，无线 adb）实装 APK `b3acc088f167b93ebc514a7eba90869270d519ae8fde90472fc6abcde662b1b0`（F1/F2 加 present UNORM 颜色修复的最终候选；`dumpsys`/`sha256sum` 核对安装后 base.apk 同摘要），资源 contentRoot 仍为 `sha256-9fca27349972…`，以 refresh import 更新 artifact、`Game build artifact updated (same files)` 接受启动；资源输入回执见 `build/android-deploy/01001B300B9BE000-z0uu400x/deployment.json`。实际日志为 `nvn_vk` direct、managed GPU disabled。**一律用 `--es s2arm.graphics_mode direct` 冷启动**：不带该参数时 AUTO 会因前次失败记录退回 generic，此时 `[gal]`/`Gpu LoadShaders` 日志和退出读数都不是直连证据（本轮曾误跑两局 generic，已作废）。11:44 的旧 APK `49892df0…` 早于 `02a76bb2`，不能与当前源码等同；11:29 的菜单截图曾见人物黑色、物品栏黑剪影和 HUD 圆球异常，本轮复验到标题与开场过场画面正常，未复验物品栏/纸娃娃与 HUD 圆球。F0 逐项状态见 §8.0.1；G0 已验收，F1/F2 状态与证据见 §8.0.2。

**19:5x F4.4 候选（2026-10-27）**：实装 APK `dd480c1bccf5abfb…`（`build/android-deploy/01001B300B9BE000-bgnxnno_/`，`--refresh-existing`）。需求编译改单槽 worker（去重/容量 1/暂停释放执行锁/Stop 取消/迟到结果丢弃），worker 线程 64 MiB 栈；真机标题/菜单 32 次 `worker compile ok`、0 拒绝、0 程序不可用；世界存活证据来自同代码候选 `28742e22…`（1853 commands/frame、87 次 worker 编译、present ~5.7 ms、Stop 干净）；final 候选在标题/菜单复验 32 次编译、0 失败，并在首条编译后立即 Stop 仍 0.36 s 完成（差异仅为槽位唤醒 broadcast 与 present 计数）。F4 全部四项至此均有代码与验证；F4.4 的边界见 §8.0.3。

**19:3x F4.4 首次候选（2026-10-27，已被栈修复取代）**：APK `aa929e5c…` 在菜单/世界加载时进程死亡（默认 1 MiB worker 栈 + 178 KB 结果），同场景 `28742e22…`（64 MiB 栈）存活。

**18:5x F4.2B 候选（2026-10-27）**：实装 APK `223fbd96e7fca718…`（`build/android-deploy/01001B300B9BE000-_bypikyi/`，`--refresh-existing`）。`program.textures[]` 输出真实绑定事实（handle=8+2*slot、cbufSlot=-1），格式表严格限制在编译器 `TextureFormat` 的 39 个名字内；纹理事实同时进入内容身份。真机世界：每次 miss 输出 21–24 条真实事实、0 次 `direct compile rejected`、0 次 `program not available`；F4.2A 的 pending 补算分支仍未触发。F4.4 未做。

**18:3x F4.3 候选（2026-10-27）**：实装 APK `24413aa95a943fae7b16cb8c37e298aa963fd72fb73be283e47c15419781db01`（`build/android-deploy/01001B300B9BE000-zq12_lh3/`，`--refresh-existing`）。查找与编译共用规范输入（完整 SHA-256 + 逐字节复核，含 `constantBufferUse` 反例），旧 64 位签名删除；真机世界 735,744 次查找 / 199 次编译 / 0 失败；revision 清单仍 `1955/32463155/7c1736…`；Stop `finish rc=0`、结算全 0。F4.2 的“真实事实”半与 F4.4 未做。

**18:2x F4.2A 候选（2026-10-27）**：实装 APK `d235e9e4c947f5b4e3031a330fa4518765946beb56d1e7a328725b7e643e695f`（`build/android-deploy/01001B300B9BE000-yu93g5du/`，`--refresh-existing`）。源快照 pin/短 control（`ctl=2128`）/编译期引用；世界内 715,728 次查找、194 次编译、0 源缺失、0 失败；revision 清单 activate/destroy 仍为 `1955/32463155/7c1736…`；Stop `finish rc=0`、结算全 0、`stop=0 destroy=0`。F4.2 的“真实事实”半未做。

**18:0x F4.1 候选（2026-10-27）**：实装 APK `5d47e03f904a747b301ae7d9d884ec5dd0507783f52fd4be726a8c46c7645592`（`build/android-deploy/01001B300B9BE000-bot0ikqu/`，`--refresh-existing`，同 contentRoot，`Game startup accepted`）。编译诊断（compile-request、补编产物、剥离标记、旧 XGS 隔离）改写 `<state_dir>/direct-diagnostics`，安装 revision 保持只读：真机 activate/destroy 清单 `files=1955 bytes=32463155 digest=7c1736…` 完全相同，15 条诊断进私有目录、0 条进 revision。F4.1 状态见 §8.0.3；下一步 F4.2（源快照生命周期与真实事实）。

**17:0x F3 候选（2026-10-27）**：实装 APK `fea8d5cd556a89412b7f81db46d2c3285f82399cdcdb3f38e46283279ffcbb23`（冻结副本 `build/android-deploy/01001B300B9BE000-922gmwk4/game.apk`，`--refresh-existing` 部署回执同目录 `deployment.json`，资源 contentRoot 仍为 `sha256-9fca…`，App 报 `Game startup accepted`）。显式 `--es s2arm.graphics_mode direct` 冷启动走到标题/过场/主菜单/世界，日志为 `direct activate: nvn_vk backend ready`、`direct composition: managed GPU disabled`。**F3.1/F3.2 已按 §8.0.3 通过**：真实 occlusion query，世界内 `resets=4553 reports=4553 segments=21679 total_samples=2119492 zero=38 fails=0`，零与非零结果都出现，Stop 后 `frame queue finish rc=0`、`retained settlement record=0(unknown 0)`、`direct session closed: stop=0 destroy=0`。**F3.3（MRT）本样本未触发**：505,856 笔 draw 全部 `rt_count=1`，仍是产品待办。仍未解决：§8.0.2 的直连补编/着色器缺口、`NVNcounterData.timestamp` 合同、Report 同步成本（13 次/frame 约 22.8–25.9 ms，见 §8.0.3 限制）。

| §8 阶段 | 已有证据 / 已接通 | 仍未完成或未验收 |
|---|---|---|
| 1 自动出包 | 共用抽取、Android 打包与 APK/资源身份绑定有工程接点和设备部署证据 | 抽取→完整事实/批量编译→只读离线库/描述符→设备真实命中尚未产品闭环；未证明未知 NVN 游戏零配置一键产包 |
| 2 着色器与首遇 | 真实 Draw 调用统一编译器，结果交自有 Vulkan 后端，已有进程内 program 缓存 | 完整源/事实/设备身份和碰撞校验、实际查询的纹理事实、生产离线库与私有跨局缓存未闭环；需求 worker 未接，当前持 adapter 锁同步编译。VS+FS 以外的阶段与 Dispatch 不得按已有 graphics 路径计为完成 |
| 3 执行、画面与窗口 | direct 真机标题、开场过场、世界画面与输入有记录；cube 目标修正、清屏微例、提交失败注入有阶段证据；F0.1–F0.9 通过，G0 已验收（直连加载中 Stop 由旧候选 2/3 次 125 变为新候选 3/3 次 0，含一次真实等待串行锁 85 ms）；F1.1/F1.2/F2.1–F2.3 真机 GPU 微例通过，F1.3 附件视图子资源微例通过 | 人物/HUD/切场景仍需同候选逐项验收；真实查询、窗口撤销/旋转、view 覆盖的真实游戏触发（本样本 cview 全空）仍未验。§8.4.5 的微例和局部负例不能替代全部生产路径验证 |
| 4 两种安全网、升级与输入法 | selection/attempt 和 generic 有接点；缺项运行时可触发统一编译；IME broker/preview 已有测试 | 故意缺离线项→本局正确绘制→次局命中未验；真实 direct 故障→下局 AUTO generic→同存档未验；真实游戏内两轨 IME、正常退出和升级/身份失效未验 |
| 5 未见游戏与前端 | NVN 首样本已进世界 | 第二款不同引擎、Switch Vulkan、OpenGL、更多 GPU/页大小未做完整产品验收；不能由暗黑3外推 |
| 6 性能与能耗 | arena、draw 合批、open pass、program/pipeline 对象已有消费；旧世界局部帧账有记录 | G0 完成后才做 S1 清屏入队与 D1/D2 描述符复用；完整管线键/退休、driver cache 与配方预热、同场景 A/B、真实显示帧时和能耗尚未达标验收 |

§8.4.1 的旧缺口表按当时的基线阅读，不用它判当前实现；本表是当前状态摘要，具体任务和验收在 §8、§8.5、§9。阶段不能等权相加得到可靠百分比；本轮未重跑全部测试或完整游戏路线。

</details>

### 7.1 证据环境与身份

- 既有 NVN 候选：`nvn/fill-all@2d9c7704`，已在本地分支合入并保留作者历史；这是证据基线，不代表远端最新状态。早期上游核对点 `59b5784e` / `777962e5` 不作为当前 main。
- 设备证据：Redmi 22081212C（diting），Android16/SDK36，Adreno730，Vulkan1.1.128，driver `2150002783`，maintenance1=1。设备序号、无线地址和当前安装版本每轮重新读取，不作为通用实现条件。
- 历史宿主：Linux 与 macOS arm64，NDK r29、JDK17；工具链由 `tools/ndk_toolchain.sh` 解析，macOS 的 AOT 静态库重归档使用 NDK llvm-ar。跨宿主证据分别保留，不能互相代替。
- 包类型必须分开：普通 preview、`S2ARM_ANDROID_VK_ENGINE=1` 引擎探针、`-Ps2arm.nativeMode=game` 的 per-game APK。合成 per-game 包不等于真实游戏包；既有 APK 大小和摘要仅对应当次冻结版本，不宣称仍安装在设备上。
- 真实游戏证据：暗黑3 `01001B300B9BE000`，direct 资源包646文件/17,187,193,745 B，revision `sha256-9fca2734…`、APK 摘要前缀 `d08ff4b4…`。完整日志与产物身份见 CHANGELOG `ANDROID-DIRECT-C7-REAL-GAME-SESSION-001`，不将资源或 shader 字节放入仓库。

### 7.2 历史验收基线（2026-10-25，现状见 §7.0）

<a id="72-当前验收状态"></a>

当前任务以 [§7.0](#android-current-progress) 和 [§8.0](#android-foundation-delivery) 为准；下表中的“无真实 direct 帧”等结论只属于 10-25。

<details>
<summary>展开 10-25 C0–C8 原始验收基线、已有证据与当时缺口</summary>

| 项 | 当前状态与已有证据 | 剩余交付 / 不可外推范围 |
|---|---|---|
| C0 ABI/前端 | 部分；table64/status24/request80/runtime160 布局、C/C#/ARM64 对拍与窄整数/浮点/HFA/栈/回调探针有证据；536名入口与48种记录已分类；真实游戏已有 NVN 入口调用 | 探针返回正确不代表全部真实 ELF/xstack/回调及录制生命周期完成，需覆盖生产调用链 |
| C1 选路/故障锁 | 部分；relocation 前 direct commit、单 device/queue、v2服务、原子 attempt；36项host与11项ARM64用例；合成包正常清锁后连续两局 AUTO direct，真实游戏 provider 已激活 | 自动设备装配、多 profile、完整失败/Stop矩阵；#287仅核对 session 不进key，完整运行时闭包身份仍需审计 |
| C2 统一编译 | 部分；同一编译核心、57方法静态 accessor、四set/同源support；119项host检查；设备AOT结果26087 B与离线CLI逐字节一致；compute control parser 51例；合成VS/FS/纹理/UBO和部分XGS封装有证据 | 真实 Draw/Dispatch 状态/C1/纹理事实→请求未接；XGS单set子集不等于完整shader ABI；缺离线项的真实现场补编与次局命中未验 |
| C3 GPU执行 | 部分；**2026-10-28 真机定位并修复：清屏读未初始化 `rect`（UB）+ `clr_pass` 按 `do_clear` 同时清 depth/stencil，导致 depth-only 清掉模板、stencil-only 覆盖深度、整幅清除随机不生效；测试补深度读回布局转换与 pass-break 边界。修复后 `vk-record: ok`（0 FAIL，depth/stencil/view/query/pass-break），query 段用 `debug.s2a.query_wait=1` 的 immediate 口径，产品默认 deferred 写回另验**；真实GPU clear/draw/dispatch/copy/回读，SSBO `3i+1`、stride间隙保留、部分通道/区域、signed INT_MIN/INT_MAX/±16777217有独立期望；语义表登记17函数（12 executed/5 unsupported），另一轮replay为9种opcode，二者不混计 | 多数程序/资源仍测试注册；真实pool/view/mip/数组、同址重建、间接参数与高级stage未完整验收 |
| C4 同步/WSI | 部分；fence顺序/timeout pending、在途销毁拒绝；track单消费者；独立SurfaceView两代swapchain与present fence退休；引擎上屏探针20提交/20退休有记录 | 游戏窗口lease仍未接，`present_without_wsi`保留；backing/alias/读回重入、无后续帧撤销及错误退休需生产链验证 |
| C5 HLE/资源/视频 | 部分；共享前端+引擎已进同DSO/per-game APK，真实游戏HLE→nnMain→NVN命令；合成双纹理/UBO、第二pool与引擎绘制读回通过 | 真实prog_t/资源事实与完整描述符语义、游戏present/节拍、视频/音频联合验收仍缺；d2r 引擎的“加载/现编”证据只作脚手架；新 Vulkan 后端已有“C2 输出→pipeline→draw→读回”设备微例，含 support/guest UBO 数据、set 2/binding 0 纹理采样，NVN→Vulkan 格式映射（8 类样例 + 未知→UNDEFINED），按真实 NVN 纹理描述（RGBA8/RGB565 × 4×4）建 VkImage 并采样，纹理缓存按 NVN 身份/generation 复用（同址新 serial 重建），NVN 采样器→VkSamplerCreateInfo 映射（过滤/寻址/比较/边框），以及共享前端 tex_t 桥接（线性 + 块线性经 `nvn_deswizzle` 解码，多级 mipmap 逐级上传，3D 纹理逐级逐 slice 上传，视图类型按 target 映射（2D/2D_ARRAY/3D；cube 因前端 deswizzle 不支持而明确拒绝））；仍非游戏帧，尚未接 provider/present；不能沿用旧“provider为空、direct不能启动”的结论 |
| C6 系统IME | 部分；modal broker绑定真实session，TextWatcher/SpanWatcher；199项broker断言；preview中文“你好”确认、取消、Stop唤醒有设备证据 | direct/generic真实游戏文本、单虚拟核Stop、横屏/extract与候选交互仍待验，preview不等于游戏内完成 |
| C7 首款完整可玩 | 部分；direct descriptor打包/安装/身份篡改拒绝等测试；真实游戏已direct commit→HLE→nnMain→NVN命令，在首个缺失 `.xgs` fatal；generic同存档可玩 | **尚无真实游戏direct帧**；d2r 引擎路径的 fatal 只作脚手架证据；自动出包、缺项补编、真实上屏、完整路线及失败下局generic未闭合，不能标“首版完成” |
| C8 泛化/前端/性能 | 待验，属于必交付扩展 | 不同引擎未见NVN游戏、Switch Vulkan、GL、更多GPU/页大小与同口径性能/能耗；不能写成“不做”或用首款结果外推 |

C0–C8 的具体验收合同见[实施契约 §9](direct-mode-contracts.md#9-交付顺序验收与回滚)。当时主要阻塞是“真实程序事实→统一编译→资源绑定”和“游戏窗口 present”；之后已有真实游戏上屏，当前阻塞见 §7.0。保留已有通用机制与探针，不为当前报错键造固定答案。

</details>

### 7.3 上游复用的证据边界

| 来源 | 可复用内容 / 已有记录 | 仍需注意 |
|---|---|---|
| #273/PR307 | 画面对拍、ROI与局部缺内容检查 | CoreGraphics依赖未在Linux适配；不是运行时黑屏判官，本轮未运行 |
| #287、#247/#198 | attempt版本身份、control local/shared事实与51例对拍 | 不能搬游戏facts；Oodle/CASC未因此完成，完整runtime闭包身份未验 |
| #281/PR334 | 已选取合入的现编回收工具；历史18+25项合成测试、缺口分类 | 原工具用MSL/metallib/短键，Android需换成完整directABI/profile/SPIR-V/反射身份 |
| #172/PR220、#208/PR209 | 自动出包元数据、帧表和功耗候选 | 临时推导不是真实shader事实；帧表候选未作已验证依赖，历史PR状态需另核 |
| #274 | 与 fengbird 的Switch Vulkan前端共建设备/窗口/故障合同；入口 `s2a_vk_entry` / `s2a_vk_lib_ready` | 不建第二套device owner/loader选择器/WSI；NVN成功不替代其验收 |
| #291/#282/#178/#298/#164/#284 | pool重建、切模式、局部黑线、首次呈现、视频、音频等负例 | 不预置“已修”，每项需自己的证据，不能仅靠全图相似度或帧数 |

### 7.3.1 本轮 main 复用取舍：只加速 §8.1 的真实 draw（2026-10-26，main `cecd8313`）

本节保留首绘阶段的复用审计；其“两小时/延后”安排已结束。最新主线对照读[§7.5](#android-ios-main-alignment)，当前交付按 §8.0、性能按 §8.5。

<details>
<summary>展开 main@cecd8313 的 ABI 对照、反例、引用边界和当时延后清单</summary>

复核后收窄范围：PR1 不参与本轮，不整分支合并、不等待上游 D1、不变更编译器/程序格式。
本轮复用的是 NVN 资源寻址规则和能揭露错误的用例；Metal 建设备、参数编码器、缓存/预热线程不搬。

**两项直接影响当前草稿的编号转换，先于 GPU 试跑核清：**

| 问题 / 来源 | 复核事实 | 实施与回归 |
|---|---|---|
| UBO 坐标：`dmsh_build.py` 的 `reflect`、`Dsh.cs` 的 `Reflect`、`nvn_mtl.m` 的 CBUF 分支 | NVN 的用户常量缓冲在 shader 的 c3 起；上游把 cN 映射为 NVN 槽 N−3。统一编译器 `CreateConstantBufferBinding(index)` 原样记录 shader cbuf index。审查时 `nvn_vk_first_draw.c` 草稿却按 `slot−1` 查 NVN 表：首笔反射 slot=3 会错取槽2，正确来源应为槽0 | 明确区分 shader bank、NVN API 槽与 Vulkan set/binding；生产者/消费者只转换一次，cbUse 掩码坐标一并核对；c0/c1/c2 分别按驱动/常量段语义处理，不能套用户槽规则。构造槽0与槽2内容不同的用例，再测 VS/FS 同号不同绑定，不能只验证描述符创建成功 |
| 纹理坐标：`dmsh_xlate/Program.cs` 的 `Slot`、`dmsh_build.py` 的 `decode_tex`、`nvn_mtl.m` 的 `tex_slot_h` | 统一结果的 binding.slot 目前是 `TextureDescriptor.HandleIndex`，不是 NVN BindTexture 槽号。普通 c2 组合句柄要先解编码，word offset×4 得字节偏移，再按驱动表基址/步长定位。首笔 handleIndex=8 → 0x20 → NVN纹理槽0；当前草稿直接读纹理槽8，会错取或报未绑定 | 消费结构化反射的 cbufSlot/handleIndex/separate/flags，按句柄种类解析；已在 BindHandles 记录时加过 pool base 的句柄不能重复加。本次只提取 main 原始 `decode_tex` 函数在 Linux 运行，8→0、10→1、54→23 三项通过。追加槽0/槽8不同纹理、跨阶段及解绑负例；不支持的 UBO间接/独立采样器形式明确失败，不猜槽 |

这两条是全游戏共用 ABI 规则，例中的数字仅是核对值，禁止针对暗黑 shader key 写条件。
移植时以 NVN 驱动布局与本仓锁定的 Ryujinx 编码相互核验，不把 Metal 参数名、固定 binding 或旧 Dsh 默认答案带进统一编译器。

**仅保留与本笔消费直接相关的另外两项检查：**

- 程序/源引用：参考 `fbd484ce` 的 `bind_stages` / `t_nvn_bindstale`，用宿主对象与绑定时代际覆盖部分阶段换绑、Finalize/同址复用、跨提交。借用场景，不机械搬64项环形替身表，也不要求先重构全部资源缓存。
- 资源可见性/退休：借用 main 的 `t_rt_range` 场景测 draw→sample→copy，Vulkan 按真实 stage/access/layout 建依赖；Metal 的首尾屏障不意味着 Vulkan 必须机械加两条屏障。同样，提交成功但 fence 等待超时不等于完成：审查时 first_draw 草稿在等待失败后仍销毁 fence/command buffer 并进入资源释放，需要改为由 session owner 保留在途资源直到有完成/安全销毁证明。成功提交与未提交失败分开处理。

所有反射项逐项校验。若当前消费者只实现单个 UBO/纹理的子集，额外绑定/数组必须显式 Unsupported，
不能循环中只取第一项，再把同一个 VkBuffer/VkImageView 写给其它绑定；view 的 mip/layer/swizzle 与资源代际也不能丢。
本轮重点是修接线并取得真实 GPU 输出/完成证明，不增加另一套产物、缓存或渲染器。

**延后候选（不占当前两小时）：** `9c1079b0` 的存储别名、`46ae1708` 的 image 写用途升级，只有本笔真实使用触发时才补必需部分；
`d413c0ee/46ab713e` 的管线缓存与预热、`ae2866ff` 的大库按项读取、WP17 零拷贝池及 BC 解码均留待命中缺口或首帧后。
BC 模块已做 Linux BC1裁剪/BC3颜色与alpha小例验证，但当前首笔反射并未证明存在BC阻塞，不能因此新开格式工程。
`b509013d` 与 `direct/first-skip` 的首遇跳 draw 明确不吸收。以上 main 测试/游戏读数不冒充 Android 验收。

</details>

### 7.4 历史接线与待证实问题（2026-10-26，现状见 §7.0）

<a id="74-当前接线与待证实问题2026-10-26"></a>

本节的“尚无真实游戏 direct 帧”等是 10-26 当时结论；当前已进入世界，完成范围见 [§7.0](#android-current-progress)。构建身份、错误归因与证据限制仍按原记录保留。

<details>
<summary>展开 10-26 接线日志、待证实归因和构建复现记录</summary>

- **源码已接**：`S2ARM_ANDROID_VK_BACKEND=nvn_vk` 分支选择共享前端、`mtl_vk_shim`、adapter/session 和 provider，不编 D2R 引擎执行器；目前仍需满足旧 `S2ARM_ANDROID_VK_ENGINE=1` 编译门，名字不代表实际选择旧引擎。构建参数和最终 ELF/运行日志共同核实。
- **已有真实日志**：本地 `run23.log` 有 `direct activate: nvn_vk backend ready, window=1` 和 `managed GPU disabled`，随后第一条索引绘制因阶段 key 缺失失败。`31349a63` 作者报告推进到缺 `.xgs` 文件；只证明诊断路径在打开该文件时失败，具体来源/编译时序仍待证实。**尚无真实游戏 direct 帧或可操作证据**。
- **已审查的实现缺口**：`31349a63` 修正了视口复制源码，但作者声明针对性回归未跑；阶段数组仍按掩码置位排序猜对应；TIMESTAMP 未按16字节结果布局/单位实现；draw cache 命中仍用短 key；serial 环形表未证明保活/并发安全；补编仍写安装 revision。§5.5–5.6/§6.1 是这些问题的验收标准，不因日志往前而默认修好。
- **编译与产物**：源码现存 `DshVk/s2a_direct_bundle_v1` 是待移除的旧 XGS 链，§3.1 要求删除 Android 的生成/加载/诊断兼容依赖；本次文档更新没有替代实现或完成删除代码。生产 miss 接 `DirectCompileNative` 与已绑定 compile_fn。关闭 interlock 剥离是正确测试条件，既有无来源/剥离产物须隔离在私有诊断目录；没有标记不自动证明可信。只有编译器原始诊断/能力与实际指令证据匹配，才能把某个失败归因为 interlock，不能只看 rc=1。
- **后续报告待核实**：`be83618e` 将排队补编和大量 fragment 失败归因为设备缺 interlock，但旧 accessor 默认能力与输出冗余声明已构成另一解释（§5.5.4）。队列是否捕获真实缺项、目标程序是否实际需要 FSI 仍待证明；不采用“换场景、排除 pass 或改首帧设备”作为已确定下一步，也不将诊断补编描述为生产安全网已闭环。
- **构建复现注意**：完整 AOT 重建后检查并补齐 OpenSSL 的 `libssl.so/libcrypto.so` 再打 APK；只执行 Gradle task 不保证 AOT 重编。APK 字节改变后用 `game_apk.py --resources` 重新生成匹配的 artifact，并经正常校验/安装事务激活；不能把“修改旧 artifact 的 APK hash”当正式升级闭环。私有游戏数据、设备地址和大日志不进仓库。

</details>

<a id="android-ios-main-alignment"></a>

### 7.5 最新主线 iOS 对齐：借机制，保留 Android 目标（2026-10-27）

本次 `git fetch origin main` 所见最新快照为 `main@5be7742f7a419c8edf9f90e45c81320fd2c24ad4`（2026-10-27 18:22:13 +0800），更新此前 `6590ba40` 对照；用 `git show` 与 Android 当前分支分开读取，未切换/合并主线。下表引用已核对的最新快照；本节是源码研究，不代表本轮执行过 iOS/Android 真机验证。**F4 是 Android 的任务编号，iOS 对应能力分散在 NVN 补编、NVN 管线/库预建与通用 Metal 编译队列，不能把它们算成同一个 worker。**

| 主线事实与参考 | Android 应采用的机制和边界 |
|---|---|
| iOS NVN [缺项登记与首次使用现编](https://github.com/jhaizhou-ops/S2Arm/blob/5be7742f7a419c8edf9f90e45c81320fd2c24ad4/gfx/nvn/host/dsh_miss.inc)：SetShaders 登记缺项并复制 control，首次建程序需要时在提交线程同步调用编译；主线假定那时 code 区仍有效 | 采用“先登记、真正需要时补全事实”，避免 SetShaders 将大量未使用程序全编；Android 依 §5.5 复制/保活 code、control、C1、事实和代际，不能照搬裸 code 指针或短键。**我方当前同样同步现编，worker 是待实现目标，不是已完成，也不是从 iOS NVN 原样复制** |
| iOS Ryujinx **通用 Metal** [编译队列与首用等待](https://github.com/jhaizhou-ops/S2Arm/blob/5be7742f7a419c8edf9f90e45c81320fd2c24ad4/gfx/metal/gal_prog.m) 有后台任务；iOS NVN 的 [first-use pipeline skip](https://github.com/jhaizhou-ops/S2Arm/blob/5be7742f7a419c8edf9f90e45c81320fd2c24ad4/gfx/nvn/gfx/nvn/nvn_mtl.m) 在满足启发条件时默认允许跳 draw | 借有界任务、在途去重和首用等待，不搬 Metal 编译对象；Android 的依赖 draw 必须等正确结果并保序，不采用跳 draw。worker 主要让 owner 能响应 Stop/窗口、允许已知任务提前并行；没有提前量的首次依赖仍要等待，必须分别测首遇、加载和稳态收益，不能宣称自动消除卡顿 |
| iOS [采样视图](https://github.com/jhaizhou-ops/S2Arm/blob/5be7742f7a419c8edf9f90e45c81320fd2c24ad4/gfx/nvn/gfx/nvn/nvn_mtl.m) 优先使用 view 的 swizzle，否则用 texture builder 的 swizzle，再结合格式通道映射；附带目标/mip/layer 与底图代际处理 | 借“视图覆盖、格式映射、底图/view 分离”机制，在 Android 按共享 `nvn_obj.h/hle_nvn.c` 的 0=ZERO、1=ONE、2..5=R/G/B/A 转 VkComponentMapping，并按实际格式、用途和 GPU 内容来源验证。view 覆盖应替换 builder swizzle，再与格式映射组合；不能忽略 view、盲用 Metal 枚举/格式映射、用旧 CPU 镜像重建 GPU 写入底图或提前销毁在途 view。iOS 某些不支持的格式/非法值会退回其他视图，Android 必须独立验证或明确 Unsupported |
| iOS [附件和清理](https://github.com/jhaizhou-ops/S2Arm/blob/5be7742f7a419c8edf9f90e45c81320fd2c24ad4/gfx/nvn/gfx/nvn/nvn_mtl.m) 记录真实附件并处理 pass；某些局部 depth/stencil 清理路径明确记“整面清除” | 借目标切换前落地清理、按附件/平面记录的结构；不照抄整面清理或降级。Android 的 scissor、mip/layer、颜色通道、stencil 位、保存其他平面以及 draw/clear/copy 顺序都需独立期望和生产队列验证 |
| iOS [资源延迟释放](https://github.com/jhaizhou-ops/S2Arm/blob/5be7742f7a419c8edf9f90e45c81320fd2c24ad4/gfx/nvn/gfx/nvn/nvn_mtl.m) 与命令完成绑定；设备现编 [Metal 编译选项](https://github.com/jhaizhou-ops/S2Arm/blob/5be7742f7a419c8edf9f90e45c81320fd2c24ad4/gfx/nvn/gfx/nvn/nvn_mtl.m) 新近与离线选项对齐 | Android 用实际 Vulkan 提交/fence 的完成证据持有对象，submit 失败与成功但 timeout 分开处理。CLI/AOT 的 SPIR-V 和完整反射在同一输入、事实、profile、优化及语义版本下对拍；补 NaN/Inf 等边界用例并将有效编译选项纳入身份，不能把 Metal relaxed 选项直接套到 Vulkan |
| iOS [两段式出包](https://github.com/jhaizhou-ops/S2Arm/blob/5be7742f7a419c8edf9f90e45c81320fd2c24ad4/pack/jobs/ipa.py) 优先已知热键，后续补其余库；[管线种子](https://github.com/jhaizhou-ops/S2Arm/blob/5be7742f7a419c8edf9f90e45c81320fd2c24ad4/gfx/tools/direct/pso_seed.py) 的图形配方来自真实运行记录 | 共用抽取、输入/工具/翻译链身份和原子发布值得借鉴。热键和真实配方只是后续可选加速，首个零配置 Android 包不能要求先玩一遍或联网；离线 shader 数量不是全集，shader key 不能推导完整图形管线，设备 driver cache 也不能跨设备照搬。iOS metallib/MSL/XGS 不作 Android 产物 |
| iOS [模式选择](https://github.com/jhaizhou-ops/S2Arm/blob/5be7742f7a419c8edf9f90e45c81320fd2c24ad4/native/src/gfxmode.c) 删除旧 fail 标记，[异常入口](https://github.com/jhaizhou-ops/S2Arm/blob/5be7742f7a419c8edf9f90e45c81320fd2c24ad4/gfx/nvn/host_adapt.m) 按类别报红并继续，不据此落实“下局自动退 generic” | 这是 iOS 当前策略与本 Android 方案的明确差异，不作为两道安全网完成证据；Android 仍按用户指定目标保留缺项补编、错误结束本局、下一进程 AUTO 整局 generic 与同存档验收，不因对齐实现擅自改产品要求 |

**按 F4 核对最新 main 的具体做法**

| Android 项 | 最新 iOS 的实际接点 | 可以借鉴 / 仍须独立实现 |
|---|---|---|
| F4.1 私有输出 | [host_adapt.m:direct_paths](https://github.com/jhaizhou-ops/S2Arm/blob/5be7742f7a419c8edf9f90e45c81320fd2c24ad4/gfx/nvn/host_adapt.m#L210-L239) 分开设置随包 `DM_MSL_DIR` 与本机 `DM_MSL_FALLBACK=Documents/wire/<程序号>/shaders`；补编 `.metal/.json` 写后者 | 借输入库/运行时输出分离。Android F4.1 已有自己的私有诊断目录和 revision 清单验证；不能把 iOS 路径或缓存格式当成 Android 合同 |
| F4.2 源和真实事实 | [dsh_miss.inc:dm_shader_miss/late](https://github.com/jhaizhou-ops/S2Arm/blob/5be7742f7a419c8edf9f90e45c81320fd2c24ad4/gfx/nvn/host/dsh_miss.inc#L45-L91) 在 SetShaders 复制 control 入待编表，首次 `prog_get` 取出并同步调用编译，code 仍取在用程序地址；[DshCApi.CompileCore](https://github.com/jhaizhou-ops/S2Arm/blob/5be7742f7a419c8edf9f90e45c81320fd2c24ad4/gfx/tools/direct/dsh/DshCApi.cs#L25-L48) 进入托管后才复制 code/control。事实来自随包表，[JobFor](https://github.com/jhaizhou-ops/S2Arm/blob/5be7742f7a419c8edf9f90e45c81320fd2c24ad4/gfx/tools/direct/dsh/Dsh.cs#L100-L121) 缺表时标 `no_facts` 并允许默认查询 | 借登记缺项、仅编真正用到的程序和复制短命 control。不能用“程序在用所以 code 有效”的假设替代 Android worker 自持快照，也不能复制默认查询策略；Android F4.2 的真实纹理/view/driver 事实和 MissingFact 仍须完成 |
| F4.3 身份 | [dsh_have](https://github.com/jhaizhou-ops/S2Arm/blob/5be7742f7a419c8edf9f90e45c81320fd2c24ad4/gfx/nvn/host/dsh_miss.inc#L18-L25) 用阶段短键定位、核 `DMSH_CHAIN`；整数输出变体另核类型掩码及源/变体新旧。NVN 内存管线用 `pso_key_fill/norm` 归一化实际创建状态、`memcmp` 去重；[pso_archive.h](https://github.com/jhaizhou-ops/S2Arm/blob/5be7742f7a419c8edf9f90e45c81320fd2c24ad4/gfx/nvn/gfx/nvn/pso_archive.h#L1-L35) 按 OS/GPU/chain 隔离，文件名定位后由 Metal 核是否匹配 | 借版本失效、有效状态规范化及命中后核验；不把短 shader 键或 Metal archive 文件名当完整 ProgramKey。Android 保持 code/control/C1/事实/ABI/profile/closure 的完整身份和真实命中分支验证，不能用 iOS 驱动的 archive 核验代替 SPIR-V/反射/contentHash 核验 |
| F4.4 调度与发布 | NVN 的 [shader prefetch](https://github.com/jhaizhou-ops/S2Arm/blob/5be7742f7a419c8edf9f90e45c81320fd2c24ad4/gfx/nvn/gfx/nvn/nvn_mtl.m#L5233-L5262) 在串行低优先级队列加载**已有**库；缺库 shader 仍由提交线程同步补编。[pso_pend_kick/take](https://github.com/jhaizhou-ops/S2Arm/blob/5be7742f7a419c8edf9f90e45c81320fd2c24ad4/gfx/nvn/gfx/nvn/nvn_mtl.m#L4950-L5041) 另有 384 槽在途管线表、完整 key 比较、后台构建和条件变量；[warm_claim](https://github.com/jhaizhou-ops/S2Arm/blob/5be7742f7a419c8edf9f90e45c81320fd2c24ad4/gfx/nvn/gfx/nvn/nvn_mtl.m#L8176-L8203) 在提交线程发布结果 | 借任务去重、后台只产结果、owner 统一安装。预取已有库、补编新 shader、创建管线须分别计数。Android 的当前包挂起/恢复、控制 poll、Stop/取消、会话代际/迟到结果和字节预算仍需独立接线，不能拿进程级静态表或条件变量等待替代 |

**最新改动的边界**：`d126815c`、`b8b52980` 修改 NVN 管线等待。[当前 pso_pend_take](https://github.com/jhaizhou-ops/S2Arm/blob/5be7742f7a419c8edf9f90e45c81320fd2c24ad4/gfx/nvn/gfx/nvn/nvn_mtl.m#L4986-L5040) 默认单管线等待 2000 ms、可跳绘制的帧等待预算 100 ms；不满足可跳条件的 draw 默认另等 10000 ms，上限后仍报红并跳过，`stuck` 阻止后续同管线反复等满。它提高 iOS 卡住时的前进能力，但不能证明被跳绘制无副作用，**不移植到 Android 的“必须等正确结果并保序”合同**；Android 到总 deadline 应准确结束本局，而非丢 draw 返回成功。

**通用 Metal 的单独参考**：[gal_prog.m:xjob_start/prog_finalize](https://github.com/jhaizhou-ops/S2Arm/blob/5be7742f7a419c8edf9f90e45c81320fd2c24ad4/gfx/metal/gal_prog.m#L815-L950) 自持 SPIR-V、按键共用作业，iOS 默认 2 个并发编译槽，首次依赖未完成就等，未开工任务可由首用线程认领就地编；这是 Ryujinx 通用 Metal 路径，不是 NVN 缺库补编。槽数只限制同时编译数，不能据此认定总排队/内存也有界。[cache_write](https://github.com/jhaizhou-ops/S2Arm/blob/5be7742f7a419c8edf9f90e45c81320fd2c24ad4/gfx/metal/gal_prog.m#L846-L899) 把写盘交独立串行队列，`xjob_run` 置完成并发通知不等待磁盘；[t_xcstall.m](https://github.com/jhaizhou-ops/S2Arm/blob/5be7742f7a419c8edf9f90e45c81320fd2c24ad4/gfx/metal/tests/t_xcstall.m) 用人为卡住 writer 验证首用仍能完成、放开后文件补齐。借其发布顺序和确定性用例；磁盘持久化仍归 Android F5.1，不并进 F4.4。

最新 main 仍包含 `6590ba40` 已有的 OpenGL→Metal MRT、分离深度/模板和 GPU 测试；可参考独立期望与用例组织，不把该前端结果当 Android NVN→Vulkan 已支持。本次对齐不引入另一个后端、XGS/S2AP 或第二套设备/缓存。

<a id="android-merge-boundaries"></a>

### 7.6 与 Android/main 汇总分支合流的边界（2026-10-28）

详细比较、冻结提交、完整冲突清单、行为兼容风险、合入单元与验收矩阵见[Android 直连与 T02/main 合并分析](direct-main-merge-analysis-20261028.md)。按用户要求，本节只保留引用，专题明细在该文维护。

产品路线、当前完成状态和下一交付仍以本文为准，ABI/所有权以[实施契约](direct-mode-contracts.md)为准；合并分析不是第二套架构合同。实际合流前须按新的目标/main/本线提交重新预演；原分支通过和文本冲突解决不能替代新候选验收。

## 8. 历史实施顺序与完成标准

任务围绕一条真实产品链推进，编译、前端、后端、出包的消费者必须闭合。现有 C0–C7 是工程检查项，不等于完整产品目标；多游戏、前端扩展和性能仍是后续必交付项。

| 顺序 | 实现工作与主要落点 | 完成标准 |
|---|---|---|
| 1 自动识别与出包 | 共享 `pack/`、`graphics/tools/direct/`；Android `tools/make_pack.py`、graphics descriptor 生产者 | 未登记 NVN 游戏从合法输入一键产包，无手工 JSON/facts/模块名单；抽取缺口可见，缺离线项不阻止具备补编能力的 direct |
| 2 真实事实与生产 shader ABI | `graphics/nvn/gfx/nvn`、`graphics/tools/direct/compiler`、`android/native/direct`、`core-runtime` | Draw/Dispatch 快照真实驱动统一编译；完整身份和绑定被新 Vulkan 后端消费；故意缺一条离线项仍正确绘制，次局命中；缺事实负例明确失败 |
| 3 真实游戏资源与 WSI | 新 Vulkan 后端 `nvn_vk_be.*`、adapter、`provider_vk.c`、窗口租约/跟踪与 HLE 服务 | 替换 `present_without_wsi`；真实游戏第一帧→可操作、视频/声音/输入/存档正常；旋转/撤销/Stop 有真实退休证明，无第二 owner |
| 4 整局兜底与升级 | selection/attempt、Android UI、安装和缓存生产者 | 同身份故障/SIGKILL 后下局 AUTO generic、不循环崩；正常 Stop 不误退；包/编译器/profile 更新正确失效，保留存档；真实 IME 与两轨均验 |
| 5 未见游戏与前端扩展 | 相同 NVN 链验证不同引擎样本；与 #274 共建 Switch Vulkan；GL 样本子集 | 换内容只换输入，不加标题/地址规则；各前端各有真实零配置路线、画面对拍和能力缺口清单，共用 device/WSI 核心 |
| 6 首遇、稳态与能耗 | 预读、索引分片、管线配方、driver cache、资源上传/分配与统计 | 先分清 I/O、翻译、pipeline、GPU、呈现等待再做 A/B；记录首局/暖局/新场景、画面/帧率/功耗/分配，达标才扩大默认支持 |

后端切换先行：`nvn_vk_be` 骨架（device/clear/present 微例）→ 编译器 SPIR-V/反射 + 资源/管线消费 → `provider_vk.c` 默认切到新后端 → 游戏窗口 present。步骤 1/2/3 可在已确定接缝上并行，合成一个生产候选后验证；步骤 4 必须和首次正式 direct 启用同批通过，不能先给玩家启用再补兜底。现有通用模式保正确性与兜底，不另起通用 GPU 性能重构。任何新增共享目录改动先与原负责线对齐，不复制一套长期并存。

<a id="android-current-delivery"></a>

**依赖规则**：资源复用和异步启用依赖对应的完成/退休证明，编译缓存依赖真实输入与完整身份，正式直连启用依赖故障兜底。满足各自前置的独立项按 §8.5.9 推进，不把已完成的 F0–F4 当作重做起点；整体剩余范围见 §7.0。

<a id="android-foundation-delivery"></a>

### 8.0 基础代码优先：可独立交付的实施计划（2026-10-27）

**执行单位**：本节细化[总体依赖顺序](#android-current-delivery)；F0–F5 是任务组，不能整组作为一次提交。下面每个编号才是单独交付；一次改变一个接口合同、一个资源入口或一种图形语义，必要的头文件、弱声明、全部调用方和相关测试必须同批改齐。已有 `02a76bb2` 的实现继续沿用；执行前核 HEAD 和并行 diff，发现某项已完成就核对证据，不再实现一次。

**当前用法**：F0–F4 和 F5.1 已有分项成果，只对缺口及变更影响回归；F4.4 的执行证据见下，不重新领取。F5.2–F5.5、性能与多游戏/三前端的剩余工作分别见 §7.0、§8.5.9 和 §9。

<details>
<summary>展开 F0 开始时的历史启动指令及同日 G0 验收说明；不作为当前起点</summary>

**当前只从 F0.1 开始。** F0.1 的代码、针对性测试和实际覆盖范围通过后继续 F0.2；依次推进，不把 F0 整组混在一个补丁里。（2026-10-27 本轮按此顺序完成 F0.1–F0.8，并执行了 F0.9 的集成结算；同日 14:3x 修复收局线程对内存 SVC 串行锁的 liveness 缺口后，直连加载中 Stop 3/3 退出 0，**G0 已验收**。逐项证据见本节末表。）若用例失败，先修当前编号；后续依赖项不启动。独立研究可继续，但不能在未验证的退休基础上启用复用优化。接口需要新增时限于既有 owner 和消费者，不另建 device/queue 或第二套生命周期管理。

</details>

#### 8.0.1 F0：完成与退休，逐入口交付

| 编号 / 前置 | 本次修改范围与结果 | 本次通过条件 |
|---|---|---|
| **F0.1 失败传播** / 无新增前置 | `nvn_vk_first_draw.c/h::pass_break`、`vk_record.c` 和全部直接调用者/弱声明返回并处理失败；本项先不重构上传、清屏或 present 的资源包 | 在生产帧队列注入提交失败，record 在该位置返回真实错误；后续 clear/copy/fence/event 调用计数不增加，首错不被覆盖。成功路径仍执行原指令序列；fixture 不能用永远成功的 pass_break 代替真实调用 |
| **F0.2 前缀记账** / F0.1 | 只修帧队列提交游标和完成依赖：`submitted_n` 在实际 submit 成功后推进；区分未提交前缀与已经提交但未完成的前缀 | submit 失败不推进游标；第 8 个 pass 提前提交后即使 `ncmd==submitted_n>0`，需要 CPU 可见完成的操作仍等匹配 fence；同一批不重复提交，不把已提交当已完成 |
| **F0.3 record 一次性提交** / F0.2 | `vk_record.c` 的 submit 及其直接调用者区分未提交失败、成功提交后完成未知、成功完成；所需待退休条目归现有 owner | 真实提交后注入 wait timeout，相关 fence/CB/辅助 buffer-memory 不被释放或重用；原操作准确失败。记录每类对象的创建/销毁计数，正常完成后恰好回收一次 |
| **F0.4 clear helper 退休** / F0.3 的结果/保活合同 | 只适配 `vk_clear.c` 及其调用者，复用上一项结果分类；保留已有清理算法 | clear 提交成功但 timeout 后，CB/fence/framebuffer/view 全部保留；失败不发布完成。pending GPU producer 仍须登记以阻止旧 CPU 镜像重建，这与“已完成”分开。正常整平面和部分模板清除仍通过；不在此项增加颜色 mask 或清屏合批 |
| **F0.5 纹理上传退休** / F0.3 的结果/保活合同 | 只适配 `nvn_vk_texcache.c` 上传及消费者；检查 submit/wait 结果，持有 staging/image 和相关句柄 | 上传 timeout 保留 staging/image/CB/fence，不能返回“可采样”的成功条目；正常上传字节和格式结果保持正确；后续操作不能消费失败上传 |
| **F0.6 present 失败退休** / F0.3 的结果/保活合同 | 只适配 `nvn_vk_swapchain.c` 的生产 present 路径及 owner 收尾；绘制完成和 presentation 退休分别记账 | 提交成功后 present 报错或 fence timeout，不释放仍在使用的命令/资源，不调用成功的 present_done；Surface/swapchain 另按窗口退休合同保活。成功路径正常呈现，不能用渲染 fence 冒充 presentation 已退休 |
| **F0.7 帧队列容量** / F0.2–F0.6 | 只修 open pass 入队失败传播。首版容量满时明确失败并持有既有工作，后续安全分批续录优化另排 | 测试将容量缩小，触达真实“满”分支；不静默丢 pass/CB，不越界写，不在失败后继续录制；该容量下允许明确失败，不允许以少画换成功 |
| **F0.8 纹理保活容量** / F0.7 | 只修 `fd_pin_tex` 的失败返回与各消费者。首版登记满时停止该笔 draw 并准确失败 | 小容量触达真实 pin 满分支；没有未登记的资源继续进入 descriptor/命令，无永久多 pin 或 double unpin；保留的资源依 F0 退休 |
| **F0.9 退出/重建联合验收** / F0.1–F0.8 | 沿既有 Stop、release_device 和 device 销毁路径核实际子对象收尾，仅修集成发现的生命周期缺口 | 正常结束及失败后停止生产，拿到实际完成或适用的合法终止依据后显式清理子对象/host 分配，再销毁 device；完成未知与 device lost 分开。不能以 `vkDestroyDevice`、memset 或丢失资源表替代证明。新会话不返回旧句柄；无法证明安全就保留并准确失败 |


**当前差异（`dd084536`，2026-10-28；未在设备上重跑本表）**：`mtl_wait` 的完成证明改走带预算的帧队列入口（见 §7.0 修复记录），并修正“再次提交时 reset 仍 in-flight 的旧 fence”这一 Vulkan 违规：旧 fence 降级进早批次表，本次提交用新 fence。上面的 F0.2/F0.9 通过范围只属于各自候选；这条新路径需要真机复跑 F0.2 的前缀等待、guest fence 轮询/超时与 G0 收尾后才能并入。`mtl_wait` 现在会在 guest 的**有限超时等待**点提交积压前缀（`timeout=0` 的纯轮询不提交、不关 pass），**提交节奏会变**，性能影响必须按同包 A/B 量，不能用旧读数外推。

**F0 执行状态（2026-10-27，本轮；只记实际覆盖，未通过项不并入通过）**

| 编号 | 代码已改 | 针对性验证（真机 GPU / 生产队列） | 结论 |
|---|---|---|---|
| F0.1 | `nvn_vk_first_draw_pass_break` 改为返回 int，头文件、弱声明、`vk_record.c` 与 draw 入口全部消费返回值；失败时在触发 opcode 处返回 `S2A_RECORD_GPU` 并附帧队列首错 | `vk_record_test`（Adreno 730 真机）：注入失败后 rc=GPU、opcode=CLEAR_DS、其后的 update/copy/fence/event 一个都没执行、首错原文保留；同一命令流成功路径仍完整执行。生产队列（APK `ca57830a…`）：`debug.s2a.batch_passes=1` + `debug.s2a.fail_submit=1` → `frame queue: injected batch submit failure; 1 command buffer(s) … retained (submitted=0 of 1…)`、`pass break: closing the open pass failed`、`mtl_exec: NVN record op=8 failed (gpu): pass break before opcode 8 has no completion proof; … not executed` | 代码/微例/生产队列通过 |
| F0.2 | `submitted_n` 只在 `vkQueueSubmit` 成功后推进；早批次各自保留 fence（`batch_fence`），flush 按提交顺序全部等到；`ncmd==submitted_n>0` 时 `pass_break(sync)` 与 `QueueFinish` 仍等完成；去掉“空批次只挂 fence”；新增队列设备归属检查 | 生产队列：`batch_passes=1` + `fail_submit=2` → `pass break: waiting for 1 early batch(es) with no unsubmitted prefix (needs CPU-visible completion)`（旧实现这里跳过）→ `injected fence timeout … 1 command buffer(s) retained (submitted=1 of 1, early batches=1)` → record 在该 opcode 准确失败；正常局连续多轮 flush rc=0、present 正常 | 代码/生产队列通过 |
| F0.3 | `vk_record.c` 一次性提交分 `COMPLETED/UNSUBMITTED/INCOMPLETE`；完成未知时 fence/命令缓冲/staging buffer-memory/临时图像转入保留账本；新增逐类创建/销毁计数、三类提交计数与 `s2a_record_release_retained`；诊断注入 1=提交后完成未知、2=假装提交失败 | `vk_record_test` 真机：正常完成 cmd/fence/buffer/memory 创建==销毁且各 1；注入完成未知后对象全部保留、guest 未被写、原操作失败；注入未提交后全部回收、无保留；设备销毁前结算把 1 条保留集等到完成并显式回收（此后创建==销毁） | 代码/微例通过 |
| F0.4 | `vk_clear` 提交分 `OK/NOOP/UNSUBMITTED/UNCOMPLETED`；完成未知时命令缓冲/fence/framebuffer/view 全部保留；`vk_record` 对 `UNCOMPLETED` 仍登记 GPU 生产者（`mark_written`），与“已完成”分开 | `vk_record_test` 真机：注入完成未知后 `uncompleted+1、retained+1`，cmd/fence/fb/view 都没回收，原清除失败；注入未提交后四类对象各回收 1、无保留；随后正常清除仍读到 0.25；结算后四类创建==销毁 | 代码/微例通过 |
| F0.5 | `nvn_vk_texcache` 上传分三类结果；完成未知时 staging/CB/fence 进保留账本、图像/视图标记 `upload_incomplete` 并转移给账本，槽不可命中；重传失败也不再返回可采样条目；新增上传记账与 `release_retained`；诊断注入同 F0.3 | `nvn_vk_texcache_tex_test` 真机：正常上传 staging/cmd/fence 各回收 1；注入完成未知返回 NULL（不返回可采样条目）、staging/CB/fence 保留、图像保留计数 +1；注入未提交全部回收且不登记图像；注入后新条目仍可创建 | 代码/微例通过 |
| F0.6 | `nvn_vk_swapchain_present_image` 提交成功后 present 失败或 present fence 超时：命令缓冲/fence 保留、不调用 `present_done`、swapchain 呈现路径进入失败终态（`present_failed`）；present fence 由本函数持有/回收，destroy 前先做有界完成检查再显式回收或按窗口退休保留 | 生产队列（游戏，APK `ca57830a…` 前一同源码候选 `63537a41…` 上注入）：`fail_present=1` → `vkQueuePresentKHR failed after submit; command buffer/fence retained, present_done not called; swapchain present path retired (… 1 in-flight command set(s) retained)`；`mtl_present` 收到同一失败。正常结束：WSI 探针真实 owner 关闭 → `adapter shutdown: frame queue finish rc=0` → `session destroy: retained settlement record=0 …`（无保留） | 代码/真机失败注入通过；presentation 退休的显式结算只在正常结束路径验证 |
| F0.7 | open pass 入队满不再静默丢 pass：明确失败、既有工作保留、未提交的新 CB 释放；fb/pass/pool 表满同样传播失败；新增 `debug.s2a.fq_cmds`/`fq_no_make_room` 诊断（只缩小容量/跳过腾挪优化，不改容量检查） | 生产队列（APK `ca57830a…`，`batch_passes=1`+`fq_cmds=4`+`fq_no_make_room=1`）：`frame queue command-buffer table is full; the open pass was not submitted; 4 command buffer(s) and their resources retained (submitted=4 of 4, early batches=4)` → record 在下一 opcode 准确失败；无早批次前缀时同一分支为 `submitted=0 of 4` | 代码/生产队列“满”分支通过 |
| F0.8 | `fd_pin_tex` 返回失败，附件/采样纹理登记满时停止该笔 draw 并准确失败；不再“未 pin 也继续用”；新增 `debug.s2a.pin_max` 诊断 | 生产队列（APK `ca57830a…`）：`pin_max=2`/`3` → `texture pin list full (3 of 3); refusing this draw (no unregistered resource may be used)` → `mtl_exec: NVN record op=26 failed (unsupported): draw: 真实绘制未完成：texture pin list is full; …`（本局按错误结束） | 代码/生产队列“满”分支通过 |
| F0.9 | 设备销毁前按 owner 结算：`s2a_record_release_retained` / `s2a_vk_clear_release_retained` / `nvn_vk_texcache_release_retained` 做有界完成检查（拿到完成显式销毁，拿不到保留并写原因），`nvn_vk_session_destroy` 在 `s2a_vk_device_destroy` 前调用；`s2a_vk_adapter_shutdown` 先 `QueueFinish`；swapchain destroy 先结算在途 present；`_exit(125)` 三个失败分支同时直写 logcat | 真机微例：F0.3/F0.4 的拒绝集在设备销毁前被显式回收（创建==销毁）；真机正常结束（WSI 探针走真实 adapter owner，APK `ca57830a…`）：`frame queue finish rc=0`、`settlement record=0(unknown 0) clear=0(unknown 0) upload=0(unknown 0)`，随后销毁 device（同一最终候选上游戏首帧与 #60 呈现正常）；顺序联合用例：真机 `draw→clear 蓝→读回 (0,0,255,255)`、`clear A→绑 B→只清 B → A=(255,0,0,255) B=(0,255,0,255)` | **G0 已验收（14:3x 补）**：根因是收局线程不是 guest、不在内存 SVC 范围内，串行锁被真实内存 SVC 占用时 `begin` 立即 `EBUSY(16)`。新增 `s2a_android_guest_writers_begin_terminal`：非 guest 收尾线程在 1 s 预算内等待串行锁（等待时若有虚拟核则先放核），超时准确失败；成功仍不 end。真机直连（显式 `s2arm.graphics_mode direct`）加载中 Stop：旧候选 `ca57830a…` 3 次中 2 次 `_exit(125)` errno=16；新候选 `59f6674a…`/`1416715c…` 3/3 `_exit(0)`，其中实际等待 85 ms（早一候选）与 94 ms（最终候选）各一次、收尾 0.168–0.312 s，随后 `frame queue finish rc=0`、`session destroy … record=0(unknown 0) clear=0(unknown 0) upload=0(unknown 0)`。失败局（注入提交/present 失败）仍按产品策略 abort/退出，资源随进程终止，不伪造完成 |

F0.9 通过才标记 §8.5.2 的 **G0 已验收**，F0.1 通过只更新 F0.1。
生产顺序联合用例必须包括 draw 红→clear 蓝→读回蓝、clear A→绑 B→只改 B，以及已有提前提交前缀；主机模拟覆盖调用/生命周期，真机 GPU 用例覆盖真实顺序与输出，二者分别报告。

#### 8.0.2 F1/F2：view 与清理分别改、分别验

以下正常生产路径修改在 G0 通过后推进；可以提前用隔离微例核枚举和预期，但不能把隔离结果说成游戏已正确。（G0 已于 2026-10-27 14:3x 验收，以下按编号逐项实施。）

| 编号 / 前置 | 本次范围 | 独立期望和通过条件 |
|---|---|---|
| **F1.1 采样通道映射** / G0 | 只接 `set_swizzle` 覆盖判断、共享 NVN→Vulkan 分量转换和 cache key；view 的四字节数组不能按 texture 的 3-bit packed 字段解码。采样 view 覆盖 builder 映射，再按实际格式转换组合；不同时改底图上传/格式解码/颜色空间 | 微例输入 `R8_UNORM=0x20`，view `(ONE,ONE,ONE,R)`，输出到 `RGBA8_UNORM` 为 `(255,255,255,32)`；该微例用确定的采样坐标和过滤、无混合/alpha test/颜色空间转换，避免测到别的状态。另验无 view、默认 view、显式 identity、view 与 builder 不同、ZERO/ONE；非法枚举准确失败，不退回 identity |
| **F1.2 view 在途引用** / F1.1 | 只补 view 条目的引用/代际及 LRU 退休，沿用 F0 完成边界；底图 pin 不算其全部 view 已保活 | 同一录制批次建立超过 view 缓存容量的不同 view；可安全保留则每笔输出均正确，否则准确失败。录制或在途 view 不被提前 destroy；完成后可回收且仅销毁一次；GPU 写入后换 view 仍读到 GPU 内容 |
| **F1.3 一个已触发的 view 缺口** / F1.2 | 依据真实请求在 mip/层、格式或 depth/stencil aspect 中只选一个缺口，记录输入、NVN 合同和 Vulkan 合法性，再改其 producer→consumer | 选定子资源读回正确，其他 mip/层哨兵保留，不为换 view 重建已有 GPU 内容；未触发或无合法性证明的配置保留 Unsupported。完成一类不标全部 view/附件能力完成 |
| **F2.1 已有清理边界回归** / G0 | 复用现有 scissor、子资源和部分模板算法，仅补失败用例实际暴露的缺口；不重新实现整套 clear | stencil 原 `0xAA`、清 `0x55`：mask `0x01` 得 `0xAB`，mask `0x0F` 得 `0xA5`；depth 与未选 scissor/mip/layer 保留。清后无 draw、清 A→绑 B 通过，失败/timeout 依 F0.4 处理 |
| **F2.2 部分颜色通道** / F2.1 | 只补颜色 write mask 路径，格式覆盖和 S1 入队不在本次范围 | RGBA8 旧 `(255,0,255,255)`、清 `(0,255,0,0)`、仅 RG 掩码，结果 `(0,255,255,255)`；全 mask、零 mask、局部 scissor 各有独立预期；helper 不污染后续游戏状态 |
| **F2.3 附件格式覆盖** / F2.2、对应 view 合法性已证明 | 只接当前已触发且合法的附件格式覆盖与 cache/pass 身份，不能默认所有同字节数格式均可互换 | 独立微例验证覆写格式与原 view 的预期、错误格式准确拒绝；正常路径真正消费覆盖，而非日志后使用 base 格式。未实现时仍准确拒绝且保持本项待完成 |

**F1/F2 执行状态（2026-10-27，直连候选 `1416715c…`；只记实际覆盖）**

微例在 `1416715c…` 的同源 texcache/clear 代码上执行；最终候选相对微例候选只追加“附件视图选中 mip 时 framebuffer 用该 mip 尺寸”的 draw 路径修正，并在最终候选上复跑直连标题/过场帧、正常 Stop 与加载中 Stop 3 局。真机 `nvn_vk_probes.sh` 12/12 全过（新增 `nvn_vk_texview_probe`；`nvn_vk_session_probe` 补链接真实 `vk_record`/`vk_clear` retirement 入口，只为本 probe 不创建的 swapchain/present 提供两个不会被调用的链接桩）。

| 编号 | 代码已改 | 针对性验证（真机 GPU / 生产路径） | 结论 |
|---|---|---|---|
| F1.1 | `nvn_vk_texcache.c`：`view_t.swz[4]` 按四个独立 NVN 枚举（0..5）解码，不能按 builder 的 3-bit packed 字段读；view 设置 swizzle 时覆盖 builder 映射，再交给 Vulkan 按实际格式组合；非法枚举/非法 builder 分量明确失败，不退回 identity；通道映射并入 view 缓存键 | `nvn_vk_texview_test`（Adreno 730 真机，固定 (0.5,0.5)、NEAREST/CLAMP、RGBA8 输出）：R8_UNORM=0x20 无 view/空 view/显式 identity → (32,0,0,255)；view `(ONE,ONE,ONE,R)` → **(255,255,255,32)**；builder `a=R` 默认视图 → (32,0,0,32)，同图 view 覆盖 builder → (255,255,255,32)；`(ZERO,ONE,ONE,R)` → (0,255,255,32)；view/builder 枚举 6 均被拒并写 `valid 0..5` | 代码/真机微例通过；真实游戏本样本只采到 builder 恒等（0xB1A）、无注册 view，游戏内 view swizzle 未触发 |
| F1.2 | `struct nvn_vk_tex_view.pins`、`nvn_vk_texcache_pin_view/unpin_view`、视图缓存诊断计数；LRU 只回收 pins==0，全部在途时准确失败；`release`/`drop_tex` 遇到在途 view 保留不销毁；draw 对采样 view 与附件 view 在 present_done 前 pin | `nvn_vk_texview_test`（`debug.s2a.view_max=3`，2 个附加槽）：A/B 各建一次并 pin，第三个 view 被拒 `in-flight`；unpin A 后新 view 回收其槽并采样正确，B 仍正确；`evicted`/`pinned_full_rejects` 计数增加；真实 GPU 把底图清成蓝色后 `mark_written`，换 view 仍采到 (0,0,255,255)（没有用 CPU 镜像重建） | 代码/真机微例通过；真实游戏加载/过场 3 局无 view 保活错误 |
| F1.3 | 选定缺口：**颜色附件的视图子资源（mip/层）**。producer 是 `p_set_rt.cview`（`vk_record` 暂存），consumer 是 `vk_clear` 与 `nvn_vk_first_draw` 的附件视图；新增 `nvn_vk_texcache_attachment_view`，附件必须单 mip/单层，否则准确 Unsupported；不为换 view 重建图像 | `vk_record_test`（Adreno 730）：2 mip × 2 层 RGBA8，先把 mip0/layer0 清绿、mip1/layer1 清蓝，再只把 mip1/layer1 清红；读回 mip1/layer1=(255,0,0,255)、**mip0/layer0=(0,255,0,255) 哨兵保留**；深度 mip1/layer1 清除同样保留 mip0/layer0=0.9（既有用例） | 选定子资源/微例通过；真实游戏诊断未出现 `cview`（“first real colour attachment view” 未打印），游戏内触发未验；多 mip/多层附件仍明确拒绝 |
| F2.1 | 复用既有 scissor/子资源/部分模板算法，仅补回归；不变更清理算法 | `vk_record_test`：stencil 0xAA + 清值 0x55，mask 0x01 → **0xAB**、mask 0x0F → **0xA5**，深度 0.25 保留；既有 case 继续通过：只清深度保 stencil、只清 stencil 保深度、部分 stencil 0x0F→0x3F、scissor 外保留、深度视图 mip1/layer1 不清 mip0/layer0 | 代码/真机微例通过 |
| F2.2 | `vk_clear` 新增颜色写掩码：0 = NOOP，0xF = 原 `vkCmdClearAttachments`，其余用 push-constant 全屏三角形 + `VkColorWriteMask`；整数附件的部分掩码明确拒绝；管线按格式+掩码缓存；`vk_record` 不再拒绝部分掩码并传递真实 mask | `vk_record_test`：RGBA8 旧 (255,0,255,255)、清 (0,255,0,0)、mask 0x3 → **(0,255,255,255)**；全掩码 → (10,20,30,40)；零掩码 → 像素不变；局部 scissor + 部分掩码：区域内 RG 变、区域外保留、B/A 不变；helper 不写 guest 状态，后续 draw/clear 用例继续通过 | 代码/真机微例通过 |
| F2.3 | 颜色图像按兼容类开启 `MUTABLE_FORMAT`；新增附件视图格式覆盖（同类 8 位颜色），`VkFormat*` 返回真实覆写格式；`vk_record` 清除路径使用覆写格式，不同兼容类/深度模板覆盖准确拒绝；draw 的 pass/framebuffer/pipeline key 使用附件视图格式 | `nvn_vk_texview_test`：RGBA8_SRGB 底图申请 UNORM 附件视图成功且返回 `VK_FORMAT_R8G8B8A8_UNORM`，RGBA16F 覆盖被拒（同类检查）；深度覆盖被拒（无 mutable depth 路径）。`vk_record_test`：SRGB 底图 + UNORM 视图清 0.5 → **128**（base SRGB 会编码成 188），不同兼容类覆盖 `UNSUPPORTED` | 清除/视图微例通过；draw 路径已消费附件视图与格式，真实游戏本样本未触发 `cview.set_format`，游戏内 draw 覆盖未验 |

**历史观察（2026-10-27 16:0x）**：角色菜单武器缺失、加载切换一帧竖条纹。真机日志同一进程多条
`direct shader survey: <id> 现编失败 stage=4 code=512/768/1024 ctl=2128 rc=2` 与
`【红】直连补编：统一生产链待接（compile_fn 请求构造未实现，未写任何产物）`。对应程序和 draw 被跳过时，
新 RT 的未定义内容会外露（竖条纹），文字/UI 因其他 shader 成功仍清晰；generic 编译器可正常产出。根因指向
统一编译器覆盖/直连补编，不是 view/clear/颜色空间的游戏特例；下一步是按失败 stage/code 补编译或实现补编请求，
该时点尚未完成 F4 生产链；其后 F4 已有交付，不能再按这些旧日志认定“compile_fn 未接”。人物/转场的同候选画面仍按 §8.4 验收。详见 [坑记录](../../docs/坑记录.md) 10-27 条。

**直连 present 颜色空间修复（F1/F2 后同候选，2026-10-27 15:1x）**

- 现象：显式 `s2arm.graphics_mode direct` 的标题/开场明显发白、发青，黑位抬高；同一屏幕切 `generic` 后是正常的深色。两个模式都是真实游戏上屏，不是截图/叠加层差异。
- 根因：游戏最终 RT 是 `R8G8B8A8_UNORM`（`present image … src_fmt=37`），直连 swapchain 先选到 `R8G8B8A8_SRGB`（`swapchain create … fmt=43`）。`vkCmdBlitImage` 从 UNORM 源写 SRGB 目标时做线性→sRGB 再编码，把本来已是显示编码的 RT 字节二次抬亮。通用模式（Ryujinx `Window.cs`）优先 `B8G8R8A8_UNORM` + `PaceSrgbNonlinear`，同一批字节只由合成器按 sRGB 解释，不做二次编码。
- 修法：`nvn_vk_pick_surface_format` 先选 UNORM（R8/B8G8R8A8_UNORM，保留 SRGB_NONLINEAR color space），只有 surface 完全不提供 UNORM 时才退回 SRGB 并打警告；swapchain 创建时记录 `fmt/colorspace`，present 记录 `src_fmt`，便于核对二者一致。surface 单测同步断言 UNORM 回退。
- 实测（同一标题屏，2712×1220）：修前 direct 均值 RGB `(55.2,91.1,91.5)`、p50 `(56,108,108)`；修后 direct `(22.4,43.0,43.3)`、p50 `(11,40,42)`；generic `(24.4,47.2,47.5)`、p50 `(14,44,46)`。修后与通用模式差 ≤4/255（剩余差异来自标题动画相位），修前差约 43–64。修后主菜单/标题为正常深色，正常 Stop 仍 `_exit(0)`、结算全 0，`nvn_vk_probes.sh` 12/12 通过。

**画面检查点**：F0.9、F1.1、F1.2、F2.1–F2.3 各自完成后按实际影响做一次短回归，不必等所有功能齐全；F1.3 或其他真实功能缺口按现象选择，避免无目标扩面。人物黑色、HUD 圆球和转场分别记是否复现；仍错就捕获该 draw 的实际输入/所选 view/最近生产者和输出，不能宣称基础修补必然解决三者。禁止用跳 draw、改 alpha、关深度或删指令制造通过。

#### 8.0.3 F3–F5：后续按单一产物展开

这些是后续任务清单，不允许把一行多个步骤合成一个大改。正式实施某一编号前，按前两表的格式补齐该编号的“真实入口、修改范围、独立期望和失败断言”，再开始代码变更；存在准确实现和证据的编号直接核验。

| 任务组 | 独立交付顺序及开始条件 |
|---|---|
| **F3 查询 / MRT** | G0 后先做 **F3.1**：删除固定 samples-passed 成功值，未支持时准确失败并证明没有伪造回写；这不算查询功能完成。**F3.2** 单独接真实 query 的 reset/计数/report/完成后回写，覆盖零、非零和 reset，才可标功能通过。**F3.3** 仅在路线真实使用 MRT 时接颜色 Location/空洞/逐槽状态，用 Location 0/2、槽 1 空洞的独立输出验证；MRT 未触发不妨碍其他独立任务，但仍是产品待办 |
| **F4 编译输入 / 缓存 / worker** | **F4.1** 只把编译诊断写入改到私有目录，比较 revision 文件清单/摘要无变化；这是独立缺陷，F0 等设备证据时可先处理。**F4.2** 核源码与事实的自持快照及 MissingFact；**F4.3** 规范化完整身份和碰撞核验，同输入 CLI/AOT 的 SPIR-V/反射对拍；**F4.4** 依 F4.1–F4.3 和 G0 只接有界 worker，测试同请求去重、保序等待、Stop/代际/迟到结果。F4.4 不同时增加磁盘缓存或管线预热，首遇依赖无提前量时仍可能等待 |
| **F5 生产链 / 交付验收** | 另拆 **F5.1** 私有缓存原子写、损坏拒绝和次局命中；**F5.2** 抽取→批编→库/描述符生成；**F5.3** 运行时离线库命中与故意漏项补编；**F5.4** 故障下局 AUTO generic 同存档及正常 Stop；**F5.5** 两轨真实游戏 IME。F5.1/F5.2 依 F4.2/F4.3 的稳定数据与身份合同，可先于 worker 独立交付；F5.3 需 F5.1/F5.2，F5.4 需 G0 与冻结可运行候选，F5.5 需真实触发游戏输入。性能 S1/D1/D2、完整管线键/退休、driver cache、配方预热各独立验收，第二款和其他前端按 §9 各自验证，不包进上述编号 |

<a id="android-f4-implementation-research"></a>

以下调研发生在 F4 实施前，“F4.1–F4.4 仍待交付”等只描述基线 `48c95ade`。实施后的状态读本节各执行状态表与 [§7.0](#android-current-progress)；原始反例和验证范围保留如下。调研中的 F4.4 待验指当时基线；其后交付见本节执行状态与 §7.0。有界需求、执行包保序等待、Stop/代际和迟到结果合同继续沿用，不因调研折叠而省略。

<details>
<summary>展开 F4 实施前调研：原调用链、映射/身份反例、worker 合同与当时验证</summary>

**F4 实施调研（2026-10-27，源码基线 `48c95ade`；未实施 F4 运行时代码）**

沿用 `s2a-direct-compile-v1 → DirectCompileNative → DirectShaderCompiler → s2a-direct-program-v1`，按 **F4.1 → F4.2 → F4.3 → F4.4** 分别交付。F3.1/F3.2 已有证据，F3.3 未触发不阻塞这些独立项；F3 的 timestamp、Report 同步成本仍另验。下面给出真实入口、修改范围和独立期望，不是新增通过结论。

**F4.1：先使编译诊断不写安装 revision。**

- 真实入口：`provider_vk.c:activate` 将 revision 下 `shaders/vulkan/direct` 放入 `S2A_SHADER_DIR`；adapter 把它交给 `nvk_draw_builder`，`nvn_vk_draw.c:nvk_program_compile` 向其中写 `<ident>.compile-request.json`。另有 `debug.s2a.dump_fail` 请求/结果导出。不能把只读离线输入目录继续当现场诊断输出目录。
- 修改范围：现有 provider/adapter 的诊断目录传递、draw 的诊断写入及对应原生夹具。由现有私有 `state_dir` 派生本局诊断目录，写失败只记录诊断未保存，不改变正确的内存编译结果。核对 `shader_survey.c` 的旧 stub 调用、剥离归档和改名接点，不能遗漏其 revision 写入；§3.1 旧链退役超出本项的部分单列，不恢复旧产物准入。
- 独立期望：同一 revision 在启动/补编/停止前后的**文件路径清单、长度、逐文件 SHA-256 完全相同**，不能只比较 manifest。把诊断目录设为不可写，合法编译仍返回相同正确内存结果；输出路径不能回落到 revision。

**F4.2：先交源生命周期，再接真实编译事实。** 两个交付分别验证，都归 F4.2。

- 真实入口：`source_store.c:get*` 解锁后返回内部借用指针，下次 keep/淘汰/clear 可释放；没有按 BoundProgram/Draw/任务引用保活。`hle_nvn.c` 在 Bind 仍重读 guest control，捕获固定 `0x880`，但 `keys_hash` 已识别较短自描述 control。`nvk_program_compile` 按短 key 取源、按掩码顺序组阶段；`compile_request.c` 固定输出空 `textures[]`。Draw 已有逐 stage 纹理句柄、UBO 与附件 view，编译生产者尚未完整消费。
- 源修改范围：`runtime/direct/source_store.*`、必要的共享 `hle_nvn.c` 输入钩子及 record/draw 消费者；同步弱声明、头文件与测试。按 §5.5 保存合法 code、自描述 control、完整 C1、已验证阶段和源/池代际；代码未映射时保留有界待解析引用，control 必须当场自持。持有者引用释放前不得淘汰，C1 也计入预算；不靠扩大源表代替所有权。阶段不能按数组位置猜，也不能把未知图形头一律当 compute。
- 事实修改范围：`compile_request.*`、当前 record/draw/adapter/provider。从实际绑定和 view 解出纹理类型、格式、数组及被查询的 driver/C1 事实；区分未知、未绑定与合法零值。`constantBufferUse` 的 `0x1F` 合同不足时准确拒绝，不截断高槽，不按某游戏补默认 2D。只有真正必需的事实缺失时准确 MissingFact，未实现语义准确 Unsupported；打印 gaps 不等于事实已补齐。
- 独立期望：SetShaders 后改原 code/control，Bind/Draw 仍读原快照；Bind 后 Finalize、同址重建、并发 keep/源表满/clear 时，已持引用的源不变，末个引用释放后预算回落。覆盖短 control、FS/VS 倒序、分开绑定、未知阶段、C1 边界及被查询纹理事实缺失。共享前端改动同时核 Apple 原有路径；不将当前“源内存改写”单测外推为并发/生命周期已通过。

**F4.3：规范化完整输入，并在实际命中分支和接收器验证。**

- 真实入口：`nvn_vk_draw.c:nvk_request_signature` 使用短 stage key 与 64-bit 签名，`nvk_program_for_draw` 命中后不比较完整规范输入；`request_sha` 仅在 miss 后生成用于统计。主机反例已确认：FS `ubo_use` 0→1，序列化请求不同，生产签名仍相同。`nvn_vk_first_draw.c:parse_program` 尚未核完整 transport/contentHash/identity/dependencies，固定 binding 容量也须补超限拒绝；给 envelope 算 SHA 不等于已核验其 contentHash。
- 修改范围：F4.2 稳定输入的单一身份生成接点、当前 program cache 的真实查找分支、内存结果接收器和既有 CLI/AOT 测试。code/control/C1、stage、真实编译事实、ABI/parser/profile/closure 纳入内容身份；session/generation/requestId 只作传输或本局有效性校验。规范字段顺序、显式长度、LE/浮点位；使用完整 SHA-256 作索引，命中还核完整规范输入与实际查询依赖。命中热路径留 native，不每笔 JSON 序列化/跨 AOT。
- 接收边界：核内容摘要、传输身份、阶段/入口/目标环境、完整反射与资源来源、SupportBuffer 布局；当前消费者能力之外的数组/绑定等准确拒绝，不能裁掉反射后继续画。保留编译器原始错误码/字段诊断；目前 NativeAOT 会把 MissingFact 等合并为 Argument，单看 rc 无法区分。
- 独立期望：同短 key 不同源、同代码不同 C1/纹理类型/整数附件/UBO 使用掩码/profile/closure 不误命中；注入相同查找哈希仍能区分不同规范输入。普通 uniform 数值变化不无故重编；传输身份变化不改变内容身份。坏 contentHash、旧会话结果、反射缺项、重复或超限绑定必须拒绝且不发布缓存。相同请求 CLI/AOT 的规范 SPIR-V、反射、依赖逐字节一致。

**F4.4：接一个有界需求 worker，同时交付当前执行包挂起/恢复。**

- 真实入口：`mtl_vk_adapter.c:exec_guest` 持递归 `g_mu` 跑完整回放/现编；Draw 回调只有成功/失败，`s2a_record_result` 没有挂起恢复责任，shim 把非零结果当错误。provider 的 `poll` 是空实现，`request_stop` 同步关闭 adapter，`destroy` 直接 free context。只把 compile 调用放入 pthread 不能解决持锁等待、命令越过及迟到结果访问旧上下文。
- 修改范围：既有 provider/adapter/record/shim 的等待/恢复、编译调用与会话收尾，不另造 executor/device/queue。定义待编执行包的自有内容、源/资源租约、队列执行序号和恢复点；挂起期间释放 guest/queue/VM 锁，接通 owner 的 poll **及实际控制调用者**处理 Stop/窗口，同队列后续工作不能越过，当前 draw 只恢复一次。限制排队条数、快照总字节和结果预算，需求按完整 ProgramKey 去重；首版一个需求槽，预热保持关闭。
- worker 所有权：从明确的本局 context 取已绑定编译入口，不用 `bound_compile_any` 推断本局归属；emit 返回前复制结果，owner 核身份后发布。按实施契约 §4.3 完成同 device 的主机侧管线创建与转交，worker 不提交 queue、不直接修改 owner 全局缓存；仅接 CPU 编译线程只能标部分完成。Stop 取消未开始任务，在途调用返回前保留所需上下文/对象，迟到结果按 session/generation 拒绝；控制墓碑/回调登记按合同保活，不 dlclose AOT。
- 独立期望：用可控编译屏障验证同请求只编一次、不同请求不串、容量满准确失败、挂起 draw 前后哨兵顺序不变；挂起期间确实处理到 Stop/窗口事件。覆盖排队取消、编译中 Stop、generation 变化、迟到成功/失败/emit、正常 Stop 后重启。统一总 deadline，核对已有停止/退休预算；不能新增无界 join 或每次 poll 重置超时，也不能请求停止后立即销毁 worker 仍可能使用的对象。

**可复用接点与验证边界**

- 统一编译器/静态 accessor 已有严格解析、实际查询依赖、MissingFact、contentHash 与 transport/content 分离；`graphics/tools/direct/tests/compiler/Program.cs` 已覆盖同输入一致、transport 不影响内容、整数附件变体和缺事实。复用核心，不另维护手机/桌面两套编译器；managed 单测不能替代 native 的源生命周期、真实 cache-hit 和结果接收验证。
- `direct_source_store_test.c`、`direct_compile_request_test.c` 由 `direct_c1_probe.sh` 调用，可扩充宿主/ARM64 回归；`direct_c2_aot_probe.sh` 已比较同一合成请求 CLI/AOT 的完整输出，F4.3 再加 transport 不同但 content 相同、真实纹理事实变体。该脚本会启动诊断 APK，执行前核目标设备，不把 selftest 算真实游戏通过。
- iOS NVN `graphics/nvn/host/dsh_miss.inc` 可借缺项登记/按需补编，不能搬裸 code 指针或短键身份。通用 Metal `graphics/metal/gal_prog.m` 的 `g_jobs/xjob_start/prog_finalize` 可借在途去重、有界槽和首用消费；其首用线程就地编译会阻塞，Android 仍按 owner 控制轮询合同实现。旧引擎只作历史参考，不接回 XGS/NVKP。
- 官方资料核对：[NativeAOT 原生库](https://learn.microsoft.com/en-us/dotnet/core/deploying/native-aot/libraries) 不支持 dlclose/FreeLibrary 卸载；[Vulkan 管线缓存](https://docs.vulkan.org/spec/latest/chapters/pipelines.html) 要按实际创建/合并/读取操作及 flags 核同步，不能一概认定共享缓存天然安全或一概持 queue 锁。F4 不新增 driver cache；涉及已有管线任务仍要遵守同步和设备保活。

**本轮实际验证**：Linux x86_64 / GCC 16.2.1，`48c95ade` 的现有 source-store/request 宿主测试各 1 次通过；从生产源码原样提取签名 helper，调用真实请求生产者做单变量反例：FS 常量缓冲使用掩码 0→1，请求字节不同、签名相同（`a63653ea25a3f33a`），详见[坑记录](../../docs/坑记录.md)。这是缺口证据，未修复、未跑真机、未重编 APK；F4.1–F4.4 仍待交付。私有磁盘持久化/次局命中归 F5.1，离线批编归 F5.2，完整管线键/退休、driver cache 与预热继续独立验收。各项真机短回归使用同候选、显式 direct 和本文 TouchPad 输入流程，不能用 generic/标题帧或手柄覆盖层变化代替真实绘制。

</details>

**F3 执行状态（2026-10-27，直连候选 `fea8d5cd…`；只记实际覆盖）**

| 编号 | 代码已改 | 针对性验证（真机 GPU / 生产路线） | 结论 |
|---|---|---|---|
| F3.1 | `vk_record.c` 的 `OP_REPORT_COUNTER(SAMPLES_PASSED)` 不再把 `0xFFFFFFFF` 当样本数写进 guest；`OP_RESET_COUNTER(SAMPLES_PASSED)` 不再接受没有查询状态的“空复位”。两者在没有真实 query 时返回 `S2A_RECORD_UNSUPPORTED`，一个字节都不写 | `vk_record_test`（Adreno 730，`-O2 -Werror`）：`samples-passed reset: accurate failure (no query state), op=36`；`samples-passed report: accurate failure, guest counter untouched, later op not executed`；`vk-record: ok` | 代码/真机微例通过；只证明去掉了伪造成功值，不标查询功能完成 |
| F3.2 | 新增 `nvn_vk_query.c/h`：真实 `VK_QUERY_TYPE_OCCLUSION` 池（8192 槽，要求并启用 `occlusionQueryPrecise`，开查询用 `PRECISE_BIT`）；每 render pass 内连续计数绘制为一段，Report/Reset 处切段；Report 汇总自上次 Reset 的全部段且不清零；Report 先 `pass_break(1)` 取得完成证明，再 `vkGetQueryPoolResults(64_BIT|WAIT)` 写回 `NVNcounterData.counter`；结果取走后下一命令缓冲整池 reset 再复用；接入 `first_draw` 的 pass begin/close、flush、release_device 和 `vk_record` 的 reset/report/静态 draw 路径 | `vk_record_test`（真机）：第一次 Reset 前 report 写 `0`；8×8 全屏三角形 `64`；无新绘制再 report 仍 `64`；再画后 `128`；reset 后 `0`；count=0 绘制 `0`；`64 → reset → 64 → reset → 0`（旧值不漏）；部分掩码辅助清屏 `0`（辅助三角形不计数）；跨两个 render pass `128`；连续两次 report `64,128`；`counterData.timestamp` 8 字节保持哨兵（未写）。生产（暗黑3，显式 direct，APK `fea8d5cd…`）：世界内 `resets=4553 reports=4553 segments=21679 slots=21679 total_samples=2119492 zero=38 before_reset=0 fails=0`，首个非零 `samples=851` 与零结果同时出现；Stop 后 `frame queue finish rc=0`、`retained settlement record=0(unknown 0) …`、device 销毁、`direct session closed: stop=0 destroy=0` | 代码/真机微例/生产路线通过（功能）；限制见下，不并入通过范围 |
| F3.3 | **未实现（本样本路线未触发）**：只新增绘制诊断 `draw rt histogram`，统计真实 `rt_count` 与槽 1..n 是否绑定；槽 1..n 绑真实纹理仍由现有代码明确拒绝 | 生产（同一候选，505,856 笔 draw，含菜单/加载/世界）：`count1=505856 count2=0 count3=0 count4+=0 slot>0-bound=0 with-hole=0`，没有 `multi-colour render target` 拒绝 | 按 §8.0.3 的开工条件保持产品待办；不实现未触发的 MRT 语义，也不把“只画槽 0”算支持 |

**F3.2 已知限制（不并入通过范围）**

- `NVNcounterData.timestamp`（+8）不写：§6.1.3 的 GPU/guest 时钟域合同仍未定义并验证；只写真实可证的 `counter`，不用 CPU 时钟冒充。微例用哨兵断言这 8 字节未被改写。
- Report 在 `g_mu` 内做 `pass_break(1)`（提交 + 等 fence）再读结果，单次约 1.75–2.0 ms；生产世界内 13 次/frame 合计约 22.8–25.9 ms/frame（同一局 `gap=142.7–185.4 ms`，主要耗时仍是 draw 69.9–97.4 ms/frame 与 ClearColor 27.1–31.6 ms/frame）。这是“Report 后没有新绘制也要能回写”的代价，属 §8.5 的独立性能项，不能把同步实现说成最终性能。
- `debug.s2a.trace`/probe 的逐笔诊断路径不建 render pass：计数开启后该路径的 draw 会被明确拒绝（不能“少计数还画”），不影响正常合并路径。
- 两次 resolve 之间最多 8192 段；耗尽时准确失败。生产 `slots=21679` 是跨周期累计数，单周期未接近上限。
- 本样本只覆盖暗黑3 的标题/过场/主菜单/世界，未复验人物菜单/物品栏画面。
- 池销毁前若仍有未证明完成的状态（打开的段/已录制 query/pending 报告），保留池随设备回收、不 `vkDestroyQueryPool`；`release_device` 同时清掉会话首错与全部计数，同一进程重建设备不从上一局失败状态继续。第一次 Reset 之前的 Report 也真正写 0 并清 pending（不能成功返回却留旧值）。
- Report 的同步等待沿用帧队列 5 s 完成预算，而收尾 writer 等待预算 1 s、watchdog 1.5 s；GPU 真的卡死超过 1 s 时 Stop 可能以 125/124 结束。正常 Report 约 2 ms，本轮未触发；统一收尾 deadline 属后续独立项。
- guest 输出地址仍由共享记录的 memory 入口直接写（与 event/fence/copy 相同）；非法地址是 guest 访存故障，本项没有新增地址校验/权限查询。

**F4.4 执行状态（2026-10-27，有界需求编译 worker；直连候选 `dd480c1b…`）**

| 项 | 代码已改 | 针对性验证 | 结论 |
|---|---|---|---|
| worker | 新增 `runtime/direct/compile_worker.{c,h}`：单槽、按请求 SHA-256 去重、不同请求排队（容量 1）、等待超时/放弃后丢弃迟到结果、Stop 唤醒等待者并 join、可重启；线程栈 64 MiB（默认 1 MiB 会在复杂 shader 上把进程打爆） | 宿主 `direct_compile_worker_test`（CTest `android_direct_compile_worker`）与 ARM64 C1 探针：4 个同 sha 并发只编译 1 次、不同请求串行、pause/resume 成对、Stop 让等待者准确失败且可重启、超时后迟到结果不复用、编译失败原样带回 | 通过 |
| 执行包挂起/恢复 | `mtl_vk_adapter.c` 增加 `g_exec_busy` 独占（其他 guest 线程 exec 排队）+ `s2a_vk_adapter_exec_pause/resume`（仅当前执行包线程可交还/重取 `g_mu`）+ `g_cancel` + 暂停窗口内的 present 计数；`nvn_vk_draw.c` 的 miss 编译改走 worker，等待期间释放 `g_mu`，无 worker 时退回同步编译 | 真机：`adapter: compile worker started`；标题/菜单/世界 `worker compile ok`（32/58/87 条），0 `direct compile rejected`、0 `program not available`；世界 1853 commands/frame、present ~5.7 ms；Stop 在首条 worker 编译后立即发出仍 `finish rc=0`（0.36 s 完成）、结算全 0、`stop=0 destroy=0`；`owner presented during pause` 计数 0（见边界） | 通过（见边界） |

**F4.4 边界**：① 等待时释放 `g_mu` 与宿主 pause/resume 用例证明接缝存在；真机 `owner presented during pause` 为 0，未证明暂停窗口内实际推进 present/窗口退休。Stop 在编译爆发后立即发出 0.36 s 完成，只覆盖该短编译候选；② `5ac9696f` 把 Stop 改成有界（`s2a_compile_worker_stop_bounded`，adapter 用 1 s；未退出就如实报错、迟到结果丢弃、未退出前拒绝重启、下一次 Stop 回收），但 managed 编译不可中断，**长编译/卡住时的真机收尾预算仍未验证**；未退出时编译入口/上下文保留到进程结束（AOT 不卸载），不能据此宣布长编译也能安全收尾；③ 其他 guest 线程在暂停期间排队，不与执行包交错；④ `provider.poll` 已不再是空实现（返回真实在途 PENDING/OK/STOPPED，单次最多一个 10 ms 控制片），但 **managed 侧没有调用者**，draw 仍自己等待编译结果，执行包的挂起/恢复与“同队列后续不越过该 draw”尚未交付；driver pipeline 创建仍在 draw 线程，实施契约 §4.3 的完整调度待交付；⑤ 大栈是实测必需：1 MiB 默认栈在 178 KB 结果那次编译时进程直接死亡（见坑记录），64 MiB 后同场景世界存活。表中“通过”仅指实际 CPU 编译子集，不等于整个首遇调度完成。

**F4.2B 执行状态（2026-10-27，真实纹理事实；直连候选 `223fbd96…`；F4.2 两次交付均已有代码与验证）**

| 项 | 代码已改 | 针对性验证 | 结论 |
|---|---|---|---|
| 事实编码 | 新增 `runtime/direct/texture_facts.{c,h}`：NVN 颜色格式 + 非 buffer/rect 目标 → 编译器 `TextureFormat/SamplerType/isBuffer/normalized/arrayLength`；未映射一律 -1，不猜默认 2D/UNORM。**编译器 `TextureFormat` 只有 39 个名字**（`Ryujinx.Graphics.Shader.TextureFormat`），Bc*/sRGB/565/4444/3 通道/深度都不在里面，写进去会让整份请求 `MISSING_FACT` 被拒（实测 `textures[0].format is not a known concrete TextureFormat` 直接跳掉一笔 draw），所以这些格式不输出事实 | 宿主 `direct_texture_facts_test`（CTest `android_direct_texture_facts`）与 ARM64 C1 探针：39 个枚举名全覆盖、深度/BC/sRGB/buffer/rect/UI2F 一律拒绝、cube-array 层数非 6 倍数拒绝 | 通过 |
| 请求输出 | `s2a_compile_request_input` 增加 `textures[64]`；`compile_request.c` 按 `(stage, handle=8+2*slot, cbufSlot=-1)` 输出真实事实，没有事实时保留 gap | `direct_compile_request_test`（宿主+ARM64）断言 JSON 的四元组/布尔/数组长度与“有事实时无 gap” | 通过 |
| 生产接线 | `mtl_vk_adapter.c` 新增只读 `s2a_vk_adapter_tex_facts`（读注册表，不建视图/不上传）；`nvn_vk_draw.c` 在 miss 时收集一次事实，**同一份**同时喂给 F4.3 内容身份与请求体（纹理事实已纳入 `input_identity`，逐字段反例覆盖） | 真机暗黑3：175 次编译、每次 21–24 条事实、0 次 `direct compile rejected`、0 次 `program not available`；世界画面与 F4.3 一致；Stop 干净 | 通过 |

**F4.2B 边界**：只覆盖编译器枚举能表达的颜色格式；BC1/3/7、sRGB、R5G6B5、R4G4B4A4、R8G8B8、深度/模板、buffer/rect、UI2F/I2F 不输出事实（这些纹理若被 shader 查询，编译器仍按 MISSING_FACT 失败，与空 `textures[]` 时一致，不是静默补默认）。`textureBufferLengths` 未产出（buffer 纹理未接）。本项没有改变“首笔编译仍同步等待”的事实，属 F4.4。

**F4.3 执行状态（2026-10-27，完整规范输入身份；直连候选 `24413aa9…`）**

| 项 | 代码已改 | 针对性验证 | 结论 |
|---|---|---|---|
| 规范输入 | 新增 `runtime/direct/input_identity.{c,h}`：固定顺序、显式长度、小端；覆盖 profile SHA-256、directABI、translator closure、阶段掩码/各阶段 key、`constantBufferUse`（6 槽）、纹理/采样器池容量、TF 与 graphicsState 全部字段；容量不足准确失败 | 宿主 `direct_input_identity_test`（CTest `android_direct_input_identity`）与 ARM64 C1 探针：逐字段改动编码都不同（含反例 `constantBufferUse` 0→1）、相同输入相同编码、NULL 与空串可区分 | 代码/宿主/ARM64 通过 |
| 查找与命中 | `nvk_program_for_draw` 改用“规范输入 + 完整 SHA-256 + 逐字节复核”命中；session/generation 仍只作本局有效性；删除旧 64 位签名与 `nvk_sig_*`；profile SHA-256 按 (session,generation) 缓存，不再逐笔哈希约 8 KB | 真机暗黑3（同候选，标题→世界）：735,744 次查找 / 199 次编译 / 0 程序不可用 / 0 源快照缺失；世界渲染与 F4.2A 一致；Stop `finish rc=0`、结算全 0、`stop=0 destroy=0` | 通过 |

**F4.3 边界**：编码覆盖请求生产者当前写出的全部内容字段（F4.2B 后含 `textures[]` 的 stage/handle/cbufSlot/samplerType/format/isBuffer/normalized/separate/arrayLength）；新增请求字段必须同时更新 `input_identity.c` 与 `direct_input_identity_test.c`（逐字段反例就是守卫）。传输身份（session/generation/requestId）不参与内容键。命中路径每笔编码约 394 B + SHA-256，不再序列化 JSON。真机本局 `debug.s2a.compile_shaders=1` 残留开启（上一局属性未复位），产生 3,324 条旧补编链红行；这些走诊断目录、不影响 draw（0 真实失败），本轮已把属性置回 0。

F4.2A 只记录该候选的源快照交付；其中“真实事实未做”已由上面的 F4.2B 后续交付接替，不是当前仍为空的声明。pending 补算等未触发分支的证据限制继续保留。

<details>
<summary>展开 F4.2A 源快照候选的原始验证与当时边界</summary>

**F4.2A 执行状态（2026-10-27，源快照生命周期；直连候选 `d235e9e4…`；F4.2 的“真实事实”半未做，不标 F4.2 完成）**

| 项 | 代码已改 | 针对性验证 | 结论 |
|---|---|---|---|
| 所有权/引用 | `source_store` 增加 pin/retired：`acquire/release` 跨步骤持有，引用中的条目不淘汰、`clear` 只标记 retired，最后一个 release 才回收；字节预算计入 c1；可淘汰条目全被引用时 `keep` 准确失败 | 宿主与 ARM64 `direct_source_store_test`：pin 期间 clear 后字节仍有效、被引用条目跳过字节淘汰、release 后预算回落、c1 计入 | 通过 |
| 自描述 control | `keep` 接受 0x760..0x880 的自描述长度（按 +0x20），过短准确拒绝；HLE 在 SetShaders/Bind 传真实长度。暗黑3 实测 `ctl=2128`（0x850）：旧代码固定抓 0x880，会多读 0x30 字节且与 key 覆盖的字节不一致 | 同上；真机 `draw 源快照 stage=0/1 … ctl=2128 complete=1` | 通过 |
| control 当场自持 | SetShaders 用弱钩子 `s2a_source_hold_pending` 保存 control；Bind 优先用它；key 缺失（code 当时未映射）时用当时 code + 自持 control 补算并写回 serial 表；已有完整快照时不再重读 guest control | 微例（pending 取回/按阶段/有界淘汰）；真机本局未触发补算分支（无 `key completed` 日志），两阶段快照均完整 | 钩子与分支已接，补算分支真机未触发（未验证） |
| 编译期引用 | `nvn_vk_draw.c` 的编译与 c1 拷贝按 key 持有引用，请求 JSON 建好后释放 | 真机世界 715k 次查找、0 次“源快照缺失”、0 失败；Stop 干净 | 通过 |

**F4.2A 边界**：真机只在暗黑3 标题/菜单/世界跑过，未复验人物菜单/物品栏；pending 补算分支无真机样本。F4.2 剩余的“真实编译事实”（`program.textures[]` 全空、纹理/格式/绑定事实、MissingFact）未实现，不能把本表当作 F4.2 完成。

</details>

**F4.1 执行状态（2026-10-27，直连候选 `5d47e03f…`；只记实际覆盖）**

| 项 | 代码已改 | 针对性验证 | 结论 |
|---|---|---|---|
| 诊断目录 | 新增 `runtime/direct/diag.{c,h}`：`<state_dir>/direct-diagnostics` 派生、安全文件名写入、目录清单摘要（name/size/SHA-256 再取 SHA-256）；provider activate 创建目录并设 `S2A_DIRECT_DIAG_DIR`，派生失败只告警、不回落 revision；`nvn_vk_draw.c` 的 compile-request 诊断与 `shader_survey.c` 的补编产物/剥离标记/旧 XGS 隔离全部改到该目录；`debug.s2a.diag_manifest=1` 时 activate/destroy 各打一行 revision 清单 | 宿主 `direct_diag_test`（CTest `android_direct_diag`）与 ARM64 C1 探针：目录恒在 state 下；写失败/不安全文件名准确拒绝；诊断写入前后 revision 清单（文件数/字节/摘要）完全一致，且清单能检出内容变化与新增文件 | 代码/宿主/ARM64 通过 |
| 真机路线 | 暗黑3 显式 direct，`debug.s2a.diag_manifest=1`：`direct activate: diagnostics directory …/direct-diagnostics`；activate manifest `files=1955 bytes=32463155 digest=7c1736…`，destroy manifest 同 `files/bytes/digest`；`已保存诊断 …/direct-diagnostics/…` 15 条，revision 路径诊断保存 0 条；Stop 后 finish rc=0、结算全 0、`direct session closed: stop=0 destroy=0` | 通过（安装 revision 逐文件不变） |

**F4.1 边界**：清单只覆盖 `shaders/vulkan/direct`（诊断写入的唯一目标），不对 17 GB romfs 做全量哈希；`debug.s2a.dump_fail` 仍是开发者显式给绝对路径的导出，不属于安装 revision；本项不改编译输入、身份或 worker。诊断仍按每次首次编译写一份 JSON（无轮转），属诊断目录容量问题、不是 revision 写入。

#### 8.0.4 完成口径与执行边界

每个编号分列“代码已改、针对性验证、真机路线”，只能对实际覆盖的范围标通过；状态写在本节和 §7.0，不新增交接文档。**准确 Unsupported 是错误处理正确，功能仍未实现；截图变好是现象，不能替代接口语义证明；某个 probe 通过不等于 G0 或真实游戏通过。** 提交标题和报告写实际小任务编号，不写“完成全部 F0/F4”。

接口变更同步头文件、弱声明、测试 fixture 和真实消费者，不留下失败后仍返回成功的旧调用。可复用 `bash android/tools/direct_c3_vk_probe.sh`、`bash android/tools/direct_c5_nvn_test.sh` 的相关用例，但要注明是否调用生产 owner；`nvn_vk_record_step_probe.sh` 的 stub 不能单独证明 G0。需要新的生产测试接点时，将最小测试接点和它覆盖的当前任务同批交付，不先造一整套通用测试框架。

冻结源码/构建输入、APK/资源 revision、实际模式和诊断开关后才作前后对照；设备测试未运行写未测。真实游戏长路线放在阶段检查点，不要求每个签名修改都重跑完整游戏；接口、像素和故障测试仍按本项风险执行。失败时保留该编号的首错，修当前项后继续；若外部条件缺失，准确记录所缺证据，不宣布通过、不越过依赖，也不重复请求已授权的常规操作。设备由当前使用方协调，避免多执行者同时安装、改属性或注入按键。


### 8.1 历史两小时交付目标及执行记录：完成首笔真实 GPU 绘制（2026-10-26）

首绘阶段的原计划与逐笔定位证据保留在下面；该两小时排期已结束。当前进入世界的范围见 §7.0，后续编译/生命周期任务按 §8.0，不重新执行本节的“下一步”。

<details>
<summary>展开 10-26 首绘计划与完整实验记录：ABI、视口、字形、APK/请求身份及未解释现象</summary>

**上一轮验收范围**：基线 `ca4634c8`。复核直接读取设备诊断域的原始请求（11,555 B，SHA-256 `e906f01e…`）
与结果（53,016 B，SHA-256 `e4bfaa20…`），主机 CLI 对同一请求复编与设备结果逐字节一致；请求生成/emit 复制、
源快照两个主机回归通过。上一轮“真实 Draw 调统一编译器并返回结果”目标完成，不代表输入语义全审通过、GPU 消费或首帧完成。
当前 `nvk_first_compile_request` 打印/dump 后释放结果，随后仍按短 key 查阶段文件并失败；这正是下一轮要替换的接缝。

**两小时主目标**：真实 Draw 的完整 program 结果直接进入内存消费者，按反射绑定真实资源，使用实际顶点/索引/实例参数，
在游戏真实目标纹理上完成首笔 GPU 绘制并取得完成证明；回放继续到下一条命令或准确的下一处缺口。争取继续到游戏窗口首帧，
但清屏、合成三角形、`VkShaderModule`/`VkPipeline` 创建成功不能替代真实 draw 验收。

| 时间预算 | 工作 | 本段验收 |
|---|---|---|
| 0–25 分钟 | 核对 profile 与实际绘制使用同一 device，复用已创建 owner；纠正状态来源，捕获 `nvnCommandBufferSetAlphaRef` 等已存在入口；只针对本链接缝修复，不另建后端 | 同一设备/会话身份贯穿编译与消费；初始值、真实绑定、未定义/未知状态分清；缺事实不能冒充零值 |
| 25–65 分钟 | 将完整 `s2a-direct-program-v1` 交给长度受限的内存消费者，核 transport、身份、contentHash、阶段、SPIR-V 摘要、supportLayout、bindings/来源及 dependencies；补齐 per-stage/per-slot 的资源快照 | 成功结果不再释放后另找文件；坏 hash、旧 generation、阶段错配被拒；能从真实对象追到 UBO、纹理/view、sampler 和顶点流 |
| 65–100 分钟 | 复用现有 Vulkan 管线/纹理/同步代码，按统一结果和真实 Draw 状态创建管线、填 SupportBuffer 与描述符并执行实际 indexed draw | 正确的目标/view、viewport/scissor、顶点格式/步长/偏移、索引类型/地址、count/base vertex/instances；GPU 完成前资源不回收，不跳 draw |
| 100–120 分钟 | 针对性回归，冻结 APK，使用 §4.2.1 部署，显式 direct 冷启动验证并保存首错/结果；只在候选变化后重跑 | 首笔真实 draw 的请求/程序身份、资源来源、实际 GPU 参数和完成证明齐全；继续执行后的首个阻塞明确；文档如实更新 |

本笔反射为 program SupportBuffer、VS 的 guest UBO 槽 3、FS 的 texture 引用（当前反射 handleIndex=8），
VS `attributeReadMask=7`。这些数字仅用于本次核对，禁止硬编码在生产路径；解析器必须从 program.bindings 与真实 NVN 状态逐项解析。
当前 `DrawSnapshot` 的“最近一次 UBO/SSBO”和纹理/VB 的数量摘要不足以执行绘制，需保存各阶段各槽位的完整地址、范围、类型、步长及资源代际。
同一纹理还要核对实际 view/采样器与 shader 使用方式，不能用内置 1×1 纹理或固定 VB/UBO 通过首绘。

状态来源复核的明确问题：前述“NVN 没有 alpha reference 设置入口”不成立，`hle_nvn.c` 已有
`nvnCommandBufferSetAlphaRef`（目前只记日志）。必须记录真实调用；没有调用时，仅可使用有依据的初始语义，
或证明当前 shader/alpha-test 模式不依赖该值，不能由“旧 Metal 路径未实现”推导 guest 值为零。
其余未绑定状态采用前端模型的范围与语义仍待审，不以本笔编译成功替代正确性证明。

**本轮边界与报告**：不新增 S2AP/XGS/NVKP 生产格式，不把完整 program 拆成必须落盘的阶段文件，不往安装 revision 写诊断或学习产物；
编译失败保留原错，不被后续“文件不存在”覆盖；不为首帧剥离指令、跳过 pass 或写游戏专用规则。
缓存身份包含实际代码/事实/profile/布局，不能沿用“进程首次成功后全局 done”作为所有程序的生产准入。
本轮只做当前 GPU 消费所必需的设备/快照/提交生命周期；离线批处理扩面、IME、能耗优化及三前端扩展留在后续既定计划。
GPU 微例先以独立期望校验 UBO/纹理/顶点输入，真实游戏 draw 再留目标读回/参考对照；全黑或非零像素单独均不能证明正确。
到两小时按实际结果收尾：主目标未达到就标部分完成并列出准确缺口，不延长为无上限试错，也不把模块/管线创建当作已画。

**执行记录（2026-10-26 15:0x，暗黑3，Adreno 730，显式 direct，冻结 APK `ca1f3c81…` 之后的候选）**

- 内存消费已接：`runtime/nvn/nvn_vk_first_draw.c/h` 直接吃首绘的 `s2a-direct-program-v1`（不再查
  `<key>.program.json`），按反射建描述符集/管线，资源逐项来自真实快照：SupportBuffer（2608 B，
  s2a_flags/s2a_point/render_scale 按编译器布局）、VS 用户 UBO、FS 组合纹理+采样器、三项顶点属性、
  索引缓冲；viewport/scissor/RT 用真实值，提交后等 fence。
- **两处 ABI 坐标按 §7.3.1 复核修正**（原草稿错，已改）：
  1. UBO：统一编译器的 uniform slot 是 shader cbuf index，NVN 用户 UBO 从 c3 起 → NVN 槽 = cbuf − 3；
     首笔 slot=3 → 槽 0（原草稿用 slot−1=2，绑错缓冲）。
  2. 纹理：binding.slot 是 `TextureDescriptor.HandleIndex`（c2 word offset），不是 BindTexture 槽号；
     组合表 [0x20,0x168) 每 8 字节一个槽 → 首笔 handleIndex=8（byte 0x20）→ NVN 槽 0（原草稿读槽 8，绑错纹理）。
  3. `constantBufferUse` 掩码坐标同步改为 `NVN 槽 + 3`。
- **真机结果**：首笔 indexed draw 实际执行并等到 fence 完成：
  `draw: first indexed draw executed: rt=1024x1024 count=3 baseVertex=0 instances=1 ubo=bound tex=bound
  pixel_before=0000… pixel_after=003800380038003c0000000000000000 request=18f2aadcec113d49a566892b88596132`。
  读回是同一命令缓冲内 draw 前后的目标中心像素：GPU 确实写了目标（非零）。这证明真实参数/资源/完成，
  **不代表像素正确**；RT 格式与写入字节的匹配、全屏覆盖与采样结果仍需独立期望（§8.1 的微例）。
- 继续执行：该笔成功后回放继续到下一条绘制，首个阻塞是**下一笔程序还没编译**
  （`draw: program result load failed: nvn stage 0 key …program.json: cannot open`）。按程序按需编译/缓存是下一步，
  不能把“进程首次成功后全局 done”当成所有程序已就绪。
- 期间修掉的真实缺陷：适配层互斥需递归（exec 持锁时绘制消费者又取纹理 → 自锁死）；纹理缓存只有 64 槽且满了
  直接失败（首绘前已满）→ LRU 淘汰；纹理缓存不认识 LINEAR 布局 → 按行主序直接上传；结果 JSON 的通用解析器
  每个字符串只留 256 B（SPIR-V base64 7–15 KB）→ 首绘消费者改用跨度扫描器；stage 名缓冲 4 B 放不下 "program"。
- 仍未做/待证：像素正确性（UBO/纹理/顶点输入的独立微例）、按程序按需编译与结果缓存、
  未绑定状态的剩余语义（scissor 未设时用整目标、点大小/alpha 参考值仍为前端模型）、
  多 UBO/多纹理的完整绑定（当前只实现单 UBO/单纹理，多于一个必须显式 Unsupported 而不是只取第一项）。

**画面定位记录（2026-10-26 15:35–15:45，按“先分 RT/屏幕”的诊断口径）**

- 新增一次性/逐帧上屏源图转储：`debug.s2a.dump_frame=1|2` + `debug.s2a.dump_fail=<dir>` 时，在 present
  完成后把真实上屏源图整幅读回落成 `present-src.raw`（附 4×4 采样日志），用于和屏幕截图同一时刻对照。
  该转储只读，不改绘制/呈现语义。
- 证据（冻结 APK `8e382250…`，contentRoot `sha256-9fca…`）：
  - 修复前上屏源图 = 全黑 + 底部一行文字被画成**实心色块**；屏幕截图同一区域没有这行字 → 至少两个问题：
    文字/字形绘制（混合关闭时 alpha 字形退化成方块）和屏幕上看不到 RT 内容。
  - 修复后同一转储 = 均匀深蓝灰 `(19,34,47,90)` + 中部极淡的几何形状；屏幕截图同步变成同一深蓝灰
    （`(77,102,119)`，overlay 叠加后），证明 **present 路径已经能把真实 RT 显示出来**。
- 本轮按评审修掉 5 个 P1（每次只动一项，随后复跑）：
  1. C1 捕获改为控制段 `+0x700/+0x704` 给出的真实范围（对照 `Dsh.cs` 的 JobFor），不再固定读
     `control−0x100` 256 字节，也不再依赖“同一页”假设；长度保留真实值。
  2. 采样纹理布局一致：描述符声明的布局改成与实际一致的 `GENERAL`（上传/回放一直停在 GENERAL）。
  3. 上传行跨度 `bufferRowLength` 改为 0（紧凑数据）；单位是纹素/块，不再按 `row_bytes/4` 蒙。
  4. 管线状态消费真实 NVN 状态：blend_en/因子/方程、channel mask、cull/front、samples/a2c；
     未绑定状态保持 NVN 默认零值。深度附件尚未进 Draw 快照，仍无深度测试（下一项）。
  5. fence 超时不再释放在途资源：提交成功但未等到完成时保留命令缓冲/管线/缓冲（有意泄漏并报错），
     只有提交失败才正常销毁。
- 当前阻塞与下一步：帧仍是纯色（+极淡形状），文字是实心块 → 先补深度附件记录与真实深度/模板状态，
  再按“最早产生错误输出的 pass”定位；上屏源图/屏幕已能同刻对照，后续每笔只改一个已证实的问题。

**继续定位（15:45–15:52）：布局/深度/模板按 d2r-mobile 参考实现对齐**

- 参考 `dm/gfx/vulkan/engine/xbg_game.cpp` 的 `Image::transition`/`prepare_read`/`prepare_attachment`：
  采样与附件统一停在 `VK_IMAGE_LAYOUT_GENERAL`（附件 initial=final=GENERAL、描述符声明 GENERAL、
  上传后回 GENERAL），不再出现“声明 SHADER_READ_ONLY、实际 GENERAL”的不一致；渲染前后只留同布局的
  memory barrier，不再做 GENERAL↔COLOR_ATTACHMENT 的隐式布局切换。
- 参考同一文件的纹理上传路径与 `dm/gfx/vulkan/engine/xbg_blit.cpp` 的 `xbg_copy_rows`：
  - 线性纹理按真实行距（`t->d.stride`，未给则 32 字节对齐）逐行拷成紧凑缓冲再上传，`bufferRowLength=0`；
  - 深度格式的 barrier 用 DEPTH(/STENCIL) aspect，image usage 加 `DEPTH_STENCIL_ATTACHMENT`，view aspect 同步；
  - `nvn_copy_pitch` 的“行/镜像/总量”约束已由现有 `nvn_tex_layout`/`nvn_tex_level_offset` 覆盖，未另造模块。
- 深度/模板真实化：Draw 快照新增 `SetRenderTarget` 的 depth 快照与 `OP_CLEAR_DS` 的清理值；管线接真实
  `ds_st`（dt/dw/df、stencil 前后 compare/op），渲染通道带深度附件（GENERAL、清理时 CLEAR）。
  真机效果：带模板的 D3 绘制不再被“stencil test enabled”挡住，单次运行执行绘制数从约 1.1 万升到约 2.6 万。
- 仍未解释的画面事实（下一条定位线）：
  - 上屏源图（1600x900，R8G8B8A8_UNORM）为均匀深蓝 `(19,34,47)`、alpha 0x5A；窗口 RT 中心读回
    `(0x15,0x24,0x30,0x00)`——alpha 为 0，需要确认这是游戏清屏值还是我们漏写了 alpha；
  - 前 8 张上传纹理都是 1600x900/1280x720 的黑图（RT 尺寸的 CPU 副本），暂未出现字体图集；
  - 1600x900 的绘制只有 count=6/12/18 的小批次（程序 `4b66ce1a…`），中心像素 draw 前后不变，
    说明窗口内容主要来自清屏 + 这些 UI 小批次，需要逐笔核对其 UBO/顶点/纹理输入。

**继续定位（本轮，17:0x–17:2x）：固定一笔上屏 draw，修掉 NVN→Vulkan 视口 Y 方向这一处确定错误**

- **固定 draw（真实参与上屏）**：request `bdacf210dde2c84d76a9b1fafc7c5d8c`（VS key `bdacf2…`、FS key
  `76a9b1fa…`），1600×900 RGBA8 颜色目标 + D24S8 深度，indexed triangles `count=6 baseVertex=0 instances=1`，
  索引 `12,13,14,14,13,15`；顶点属性 loc0 RGB32F@0、loc1 RGBA8@12、loc2 RGBA8@16、loc3 RG32F@20，
  stream0 stride=44；VS UBO c3（NVN slot 0）2384 B sha256 `c43347ba…`，更新区间 2384@`103f73f000` 与绑定
  完全相同（`exact_full_cover=1`，日志区分了局部更新/完整覆盖/绑定包含更新）；FS 纹理 1014 为 R8 256×256
  （sampler 509）；状态 cull=BACK/front=CCW/FILL、blend=SRC_ALPHA/ONE_MINUS_SRC_ALPHA、chmask=0x7（只写 RGB）、
  深度/模板关；viewport `(0,0,1600,900)`，scissor 在本命令流从未设置（回退整幅，日志标明是替代值；显式空裁剪
  现在保持为空，不再被当成整幅）。
- **独立求值**：按真实索引/baseVertex/属性/UBO 走该 VS 的 Position 依赖链，四顶点 clip=
  `(-0.105,0.813,0.9986,1)` 等，组成两个非退化三角形；按 NVN/Metal 视口方向应覆盖
  `(716,84)-(752,127)`，与 GPU 实测差异 bbox `(716,84)-(751,126)` 一致。
- **首先发现的错误：视口 Y 方向**。`VkViewport` 直接用了 NVN 的 x/y/w/h；Vulkan 同号 height 得到
  `screenY=y+(ndcY+1)*h/2`，而 NVN/Metal 是 `y+(1−ndcY)*h/2`。除整幅上下镜像外，帧缓冲绕序也取反：
  同一组三角形在旧视口下帧缓冲有符号面积为 `+774`，修正为 `y+h / −h` 后为 `−774`；该笔 `cull=BACK`，
  于是 NVN 正面被全部剔除（draw 执行、fence 完成，但目标像素不变）。参考
  `d2r-mobile/dm/gfx/vulkan/engine/xbg_nvn.cpp:5` 的 `xbg_nvn_viewport`（`{x, y+height, width, -height}`；
  注释明确不能只翻 frontFace，也不能关剔除）。
- **修复**：`nvn_vk_first_draw.c` 的视口改为 `{vp_x, vp_y+vp_h, vp_w, -vp_h}`，未设置视口仍回退整幅并注明；
  同时把 scissor 的“未设置/显式空”和 UBO 的覆盖判定（`update_within_binding`/`exact_full_cover`/
  `binding_within_update`，无符号溢出安全）改成可核对的名字。
- **同场景修前/修后**（同一 contentRoot `sha256-9fca…`、显式 direct、同一启动画面）：
  - 修前 APK `51ae9131…`：present-src 1600×900 只有两种颜色 `(19,34,47,90)`/`(17,32,46,87)`，没有任何 UI；
  - 修后 APK `0ca4c973…`（`3871f2b9…` 已先行复验同一视口修复；两者渲染语义相同，后者只多 trace 序号）：
    同一笔 draw 实际写入 1548 px，bbox `(716,84)-(751,126)`，颜色从 `(0,0,0,90)` 变为
    `(205,157,81,90)`；present-src 出现 logo 行和文字行（字形仍是实心块，见下一处阻塞）。
- **稳定性/身份**：修后进程执行 7300+ 笔 indexed draw（深度/模板附件启用），无 `DEVICE_LOST`/fence 超时；
  进程随后结束，未捕获退出原因（非 GPU 设备丢失），因此不把本轮当作持续可玩验收。部署回执
  `build/android-deploy/01001B300B9BE000-l5pzusdz/deployment.json`（APK `0ca4c973…`，contentRoot
  `sha256-9fca2734…`，startupAccepted；视口修复后的首个回执为
  `build/android-deploy/01001B300B9BE000-7ogderf8/deployment.json`，APK `3871f2b9…`）。`debug.s2a.trace=<requestId>` 或 `debug.s2a.trace=prog:<8位内容前缀>` + `trace_max`/`trace_skip` 可在真机按笔转储（`prog:` 只抓本帧 draw 数 >100 的世界帧，避开载入屏反复使用同一程序；trace 不再强制逐笔同步路径）
  UBO/顶点/索引/纹理/整幅 RT 前后图与 bbox；这些是诊断产物，不改变绘制语义。
- **下一处明确阻塞：纹理通道 swizzle 未消费**。该笔纹理 `set_swz=1, swz=0x0400`（r=ZERO,g=ZERO,b=ZERO,a=R），
  FS 读采样的 `.a` 并与 `fp_c3[118].w` 比较后 `OpKill`；当前 `VkImageView` 恒等映射使 R8 的 `.a` 恒为 1，
  所有片元通过 alpha test，实测覆盖是 36×43 的实心矩形（1548 px）而不是字形。修法：按 NVN swizzle（0..5 →
  VK ZERO/ONE/R/G/B/A）设置采样 view 的 `VkComponentMapping`，不强制 alpha、不改阈值、不删 discard。
- 说明：最早跟踪的 `d497…` 文字实例顶点色是 `(0,0,0,0.749)`，在黑色目标上黑对黑，RT 差异 0 不能当作
  “没有覆盖”；随后改用同一位置、能改变目标的 `bdacf2…` 实例取得上述证据。

**继续（同一轮）：消费纹理通道 swizzle，字形从实心块恢复为真实覆盖**

- 视口修复后 fixed draw 的覆盖是 36×43 全满（1548 px），确认几何已正确、首错不在顶点；按 §8.1 的顺序追
  FS：该笔 FS 取 `texture(...).a`（R8 图集）与 `fp_c3[118].w` 比较后 `OpKill`，纹理对象
  `set_swz=1, swz=0x0400`（r=ZERO,g=ZERO,b=ZERO,a=R），而 `VkImageView` 用恒等 component mapping，
  R8 采样 `.a` 恒为 1，所有片元通过 alpha test。
- 修复：`nvn_vk_texcache.c` 按真实 NVN swizzle 设置采样 view 的 `VkComponentMapping`
  （0..5 → VK ZERO/ONE/R/G/B/A；深度/模板 view 保持恒等），并把 `set_swz/swz` 纳入缓存命中比较；
  不改 shader、不强推 alpha、不改阈值、不删 discard。
- 真机结果（同一 request / 同一场景，APK `da349b12…`）：
  - fixed draw #0 的 RT 差异从 **1548 px（整块）降到 703 px（字形笔画）**，bbox 仍为 `(716,84)-(750,125)`；
    #1/#2 中心点变为背景色（字形镂空），#3 出现抗锯齿的 `(0x7c,0x5f,0x31,0x5a)`；
  - present-src 从实心色块变为可读文本：橙色“自动存档”标题 + 两行正文
    “《暗黑破坏神III：永恒珍藏版》支持自动存档。……Nintendo Switch主机。”；
  - 部署回执 `build/android-deploy/01001B300B9BE000-dkimwvqr/deployment.json`（APK `da349b12…`，
    contentRoot `sha256-9fca2734…`，startupAccepted）。
- 下一处定位线：自动存档页之后的画面出现**竖排/单列文字**（左列约 1 字宽、多行叠在一起）；需要分清这是
  游戏后续 UI 的布局输入（宽度/换行/容器）错误，还是过渡帧/另一套 UI，再决定最小修复。

</details>

<a id="android-three-hour-plan"></a>

### 8.2 加载、存档、输入与性能验证口径

§8.2.4–§8.2.6、§8.2.8 继续提供同步、正常性能模式、TouchPad、加载/保存计时和交付验证要求；P0/P1 只保留原标签，不另设当前任务顺序。已通过范围以 §8.0 为准，性能实施按 §8.5。§8.2.1–§8.2.3 的三小时排期与 §8.2.7 的限时热点候选只作历史，展开后可追溯原始证据与约束。

<details>
<summary>展开 10-26 晚间三小时计划：原始读数、参考来源、时间表与当时范围</summary>

#### 8.2 三小时实施方案：加载慢、存档等待与低 FPS（2026-10-26 晚间复核）

**执行目标**：在现有通用直连生产链上，先验收队列同步和切场景稳定性，再去除已确认的开发开销，测出并处理剩余最大热点；沿启动、标题、角色/实际游戏、真实保存、重启读取完成一次闭环。暗黑3只是本轮测试样本，修复按通用 API 语义落地。

本节替换上一轮两小时安排；§8.1 是历史记录，不重新执行。完整管线缓存设计继续遵循 [复用审计 R17](direct-mode-d2r-study.md#417-r17管线身份驱动缓存和预热)。三小时是执行预算，包含编译、部署和回归；不预先承诺稳定 30/60 FPS，也不把未测的存档问题宣布修复。**以下是实施要求，不是完成报告。**

#### 8.2.1 已查到什么：先更新判断，别继续修旧问题

| 证据 | 当前判断与下一步 |
|---|---|
| PID `31667` 在 `23:16:11.679` 执行 `mtl_finish`，随后重建 Vulkan session；`23:16:13` 退出 139。与 APK Build ID 匹配的库将栈定位到 `nvn_vk_first_draw_flush → vkResetFences` | 已发现 QueueFinish 错接 shutdown、旧设备 fence 跨重建使用的生命周期错误。先验收修复，不把这次退出归为 shader parse/interlock |
| PID `32289` 在 `23:22:19.696` 的缓存统计：lookups=89600、hits=89548、misses=52、evicts=0、identical_recompiles=0、resident=2976286 B | 命中约 99.94%。此前16槽反复翻译已有改进；当前暖场景低帧率不能继续默认归因重复现编。跨进程缓存、其他场景和真实变体仍须分别测 |
| 同 PID `23:22:15.346`：平均140 draws，flush 间隔338 ms，submit+wait约28.3 ms | 约310 ms没有被该段提交等待解释，优先拆查 CPU、游戏/服务等待、present和IO。28.3 ms是宿主测得的提交/等待墙钟，不是独立 GPU 时间；整数日志写“2 fps”不能代替逐帧统计 |
| 同 PID 截取7.62秒内约4.7万条逐笔日志，出现2312次 modules/layouts created，只有26条 creating graphics pipeline | 大量逐笔日志和“管线命中前仍建模块/布局”值得测。创建次数来自日志标记，实施时补真实 API 计数，不能只凭标记计算创建耗时 |
| 实际 Debug 构建的 `compile_commands.json`：`nvn_vk_first_draw.c`、`vk_record.c`、`sha256.c`、`runtime/src/thread.c` 没有任何 `-O` 参数，带 `-g`；C# publish已用Release | 原生部分未启用编译优化，是先做对照的低成本因素；不能把开启优化等同于已经解决所有热点 |
| 复核时设备 `draw_log=1`，`draw_probe=0`、`dump_frame=0`、`no_depth=0`、`strip_interlock=0` | 默认关开关已经出现在工作树，设备仍显式开着逐笔日志。先确认安装包支持开关，再用新进程关闭逐笔日志复测；不能拿诊断局当正常性能 |
| 当前没有实际 save Write/Flush/Commit 的进入退出耗时 | “自动存档提示停留很久”尚不等于磁盘慢。需要把游戏等待、GPU完成、服务排队、真实写入、Commit及提交后回调拆开 |

上述性能日志属于此前 PID，不能套到后续安装包。复核最后核到的安装 APK 为 `a27b6e08f94a78f34923511ee83bd98253d38bcad199e67d8bd94af12b257f86`，对应 `build/android-deploy/01001B300B9BE000-5cxii26f/deployment.json`；只证明部署身份与启动接受。工作树同期已出现 QueueFinish/设备清理修补，但清账、失败传播与真实回归仍需本轮审核。执行时重新冻结当前 HEAD、dirty diff、最终 APK SHA、SO Build ID和回执，避免用旧截图/旧性能给新代码验收。

#### 8.2.2 参考代码：借明确机制，不整引擎搬入

D2R参考根：d2r-mobile 仓的 `dm` 目录（本次核对 `445bf05`）。iOS参照本仓源码及本地 `origin/main` 的 `e219c491`；引用函数名定位，行号随合入会变。

| 参考入口 | 借什么、怎么接 | 本轮边界 |
|---|---|---|
| [iOS nvn_mtl.m](../../graphics/nvn/gfx/nvn/nvn_mtl.m)：`mtl_finish_gpu/mtl_finish/mtl_drain`；main对应入口叫 `nvn_be_finish/nvn_be_drain` | QueueFinish只等此前提交的GPU工作与必要上传，不等显示节拍。源码记录过错误等待present把加载拖长的案例 | Android接当前adapter锁和帧队列；不销毁会话，不给每次Finish额外增加显示等待。Drain/Stop的责任单独实现 |
| D2R `graphics/vulkan/engine/xbg_game.cpp`：`xbg_legacy_finish/complete_all`、`Slot/retire_handle` | 等待完成、录制资源由所属slot持有、完成后退休 | 借顺序和所有权；本轮用保守同步边界，不同时引入异步双帧队列或延迟事件系统 |
| 同文件 `perf_frame/CPU_SCOPE` | 拆开program、pipeline、descriptor、snapshot、record、submit、fence、present及cleanup | 接到正常批量分支，用计数和低频摘要；不复制整套HUD，不在每draw同步写文件 |
| [iOS nvn_mtl.m](../../graphics/nvn/gfx/nvn/nvn_mtl.m)：`pso_key_fill/pso_get_`；D2R `pipeline_lookup` | 正确身份命中后省掉创建；miss才建对象 | 模块/布局复用若成为实测首要热点，按R17的owner与引用规则做一小步；不用requestId代替program身份 |
| D2R同文件 `Arena/Slot`、`uniform_snapshot_cached`、`BindCache` | 完成后复用arena/pool；已证明输入不变才复用快照；同一command buffer内省重复绑定 | 本轮优先池/arena回收或自有结果digest中的一个热点。跨帧vcache依赖写跟踪与别名，不能直接启用；逐draw不同command buffer时不能跨buffer跳bind |
| D2R `host/hle_fs.c`：Commit计时和事务失败记录；`tools/save_txn_regress.sh` | 区分首次写到提交结束、Commit本体、前后回调；保存失败不破坏上一版本，提交后重启验证 | 其APFS clonefile/RENAME_SWAP及SDK拦截不移植。Android继续用Ryujinx/LibHac，不另建存档后端、不复制暗黑角色/仓库规则 |
| [Ryujinx IFile](../../compat/tree/src/Ryujinx.HLE/HOS/Services/Fs/FileSystemProxy/IFile.cs)：Read/Write/Flush；[IFileSystem](../../compat/tree/src/Ryujinx.HLE/HOS/Services/Fs/FileSystemProxy/IFileSystem.cs)：Commit | 真实调用入口、WriteOption与返回码；Commit底层调用和 `S2AHooks.SaveCommitted` 回调分开计时 | 保留既有提交/持久化语义，不提前返回成功，不用改服务返回值来缩短画面停留 |
| [Application.cs](../../services/S2A.Services/Application.cs)、[RomFsIndex.cs](../../services/S2A.Services/RomFsIndex.cs)、[InputPump.cs](../../services/S2A.Services/InputPump.cs) | 确认预建RomFS索引被消费、已有位置读取路径、保存提交后是否启动录制快照 | 不重复发明资源索引；实际加载慢才查索引缺失/大量小读；回调快照确实触发且占时才修其工作 |

外部核对：[Khronos fence约束](https://docs.vulkan.org/refpages/latest/refpages/source/vkResetFences.html)要求fence归属当前设备且没有未完成关联；[销毁设备约束](https://docs.vulkan.org/refpages/latest/refpages/source/vkDestroyDevice.html)要求显式释放可释放的子对象。池与描述符复用参考 [Khronos descriptor管理](https://docs.vulkan.org/samples/latest/samples/performance/descriptor_management/README.html)，命令池策略参考 [command buffer管理](https://docs.vulkan.org/samples/latest/samples/performance/command_buffer_usage/README.html)。不把样例里的收益比例当作本项目收益。

#### 8.2.3 三小时时间表与范围

| 时间 | 任务 | 必须交付 |
|---|---|---|
| 0–20分钟 | 冻结当前候选、核对已有修补；采一次短基线，建立加载/帧/存档计时；确认优化参数和诊断开关 | 同一候选身份、可重跑路线、最大的两个耗时段；没有到达真实保存则标“尚未复现” |
| 20–65分钟 | P0：验收QueueFinish，补最小提交顺序、完成状态、清理和超时处理 | 同设备反复Finish后继续draw；draw→clear/copy/event顺序正确；真正重建不复用旧对象；异常不伪成功 |
| 65–100分钟 | P1：正常诊断开关对照；增加Android原生优化性能构建，保留符号和检查 | 正常模式不做额外逐笔读回/刷日志；实际编译命令有优化；新APK与回执匹配，画面/输入无退化 |
| 100–125分钟 | P2：根据P1之后实测，只完成一个最大的安全优化；同时读短FS统计确认“存档慢”所在层 | 一项可单独回退的改动、API次数或耗时前后对照；不同时铺开完整A2–A4+B+C |
| 125–180分钟 | 冻结最终候选，针对性主机检查、部署、完整路线、真实保存后重启读取、第二次启动与短soak | 首错、加载/保存/帧时间对照、实际达到界面、持续时间、APK/Build ID/回执与未完成项 |

最后55分钟留给实机交付，不挪去大重构。P0超出预算时，P2取消，优先把正确性与可验证候选交付；不能为了赶时间用跳draw、删shader语义、关闭深度或提前确认保存换“通过”。已由另一AI完成的项先查代码与新包证据，通过即进入下一项，不整批回退、不覆盖其未提交改动。

默认改动范围：`android/native/{nvn,direct}`、对应tests、Android CMake/Gradle与必要的core-runtime诊断。需要给共享FS入口补观测时，使用既有Ryujinx补丁流程，开关默认关闭，证明Apple正常路径行为不变；不顺手重写FS、调度或GC。遵循当前任务目录约定，不合并整支main当作修复。

</details>

#### 8.2.4 P0：先完成同步契约，不能只补一个旧fence判断

**使用范围**：以下保留完成、顺序和寿命的验证要求；当时列出的源码缺口不自动代表当前仍存在。F0/G0、F1–F3 的实际交付与未覆盖边界读 §8.0，已通过的部分不重复领取。

当前接点：[mtl_vk_shim.c](../native/nvn/mtl_vk_shim.c)、[mtl_vk_adapter.c](../native/nvn/mtl_vk_adapter.c)、[nvn_vk_first_draw.c](../native/nvn/nvn_vk_first_draw.c)、[vk_record.c](../native/direct/vk_record.c)、[nvn_vk_session.c](../native/nvn/nvn_vk_session.c)、[nvn_vk_swapchain.c](../native/nvn/nvn_vk_swapchain.c)。

1. **QueueFinish保持同一device/session**。锁内提交此前积压的draw，等待其真实完成并传播错误；不走shutdown、不新建device、不等待新的显示节拍。只清CPU队列/返回成功不算完成。`mtl_drain`也不能继续以“每条命令已同步”为理由只做初始化。
2. **批量录制后重新核对顺序**。源码里仍有“同步后端，每条命令执行时已经完成”的旧假设：`mtl_wait`立即成功、`OP_FENCE_SYNC`写完成、`OP_SIGNAL_EVENT`直接发布，以及clear/copy独立立即提交。它们与draw延后至present提交并不自动兼容。先列实际边界；最低实现是在有完成依赖的wait/fence/event/CPU可见读回处提交并等待前缀，在独立GPU clear/copy前至少保证前缀先提交且依赖正确。无可靠状态跟踪时采用保守flush+wait，不跨语义边界攒整帧。
3. **屏障不是完成证明，flush也不是读回**。不能把shader写入CPU镜像当作flush后自动可见；涉及GPU写入缓冲/纹理的CPU读取仍须走真实读回和可见性路径，未支持则准确报告。`OP_BARRIER`不能继续靠已失效的逐条同步假设跳过。
4. **提交状态明确**：至少区分Recorded、Submitted、Completed、Failed/完成未知。flush返回结果给present/finish；wait超时或submit失败后停止该失败批次的后续消费，不重置仍在途fence、不重复submit同批、不回收仍引用的资源；保留首错。对一次性clear/copy和present的超时清理也应用同一规则。
5. **录制期间的寿命也算数**。管线LRU、纹理/view释放、描述符池扩容不能销毁已录制命令正在引用的对象。最小做法可在容量边界安全完成旧批后再淘汰；或用引用/退休列表。不能只保护已经GPU写过的纹理，而忽略尚被命令采样的纹理。
6. **真正Stop：先停生产者，完成/处理命令，再销毁对象，最后销毁设备**。frame fence、pipeline/cache/layout、descriptor pools、mapped arena/buffers、framebuffers等由唯一owner显式清理，再清账。`memset`全局表不是退休；“子对象都随vkDestroyDevice回收”不符合正常销毁契约。新会话用递增generation，不能仅比较可能复用的VkDevice地址。
7. **针对性验证**：连续多次QueueFinish后draw仍成功且device未重建；draw写红→clear蓝→读回应为蓝；事件不能早于前缀完成发布；注入wait超时不能释放pending资源或二次提交；强制小缓存/小pool覆盖录制期容量边界；正常Stop→新会话无旧句柄。使用生产消费者，原有只create/destroy纹理的session探针不覆盖这些要求。

P0只建立当前路径所需的保守完成与顺序；延迟事件、GPU时间戳精度扩面、异步多帧并行分别排后续。不要把CPU单调钟或逻辑fence计数称为GPU执行耗时。

#### 8.2.5 P1：可调试的优化构建与正常性能模式

1. 现有属性支持时，性能候选启动前设 `debug.s2a.draw_log=0`、`draw_probe=0`、`dump_frame=0`；保持 `no_depth=0`、`strip_interlock=0`。这些属性按进程缓存的，须新进程生效。诊断局另开、短采样；错误/Unsupported仍输出，正常摘要按时间低频输出，不按draw刷屏。
2. 确认实际安装SO包含开关实现，完整构建和部署，不只修改属性就推断生效。除开关值外，用同APK、同场景比较诊断开/关；本轮调研未替其他正在测试的进程改属性。
3. 给Android原生性能构建启用 `-O2 -g`，保留unwind与符号，保留现有断言/错误检查；可在当前Debug可安装流程增加显式native性能配置，避免为此改变签名/资源身份流程。不加fast-math、不改shader优化策略、不盲开LTO。检查最终 `compile_commands.json` 覆盖真实热点，不能只优化探针target或Java；NativeAOT已是Release，无托管改动时不重编AOT。
4. CMake/NDK配置以实际命令为准，不能仅把日志写成Release。保留与APK匹配的未剥符号SO及Build ID。改优化可能暴露原有UB，出现新崩溃按匹配栈修，不用关闭检查掩盖。构建类型规则参见 [CMake文档](https://cmake.org/cmake/help/latest/variable/CMAKE_BUILD_TYPE.html)。
5. 低开销计时要覆盖**正常deferred分支**：program查找/翻译、结果hash/parse、modules/layouts、renderpass/framebuffer、pipeline查找/创建、UBO/VB/IB拷贝字节、描述符、命令录制、submit、fence、acquire/present、cleanup分别计数/累计时间。当前只在非deferred分支计算的 `draw timing` 不代表批量性能。
6. 正常测量用内存有界记录，周期汇总/收局落盘；没有GPU query时仅报宿主等待。`AndroidRunMetrics`的 `frames.tsv` 是显式诊断且同步文件IO，必须注明；direct画面帧数取其真实present成功路径，不能拿通用安全网的节拍或触屏overlay刷新当游戏FPS。需要线程归属时短采 [Perfetto/simpleperf](https://developer.android.com/games/optimize/optimization-tips)，不要用大量逐笔日志代替采样。

验收：正常模式额外draw探针copy为0、逐笔进度日志为0，错误保留；同画面逐帧p50/p95和各项创建计数有前后数据。优化构建的收益单独记录，不能跟代码复用混成一个无法归因的结果。

#### 8.2.6 加载和存档：测同一条时间线，再决定改哪里

时间戳用统一CLOCK_BOOTTIME或输出明确对齐点；服务本体耗时可用Stopwatch测duration。加载至少记录：启动接受→服务ready→guest运行→首个真实present→自动存档说明→标题→可操作角色/游戏。单列玩家停留、按键时刻、过场播放；不把等待按A/看完视频计入后端加载。第一次新进程启动和保留缓存的第二次启动分别报告，不清存档或缓存伪造“冷/暖”。

<a id="android-input-test-quickref"></a>

**通用虚拟手柄按键速查（适用于 Android 各游戏、direct/generic 两种模式）**

**本节“按 A”统一指触摸宿主 TouchPad 覆盖层的 A 圆形按钮，并完整松开。** 游戏画面里的“按 A”提示是提示文字，坐标要取 TouchPad 按钮中心；输入文本 `A`、发送普通键盘 A 或点击提示文字都不等同于触发此按钮。AI 默认通过下面的 `adb ... input touchscreen swipe` 在 TouchPad 按钮上合成触摸，不调用游戏内部函数、不把实验性游戏原生触屏当手柄按钮。

已核对的输入链是：`触摸坐标 → TouchPadView / TouchRouting → TouchPad.down/up → MainActivity.publishInput → NativeBridge.input → s2a_android_input_set → s2a_vpad_read / InputPump → 游戏 Npad`。**先看 TouchPad 是否发布 A 位，再看游戏是否回到标题/进入菜单**；缺少前一步证据时，先查触摸命中和发布，不据此认定动画不可跳过。

**AI 真机操作按下面顺序执行，每次只发一个动作，确认结果后再按下一次。** ADB 命令返回 0 仅表示注入命令执行完，不能证明按钮命中或游戏已消费；触屏覆盖层会动也不能证明游戏画面已更新。

1. **先确认本局身份、前台与输入日志。** 沿正常部署/启动流程，在本局启动命令中加 `--es s2arm.touchpad on --es s2arm.touchlog on`，使虚拟手柄可见并记录布局与输入变化。用实际设备 serial、包名和 `pidof` 取得的本局 PID 取日志；用完整 `dumpsys window` 核对焦点窗口属于该应用，不只截取某个可能没有焦点字段的子段。direct 测试还要有本局 `direct activate: nvn_vk backend ready` 和 `direct composition: managed GPU disabled`，不能把 AUTO 退回 generic 的结果算 direct。

   ```sh
   # 将占位值换成本局实际值；PID 由下一条命令取得。
   S2A_INPUT_SERIAL='<设备 serial>'
   S2A_INPUT_PACKAGE='<本次游戏 APK 包名>'
   adb -s "$S2A_INPUT_SERIAL" shell pidof "$S2A_INPUT_PACKAGE"
   S2A_INPUT_PID='<上述命令得到的本局 PID>'
   adb -s "$S2A_INPUT_SERIAL" shell dumpsys window
   adb -s "$S2A_INPUT_SERIAL" logcat -d --pid="$S2A_INPUT_PID" -v threadtime -s S2Arm:I
   ```

   若已在运行的局未开 touchlog，可用该包的 `am start -n <包名>/org.s2arm.android.MainActivity --es s2arm.touchpad on --es s2arm.touchlog on` 请求更新；先核 PID 是否保持，再读更新后的输入日志。布局只在下一次输入发布且布局版本变化时输出，缺布局行时结合新截图定位，不复用上一进程/上一方向的坐标。不为打开日志重装、清数据或清存档。输入日志仅用于短诊断，不拿其局部帧时作性能验收。

2. **定位 TouchPad 按钮，不把 A/B 说反。** 先确认 TouchPad 可见；若不可见，回到第 1 步启用 `s2arm.touchpad on`，不能凭游戏提示猜触点。按当前截图和本局 `touchpad layout: ... A=(x,y,r...) ...` 找圆形按钮中心；布局日志使用 View 像素，须与截图核对窗口位置。系统栏、刘海、旋转、沉浸模式变化后重新定位。TouchPad 按钮的映射如下；确认/取消及跳片头的用途仍按游戏提示。

   | 屏幕按钮 | Switch/Npad 位 | 单独按住时的宿主日志 |
   |---|---|---|
   | A（右侧面键） | bit 0 | `buttons=0x0001` |
   | B（下方面键） | bit 1 | `buttons=0x0002` |
   | +（上方靠右） | bit 10 | `buttons=0x0400` |

   用户本次提供的暗黑3参考坐标来自 **2712×1220 横屏截图**：A 约 `(2528,683)`，B 约 `(2371,824)`，只用于识别那张图；不得直接用于另一布局。屏幕 A/B 与 Android 实体手柄 `KEYCODE_BUTTON_A/B` 的名称不能互换：`MainActivity` 对实体键按位置转换，Android A 对应 Switch B，Android B 对应 Switch A。

3. **确认当前页面接受什么输入，再发一组完整按下/释放。** 先确认应用在前台；可以在确认没有控件的空白区域点一次，再重新确认焦点和画面，但不要把这一步当作“已经证明首次触摸会被吃掉”。实际读盘、淡入淡出或菜单切换时先观察；菜单文字和选中项清晰后再确认。**动画播放不等于禁止输入：用户确认本次暗黑3片头动画可按 A 跳回标题页，应直接尝试，不必等动画播完或先出现跳过提示。** 低帧率诊断先用按钮中心的定点长按，约 1.5 秒；抬起后保留约 1.5 秒无输入窗口，再截屏判断页面是否变化。时间只是重试起点，不能保证卡住的游戏完成了采样。

   ```sh
   # 这条手势必须落在 TouchPad 的 A 圆形按钮内；不是游戏里的“按 A”提示文字。
   # 按当前截图/布局填写按钮中心，不能照抄上面的参考坐标。
   S2A_INPUT_AX='<当前 TouchPad A 中心 X>'
   S2A_INPUT_AY='<当前 TouchPad A 中心 Y>'
   adb -s "$S2A_INPUT_SERIAL" shell input touchscreen swipe "$S2A_INPUT_AX" "$S2A_INPUT_AY" "$S2A_INPUT_AX" "$S2A_INPUT_AY" 1500
   # 约 1.5 秒不注入其他输入，再取本次动作之后的日志和截图。
   adb -s "$S2A_INPUT_SERIAL" logcat -d --pid="$S2A_INPUT_PID" -v threadtime -s S2Arm:I
   ```

   在本次动作的时间窗口里，应先见 A 位从 0 变 1，再变回 0；没有其他输入时就是 `0x0001 → 0x0000`，更早的一条零值不算这次释放。宿主按下/释放对只证明输入已发布，游戏是否消费仍要看菜单选中项/页面或游戏动作。不要连续高速点 A，也不要直接批量发送 A、B、+；B 会取消当前操作。

4. **跳过动画和进菜单按页面推进。** 先截图识别“标题 / 片头动画 / 主菜单 / 选择页 / 加载 / 世界”，不要按等待时长猜进度。本次暗黑3按下表操作；每步发送一次完整手势，确认释放和页面变化后再执行下一步，其他游戏按其实际操作规则。

   | 当前页面 | 动作 | 必须观察的结果 |
   |---|---|---|
   | 片头动画正在播放 | 触摸 TouchPad A 后松开以跳过，不等动画播完 | 回到标题页；这是跳过成功，尚未进入主菜单。若仍在播放，按第 5 步核输入后再试 |
   | 标题页 | 按当前开始提示，触摸 TouchPad A 后松开 | 截图确认是否到主菜单/角色等后续页面；无响应按第 5 步查输入，不把仍停在标题当成加载 |
   | 主菜单 | 确认选中“开始”，触摸 TouchPad A 后松开 | 玩家选择/难度等实际后续页面；不能只凭按钮动画或 ADB 返回值算进入 |
   | 玩家选择、难度页 | 每页重新截图，核对当前选项后触摸 TouchPad A 并松开 | 到下一页或实际加载；进入加载后停止连按 |
   | 世界内需要开菜单 | 触摸 TouchPad 上与当前游戏菜单提示对应的按钮并松开 | 菜单实际出现；不把“标题页 + 有效”推广为所有页面的规则 |

   本次参考曾记录标题页 A 无效果后按 `+` 进入过场；这只是一次观察，不把 `+` 写成进入主菜单的固定步骤。若按当前游戏提示尝试 `+`，同样核对 `0x0400 → 0x0000` 和实际页面，不在标题/动画之间无限循环。正常可跳过动画、实际加载和短暂转场必须分别记录；有效输入后仍播放只说明本次尚未跳过，不能仅凭这一现象认定游戏禁止输入。

5. **无响应时按证据分支，至多重试一次同一动作后重新定位。** 每次重试都先确认上一动作已释放、进程仍为本局 PID，再确认当前页面。不要用盲按掩盖输入链或运行时失败。

   | 本次观察 | 下一步 |
   |---|---|
   | 没有目标位的按下日志 | 核对前台、覆盖层和当前坐标；重新定位后发一次完整手势。不能仅凭 ADB 返回 0 算按到 |
   | 有按下，没有之后的释放 | 暂停后续按键。对应触点的 UP 释放该触点，CANCEL 清触屏状态，失焦或暂停清空输入；必要时 HOME 后正常回到同一应用，核 PID/会话、归零和恢复后的布局。若会话退出或未恢复，记录生命周期失败，不继续当作同一局 |
   | 只有点空白或按 B 后“恢复” | 只记录现象，不认定原 A 已释放：空白/其他键不保证移除旧触点，必须核对 A 位回到 0；B 还可能弹取消/回标题对话框 |
   | 按下/释放完整，片头动画仍在播放 | 本次暗黑3片头可按 A 跳回标题；按本次日志核对完整动作，重新定位后至多再试一次。仍不跳过时保留证据，不归为“动画必然忽略输入” |
   | 按下/释放完整，画面在实际加载或淡入淡出 | 等到可交互页面再操作，分别记录输入时刻和页面变化；不能将这段等待全算加载耗时 |
   | 按下/释放完整，稳定页面仍不响应 | 记录 PID、时间、前后截图、目标位和画面状态，查 guest HID 消费/游戏是否仍在推进；加长手势不能替代这一步 |
   | `session failed`、`HostApi stop requested`、`stop requested`、异常栈或进程消失 | 停止注入，保留本局首错；这是会话失败。主菜单“开始”曾触发 `Android host UI is not connected: player selection`，属于 A 已生效后玩家选择失败，不能算漏输入 |

   查异常时取本局时间窗口的完整日志（`adb -s "$S2A_INPUT_SERIAL" logcat -d --pid="$S2A_INPUT_PID" -v threadtime`），不能只用前面的 `-s S2Arm:I` 过滤结果判断没有 `AndroidRuntime` 等异常；进程已退出时仍用退出前记录的 PID，不改用新进程的日志。

**依据与限制**：[TouchPad](../app/src/main/java/org/s2arm/android/TouchPad.java) 定义屏幕 A/B/+ 位及触点保留，[TouchRouting](../app/src/main/java/org/s2arm/android/TouchRouting.java) 在控件可见且命中时将触摸路由到虚拟手柄，[TouchPadView](../app/src/main/java/org/s2arm/android/TouchPadView.java) 与 [MainActivity](../app/src/main/java/org/s2arm/android/MainActivity.java) 定义发布、释放和日志开关；[小米17 E04 记录 §5](reports/e04-xiaomi17-20261024/README.md#5-失败重试与清理) 在同 PID/同坐标下观测到分离 `motionevent DOWN/UP` 返回 0 却缺输入日志，而定点 swipe 有按下/释放对，说明不能只检查命令退出码。该诊断证据不证明所有设备/游戏都必须用 swipe。用户本次参考还记录了低帧率页 900 ms 首次无效果、1500 ms 第二次有效，并明确补充片头动画正常可按 A 回到标题；这些作为本次样本操作依据，不外推为全部过场/全部游戏的规则。未逐事件取证，**焦点吞触摸、两次采样间漏过短按、丢 UP、转场主动忽略输入仍是待验证解释**，不能写成已确认根因。本段是操作流程澄清，未新增真机通过结论。

真实保存至少记：对象/事务标识、Write次数/字节/WriteOption、Flush次数、Commit进入/底层返回/提交后回调结束、结果码、同窗QueueFinish与frame/present。统计锁等待与调用本体，避免把它们混为磁盘耗时；高频Read/Write只累计，逐条诊断有时长/条数上限。屏幕出现“正在存档”但没抓到服务调用时，写明尚未定位，不绕过提示。

| 观测结果 | 本轮处理 |
|---|---|
| 等待集中在QueueFinish/事件/重建设备 | 回到P0修完成/顺序。iOS的finish/present分工可直接指导，不改文件系统 |
| 启动正在现建RomFS，或读取/打开文件占最大段 | 核对包是否包含并实际消费 `romfs.s2aidx`，沿已有IndexedStorage/LazyHostFile位置读取定位多余枚举、重复打开/分配。修包或实际多余工作，不关闭索引/模块/APK哈希校验 |
| 暖场景出现同完整请求反复翻译 | 查事实身份、失效原因、容量/引用，保留新变体miss。若仍维持零重复，结束这条排查；不为提高命中合并不同事实 |
| Write/Flush/Commit本体慢 | 先量真实字节、调用数和磁盘/锁等待；只删除已证实由宿主额外加入的重复扫描/复制/刷新。保留游戏要求的Flush、事务和错误码；改涉及持久化语义则超出本轮小优化范围，交准确耗时与下一依赖 |
| Commit本体快，提交后回调慢 | 单独核 `SaveCommitted → InputPump.SaveCommitted → Saves.Snapshot` 是否因录制配置触发。诊断/录制未启用时不做额外快照；需要快照时先取得一致自有版本再异步处理，不能后台读仍在变化的live存档 |
| Commit很快但界面仍停很久 | 查游戏线程、IPC排队、输入和GPU完成等待；不要更改保存成功返回或把界面关闭当修复 |

**保存验收**：用本机测试存档完成一项可观察更改，真实提交成功，正常退出，重启后读取到同一更改。改FS代码才补独立临时目录中的写失败/提交失败/异常中断回归；真实用户存档先保留备份，故障注入不对其执行。不上传存档、资源或游戏数据。三小时未到实际保存点时，只能交“定位/待验收”，不能交“存档已修”。

#### 8.2.7 P2：正常模式下只追实测最大热点

当前热点实施按 §8.5；下面保留三小时预算内的原候选表。其“25 分钟/本轮不增加 worker”等限制只约束当时那次优化，不覆盖 F4.4 或现行交付计划。

<details>
<summary>展开历史 P2 限时选项、对应正确性条件及当时不做的范围</summary>

**选择规则**：P1之后重新排序，选一个能在25分钟内形成独立改动和针对性验证的项。不是固定把下面四项全做。完整A2/A3/A4、driver cache B与配方预建C仍按R17逐步验收。

| 最大耗时 | 可交付的小步 | 不能省略的条件 |
|---|---|---|
| 每draw对同一不可变JSON重新SHA/parse | 结果owner在构造/校验时计算并保存完整digest，pin期间传给解析缓存；命中省重复计算 | digest对应自有不可变字节；不能相信文件名/requestId/未经验证的contentHash，也不能持源LRU裸指针 |
| 每draw创建shader modules/layouts | 已在做A2时，独立完成同一program的GPU对象复用；先有明确owner、预算与命令引用 | 全program/反射身份，四set布局，pipeline与命令持引用，避免重复destroy；未能闭环就不合半成品。不能只把新layout换旧layout而漏退休 |
| 每帧反复建/销毁arena与descriptor pools | 已完成批次的arena重置offset，描述符池按完成批次复用；扩容保留旧池到完成 | 不reset仍pending资源；command pool若与上传/present共享，不能整池reset破坏别人的命令；容量与代际有界 |
| 大量CPU快照/录制、pass切换 | 给下一轮留下量化的拷贝字节、重复资源与pass/command计数；只在已有安全接点上减重复工作 | 同cmd连续draw和open-pass合并是后续独立改动，不能在不同cmd间省bind；跨帧缓存须有真实写跟踪、别名失效及退休 |

本轮不以跨GPU移植驱动二进制、盲预热所有管线、增加worker、降分辨率/帧率解锁/CPU绑核、删interlock/alpha/depth或跳draw换收益。不恢复XGS、旧shader ABI、第二个device/backend或单游戏地址表。磁盘driver cache和预建主要解决首遇创建，不能替代每draw热路径与同步错误。

</details>

#### 8.2.8 最终验收和交付格式

以下测量、身份和证据要求继续有效；末尾的三段提交顺序是原性能轮次的拆分示例，当前提交按 §8.0 的独立编号交付，不把整个 F4/F5 或多个性能项合成一次修改。

- 同设备、同内容与档位、同分辨率、相同输入路线；记录温度/热状态、缓存状态、编译优化、诊断开关。保留未优化候选，逐项对照；不把加载、2D提示与3D平均在一个FPS里。
- 稳态场景至少60秒，报告帧时间p50/p95、成功present计数/时长、超过100/250ms帧数；`FPS = 成功帧数 / 实际秒数`。把CPU录制与submit/wait/present分别报，不依据四舍五入日志或overlay推FPS。性能目标是同场景可重复下降的真实帧时间；达不到则交最大剩余热点，不编造30/60帧完成率。
- 切场景按A重复验证，QueueFinish后device/session不重建、继续真实draw；完整路线须超过自动存档说明，达到标题/角色并尽量到实际游戏操作。验证真实保存并重启读取，暖启动再跑一遍；正常收局无新SIGSEGV、DEVICE_LOST、完成超时或错误缓存命中。
- 测试走实际修改路径：队列/容量/超时的生产逻辑用例，GPU顺序用例须实机；触及解析器时跑合法可选字段/坏长度/源缓存淘汰并用ASan/UBSan查寿命。`S2A_TEST_NO_NATIVE=1`只代表跳过native的检查，不能作native通过证据；旧NVKP/C2探针也不能代替统一program消费者。
- 最终签名APK用§4.2.1的 `deploy_game.py --mode direct --refresh-existing`（同资源已激活时）部署，核APK SHA、SO Build ID、contentRoot和回执。原生改动不必反复重编未变AOT；若重编AOT，遵循OpenSSL打包检查。不得用手改artifact哈希绕开部署事务。
- 提交按“同步/寿命修复→正常性能构建/诊断→一个热点优化”分开，便于回退和归因。交付只写：改了什么、参考何函数、实际路线、前后数据、首错/限制、提交与回执。私有证据放本机build目录，日志/截图不夹带进仓库游戏数据；不另建交接文档，CHANGELOG只在形成里程碑时更新。
- 提PR前按贡献流程运行 `bash tools/contrib_check.sh` 并贴真实摘要；共享层改动附Apple路径证明。没过的项准确标未完成，不用“构建成功”“draw数增加”代替画面、保存与性能验收。

### 8.3 2026-10-27 直连首次进入暗黑3世界：历史事实与读数

<a id="83-2026-10-27-直连首次进入暗黑3世界当前事实与读数"></a>

首次进世界的读数和当时剩余项保留如下；其中固定查询值后来已由 F3.1/F3.2 接替，当前状态读 §7.0 / §8.0，不能把旧 FPS 当当前候选验收。

<details>
<summary>展开首次进世界的完整记录：设备、改动、局部帧账、性能解释与当时剩余项</summary>

本节保留首次进世界的阶段记录；当前画面问题、复核证据与下一轮优先级以 §8.4 为准。“世界内可操作”不等于人物材质、切场景和资源同步已验收。

设备：Redmi K50 Ultra（22081212C），Android 16，Adreno 730；APK `cf9e649c…`/后续批次，资源 contentRoot
`sha256-9fca2734…`，direct 冷启动。此前 §8.1/§8.2 的合成/首绘/过场结论继续有效，本节只记真游戏新事实。

**已达（真游戏 direct，未用 generic 兜底）**

- 标题、过场动画、主菜单、难度选择、玩家选择、读盘和世界内画面均有 direct 上屏记录；
  当时记录过场和菜单可到 60 fps，世界内可接受手柄/触摸输入并继续游戏，角色、字幕和 HUD 可见；后续发现人物与 HUD 异常，不能将“可见”算作画面正确。
- 世界画面在纹理 pin 修复后不再出现整片彩色噪声；此前 2–3 fps 的逐笔 pass/逐笔布局/逐笔哈希路径
  已替换为程序对象缓存、open pass 合并、结果 SHA 预计算、采样器缓存、逐帧纹理查找缓存和 `-O2`。
- 玩家选择小程序按 `services/S2A.Services/Host.cs` 同一单用户策略实现：返回存档的
  `LastOpenedUser`，不是空对话框假成功；`AssemblyInfo.cs` 仅对 `libs2a_cs`/`S2A.Android.Aot`
  开放 HLE 内部账户属性。
- 遮挡查询 `samples-passed` 仍未接 Vulkan query pool；当前报告“全部可见”的上界并记录一次，
  实际写入固定 `0xFFFFFFFF`。这不符合真实查询语义，不能证明只影响性能或不会改变游戏行为；
  必须实现当前调用要求的真实查询，未支持时明确 Unsupported，不能把固定返回值作为正确性已通过。

以上修复全部落在 NVN/Vulkan 通用语义：程序内容身份、pass 生命周期、资源在途引用、采样器/描述符缓存、查询语义和宿主单用户策略。没有按 titleId、进程名、函数名、地址或游戏分支写特例；暗黑3 只是本轮首个真实输入样本，换一款使用相同 NVN 子集的标题也走同一路径。

**本轮关键改动**

| 模块 | 改动 |
|---|---|
| `nvn_vk_first_draw.c` | 程序级 ShaderModule/四 set 布局/pipeline layout 缓存（A2）；同一附件连续 draw 合并为一个 render pass/command buffer；每 8 个 pass 提前提交，present 只等最终 fence；帧 arena 跨帧保留、只重置游标；纹理 pin 到 present fence；四 set 一次分配；`-O2` 热点构建 |
| `nvn_vk_texcache.{c,h}` | 槽位 64→256；`pins` 引用计数，pin 期间禁止淘汰/销毁；同地址新代际且旧槽在用时另找槽，不销毁在途图像 |
| `nvn_vk_draw.c` | 编译结果建立时算一次完整 SHA-256，逐笔绘制只传 32 B，不再重算 50 KB |
| `mtl_vk_adapter.c` | 注册表代际；逐帧 id→`nvn_vk_tex*`/`samp_par` 查找缓存，避免每笔 draw 取注册表锁 |
| `mtl_vk_shim.c` | 帧账：guest 逻辑、录制执行、present 分列；逐 opcode 耗时聚合（诊断用，默认低频） |
| `vk_record.c` | 附件/立即 GPU 操作前结束 open pass；sync 仅保留给真正有完成依赖的 op；`samples-passed` 上界；reset-counter 接受 timestamp/samples-passed |
| `AndroidHostUi/Runtime` | 玩家选择单用户自动应答；HLE 内部账户属性最小授权 |

**真机读数（同一 APK、世界内静止，1600×900，60 Hz 面板）**

| 场景 | 帧时 | 说明 |
|---|---|---|
| 过场/主菜单 2D | 10–18 ms | 约 55–100 fps；过场 3–7 draw/帧 |
| 世界内 | 50–57 ms | 约 18–20 fps；约 485 draw/帧、3530 条 NVN 命令/帧 |
| 世界内 CPU 录制 | 37–41 ms | 平均 93 µs/draw（菜单+世界累计；世界约 60–70 µs），res 29 µs、desc 32 µs、pass 12 µs、pipe 5 µs |
| 世界内 present | 9–13 ms | 逐批提前提交后，GPU 绘制与后续 CPU 录制重叠；fence 等待 1.6–4 ms |
| 旧串行阶段的 GPU 完成等待 | 约 26 ms（未重叠前读数） | 只有 CPU 侧 fence 等待，没有 GPU timestamp；不能等同纯 GPU 执行时间 |

上述读数来自 `frame timing` / `draw timing(batch)` 的同一进程累计；不是外推。`no_depth=1` 诊断曾把
世界加载画面从 16 fps 提到 58–62 fps，说明深度/阴影路径值得剖析；它同时改变附件、绘制和等待，不能据此确定纯 GPU 比重。该开关会丢阴影，不能当产品路径。

**当时记录的剩余项（当前优先级以 §8.4 为准）**

1. 60 fps：当时约 18–20 fps，CPU 录制仍占 37–41 ms。待画面与完成/退休语义通过后，再按实测热点选择描述符 set 复用/动态偏移或 UBO/support 批量上传；真正双缓冲另行验收，不与当前正确性修复同时铺开。
2. 遮挡查询精确化：接 Vulkan occlusion query pool（reset/begin/report/readback），替换“全部可见”上界；
   在此之前不得声称遮挡剔除已正确实现。
3. 主菜单 3D 背景曾在直接进入菜单时缩在左上角（黑屏其余区域），难度页和世界正常；需核对
   菜单合成 pass 的 viewport/scissor/RT 身份，不能用手工裁剪绕过。
4. 视频/音频/存档长跑、暂停/恢复、旋转、退出重进尚未按 §9.1 全量验收；当前只证明到“世界内可操作”。
5. `android/test.sh` 的 native 段在本机因 `wsi_probe.cpp` 缺 Android NDK 头失败（环境缺头，
   非本轮改动）；Java/契约 16+6 项和 `direct_source_store`/`direct_compile_request` 单独编译均通过。

</details>

<a id="android-render-correctness-review"></a>

### 8.4 同候选画面检查点与历史复核证据

本节保留人物/装备、HUD 和转场的复核入口。F0–F4 的分项通过不能替代这些画面验收；下面旧候选曾出现的异常，也不能直接断言在最新候选仍存在或已修复。

| 检查点 | 当前需要取得的结果 |
|---|---|
| 人物选择、装备与物品栏纸娃娃 | 同候选确认形状、材质和装备完整；有异常时关联首错 draw 的程序/附件/采样 view、输入与输出，不按旧报告预设根因 |
| 世界角色与 HUD 圆球 | 与同路线 generic/参考结果核对局部内容；“角色或 HUD 可见”不能代替材质、通道与混合正确 |
| 进入世界、返回与再次进入 | 记录切换前后与稳定帧，确认无新增花屏/竖条纹，并核实际输入、完成/退休和资源代际 |

冻结同一源码/APK/资源/profile/设备及诊断状态，按 §8.2 操作和记录。真实保存后重启、完整视频/声音/输入与故障恢复按 §9 独立验收；本次整理没有新增上述检查点通过结论。以下保留原章节标题和全部实验记录，旧优先级由 §8.0 / §8.5 接替。

<details>
<summary>展开 07:16–12:00 画面复核原文：基线、缺口、旧顺序、修补、失败及验证限制</summary>

#### 8.4 2026-10-27 画面正确性复核与下一轮任务

**07:16 复核基线（历史）**：真实 NVN 直连已进世界，渲染正确性、完整保存/恢复和性能仍未闭环。用户报告人物界面的人物全黑/外观异常、进入世界期间花屏；两处现象不能因已有世界截图或无崩溃而判通过，也不能未经抓帧就归为同一根因。当时只读审查源码和设备，没有改渲染逻辑、切换开关或重启游戏；抓到的是世界内画面，尚未独立捕获这两处异常的首错 draw。后续进展见 §7.0 和 §8.4.3–§8.4.5。

**当时身份与读数**：分支 `android/direct-mode-d2r`，HEAD `4d03d476`（当时另有文档/注释未提交改动）；当时安装 APK SHA-256 `c85db19761ef8655a1591f13276b17351d1c38b2bea1015f4e44e4b6299c18b9`，PID `23019`，07:11 启动。该进程有 `direct activate: nvn_vk backend ready` 和 `managed GPU disabled`，不是此前 PID `20204` 的 generic 局。`no_depth=0`、`strip_interlock=0`、`draw_log=0`、`draw_probe=0`；采样时电池温度 40.9°C、未充电。原始日志与截图仅保存在忽略目录 `build/android-review/render-20261027-071638/`，不将游戏输入/产物入库。

07:15:00–07:16:38 共 88 条低频帧账：gap 中位 70.75 ms，exec 48.1 ms、present 15.2 ms、other 6.35 ms。gap 对应约 14 fps 的局部节拍估算，不是完整帧时分布或正式 FPS 验收；不能与 §8.3 的不同场景/温度旧读数直接作回归结论。捕获窗口未见 DEVICE_LOST、完成超时或 `mtl_exec` 失败，但不能据此排除数据错误。

**同局 07:24 的耗时补充**：PID/APK 同上。07:24:56 的采样帧 gap=72.5 ms，其中 555 次 indexed draw（op=26）合计 34.3 ms、10 次 ClearColor（op=9）合计 12.2 ms、present 阶段 18.4 ms，其余约 7.6 ms；下一条样本对应 draw 41.4 ms、ClearColor 12.6 ms。`vk_record.c` 的 clear 路径仍逐次提交并等 fence。exec/present 都是墙钟区间，包含提交、锁与等待，不是纯 CPU/GPU 时间。除了 draw 的描述符/资源准备，清屏的提交等待也是明确待剖析项；正确性通过后再考虑按命令顺序合批，不能跳过或减少游戏要求的清理。累计约 539 万次 program 查找中 miss=206、pipeline miss=248，当前暖场景不能继续默认归因为反复编译；尚未实测上述优化的收益。

#### 8.4.1 07:16 已确认的源码缺口与影响范围（历史基线）

下表描述 07:16 的源码，cube 分类、pass_break 和 ClearDS 等已有后续修补，不能把本表当现状或重复实施；当前以 §7.0 / §8 执行顺序为准。“缺口已确认”不等于“已证明是人物全黑/本次花屏根因”；后者必须由异常 draw 的真实输入、执行与输出关联证明。

| 优先级/项目 | 当前源码证据 | 下一步与验收 |
|---|---|---|
| P0 纹理 target 枚举错误 | `nvn_vk_texcache.c` 把 target 5/6 判为 cube/cube-array，NVN 权威头文件实际定义 5/6 为 2D_MULTISAMPLE(/ARRAY)、8/9 才是 CUBEMAP(/ARRAY)。真正 8/9 因此未按 cube 建图/view；`nvn_vk_texcache_tex_test.c` 也用错误的 5 号验证“cube 被拒绝” | 依据 `graphics/nvn/gfx/nvn/include/nvn.h` 的符号常量修正分类，分别实现/明确拒绝实际 target。Cube 创建条件、六面/数组范围、view 类型与 shader 采样维度一起核对；不只换错误字符串。用六面独立颜色的真实 8/9、真实 MS 5/6 作独立期望测试。抓人物 draw 的采样输入，只有实际用到这类纹理后，才能将它归为人物黑色的根因 |
| P0 多颜色附件（MRT） | `nvn_vk_first_draw.c` 只解析 `state->rt[0]`，subpass 和 blend attachment 数为 0/1；没有按其余真实颜色槽执行。`vk_record` 虽保存最多 8 槽，不代表 GPU 已消费 | 先记人物 pass 的实际附件、FS 输出 Location 与后续读取。若使用多附件，完整接每槽 image/view、格式、blend、写掩码和 pipeline/pass 身份；空洞保持原 Location，不能压紧。未支持的真实配置明确拒绝，不能静默只画槽 0。用两个独立输出及有空洞的用例核对，再验人物材质 |
| P0 texture view 与 backing | `mtl_vk_adapter.c::s2a_vk_adapter_reg_tex` 保存 `view_t/has_view`，`tex_by_id` 只取 `tex_t`；附件消费也没有完整携带选定 mip/layer。texcache 将格式/swizzle 混入图像重建条件，尚未建立独立 view 缓存 | 接当前真实 texture/view 的格式、mip/layer、类型、swizzle 与 depth/stencil mode，按用途区分采样/附件/storage view；同 backing 改 view 只换 view，不能重建图像并上传旧 CPU 镜像。深度采样 aspect 与附件 aspect 分别核对。验 GPU 写入→换 view→采样仍保内容、多 mip/layer、A=R 与独立纹理回归 |
| P0 提交顺序与清深度/模板 | `pass_break(sync)` 在 pass 已关闭时直接返回，可能留下未提交 draw；后续立即 clear/copy/fence 能越过它。`OP_CLEAR_DS` 仍延迟到下一笔 draw，消费者用合并的 `depth_cleared` 同时决定 depth/stencil loadOp | flush 前缀是否需要提交由 pending 工作决定，不能只看 `g_op.open`。清理绑定命令发生时的真实目标/view，与 copy/read/present 顺序一致；depth/stencil 掩码分别保留，部分 stencil mask 不降为整平面清理。实机验 draw→SetRT→clear/copy、清 A→绑 B、清后无 draw、只清 stencil 保 depth |
| P0 完成状态与资源退休 | flush 仍是 void；失败可继续走 present。present 等 fence 超时后仍 free command buffer，`mtl_wait` 无条件成功；设备退出清账未形成完整显式销毁。samples-passed 仍返回固定非零 | 先落实 §8.2.4 的 Recorded/Submitted/Completed/Failed 状态和失败传播；超时不复用/释放 pending 资源，不提前发布 event/fence。真实查询替换固定值，未实现明确失败。用生产路径覆盖提交失败、超时、正常退出重建和查询零/非零结果 |
| P1 当前编译请求与启动诊断 | 本局 204 次真实 compile_fn 成功，同时日志报告 `constantBufferUse` 超出旧掩码、`program.textures[]` 缺真实 texture/view 事实。旧 survey 仍调用已固定返回 2 的 `AndroidDirectBundle` stub，产生大量“现编失败”日志 | 补当前 shader 实际查询的真实事实及依赖身份；被查询而缺失的必需事实准确 MissingFact，不能按某游戏填默认。SetShaders 保留源码快照并允许延期，真实 Draw 走统一 compile_fn。退役 stub 调用及重复 faildump，不恢复旧输出链；旧 survey 的 rc=2 不能当作 GPU 缺 interlock 的证据 |

**颜色线单独核验**：当前日志为上屏源 `src_fmt=37`（RGBA8_UNORM）、swapchain `fmt=43`（RGBA8_SRGB），呈现用 blit；这条路径会进行线性→sRGB 编码，须确认游戏上屏源的颜色约定。它可能影响整体明暗，不足以解释或证明人物全黑与切场景花屏。对照同帧真实源图和屏幕，再决定呈现策略；不全局改纹理为 UNORM、不调亮度掩盖材质缺失。

Vulkan 语义核对：[subpass 颜色附件与 FS Location 对应](https://docs.vulkan.org/refpages/latest/refpages/source/VkSubpassDescription.html)、[image view 的格式/通道/子资源范围](https://docs.vulkan.org/refpages/latest/refpages/source/VkImageViewCreateInfo.html)、[blit 的 sRGB 转换](https://docs.vulkan.org/spec/latest/chapters/copies.html#copies-blits)。

#### 8.4.2 当时建议的执行顺序（历史；当前以 §8 执行顺序为准）

1. **冻结一份实际 direct 候选并复现两处异常。** 固定人物/存档/设置与输入路线，保留人物选择页、切场景前后、世界稳定帧。确认每处 PID/APK/mode；已有 generic 正常画面可作语义对照，但不替代 direct 验收。诊断只抓目标 pass/短窗口，不持续逐 draw 全图读回。
2. **先修可独立验证的提交顺序和清理边界。** 延续 §8.2.4；此项没有闭环前，后续纹理读回可能本身就发生在错误时点。一次一改，不在同一轮再开异步双帧队列。
3. **沿人物和过渡画面的首个错误 pass 定位。** 每笔关联 program 内容身份、各 FS 输出→附件槽/格式/view、实际采样 texture/view/sampler、最近 GPU 写入/CPU 上传/generation/退休事件。先修正 target 分类的独立错误，再核实际 Cube/MRT/view 使用和真实输入；这些成立后，才深入材质 UBO、骨骼矩阵、顶点/索引/实例和 FS 数值。禁止按“哪个槽像矩阵”试绑，也不强制 alpha、关深度/剔除、跳 draw 或删 shader 语义。只修真实触发的通用缺口。
4. **完成当前候选的画面回归。** 人物有正确形状/材质，人物页→进入世界→返回/再次进入无花屏；反复场景切换覆盖纹理复用与缓存淘汰。保存首错与修前/修后证据；正常世界截图不能替代此前失败场景。设备完成状态、退出重建和真实保存后重启读取分别验收。
5. **再恢复性能与缓存任务。** 当前内容 SHA 身份及程序对象复用已有真实消费；A3 仍需完整键全文比较（现在只比较 64 位 key），A4 仍需完成引用/退休和异常闭环。B 设备 driver cache 持久化、C 配方记录/预建未完成，不宣称已具备冷启动预热。先消除正常模式中逐 draw 的 depth-only 成功日志（本局捕获 20,782 行），再按 CPU/GPU 全账选单个热点；不把关日志的预期收益当实测收益。自动离线出包、缺项安全网负例、整局 generic 兜底、第二款游戏和多设备/生命周期验收继续按 §9 完成。旧参考副本删除属于维护清理，排在渲染正确性之后。

**参考接点**：iOS [nvn_mtl.m](../../graphics/nvn/gfx/nvn/nvn_mtl.m) 的逐槽附件/`attach`、depth/stencil 分别 load/clear、注册 texture/view 的 swizzle 与子资源选择；D2R `dm/gfx/vulkan/engine/xbg_game.cpp` 的 `create_pass`、`Image::view`、`prepare_attachment/prepare_read`、`append_depth_planes` 与 slot 完成退休，只逐机制借鉴；Ryujinx Vulkan 的 texture view 和资源同步消费者作第二对照。按[借鉴审计](direct-mode-d2r-study.md) R04/R06/R08–R15/R17 适配当前自有模块，不链接旧引擎、不接 XGS 或另造 shader 格式。

#### 8.4.3 执行记录（2026-10-27 08:35，候选 APK `3052f4de…`，历史）

**改动（都在 NVN/Vulkan 通用语义内；无标题/函数名/地址分支）**

| 位置 | 改动 |
|---|---|
| `nvn_vk_texcache.c` | 目标分类按 `NVNtextureTarget`：CUBEMAP=8（固定 6 面）、CUBEMAP_ARRAY=9（depth 计层-面，必须 6 的倍数）建 `VK_IMAGE_CREATE_CUBE_COMPATIBLE_BIT` 图像与 CUBE/CUBE_ARRAY 视图；5/6 多采样与 10 BUFFER 明确拒绝并写准确原因；samples>1 的非 MS 目标拒绝；目标进入缓存身份比较 |
| `nvn_vk_sampler_cache.c` | 当时把 cube 视图采样器 U/V/W 固定为 CLAMP_TO_EDGE，缓存键含 cube 标志；“Vulkan 强制要求这样设置”的原解释不准确：普通 seamless cube 采样忽略 wrap，具体语义按 [Vulkan 采样规范](https://docs.vulkan.org/spec/latest/chapters/textures.html) 与 NVN 合同核对，不能把此变更当作普遍合法性前置 |
| `nvn_vk_first_draw.c` | `pass_break(sync)` 是否 flush 改由“是否有未提交积压命令”决定，不再只看 open pass；深度/模板 loadOp 改由两个独立掩码决定；多颜色附件槽 1..7 若绑定真实纹理则明确失败（附 `request_id`、格式、尺寸），不再静默只画槽 0；新增 `debug.s2a.tex_diag` 记录被采样的非 2D 目标 |
| `vk_record.c` | 当时 `ClearDepthStencil` 改为按命令位置立即清当时目标，深度/模板分 aspect；当时错误地把 stencil mask `0x01` 当全平面，后续 §8.4.5 已改为按位处理，不能沿用该旧行为；该 opcode 归入需要 sync 提交的操作 |
| 测试 | `nvn_vk_texcache_tex_test` 增加真实 8/9 六面独立颜色 GPU 读回与 5/6 拒绝；`vk_record_test` 增加“清后无 draw”“清 A 再绑 B”“只清深度保模板/只清模板保深度”“部分 stencil 掩码拒绝”并修正原来的假 `tex_t*`（`SET_RT` 会复制对象头）；`nvn_vk_adapter_test` 补显式绘制桩，恢复该探针链接 |

**独立验证（真机 22081212C / Adreno 730）**：`nvn-vk-texcache-tex` 通过（cube=CUBE/6 层、cube-array=CUBE_ARRAY/12 层，六面读回颜色等于写入；5/6 报“multisampled … not bridged”）；`direct_c3_vk_probe` 通过（新增 clear-ds 五项全过，含同步前提交计数）；`direct_c5_nvn_test` 全部通过；`nvn_vk_adapter_probe`、`nvn_vk_record_step_probe` 通过。

**真游戏事实（APK `3052f4de…`，PID 29145，direct/`nvn_vk`，`tex_diag=1`，未开 `draw_log`）**：标题、过场、主菜单、进世界均正常上屏；`tex-diag` 记到 17 条**真实被采样的 target=8** 纹理（RGBA/BC1，16×16–64×64，6 层、1–4 mip，`view_type=3`=CUBE），说明旧分类确实被真实数据触发，修复后按 CUBE 绑定；本窗口无多颜色附件绑定、无 cube 采样器被强制 clamp 的替换、无 draw/clear 失败。**已复现**：物品栏（人物界面）的纸娃娃仍是纯黑剪影（`23-paperdoll.png`、`24-paperdoll2.png`，持续 >5 s 不变）；世界内玩家模型偏白（`25-world-back.png`）。同窗口最后 200 条帧账 gap 中位 118.2 ms、exec 102.4 ms、present 7.5 ms、commands 5169/帧；这不是同场景 A/B，不能当性能回归或达标结论。

**08:35 尚未闭环**：① 纸娃娃黑/世界角色偏白的首错 draw 尚未定位——需要以 `debug.s2a.draw_log=1` + `debug.s2a.trace=<request 前缀>`/`trace_max` 在同一候选上抓该 pass 的真实 program、附件、采样 texture/view/sampler 与 UBO 数值；② texture view（mip/层/格式/swizzle/深度 aspect）在采样与附件两侧仍未完整消费；③ 多颜色附件只是明确拒绝，未实现；④ 当时完成状态机/失败传播/超时资源保留与 `samples-passed` 真实查询未动；⑤ 性能与缓存任务（A3/A4、磁盘缓存、预热）未开始。此后状态机与 view 有部分实现，当前差异按 §7.0 和 §8 执行顺序判断。

下一份交付的主目标是“人物材质与切场景正确，并有同一候选的完成/退休证据”；60 fps、磁盘缓存命中率、文件改名或旧目录清理不能替代它。报告逐项给出已修、已验证、未复现和仍缺项，不用没有依据的整体百分比代替验收。

#### 8.4.4 既有优化核对：保留已生效实现，只补真实生产覆盖

2026-10-27 再次按历史提交、当前调用点和 d2r/iOS 源码核对。不能把“仍有描述符/清屏耗时”写成“此前没做 arena、池复用或批量提交”，也不能从头重建第二套缓存/队列。

| 已有工作 | 历史提交与当前消费 | 实际剩余边界 |
|---|---|---|
| UBO/support/VB/IB arena、帧描述符池 | `495c0e6e` 已移除逐 draw 的 buffer/memory/pool 创建；`8de27503` 又把 arena 跨帧保留，`fd_arena_alloc/reset` 仍是当前路径 | arena 复用不等于相同 guest 范围的内容快照复用：现在仍逐 draw 分配切片并 memcpy。帧池内仍逐 draw 分配/更新四个 set，flush 后销毁池；不重复实施已完成的 buffer/pool 基础合并 |
| draw 批量提交与合并 pass | `d699d42b` 把真实 draw 挂到帧队列；`8de27503` 合并同附件 draw、每 8 个 pass 提前 submit，当前正常模式仍走这条路径 | 这几次提交没有把 `vk_record.c::gpu_clear_image_range` 的立即 submit/wait 改成队列录制。不能用“draw 已合批”推断 clear/copy/upload 都已覆盖；先修 §8.4.1 的前缀顺序和完成状态，再接这类操作 |
| 四个 descriptor set 按管线复用 | `37fc6491`、`623155bf` 已在 `nvn_vk_pipeline.c` 实现 pool/四 set 复用及 UBO/纹理更新接口 | 该消费者加载旧 NVKP/C2 探针 blob；当前游戏实际走 `nvn_vk_draw.c → nvn_vk_first_draw` 的统一 program 内存消费者，没调用这组 set 复用接口。可借机制，不把旧 loader/格式接回游戏路径；录制多笔 draw 时也不能反复覆盖仍被先前命令引用的同一 set |

**d2r 已有的具体做法**（本地基线 `445bf05`，`dm/gfx/vulkan/engine/xbg_game.cpp`）：

- `allocate_set`：按 slot/layout 批量分配 16 个 set，空闲表取用；`descriptors/DescMemo`：完整布局/资源事实命中后复用 set，动态 buffer 只重算偏移；命中仍复核 image 注册 revision、内容与生命周期。`snapshot/snapshot_slow/uniform_snapshot` 对已核对的内存范围复用上传结果，CPU/GPU 写入和提交代际负责失效。当前自有代码缺的是这层真实资源/内容复用，不是再做一遍 arena。
- `clear_attachment`：普通无掩码清理可在真实目标的 open pass 内录 `vkCmdClearAttachments`，后续 draw 接着用；部分通道/模板掩码走精确 clear helper。其他清理也录入 `recording_slot().cmd`，`Commands::finish` 结束 pass/加屏障，不等于每次 clear 都做主机 fence wait；实际提交/等待由 slot 和 CPU 可见边界决定。适配时保留目标/view/scissor/aspect 和资源引用，不导入 XGS 初始化。

**iOS 已有的对应做法**：`nvn_mtl.m` 的 `OP_CLEAR_COLOR/OP_CLEAR_DS` 把可表达的清理接入附件 load action，pass 中或局部/掩码清理用专门绘制；`OP_SET_RT` 在换目标前处理尚未落地的旧目标清理。不能只抄“留一个 pending 值到下一笔 draw”，漏掉目标所有权和 copy/read/present 边界；iOS 本身标出的限制也不能当作正确性证明。

后续按已存在机制做适配与单项 A/B：保留当前 arena、程序/管线/采样器缓存与 draw 合批，优先补当前场景真实触发的语义和 clear 顺序；完成后再选 descriptor memo/内容快照或 clear 队列录制中的一个热点。不得恢复 NVKP/XGS 路径，不把此前旧探针通过记录算成当前游戏消费者已通过。

#### 8.4.5 基础能力记录：提交/退休与清屏（2026-10-27 10:25，阶段证据）

**当时记录的改动（后续已收入 Android 提交 `02a76bb2`；范围和当前剩余缺口以 §7.0 / §8 为准）**

| 模块 | 改动 |
|---|---|
| `nvn_vk_first_draw.c` | 帧队列状态机 `IDLE→RECORDED→SUBMITTED→COMPLETED`，失败/超时为终态并保留首错：`FD_FQ_FAILED`（vkQueueSubmit / vkCreateFence 失败）与 `FD_FQ_TIMEOUT`（fence 未完成）。`nvn_vk_first_draw_flush()` 改为返回 int；终态下不再提交、不释放任何命令缓冲/在途资源、不重置 arena。新绘制在终态直接失败；`QueueFinish` 返回 -2 并写出保留数量；`release_device` 明确记录“随设备丢弃的在途命令”，不伪造完成。新增负例注入 `debug.s2a.fail_submit=1|2`（假装提交失败/假装 fence 超时，命令仍保留）。 |
| `nvn_vk_swapchain.c` | present 先取 flush 结果：队列未完成时不再呈现未完成的帧，返回失败。 |
| `vk_clear.{c,h}`（新增） | NVN 清除语义：一次 render pass + `vkCmdClearAttachments`（整平面/整通道）或受 `VkStencilWriteMask` 约束的全屏三角形（部分模板位）；**scissor 区域**与**目标视图子资源（mip/层/合法格式覆盖）** 都参与；深度/模板分平面；0x01/0x0F 等按 8 位平面掩码处理，不再降级为整平面。部分颜色通道用 push-constant 全屏三角形 + `VkColorWriteMask`（`colorclear_spv.h`），整数附件明确拒绝。fragment/vertex SPIR-V 内嵌，glslc 生成、运行时不依赖编译器。 |
| `vk_record.c` | `ClearColor`/`ClearDepthStencil` 改用上面的清除模块：按 `SetRenderTargets` 记录的视图取子资源范围、按当前 scissor 裁剪；模板掩码按位处理；颜色部分通道掩码按真实 mask 消费；清除值/格式按附件视图的合法格式覆盖转换；越界视图、不同兼容类/深度模板覆盖明确失败。 |
| `nvn_vk_texcache.{c,h}` | 深度/模板纹理拆成两个视图：采样视图只用 DEPTH/STENCIL aspect（Vulkan 不允许采样 DEPTH|STENCIL 合成视图），附件视图保留 DEPTH|STENCIL；换视图不重建图像。采样 view 消费 `view_t` 的 mip/层/target/合法格式/四字节 swizzle 覆盖 builder；view 条目有 pins，LRU 只回收已完成、全部在途时准确失败；附件视图要求单 mip/单层并返回实际 `VkFormat`，颜色兼容类覆盖走 `MUTABLE_FORMAT`，深度/模板覆盖明确拒绝。 |

**独立验证（真机 22081212C / Adreno 730，本机 C3 探针）**：`nvn-vk record` 全过，新增四例：
- 部分模板掩码 0x0F：stencil 0x33→0x3F、深度保持 0.25；
- scissor 清除：矩形内 255,0,0、矩形外保持 51,102,153；
- 深度视图子资源：清 mip1/layer1 后 mip0/layer0=0.9、mip1/layer1=0.25；
- 清后无 draw / 清 A 再绑 B / 只清深度保模板 / 只清模板保深度继续通过。
`direct_c5_nvn_test`、`nvn_vk_adapter_probe`、`nvn_vk_record_step_probe` 全过。

**核验边界**：上述微例和下述注入是执行者记录，本次文档整理未重跑；尚需补 `0x01` 单位掩码、生产队列传播和已提交超时的资源退休等负例。

**真机负例（APK `158bc4c6…`，direct）**：`debug.s2a.fail_submit=1` 后立即出现
`frame queue: injected batch submit failure; 8 command buffer(s) and their resources retained (no retry, no reuse)`，
后续绘制被明确拒绝（`refusing to record more draws`），本局按失败结束；crash 缓冲区无崩溃记录。

**当时未完成/未验证**：深度采样视图拆分已编译并部署（APK `a9ec5a89…`），但设备在进世界验证时掉线
（adb `No route to host`），当时没有拿到该修复的真机画面结论；物品栏纸娃娃黑与左下角圆球异常仍存在，
圆球从上版的彩色噪声变为“暗色玻璃球”（仅在 `158bc4c6…` 上观察，未归因）。后续源码已开始消费采样 view 的格式等覆盖，完整语义、MRT、真实 samples-passed 查询和编译事实仍以 §7.0 / §8 的当前待办为准。

**随后一轮（2026-10-27 11:20–12:00，同一分支未提交）**

- 纹理视图链：`nvn_vk_texcache_view()` 按注册的 `NVNtextureView` 取（或建）精确子资源视图，身份 =
  （mip 起点/数量、层起点/数量、格式、视图类型、通道映射）；同一图像上换视图只建/换 `VkImageView`，
  不重建图像、不重传 CPU 内容，每纹理 8 槽 LRU。深度/模板拆成采样视图（DEPTH-only；stencil 模式为
  `S8_UINT`+STENCIL）与附件视图（DEPTH|STENCIL）。格式覆盖只允许同兼容类（8 位 UNORM/SRGB）且需
  `MUTABLE_FORMAT`；当前未开该标志，覆盖请求明确失败，不赌驱动行为。
- 真机回归与修复（重要）：这一版首次部署后主菜单文字变成实心方块、人物变黑影。根因是默认视图的通道
  映射改成从缓存槽读取，而槽上的 `set_swz/swz` 在建视图之后才赋值 → 字形图集（`a=R`）按恒等映射采样
  （`.a` 恒为 1）。修复：建视图前先写 `set_swz/swz`，默认视图直接用 `tex_t` 的 swizzle。真机复验：
  标题页与主菜单文字正常，主菜单人物恢复完整贴图（与修复前基线一致）。
- 验证：`direct_c3_vk_probe`（新增视图链用例：默认整幅复用、mip/层子视图各自独立且可复用、越界 mip
  拒绝、RGBA8→sRGB 覆盖接受、跨类格式拒绝、target=2 覆盖接受）、`direct_c5_nvn_test`、
  `nvn_vk_adapter_probe`、`nvn_vk_texcache_tex_probe` 全过。
- 仍未闭环：注册视图在真实场景是否出现（当前主菜单 `tex_diag=3` 只有 1 条非 2D 记录、无覆盖视图）
  还没在战斗/物品栏确认；`MUTABLE_FORMAT` 打开后的带宽代价未量；MRT、真实 samples-passed 查询、
  编译事实与失效 survey 调用、纸娃娃黑与左下角圆球仍未解决。

</details>

<a id="android-world-render-reuse-plan"></a>

### 8.5 世界场景实施方案：清屏入队与描述符/上传复用（2026-10-27）

**现行定位（源码至 `8772cf94`）**：本节继续覆盖稳态与流水，不因 F5 完成而退出。G0/F0 已有分项成果及 §6.1 的当前收口项；S1、D1 池保留/类型耗尽轮换、S2 部分整幅 loadOp 清除已有代码，沿用而不重建。D1 的批量分配余项、D2、D3、完整流水与管线缓存仍分别验收。下面 §8.5.1–8.5.8 保留各机制的实施合同；当前优先级、状态和数据解释统一读 [§8.5.9](#android-perf-current)。F4.4 仅为需求编译 worker，不是图形翻译流水。

**目标与边界**：保留已落地的有序清屏，在当前自有 Vulkan 后端中降低程序查找、命令回放、描述符及可证明不变的上传成本；完整异步另按 §8.5.11 交付。保留 §8.4.4 已完成的 arena、draw 合批、pass 合并和程序对象缓存；不重造设备/队列/编译器，不搬入旧引擎，不消费 XGS/NVKP。人物材质与切场景正确性仍优先，性能改动不得遮蔽这些问题。

研究基线为 §8.4 的 `4d03d476` 与已安装 `c85db197…`。研究期间工作树的 `vk_record/texcache/first_draw` 已有并行修补，本文不把尚未冻结/验证的草稿计为完成。实施前重读实际 diff 和最终候选，已正确接入的步骤只补验收，不覆盖或重新实现；§8.4.1 的源码证据描述的是复核时基线。

#### 8.5.1 采用哪些既有机制，分别接到哪里

| 机制与来源 | 当前接点 | 本轮采用范围 |
|---|---|---|
| `495c0e6e/d699d42b/8de27503`：arena、帧队列、程序对象、open pass | [nvn_vk_first_draw.c](../native/nvn/nvn_vk_first_draw.c)、[其头文件](../native/nvn/nvn_vk_first_draw.h)、[swapchain](../native/nvn/nvn_vk_swapchain.c) | 继续由现有 `g_fq` 所属会话统一录制、提交和退休；沿用每 8 个 pass 提交的策略，不另开第二套 completion owner |
| d2r `xbg_game.cpp::clear_attachment/Commands/create_pass` | [vk_record.c](../native/direct/vk_record.c) 的 ClearColor/ClearDepthStencil 与当前 open pass | 借鉴“清理也是命令流的一部分”，先实现保守的有序入队，再独立评估合进 render pass；不把每次 clear 都变成主机等待 |
| d2r `allocate_set/descriptors/DescMemo/uniform_snapshot` | 当前 first_draw 的四 set 分配、更新、UBO/support 上传 | 先池/批量分配，再动态 UBO 与同批 set memo；保留真实复制，避免依赖尚未验证的写跟踪 |
| iOS `nvn_mtl.m` 的 clear/load action、旧目标清理落地、资源绑定复用 | 当前 NVN 状态快照、所选 view、批次资源引用 | 借清理与目标绑定、不可变上传和失效规则；不照搬 Metal 参数表、旧 support 大小或旧 shader ABI |
| Android [现有 tracking](../native/runtime/tracking/README.md)、`nvn_dirty` API | 后续内容快照与失效，不作为首版描述符复用前置 | 先验证最终链接和实际写入通知；优先适配已有 tracker/dispatcher，不能再装一套会争夺页保护的缺页处理器 |

`37fc6491/623155bf` 的旧 `nvn_vk_pipeline_sets/update_*` 只作接口/机制参考，不直接接其 NVKP loader。当前 program 的 set/binding/stage/element 和真实资源来源保持原合同，不重映射为 d2r 单 set。

#### 8.5.2 G0：先使现有队列成为可依赖的完成边界

**状态：F0 候选已有分项验收，适用范围见 §8.0.1；当前呈现退休/等待差异见 §6.1。** 下列为复用前置合同，不代表当前所有接点均已履约，也不要求重做已通过的用例。

G0 是清屏入队、池复用和后续缓存共同前置；不是另造一套帧队列。修改范围限于当前 queue owner、record/shim/adapter/present 调用方及相应生产用例。

1. 将 `nvn_vk_first_draw_flush` 和需要提交的 `pass_break` 改成能返回成功/失败的接口，同步头文件、弱声明、所有调用方和测试 shim。`pass_break` 关闭 pass 后，是否需要 flush 看 pending 前缀，不因 `g_op.open==0` 提前返回。
2. 明确 `Recorded → Submitted → Completed`，另记提交失败或完成未知。`submitted_n` 只在提交成功后推进；最后一个 fence 覆盖同 queue 的全部前缀。超时不 reset/re-submit 原批次、不继续 present 或发布 guest 完成，不释放其资源；保留首错。QueueFinish、需要 CPU 可见的 copy/read/event/query 与退出按真实边界消费结果。
3. 一次 frame 内可以因容量/CPU 读/Finish 多次完成批次。区分 device/session generation、提交批次 epoch、descriptor pool epoch 与 guest frame；不能以“还没 present”或“帧号相同”推断 arena/set 仍属于同一有效批次。
4. 录制时就持 image/view、buffer、program/layout/pipeline 引用，提交后继续持有到完成；LRU 只移除查找入口。队列/资源预算满时有界等待或明确失败，不能丢 pass、停止 pin 后继续画。Stop 按停止生产→完成/保留失败批次→显式销毁子对象→销毁 device 收尾。

新复用路径须先证明其依赖的完成与引用合同；现有修补与用例能覆盖时直接复用，不重建队列或重复领取。

#### 8.5.3 S1：先把现有支持的清屏有序入队

**首版选择**：先在现有 owner 内增加非绘制命令录制/入队接点，保留清屏的真实位置；不要求第一刀就折叠 loadOp、不同时把所有 copy/dispatch/upload 改异步。`vk_record` 负责解码与语义校验，owner 负责命令缓冲、资源引用和提交结果。不得只删除 `vkWaitForFences` 后继续使用旧 `submit()` 的立即释放逻辑。

内部接点分工固定为：record 解码并形成 `ClearSnapshot` → owner 的 clear-record 入口核验/持有引用、结束旧 pass并取得命令缓冲 → 录清理与依赖 → 追加同一队列。入口返回的是“已成功录制/失败”，不是 GPU 已完成；完成只由 G0 发布。接口两端与测试同批修改，真实 direct 路径缺 owner 接点必须明确失败，不能因弱符号缺失悄悄走无顺序保证的旧 helper。独立探针若保留同步执行，须显式注明其 fixture，不能冒充生产队列覆盖。

- 在清屏命令发生时形成自有 `ClearSnapshot`：命令序号、目标 backing/view 引用及 generation、有效格式/标量类别、samples、颜色槽或 depth/stencil aspect、所选 mip/layer 与尺寸、真实 scissor、通道/模板掩码和清理值。不能保留随后会变的 `S->rt`、guest `tex_t*` 或 payload 裸指针。对附件只清实际选中的子资源，不把采样 view 的全部 mip 都清掉。
- 普通整目标、整通道清理：先关闭并按序入队旧 pass，在 render pass 外录 `vkCmdClearColorImage`；合法的 depth/stencil 整平面清理用对应 clear 命令。清屏命令缓冲登记进同一个 `g_fq`，随后 draw 按原序继续，普通 clear 不自行提交/等待。可先一条 clear 一个 command buffer，连续清理共用缓冲的优化另测；不能颠倒已有命令来凑批次。
- 使用资源实际布局和 producer/consumer 的 stage/access 建依赖。保守屏障可以先宽后收窄，`GENERAL` 不代替内存依赖。除已证明的新图像/可丢弃完整内容外，不用 `oldLayout=UNDEFINED` 处理已有图像；尤其只清 depth 或 stencil、局部 scissor、其他 mip/layer 时必须保留未选部分。
- 格式覆盖 view、局部 scissor、部分颜色通道或 stencil 位掩码不能降为全图/全通道清理。可走已经证明正确的慢路径，但它执行前必须先完成有依赖的队列前缀；慢路径未实现就明确 Unsupported。后续精确实现用正确的 attachment view、`vkCmdClearAttachments` 或通用 masked-clear helper，不复制游戏 shader。
- 成功录制后就标记该范围存在 pending GPU producer，阻止取旧 CPU 镜像重建；这不是向 CPU 宣布执行完成。clear 的引用/写入代际和普通 draw 一起进入提交与退休账，提交失败/超时不将其当已完成内容。
- 其他仍立即提交的操作暂走正确保守路径：若与排队前缀有依赖，先提交并按需要等待；不能让未改造的 upload/copy 越过新队列。CPU 读回、guest 完成信号与 present 读 RT 继续按 G0 的前缀完成规则处理。

**S2 后续可选**：S1 正确且 profile 仍显示 clear/pass 开销显著，再借 d2r 把兼容清理录为 open pass 内的 `vkCmdClearAttachments`，或在证明没有中间访问时用下一遍的 `loadOp=CLEAR`。必须保持同 backing/view、Location/scissor/掩码和顺序；换目标、copy/read/present、事件/查询或退出前让旧目标清理落地。helper 不能污染后续 game pipeline/descriptor 绑定状态或计入游戏遮挡查询。S2 不和 S1 同批改，不以减少 clear 数量作为验收。

#### 8.5.4 D1：沿用 arena，先完成池与 set 分配复用

保持 `fd_arena_alloc` 的现有分配与数据复制。只在**该池关联的全部命令确已完成且不再引用其 set**后，清失效 memo/绑定记录并 reset 池，按需保留池对象供下一批使用；不能每帧固定 reset，更不能 reset pending 池。对应 epoch 在 reset 时推进，旧 set 全部视为无效，不跨 epoch 复用句柄。

参考 d2r `allocate_set`，按 set-layout 身份准备有界的空闲 set 列表，可每次分配 16 个再逐个取用；具体批量是可测参数，不按游戏写死。不同 layout/descriptor 类型和数量分别统计，空 set 的处理保持 pipeline layout 契约。池耗尽时有界新增池或安全完成批次后复用，旧池随所属批次持有。D1 只减少 pool 创建/销毁与分配 API 次数，不能称“描述符内容已缓存”。

#### 8.5.5 D2：四 set 原位映射，动态 UBO + 同批描述符 memo

**首版保留逐 draw 的 UBO/VB/IB 真实 memcpy。** 在同一个 arena buffer 内，不同 draw 用不同 offset，仍可共享只描述 buffer/range 的动态 UBO set；这项不需要先做跨帧写跟踪或快照缓存。它优先减少每 draw 的 `vkAllocateDescriptorSets/vkUpdateDescriptorSets`，不是宣称取消所有数据复制。

1. 以当前 program 的真实反射建立确定的 `LayoutVariant`：挑选可用 dynamic UBO 的绑定，查询实际 `maxDescriptorSetUniformBuffersDynamic`、每阶段 UBO 限制和 offset alignment；超过限制的绑定用静态 descriptor，策略固定且可追踪。保持 shader 的 set/binding/element 不变。host 动态 descriptor 类型属于后端 layout 策略，不修改统一 program JSON 或源 shader。
2. Program GPU 对象、pipeline layout、pipeline 缓存身份都包含这份 layout 策略/版本和 device generation，动态/静态 layout 不误共用。不能只改 `vkUpdateDescriptorSets` 的类型而沿用旧 set layout/pipeline layout。已有 A3 键与兼容性缺口同步按 §4.17 修正，不以 requestId 或一个裸 64 位 hash 代替全文相等。
3. 每个 set 的 memo key 包含：布局身份与 pool/batch epoch；每个有效 binding/array element 的类型、数量、实际 VkBuffer/静态 offset/range 或 VkImageView/VkSampler、资源/view generation 与声明 layout。只有被确认为动态绑定的 offset 可以从 key 排除；它改由本次 bind 传入。hash 只作查找，命中还比较规范化的完整有效字段，不比较 padding。
4. 动态 offset 按 Vulkan 的 set→binding→array element 次序构造，验证基址和 offset 的对齐、`baseOffset+dynamicOffset+range` 边界、`uint32_t` 可表达范围和 arena chunk。换到不同 VkBuffer 或 range 改变时，重新查 key/建立新 set；不能截断偏移、把所有阶段或槽绑定到同一块常量。
5. miss 从 D1 取新 set、只写一次真实描述符，再发布 memo；hit 复核资源存活/注册代际，绑定同一个 set 与本次 offsets，不再 update 已录制使用的 set。没有 update-after-bind 前提时，改写被 recording/executable 命令引用的 set 会使命令失效；也不能靠打开该 flag 把应有的逐 draw 输入快照变成“大家读最后一次内容”。
6. 首版 memo 只在当前可证明安全的批次/池 epoch 内有效，持有 layout 和实际资源引用。完成后随批次清条目，再回收 set；不先做跨帧 pinned memo。不满足 fast path 条件但已有正确实现的资源走当前慢路径；未实现功能仍报 Unsupported。缓存满只是缓存 miss，不跳 draw、不返回空资源成功。
7. 如再加 bind 跳过缓存，只在**同一个 command buffer 与兼容 pipeline layout**中比较 set、offsets 与绑定状态。新 cmd、helper 绘制或状态被外部调用改变时必须失效；首版可继续每笔 bind，以免一次改两类状态缓存。

#### 8.5.6 D3：上传内容复用分层，跨帧缓存不得先行

| 层次 | 可实施做法 | 准入与失效 |
|---|---|---|
| 自有不可变数据 | 对实际 support 内容与 C1 源快照建立有界只读上传对象；命中复用 buffer/offset | 由当前真实 support 布局、所有影响字节的状态、真实 C1 内容/依赖及 device generation 标识。不能只按视口宽高做 key，也不能搬 d2r 的 1392 字节默认块；已被命令引用的字节不原地改写 |
| 同批 guest 范围 | 只对同一份已捕获输入的重复消费复用自有 SnapshotRef；跨 draw 读取仍可改的源时，须完整核对当前内容或有完整写观测证明 | 地址、长度、pool/backing generation、内容版本和范围别名都要一致；`OP_UPDATE_UB`、host/guest CPU 写、GPU 写/回写及 pool/VM 变化按重叠范围失效。同一 guest 提交内也不假定内存不变；只有哈希时还须字节核对，不能用短 key 决定内容相等 |
| 跨批/跨帧 guest 内容 | 后续对经过真实写跟踪证明的稳定 VB/IB 等保留不可变副本，变化时新建、旧副本等引用退休 | 必须证明所有 relevant CPU/host 写、GPU producer、别名与地址重用都被观察。无证明或易变范围继续复制；不能先上持久缓存再靠画面发现漏失效 |

**Android 当前关键前置**：`runtime/nvn/vk_engine_host_shim.c` 中 `dm_fault_hook_register`、`dm_guest_write_prep_register`、`dm_guest_write_prepare` 仍有弱空实现。实施时必须核最终 ELF/运行时绑定及真实 guest 写、host 写、pool 销毁重建的代际测试；源码中“调用过 nvn_dirty”或 `dirty_now` 没变不构成覆盖证明。证明不足时不主动对 guest 页启用这套保护，不开放地址型跨帧命中；D1/D2 仍可独立完成。

若需要接跟踪，优先评估已有 `graphics/track` 与 Android tracking 的 dispatcher、backing/VM 和别名合同，不安装竞争的第二套 mprotect/SIGSEGV owner。pending GPU 写入范围先解决真实 producer/CPU 可见性，不把“CPU 页没写”当成 GPU 内容没变。接口能力不足单列后续工作，不让它演变成当前两处优化必须先重写内存系统。

#### 8.5.7 每个交付必须覆盖的验证

用例调用当前 production record/queue/program 消费者。现有 `vk_record_test.c`、`nvn_vk_record_step_test.c` 可扩展，但当前 record-step 脚本未链接 first_draw，不能拿它单独证明真实游戏的延迟提交正确；应增加实际 owner 的针对性用例及设备测试，不复制一个模型自行判绿。

| 验证 | 独立期望与必须保留的证据 |
|---|---|
| 绘制与清理顺序 | draw 红→SetRT/结束 pass→清蓝→读回为蓝；清 A→绑 B→draw 只改 B；清后无 draw、只有 present/read/退出时清理仍生效 |
| 只清选定部分 | RGBA8 旧值 `(255,0,255,255)`，清值 `(0,255,0,0)`、仅 RG 写掩码，结果 `(0,255,255,255)`；stencil 原 `0xAA`、清 `0x55`、mask `0x0F` 得 `0xA5` 且 depth 保持。零 scissor 不改内容，非零 mip/layer 外的哨兵不变 |
| 不可变命令与引用 | 录制后改原 NVN 对象/clear payload，不改变已录命令；小容量强制提交、LRU 和多次 flush 不丢 draw/clear、不提前复用图像/布局/arena/set |
| 提交与失败 | 在第 8 个 pass 提前提交、全部已 submit 后只挂最终 fence、submit failure、fence timeout、Stop/重建均走真实状态机；失败不重复提交/假完成、不释放 pending 资源 |
| 动态 UBO/set memo | 同 program 两笔 draw 分别用红/蓝常量，能复用同 set 但各读各自 offset；同地址随后写新字节、VS/FS 同槽不同内容、换 arena chunk、换 range/image/view/sampler 后结果正确；强制 hash 冲突不误命中 |
| 池与代际 | pool reset 后旧 memo/set 不再使用；设备重建旧句柄不返回。布局策略变化建立相容的新对象，不把旧布局下 set 绑进新 pipeline |
| 真实场景 | 同一候选验证人物页、进入世界与返回重进，没有新增全黑/花屏；保存后重启读回与失败兜底按 §8.2/§9 继续验收。旧 NVKP、合成清屏或只运行成功不能替代本项 |

诊断可对短用例启用 validation/synchronization validation；正常性能局关闭高开销层与逐 draw 转储，错误日志保持可见。条件不足明确列未测，不以 `S2A_TEST_NO_NATIVE=1` 或旧探针代替真实 native 消费。

#### 8.5.8 执行顺序、计数和收益判定

| 独立交付 | 前置 | 完成标准 |
|---|---|---|
| G0：提交/完成边界 | 核对并行修补，先跑负例 | 前缀顺序、资源引用、失败/超时传播和正常退出成立；尚有内容错误时不宣布整体验收 |
| S1：现有支持的 clear 入队 | G0，目标/view 与清理语义已核实 | 普通 clear 自身不再增加逐次 wait/submit，draw/clear 顺序与图像结果不变；其他同步慢路径正确 |
| D1：池保留与批量分配 | G0 | 完成后安全复用池，pool 创建/销毁及 set allocation API 次数下降，旧 epoch 不命中 |
| D2：动态 UBO + 批次 memo | G0/D1、layout 兼容身份成立 | eligible hit 的 descriptor allocate/update 为零，offset 不同仍画出不同正确结果；真实游戏消费该路径 |
| S2 / D3：进一步合 pass / 内容快照 | 分别有新的热点证据与其专属正确性前置 | 单项 A/B 有整帧收益；不把跨帧写跟踪、异步多帧或另一套队列塞进前四项 |

单轮只交一项可归因变化；已完成的 S1/池复用/整幅 loadOp 清理保留，按 §8.5.9 排实际剩余项，不再机械重复 S1 → D1 的施工。D2/D3/流水各满足专属前置后再实施，不把几项一起打开而无法归因；没有需要的能力则交准确缺口，不用未支持功能的伪成功维持 FPS。

低频累计计数至少包括：clear 总数/入队数/折叠数、submit/wait 的次数/原因/总时长；pool create/reset/destroy、sets allocate/update 与 memo hit/miss/失效原因；UBO/support/VB/IB 实际复制字节、内容核对开销；arena/layout/image generation、在途与退休数量。统计覆盖正常 deferred 分支，命中也要记资源刷新和失效成本，不从启动以来累计平均推断当前世界成本。

收益按同设备、同实际 direct 候选、相同内容/画面/路线与缓存温度做单项 A/B，至少记录稳定世界 60 秒的真实 successful-present 计数和完整帧时 p50/p95/p99，以及 exec/submit/wait/present 分项。性能目标先按游戏实际请求的帧率判定，不承诺从当前约 15 fps 直接达到 60。

特别注意：§8.4 的 ClearColor 12.2 ms 是主机执行该 opcode 的区间，可能包括等待前面 draw，不能全算成清屏本身的 GPU 计算。clear 时间减少、present 等待等量增加只说明换了等待位置；只有整帧时间和实际提交节奏改善且画面不变，才算收益。描述符更新次数下降也要与命中检查/复制的新增成本一起量，不能把 d2r 的命中率/收益搬作本项目数据。

实施 PR 写清具体交付、使用了哪些已有机制、首错/负例/实际场景证据和剩余缺口；按贡献流程检查，共享跟踪接口的改动另附平台影响证明。既有交付与待办以 §7.0/§8.5.9 分列，本次整理未执行运行时代码改动、真机回归或新增通过结论。不新增重复交接文档，不为普通优化更新 CHANGELOG。

规范与实现对照：[Khronos 描述符管理样例](https://docs.vulkan.org/samples/latest/samples/performance/descriptor_management/README.html)、[更新 set 对已录命令的影响](https://docs.vulkan.org/refpages/latest/refpages/source/vkUpdateDescriptorSets.html)、[动态偏移](https://docs.vulkan.org/guide/latest/descriptor_dynamic_offset.html)、[bind 顺序和偏移约束](https://docs.vulkan.org/refpages/latest/refpages/source/vkCmdBindDescriptorSets.html)、[池 reset 的完成前置](https://docs.vulkan.org/refpages/latest/refpages/source/vkResetDescriptorPool.html)、[render pass 内清理](https://docs.vulkan.org/refpages/latest/refpages/source/vkCmdClearAttachments.html)、[颜色清理](https://docs.vulkan.org/refpages/latest/refpages/source/vkCmdClearColorImage.html)、[深度/模板清理](https://docs.vulkan.org/refpages/latest/refpages/source/vkCmdClearDepthStencilImage.html)。

<a id="android-perf-current"></a>

#### 8.5.9 当前执行清单：先纠正观测，再分别降低关键路径成本

**不变的路线**：共享前端、单一 Vulkan owner、真实编译事实、`s2a-direct-program-v1`、离线预编+现场补编+跨局缓存、故障下局 generic。无需切回 XGS 或引入第二后端；JSON 包装不是本轮已定位的逐笔热点。已生效的磁盘缓存、arena、池复用和 draw 合批不重查重做，只对新增改动回归。

| 交付顺序 / 对应反馈 | 范围与真实落点 | 独立期望与开始条件 |
|---|---|---|
| 先校正观测 / P4、P5、P6 | `mtl_vk_shim` 固定 PID/模式/帧序号与独占/嵌套区间；`nvn_vk_draw` 分开 compiler attempt/success、disk adopt、内存 hit/evict；低频汇总 depth-only；缺事实诊断记录原始 format/target/layers/view 与注册代际；`5ac9696f` 起再单列“源快照拒绝”“内容代际”“身份不可用（本窗）”，把“没做查找”与“查了没中”分开 | 仅磁盘 adopt N 次时 compiler_success/identical_recompiles 必须为 0；只有真正执行并成功的相同完整编译请求才进入重编历史。启动首读模式与进程绑定；max 不冒充 p90，统计先累 ns 后归一，不逐项截断后相减。先产一份低日志、固定设置的新基线，不重装/改设置打断正在玩的局 |
| 正确性收口 / F0、F3、F4 的新增缺口 | §6.1 的提交/呈现退休区别、`mtl_wait`、拍平 OOM/Stop、查询发布；源引用/完整身份反例已在 `5ac9696f` 修（宿主回归）；F4.4 调度差距只剩 owner 循环、挂起/恢复与管线转交 | 同 key 多代引用准确配对；同短 key 不同源在普通/P1/磁盘路径均不误用，旧不完整键不再准入。**修订后必须在设备上重跑**：新身份不命中旧磁盘条目属预期，不能把“次局命中数下降”当回归。OOM 不得丢命令还发 fence；GPU 未完成不假成功；无后续帧、超时、窗口撤销准确推进/失败 |
| P1 修正与验收 | 备忘键已按 §8.5.10 补齐（`5ac9696f`），生产接缝回归 `direct_nvn_compile_facts_test` 覆盖顶点类型/附件/SSBO/closure/源代际；真实命中入口有 `debug.s2a.id_verify=1` 自检 | 先测“连续同依赖”比例，不把 99.98% 全表命中当作上一条目命中；相关字段变化、短 hash 冲突及槽位复用均不能误命中。首次/失效继续走完整身份路径，记录省掉的事实/编码次数与实际整帧收益，不承诺 6–7 us 或 19 FPS。**先真机量最近条目命中率与代际推进频率**，再决定是否继续在这条捷径上加码 |
| P3 先核实包装成本 | 测量 `mtl_vk_adapter_exec_guest → s2a_record_exec_one` 的加锁、malloc/copy/replay/free；有界批次接收/回放仅作候选优化 | 新落点计时只覆盖部分复制/回放入口，先补齐 malloc/free/锁等待/收尾，确认实际成本再决定是否批次化。若改批次，同一含 CALL/JUMP/END、跨命令状态和精确错误位置的流旧/新输出须一致；一次持有批次引用，F4.4 编译暂停/Stop 不死锁。模式 0 不因异步快照增加无必要复制；不把整个未知 guest 链无界复制。P3 的 4.9 ms 当前只是不同口径相减的猜测 |
| 按实测选择 / P2、D1/D2/S2 | 区分 render-pass/framebuffer 创建、open/close、状态切换及批提交；先给关闭原因计数，再选择复用或合法合并；描述符按现有 D1/D2 合同推进 | `passes` 当前是 begin/close 计数，不是已测出的“可消除 break”。28/256×492×73 us 不能证明可省 3.9 ms；`pass` 计时还含对象创建与关闭。附件/子资源、clear、query、copy、barrier、CPU 可见边界不因合并而改变；先核完整 pipeline/layout 身份再开 memo |
| 后续独立交付 / 完整流水 | §8.5.11 的 Present/Acquire 和有界资源槽；驱动缓存、配方预热另验（管线身份已在 `2b3e7bdb` 改为完整配方） | 旧两档线程测试只说明该 drain 实现未观察到收益，不宣布流水无用。前置正确性、资源引用和分配预算齐备后再做同包 A/B；保持缺省关直至有真实收益与时延证据 |
| 产品链继续 / F5.2–F5.5、§9 | 自动离线生产/消费/漏项安全网、下局 generic 同存档、真实 IME、首款完整路线，随后第二款/三前端/设备矩阵 | F5.1 已有交付不重领；离线库与真实失败演练不能被性能支线无限推迟。动态分辨率、格式二进制化、绑核和帧率解锁不作本轮前置 |

P4 不是“把所有未映射 NVN 格式补成某个现有枚举”：取到真实 format/target/view 后，分清采样事实、storage image 格式和 host VkFormat 的语义；该 shader 实际请求的事实缺失就准确 MissingFact/Unsupported，未查询的绑定不能仅凭提示推断已经错编。合成 accessor 反例与真机前后查询证据一起验，不写游戏 id 规则。P6 的日志在每笔 depth-only draw 的路径打印，并非独立的 pass 关闭计数。日志量已实测很大，但未测降噪收益，不把它预先称为零开销或头号瓶颈。

**排期解释**：上表不要求从第一行串行做到最后一行。正确性、观测和 F5 产品链按各自前置推进；F5 不等待 P3/D2/D3、完整流水或 driver cache 全部实现。优化机制只在热点与 A/B 支持时进入交付，某机制无收益可保持关闭；正式功能、正确性与产品性能验收仍必须完成。§7.0 的八组是范围分类，不是八个等权任务或八个必做重构。

**测量交付**：同一真实帧序号下分别登记 wall / thread CPU、guest/API 录制、快照与入队、worker 执行、drain/锁等待、GPU submit/fence、present 及 Acquire 等待；嵌套项不重复相加，跨线程重叠用时间线表示。查找和 draw/op 的统计改为同一窗口/样本集合，先累 ns 再输出；`other` 在完成分解前保留“未归因残差”。GPU 用合法的设备时间戳或 GPU 工具量完整区间，query/时钟域尚未支持时如实留缺口，不能拿 CPU fence wait 代填。Android 无 root 不自动排除采样：优先核最终 APK 的 release/profileable 与符号，实际采样权限/硬件事件不具备时单列限制。[Android profileable 官方说明](https://developer.android.com/guide/topics/manifest/profileable-element)。

#### 8.5.10 P1 的安全命中合同：复用已验证身份，不能删掉身份检查

最近结果备忘复用原缓存对象，有界保留候选，不建立另一套 program cache，不改变磁盘键、编译请求、解析器与跨局校验。**完整规范输入等价是判据；优化的是证明等价的成本。** 以下都是实施与验收要求，不是当前已有保证。

**P1 已提交版本的反例（不计验收通过）**：`a922d636` 中 `nvn_vk_draw.c` 的 SHA-256 `a9a39bae8d5da293e4b27c826fce49a5f614240ccc8fd258a3e1563f46028eeb`；抽取原样 `id_key_fill/id_memo_match/nvk_attribute_type`，链接生产 `input_identity.c/texture_facts.c`，仅把 `vattr_fmt[0]` 从 0x1 改成 0x3。NVN 期望属性类型 Float→Uint，完整编码实际不同，而该版本 memo 仍判相同（`canonical_equal=0 memo_match=1`，期望 memo_match=0，退出 1）。这是 CPU 匹配函数反例，未执行完整 draw/GPU；详见[坑记录](../../docs/坑记录.md#android-p1-memo-counterexample)。后修订需按全部 producer 核对并复跑反例；serial 只证明缓存槽未替换，不证明输入未变。

**修订实现（`5ac9696f`，2026-10-28；代码与宿主回归，未做设备命中率验收）**：备忘的键与匹配移到 `nvn_vk_compile_facts.c`（纯计算单元，`nvn_vk_draw` 只取快照/查表/编译），键覆盖：session/generation/registry 代际/源内容代际、direct ABI、closure 哈希、shaderDrawParameters、阶段掩码与 key 组、6 槽 constantBufferUse 与溢出位、**32 槽顶点属性格式**、**颜色附件槽（key/format/NVN 兜底格式/对象 magic）**、SSBO 是否绑定、纹理/采样器池容量、TF、prim/rt_count、已绑定状态对象原文与 kind 掩码、各 stage 各槽纹理句柄、depth/origin 模式；绘制参数不进键。源内容代际只在“key→内容映射变化”时推进（新 key、淘汰后重登记、冲突/拒绝），同内容重复 SetShaders 不会把备忘刷掉。`direct_nvn_compile_facts_test` 原样链接生产 `source_store`/`compile_facts`/`input_identity`，逐项断言“改变事实 → 身份与备忘键同时改变”，并保留 `a922d636` 的顶点类型反例、强制同短 key 不同内容（身份 -2，不做查找）与缺源反例。真实命中入口另有自检：`debug.s2a.id_verify=1` 时备忘命中会再走一遍完整事实/身份，与条目保存的规范输入逐字节比较；不一致就记数并退回完整判据（日志 `P1 自检失败`），`program cache` 低频行打印自检次数。它默认关闭，只用于在设备上证明捷径等价，不改变命中判据。仍待验：真机最近条目命中率、代际推进频率、以及“近条目命中”相对完整编码的实际整帧收益；未量到之前不声明性能收益。

1. **快照覆盖**：完整源身份/快照版本与阶段映射、constantBufferUse/overflow、所有实际输入 graphicsState（包括顶点 attributeTypes、附件 fragmentOutputTypes、SSBO 是否需未对齐访问的来源）、真实纹理/视图/采样事实及缺项状态、池容量、TF、profile/ABI/闭包，以及 session/device/source 生命周期都要覆盖。首版沿现有完整身份的保守依赖范围；不能未经证明就删“看起来没用”的字段。轻量 hash 只能预筛，无损字段/不可变快照引用或已证明的单调版本才可证明未变；不比较带 padding 的任意结构体内存。
2. **发布与失效**：texture/sampler 注册/覆盖、view、pool/backing 重建、代码/C1 更新及影响编译的 GPU/host 写必须被观察，相关版本在一致快照完成后发布。当前单一 `g_registry_generation` 不能直接充当全部依赖证明（例如 pool_add/del 不推进它）；需先列出 producer 覆盖与锁/发布规则。无法证明的字段仍逐项读取比较，或退回完整编码，不用未变的地址/handle 推断内容未变。
3. **缓存槽引用**：最近结果绑定原条目的槽位代际与 session/device generation；用前核存活并取得现有 users 引用，淘汰/reset/Stop/重建后失效，避免静态槽复用导致旧指针指向新条目。失败或未就绪结果不进成功捷径；disk adopt 仍须有已校验结果与对应 C1。不能为缓存命中跳过实际资源解析/保活或选择兼容 GPU pipeline。
4. **退回路径**：先补齐 §7.0 的源身份/引用缺口，普通路径不能只编码短 stage key。首次、任何依赖变化、无完整版本证明、槽已退休时，执行事实收集→包含完整源身份的规范编码→hash 候选→逐字节核验；确实 miss 才计算持久化 SHA/读盘/补编。通过后更新最近快照，不假定全表 hit 必然是最近 hit。若最近入口命中少，依据计数考虑按不可变组件缓存派生事实，而不是先增加多级表。
5. **独立反例**：同短 stage key 的不同源；仅改变 constantBufferUse/overflow、顶点属性 Float/Uint/Sint、同附件槽的输出类型及 SSBO 来源、同 handle 覆盖格式/target/view、相关容量/TF/graphicsState、profile/ABI/闭包；强制轻量 hash 相同；原槽淘汰后复用、设备重建及迟到结果。未变依赖的重复 draw 应免完整编码；任一相关变化必须进入复核/新变体或准确失败。测试走真实生产命中入口，并与禁用捷径的输出/反射/结果身份对照；像素与故障回归按实际改动范围补。

#### 8.5.11 整体流水与三层缓存：分别设计、分别验收

**现状（2026-10-28 更新）**：`dd084536`/`f6adde9a`/`930e7cee` 之后，guest fence 走带预算的完成证明（按提交回放追踪、纯轮询无副作用），管线缓存使用完整规范配方；`8772cf94` 的 shim 在 commit 才交付拍平命令，`mtl_present` 先 drain，再同步执行呈现；命令副本只解决记录字节的生命周期，引用的数据/注册表/view/池仍须各自保持语义。默认关闭是合理的开发状态。对照本地 D2R `hle_nvn.c`，其 `XJ_PRESENT` 也入队后返回，Acquire 才按对应图片的票号等待归还；所以“我们已经完整照搬它的流水”不成立。一帧一次 guest 提交也不禁止后端分批录制/提交，当前 `fd_submit_batch` 已按 pass 数提前提交。

**调整后的目标流程（待实现）**：沿现有 owner 顺序队列接收有界、自持引用的命令批次和本帧呈现任务；提交返回表明已接收，绝不表示 GPU/显示完成。先在该串行 owner 内保证本帧工作与 blit 的 GPU 依赖，再逐步让调用方返回、到对应 guest 图片再次 Acquire/复用、CPU 读回或明确同步时才等相应票号。无需把上一帧冒充本帧；允许的在途数量受真实图片/资源槽容量和延迟预算约束，不能无限排队。

- 使用现有提交/退休账本扩展批次持有：arena 切片、descriptor pool/set、命令缓冲、image/view/backing、查询记录及完成证据随真实使用保活。渲染完成、呈现资源可退休、实际显示时间分别记录；不能只删 wait 后立即 reset 池/arena 或复用单个 acquire/release 信号量。
- Stop、窗口撤销/旋转、后台、队列满和编译挂起能唤醒/准确失败；不在持 guest/VM/registry 锁时等待 owner，也不能让 owner 等自己。先通过 §6.1 的完成/present fence 合同，再测试无后续帧的退休，不把继续出帧当收尾条件。
- 同包同步/异步 A/B 除吞吐外量输入到显示时延、在途深度、内存和热状态/能耗；先证明时间线有重叠再评收益。GPU 等待变长可能只是 CPU 更早到达，某一子项变短不能替代整帧与画面验收。默认开关只能由实际验收决定。

| 缓存层 | 当前基础 | 独立剩余交付 |
|---|---|---|
| 程序内容 / F4、F5.1–F5.3 | 进程内程序、跨局 SPIR-V+元数据结果缓存已有，P1 优化其热命中 | 离线库生产/消费与漏项验收；身份正确性不因快命中降低 |
| GPU pipeline/layout 对象 | 进程内对象和 `VkPipelineCache` 已有；`93fe941d` 起驱动管线缓存落盘/恢复（`nvn_vk_driver_cache`：pipelineCacheUUID + 格式版本隔离、SHA-256 校验、原子 rename；真机 store 1,257,119 B → 次局 load 同字节同 UUID）；`f6adde9a` 起管线缓存使用完整规范配方（`nvn_vk_pipe_recipe`：程序内容 SHA-256、request_id、设备句柄、布局策略版本、全部已绑定状态对象、顶点属性/流、prim、附件格式与 rt_count/depth_only），hash 只作预筛，命中必须逐字节相等；宿主 `direct_nvn_pipe_recipe_test` 覆盖 18 项输入与强制 hash 相同也不命中的反例 | 真机上复核管线命中/新建计数与画面；布局策略变化时递增 `NVK_PIPE_LAYOUT_POLICY`；完整管线退休与 driver cache 仍独立验收；不把 program 缓存正确等同 pipeline 正确 |
| 驱动缓存与配方预热 | 当前空 initialData 创建进程内 `VkPipelineCache`，未见生产落盘/恢复 | 按设备/驱动/cache UUID 与 ABI/闭包隔离、损坏拒绝、原子持久化；只预热有真实来源的配方，不用占位 shader、不让全量预热阻塞首次启动。其收益与 shader 包格式、P1、稳态流水分别测 |

规范参考：[描述符与缓冲管理](https://docs.vulkan.org/samples/latest/samples/performance/descriptor_management/README.html)、[pipeline cache](https://docs.vulkan.org/guide/latest/pipeline_cache.html)。不搬这些样例的设备收益数值作为本项目承诺。

### 8.6 2026-10-28 收口状态（本分支，android/direct-mode-d2r）

已完成并各有提交/读数（细节见 §7.0 与 `docs/坑记录.md`）：

| 项 | 提交/证据 |
|---|---|
| 直连紫/绿反馈采样修复（快照替换，诊断+回退开关） | `9c3443587`、`415464bc1`；真机洋红 0.0/728 帧，13:51 斑块异常保留待查 |
| F5.2 离线库生产端 + 真机捕获（100 程序/7.78 MB，verify 通过） | `60682ecad` |
| F5.3 消费端接线、`no_disk_cache`/`no_offline` 解耦、诊断根 | `0d65e7563`、`4d0e262b2`、`e25e53af9` |
| F5.3 产品路径（两遍出包→新 revision 导入→revision 内符号链接条目修复） | `12a3f9d02`；真机 `offline_hits=9 offline_misses=7 offline_rejects=0`，次局 0/0/0（私有缓存优先） |
| F4.3/F4.4（owner 轮询 + 驱动管线 worker，runtime/managed） | `0d65e7563`；宿主 `nvn_vk_exec_owner`/`nvn_vk_pipe_worker` 测试 |
| §6.1 HOME/恢复/在途 surfaceDestroyed/Stop 矩阵 | `785a9b1a8`；gen1 detach 8 ms、gen2/3 attach 2712×1220、stop=0 destroy=0 |
| C3 deferred query 产品路径 | 真机 `samples-passed resets/reports` 持续、zero/fail 为 0–38 |
| B4/B9（Stop 长收尾移出窗口锁、帧队列未完成保留设备缓存） | `74865660c`；真机 cc192dbf 复验 |
| 清理（XGS 退出/直接候选不含旧引擎符号；遗留选项名未改） | §3.1、§7.0；宿主 36/37（唯一失败为本机 binutils AOT 断言） |
| 文档/坑记录/性能读数 | `6ede1f87f`、`74099a427`、`7f0ac266e`、`3cd167e51`、`8cfe05a40`、`2b507afc0`、`2063f015b` 等 |

仍未完成（均为视觉问题，按用户要求先保留、不阻塞流程）：

- 紫/绿：修复路径真机确认生效（快照替换日志+0.0 洋红），但 13:51 曾出现斑块状紫/绿，根因未定；文档不宣称彻底修好。
- HUD 圆球：direct 是带石纹的灰球、generic 是蓝色发光球；`tex_diag=1` 整局 0 条非 2D 采样，属 2D 纹理/多 pass 合成差异，蓝光层/遮罩未定位。
- HPBar：`!!Missing!! - 52004:HPBar` 是游戏 `H2OLayout` StringList 本地化缺串兜底；direct 载入路径会画占位、generic 同流程没有（16:53 抽帧确认提示条正常），触发条件（加载时序/本地化表就绪顺序）未定位，不是 GPU 渲染差异。


</details>

<a id="history-build-probes"></a>

## 旧构建与探针入口（历史命令，不作为当前步骤）

## 10. 复现入口与故障处理

以下是既有检查入口，按改动选择运行，不要求每次重复全套。设备脚本涉及安装/启动时先核目标设备与冻结包身份；本次合并文档未执行它们，也没有新增通过结论。NDK/host、合成GPU、设备AOT、preview IME、完整游戏是不同证据层。

**当前新后端 APK 构建接点**（本轮源码配置，尚非自动出包完成）：先用 §4.2 产生 `D3_APK_INPUT`，确认 SDK/JDK/.NET/NDK 和真实服务依赖齐全；重新构建 AOT 后再补 OpenSSL。显式向 host/build.sh 传 Gradle tasks 会跳过它的默认 AOT/OpenSSL 步骤，不能省略前两行。

```sh
S2ARM_ANDROID_CS_SERVICES=static bash android/cs/build.sh
bash android/openssl/build.sh
S2ARM_ANDROID_CS_SERVICES=static S2ARM_ANDROID_VK_ENGINE=1 \
S2ARM_ANDROID_VK_BACKEND=nvn_vk bash android/host/build.sh \
    :app:assembleDebug :app:lintDebug -Ps2arm.nativeMode=game \
    "-Ps2arm.gameDir=$D3_APK_INPUT"
```

这些参数只是当前接线选择；后续解除旧 ENGINE 编译门时同步本文与实际构建校验，不长期维持第二份脚本。核最终 APK 的动态库/依赖、真实后端符号和运行日志；按 §4.2 以实际签名 APK 生成资源 artifact，再正常安装。禁止只凭构建环境变量或“direct”文案判定正在运行新后端。正式测试不使用 interlock 剥离；现有无来源缓存先在私有诊断域隔离。

```sh
# 宿主（macOS/Linux 都行；NDK 由 tools/ndk_toolchain.sh 选 prebuilt/{darwin,linux}-*）
bash android/tools/direct_abi_check.sh          # C0（host C + C# + ARM64 真机）
bash android/tools/direct_c1_probe.sh           # C1 host+ARM64
(cd graphics/tools/direct/tests/compiler && dotnet run -c Release)   # C2 统一编译；检查数以当次版本为准
bash android/tools/direct_c2_control_check.sh   # C2 控制段对拍（51 例）
bash android/tools/direct_c3_vk_probe.sh        # C3 真机 GPU 微例（vk-micro/vk-record）
bash android/tools/direct_c4_sync_probe.sh      # C4 真机 fence/track
bash android/tools/direct_c4_wsi_probe.sh       # C4 真机 present fence/窗口代际（需 APK）
bash android/tools/direct_c5_nvn_test.sh        # C5 真机共享前端
bash android/tools/direct_nvn_port_check.sh     # C5 NVN 适配层 ARM64 编译
bash android/tools/direct_vk_engine_check.sh    # C5 引擎 21 对象编译
bash android/tools/direct_vk_engine_link_check.sh
bash android/tools/direct_vk_engine_init_probe.sh
bash android/tools/direct_vk_engine_draw_probe.sh   # 脚手架，非产品路径
bash android/tools/nvn_vk_format_probe.sh       # 新后端：NVN→Vulkan 格式映射
bash android/tools/nvn_vk_sampler_probe.sh      # 新后端：采样器映射
bash android/tools/nvn_vk_sampler_cache_probe.sh
bash android/tools/nvn_vk_texcache_probe.sh     # 新后端：纹理身份/generation
bash android/tools/nvn_vk_texcache_tex_probe.sh # 新后端：tex_t（线性/块线性/mip/3D）
bash android/tools/nvn_vk_texview_probe.sh       # 新后端：采样/附件 view（swizzle/mip/层/格式覆盖/在途 pin）
bash android/tools/nvn_vk_be_probe.sh           # 新后端：C2 输出→pipeline→draw→读回
bash android/tools/nvn_vk_session_probe.sh      # 新后端：device+缓存会话 create/destroy
bash android/tools/vk_interlock_probe.sh        # 设备能力：fragment shader interlock（暗黑3 卡点）
bash android/tools/vk_surface_probe.sh          # 设备能力：VK_KHR_android_surface（present 前置）
bash android/tools/nvn_vk_surface_probe.sh      # 新后端：surface 格式/呈现模式选择
bash android/tools/nvn_vk_probes.sh              # 新后端全部真机自测（总入口）
bash android/tools/nvn_vk_present_probe.sh      # 新后端 present（需已装 per-game APK）
bash android/tools/nvn_vk_pipeline_probe.sh     # 新后端：C2 blob→pipeline 缓存＋绘制读回
bash android/tools/nvn_vk_wsi_draw_probe.sh     # 新后端：真实 Surface 上画 C2 程序并 present
bash android/tools/nvn_vk_adapter_probe.sh      # 新后端：前端适配层会话 init/shutdown
bash android/tools/direct_c2_aot_probe.sh       # C2 设备 AOT（需可用的主链 APK）
bash android/tools/direct_c6_ime_zh.sh confirm  # C6 中文输入法（需 Gboard 中文子类型）
```

- 新进程强制generic使用 intent字符串 `--es s2arm.graphics_mode generic`；direct重试用 `--es s2arm.graphics_mode direct`，AUTO不带该extra。`MainActivity`使用getStringExtra读取，不能用布尔extra `--ez`。启动模式、成功present、可操作与正常退出分别核验。
- attempt/failure保存在 `<state>/graphics/direct/<implementationKey>/`。相同失败身份不自动清锁；手动direct仍须通过能力准入。更新真实实现/内容/profile后按版本规则受控重试，不能清空缓存掩盖原错误。
- 保留上一版APK及不可变revision；安装必须核签名和版本，资源激活失败时禁止代码/内容错配，存档保留。Android不保证无条件降级APK，不能把“留一份旧包”当完整上线回滚。
- 正常收局清attempt、SIGKILL遗留attempt、异常清理不清失败，分别验证。合成包连续两局direct不代表真实游戏完成；真实 NVN 游戏已取得 direct 帧并进入世界（§8.3/§8.4），整局故障兜底与恢复仍需独立验收。

文档维护：目标、实现顺序及本节C0–C8验收只在本文维护；协议细节维护[实施契约](direct-mode-contracts.md)，STATUS按需摘要引用本文，提交和实验细节留PR/测试报告。[CHANGELOG](CHANGELOG.md)只记录里程碑达成、回滚或验收结论变化，同一里程碑合并一条；普通修复、探针、重复测试和文档整理不追加。历史记录保留，本次合并不新增ChangeLog条目。
