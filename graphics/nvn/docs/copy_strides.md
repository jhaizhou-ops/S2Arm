# CommandBuffer 拷贝步长（#270 D 组子片）

原始基线 `34bd2907`；当前集成基线为 #299 的 `7e2f2a84`。`SetCopyRowStride` / `SetCopyImageStride` 是命令缓冲对象的 CPU 状态：初始化为 0，Begin/EndRecording 保留，0 表示拷贝区域紧密排列。每次 BufferToTexture / TextureToBuffer 在录制时读取当时的步长，之后修改对象或提交其他命令缓冲不应改变已录制拷贝的布局。两项 Get 查询返回该对象最近设置的状态。

## 契约依据

自有怪猎崛起 16.0.2 SDK（SHA-256 `1c9f198a91c0bcfee5cf8f5b53fb941895e91334dfb766ce79fc68576797f017`）：四个入口 `0x465bb0` / `0x465bc0` / `0x465bd0` / `0x465be0` 分别以 `str w1` 写对象 `+0x88` / `+0x8c`，再以 `ldr w0` 读回，均立即 `ret`。惊奇 1.2.1 SDK（SHA-256 `73bec5989030d4d9f056503066180a6100bb7937370a4d818c8ba53960dfa2f3`）的 `0x44db80` 至 `0x44dbb0` 同构。没有录制命令或调用内存分配的操作。

实现保留现有 `ptrdiff_t` 公开签名；内部用两个 32 位无符号字段保存，查询零扩展，与 SDK 的存取指令一致。这不宣称负值或超过 32 位的输入是合法拷贝步长。表中 SDK 地址仅作静态契约依据，不进入生产判断；没有执行或分发 SDK。

## 录制和回放

旧实现将 setter 录成 `OP_COPY_STRIDE`，在回放时改全局状态 `S.copy_stride` / `S.copy_img_stride`。录制开始前的设置不会成为之后句柄的一部分，另一命令缓冲的设置也可能影响没有重设步长的拷贝。

修复将步长保存在 `cmd_t`，两种拷贝共用的 `p_copy_b2t` 记录同时保存当前行和层步长。Metal 回放只读取该记录，不读取命令缓冲对象或前一提交的全局步长。TextureToTexture 和 BufferToBuffer 不使用这两个值。旧步长 opcode 已删除，后续操作码顺延；这些命令记录只在同一进程内录制和回放，不落盘或跨版本。

测试使用仓库已有 AppIcon PNG，经 ImageIO 解码后的真实像素作为输入与独立期望，不生成图案或仿造游戏对象。GPU 拷贝验证与状态查询分别执行，游戏/真机画面回归仍需单独验收。

## 原始基线验证

设备为 Apple M5 Pro、48 GiB、macOS 27.0（26A428），使用 Xcode 27.1。输入 `launchers/macos/Branding/AppIcon-1024.png` 的 SHA-256 为 `cb7680f89533530923983e6658f6b96c44cee2d2befe6a6f9ab7eab9aecfaf6a`；ImageIO 解码为 RGBA8 后，上下两半分别作为 1024×512 的两层，先确认两层像素不同。

- 未修改的 `34bd2907`：BeginRecording 前设置 row=4352、image=2232576，真实 Queue 提交并 Finish、GPU 提交无错误后，独立 TextureReadTexels 在字节 410895 得到 0、期望 1，测试退出 1。没有通过同一套错误上传/下载相互抵消来判定通过。
- 修复后最终测试在 `DM_NVN_ENC_THREAD=0` / `1` 下各跑一遍，均为 825 条断言、退出 0。线程模式 1 的日志明确出现 `Metal encoding runs on its own thread`，使用共用生产依赖的最终构建。
- CPU 覆盖：初始化/重新初始化为 0、两对象独立、独立设置与查询、查询不改对象、Begin/End 保留值、setter 不消耗命令内存。
- GPU 覆盖：Begin 前设置、2D array 紧排、3D 两深度片带 padding、两 CB 交错录制、同一 handle 两次拷贝之间改步长、录制后改值、B 覆写纹理后重放 A 的旧 handle、CallCommands / CopyCommands 的父子步长隔离。两种子调用分别执行，提交前以真实上传将子/父目标改为各自相反的图像并独立核对，避免未执行也通过。
- 下载用独立 TextureWriteTexels 提供真实图像源，分别验证 row/image 为非零/非零、非零/零、零/非零、零/零；逐字节检查像素、行/层 padding 和池尾未被覆盖。
- 两个新增 getter 各自临时改为错误返回 0，重编完整生产库：2/2 在各自的 Set/Get 断言失败、退出 1；恢复后上述全组再次通过。

入口经生产 bootstrap、swnvn 注册节及计数跳板解析；不抽取或复制另一份被测实现。运行 `make native-test-nvn_copy_stride`；只跑拷贝回归可传 `NVN_COPY_STRIDE_TEST_ARGS=--copy-only`。构建依赖与其他 NVN 测试共用 `NVN_TEST_HOST_OBJS` / `NVN_TEST_LIB` / `NVN_TEST_WIDEN`。

本地证据为 `build/nvn-copy-baseline.log`、`build/nvn-copy-baseline.sha256`、`build/nvn-copy-mutant-{row,image}.log`、`build/nvn-copy-parent-coverage-{encoder0,encoder1}.log`、`build/nvn-copy-parent-coverage.sha256`。另冻结了未修改生产库于 `build/stride-baseline/mac/libnvn.a`，SHA-256 `96d340e83d4db60ade3696f46fe672697f63dd95b3ab6aafd7db2293a597798d`。

## 与 #299 集成验证（`1101456a`）

变基到 `7e2f2a84` 后，继承 A 组的生产实现、ABI 头文件和测试；共享 `NVN_TEST_*` 支持保留一次，只新增本片链接与运行目标。未引入 #303 / #309 的查询，步长实现及测试相对原片没有语义变化，未重复原基线反证。

在同一台 Apple M5 Pro 上实际运行 `make native-test-nvn_a native-test-nvn_copy_stride`，退出 0，A 组 360 条与本片 825 条断言通过；日志中 NVN 子 make 与 `dotnet publish` 各调用一次。另以 `DM_NVN_ENC_THREAD=1` 运行本片，825 条通过、退出 0，日志确认 `Metal encoding runs on its own thread`。这是本次集成证据，不替代上节原始基线的失败复现。

该提交旧分类器 `nvn_func_table.py --md` 实测为436/3/14/83；完整 bootstrap 为446个语义入口、14个空操作、76个未实现。本节数值保留为当时旧工具的历史记录，当前正式工具结果见下节。证据为 `build/nvn-copy-builder-integration.log`、`build/nvn-copy-builder-integration-encoder1.log`、`build/nvn-copy-builder-coverage.md`；最终源码与产物哈希为 `build/nvn-copy-builder-integration.sha256`。该提交贡献者自检8/8通过，141秒；移除占位后的 `e62c4909` 自检8/8通过，139秒，原生层均38/38组。

移除旧步长 opcode 占位、后续编号顺延后，再次运行 A 组与本片联合测试：360 条与 825 条通过；独立编码线程模式另跑 825 条通过，日志确认该线程实际启用。生产目录已无 `COPY_STRIDE` 操作码残留。日志为 `build/nvn-copy-opcode-removal-integration.log` 与 `build/nvn-copy-opcode-removal-encoder1.log`；此次未覆盖冻结的原始基线库。

## 四支集成与门禁输出

叠入已验收的 #303 `b391fd05` 和 #309 `25d54e9e` 后，临时集成提交 `4ba5ff4a` 实跑 A360 / B111 / D410 / 拷贝825条，全部退出0；NVN子构建和dotnet publish各一次。日志为 `build/nvn-four-pr-integration.log`。

同提交的原生门禁实际退出1：期望40组、绿39组、红0组、测试make rc0。B组末行没有门禁识别的 `✓ t_` 前缀，尽管111条断言0不符仍被漏计。当前修复只在B组摘要按 `bad` 选择成功/失败标记，保留断言和退出码，以及门禁的严格数量检查。日志为 `build/nvn-four-pr-native-gate.log`；这项修复随本片交付，不改动他人分支。

## 正式分类器同步

分类修正已在 main 的 `b475a624b9e3afeb1a9997792d2b5d713dbb5e6b` 合入，补认 `NVN_NOPROTO` 定义及定义体边界。本次同步正式提交的三处变更，分类器文件与该提交逐字节相同。

当前源码包含 #299、#303、#309 和本片。实际运行维护方的 awk 计数命令及 `--md`，均得到已实现447 / 部分3 / 空操作14 / 未实现72，共536项、扫描0局；相对四支集成旧工具440/3/14/79，多出的7项是原有注册入口的漏计修正，不是新实现。原始输出为 `build/nvn-copy-formal-coverage.tsv`、`build/nvn-copy-formal-coverage-counts.txt`、`build/nvn-copy-formal-coverage.md`。

运行时与测试维持已通过完整自检的 `aaec03516`：8/8步、原生层40/40组。此次增量仅正式分类器和两份文档，执行脚本、Python语法及差异检查；未重跑 GPU 或完整自检，原基线证据不改称本次新运行。

这是一套 Mac 上的真实 NVN/Metal API 测试，没有启动游戏。完整宿主构造函数仍保留无 main.npdm、未预留游戏窗口和程序号 0 无逐款参数表的诊断；测试不屏蔽这些诊断，也不把缺省图形模式日志当作游戏直连验收。未测 iPhone、九款金样、压缩纹理格式和游戏画面，不宣称帧率或能耗改善。
