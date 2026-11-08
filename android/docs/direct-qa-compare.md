# #1434 首片：受控 QA 编译结果对拍

此工具不冷、不出包、不编译、不接网，不改变运行时或离线库。只读两套已完成的采集目录，复用 direct_library.py 的 request/result 校验，并比较每个完整身份对应的**完整 program JSON 负载字节**（S2APC1 头之后的 payload；输入文件是原始 program.json，不是容器）。不会只比 SPIR-V 或重排 JSON 后宣称字节一致。

## 证据边界

- 首片本机用 public-synthetic 集测试，不是游戏、设备、首帧或命中率验收。
- identity 必须由 QA 从运行时完整 S2AI1 v3 输入取得；不要用 request 的 SHA、16 位阶段键或枚举候选替代。请求可能已剥离源头，工具**不能重算或证明这个身份真来自设备**。
- 工具检查 manifest 身份唯一、请求/结果文件一一对应、两侧键集合相同、完整请求字节相同；再核 request/result 的 profile、closure、ABI/parser、源摘要、supportLayout、阶段、内容摘要和 transport。同一 cohort 内完整 profile 内容必须相同，不能仅相信 profileHash 文本。
- 同一根目录或共享文件 inode 不算独立对拍。即使两份复制的文件全同，也不能由此证明第二份确实经过独立编译；由 QA 的执行来源回执负责。
- 只有输出摘要可以回传。源码、原始请求、结果、游戏、固件、密钥、存档均留在合法 QA 环境，不上传 PR/Issue，不转移到外部云环境。
- 出包校验失败不发布、运行时沿用逐条拒绝/计数/回退，是后续阶段合同；本工具不实现或声称完成该阶段。

## 输入目录

两侧都使用既有 capture.v1.json 格式；此工具额外要求 profileHash 明确存在：

    {"schema":"s2a-direct-capture-v1",
     "directABI":1,
     "translatorClosure":"<构建的真实 closure>",
     "sourceParserVersion":1,
     "profileHash":"sha256-<64 位小写十六进制>",
     "entries":[
       {"identity":"<运行时完整 64 位小写十六进制身份>",
        "request":"requests/0000.json","result":"results/0000.json"}]}

目录只允许 manifest 所列普通文件（以及目录），不混日志、identity.json、其它未配对结果；拒绝符号链接、FIFO、重复路径和硬链接别名。调用期间两棵目录必须冻结，不与采集/编译进程并发写。根目录由 QA 信任，子路径逐级以 no-follow 打开。每文件受生产格式限制，每侧总读取上限 2 GiB、manifest 最多 100000 键，超过应拆成可追溯的不重叠批次。

manifest 中 identity 到 request 的关系来自生产者断言，校验通过不把该断言升级为独立证明。QA 须在受控清单中保留源快照、设备/会话、源码提交、APK SHA-256、profile/编译闭包、归档摘要与身份来源。不要改写 closure 以适配新编译器。

## QA 内部操作

1. 冻结真实采集目录及 provenance 清单。保存原始 request/result 字节，用明确 manifest 配对，不按目录顺序猜测。
2. 在 QA 内部检出与采集 closure 相符的编译器源版本并构建 CLI。离线 CLI 与 NativeAOT 的 DirectCompileNative 都调用 DirectShaderCompiler.Compile，禁止换用 DshVk 或旧 LibPack。
3. 先运行 CLI 的 identity，输出保存到采集目录外的 compiler-identity.json。与采集 closure 不同就停止，不能修写采集身份让它通过。
4. 对 manifest **每条**原始 request 调同一个 CLI（输出必须是新目录）：

       dotnet <已构建的 S2A.DirectCompiler.Cli.dll> compile --request <原始请求> --output <新输出目录>

   不改 session/generation/requestId，也不重排/再序列化请求。任一失败或 deferred 都记未完成，不删掉该键后宣称全过。编译器 stdout/stderr 也只留 QA 内部。
5. 新建 replay 目录，以逐字节复制的原请求及各次 CLI 输出 program.json 生成同格式 manifest，保留相同完整身份。不要复制采集的旧 result 充当 replay；不要用硬链接。manifest 完成后冻结目录。
6. 在 QA 环境运行：

       python3 android/tools/direct_qa_compare.py --capture <采集目录> --replay <重编目录> --compiler-identity <compiler-identity.json> --scope qa-internal > <目录外的摘要.json>

   退出 0 才是工具比较通过；1 是输入/比较失败；2 是参数错误。输出无原始路径、异常原文、profile 文本、requestId 或 payload，只有固定代码、计数及 SHA-256(identity 字节) 键摘要。scope 是调用方声明，不证明设备来源。摘要的 errors 是批级失败，failed 是逐键失败，passed > 0 且两者全空/0 才 ok=true。
7. 维护者只回传脱敏 provenance 清单和摘要；覆盖明确写“这批采集的 N 键”。本工具不测首帧耗时、现编次数、全 NVN 覆盖或真实 Vulkan 语义。生产环境及游戏数据不会送到外部执行器。

## 自证与负控

    python3 android/tests/direct_qa_compare_test.py

用例仅使用仓库公开合成 request/result（含 graphics 与 compute），**不是执行真实编译器或 GPU**。覆盖正常 2 键、源/结果错配、缺键、重复身份、重复文件、profile/closure 不符、同哈希不同 profile 内容、transport 及布尔冒充整数、坏内容摘要、相同 JSON 语义但字节不同、链接/FIFO、越界路径、重复 JSON 键、未登记文件、无私密错误泄漏和输入不变。接入既有 Android gate。真实 CLI 同源字节对拍按上面步骤在 QA 内部完成。

### 评审回归：声明与请求、逐键硬链接归因

- 两侧 manifest 同时改成同一合法 profileHash，或同时改 closure 并同步 compiler identity，仍必须和原请求的 cohort 对齐；只改一侧的负例不能覆盖这个守卫。删除请求 cohort 守卫后，两条新增回归均由退出 1 / failed=2 变成错误的退出 0 / failed=0。
- 跨侧 inode 原先用累计集合比较，排序最前的键发生硬链接时会把后一个独立键也算失败：原实现 failed=2 / passed=0，修后只将当前键的 inode 与对侧已读取 inode 比较，failed=1 / passed=1；跨键硬链接仍拒绝，归到检测到共享 inode 的当前键，不污染后续独立键。同侧重复 inode 仍由 Reader 拒绝，共享 manifest 仍为批级 SAME_INPUT。
- 回归只用公开原创合成输入，断言具体失败键的 SHA-256 摘要及计数，不代表独立编译来源、设备或真实游戏语义已经验收。
- 只比较当前对四个文件会漏掉跨键跨侧硬链接：两种方向的合成反例均错误地 passed=2；改为当前键对对侧历史集合后，两种方向均 failed=1 / passed=1。
