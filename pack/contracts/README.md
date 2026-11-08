# 统一出包契约（J06 / #182，Phase 0）

新入口是 `pack/jobs/target_main.py`，当前只支持 Apple Silicon Mac 上的 iOS 宿主目标。
它使用旧 worker 的请求文件权限检查、取消、进度、日志、引擎安装和出包实现。
原 `pack/jobs/main.py` CLI 保持默认行为；Mac 启动器尚未切换入口。

## 本机使用

契约校验器与新 worker 只用 Python 标准库，不需要安装 `jsonschema` 或其他校验依赖。
出包链原有的 Xcode / .NET / 改写器工具依赖不变；测试不联网。

```bash
bash tests/pack_contracts_test.sh
python3 -I -S -B pack/contracts/validate.py target pack/targets/ios/target.json
python3 -I -S -B pack/jobs/target_main.py --request <0600-请求文件>
```

请求文件须归当前用户所有且不向组或其他用户开放，沿用旧入口的要求。不要把真实请求、
密钥、游戏包、资源包或存档提交。新请求在现有 `schema: 1` 字段上增加
`contract: "s2a.job-request.v1"` 与 `targetId: "ios"`，`operation` 为 `ipa`。
原 `target` 仍是 `{gpuArch, os, ...}` 设备参数，不用插件 ID 覆盖它。
其余参数与旧 iOS 任务相同：`privateRoot`、`library`、`libraryId`、`gameId`，以及
`engineDir` 或 `engineBundle` 等。可继续用 `jobId` / `taskId` 别名。
真实出包时将 `privateRoot` 与游戏库放到源码树外；NuGet 缓存位于 `privateRoot/cache`，
若放在源码树内，现有 C# 闭包键工具会将被导入的 NuGet targets 当作未跟踪源码而拒绝计算键。

## IPA 兼容重打请求（T199，#1065 冻结接口）

`operation: "ipa"` 可选 `graphicsMode: "generic"`；不传保持原缺省判据
（进程 `S2A_DUAL=0` 为通用，其余为直连优先）。每个 IPA Context 创建时固定
该判据，`task_direct_on()` 统一空间预算、目标设备要求、阶段计划和子进程
`S2A_DUAL=0/1`，不临时改写进程环境；原 `direct_on()` 接口不变。
兼容模式仍需目标设备，直连的目标设备仍可省略。
非 IPA 操作携带 `graphicsMode`、null、空串、非字符串、其他值，或与
`rest: true` 同来均拒绝。社区 `save` 的 `graphics` 字典不受影响。

任务记录及每条事件以 `requestedGraphicsMode` 表达请求意图，缺省请求省略。
原请求按已有 0600 request journal 保存，resume 重放时保留显式选择；新发起的
重试也须由调用者保留 `graphicsMode`，不从上个同款任务猜测。
完成结果 `result.graphicsMode` 仍只取本轮 oneclick 的 `graphics_mode`
（缺失为 unknown），不从请求填充。以下是三种字段所在层级的 JSON 片段，
不是省略其他必填字段后可直接提交的完整请求/事件：

```json
{"operation":"ipa","graphicsMode":"generic"}
```
```json
{"operation":"ipa","requestedGraphicsMode":"generic"}
```
```json
{"type":"result","requestedGraphicsMode":"generic","result":{"graphicsMode":"generic"}}
```

实际包的 `Info.plist/S2AGraphicsMode=generic`、无直连库和真机 host.log 仍须
联合验收；宿主合成测试不证明真实包、设备运行或兼容率，父卡不因此关闭。

## 空间预检「仍然继续」（11-07）

`operation` 为 `build` / `ipa` 时可选 `spaceOverride: true`：游戏库空间预检
（`library.check_pack_space`）不足也不拦，只记一条 `disk_full` 警告诊断，任务记录
`space.override=true`；真写满由出包中途的磁盘写满识别报错。其他操作或非布尔值拒绝。

## 四份格式

| 契约 | 文件 | 版本与兼容规则 |
|---|---|---|
| JobRequest | `job-request.v1.schema.json` | 保留 `schema:1`，加 `contract:s2a.job-request.v1`；未知加法字段保留 |
| JobEvent | `job-event.v1.schema.json` | 保留原字段，加 `contract:s2a.job-event.v1`、`code`、`stageId`、`description`、`nextAction` |
| ArtifactManifest | `artifact.v2.schema.json` | `schema:s2a.artifact.v2`；目标特有字段放 `details`，首个子格式为 `s2a.artifact.ios.v1` |
| Target | `target.v1.schema.json` | `schema:s2a.target.v1`；声明宿主、设备、入口、配方及阶段 |

四份格式仍是 JSON Schema Draft 2020-12；标准库校验器只实现本项目使用的子集：
`type / required / properties / additionalProperties / enum / const / pattern / minLength /
minimum / minItems / items / $ref / $defs / allOf / if / then / format:date-time`。
不宣称是通用 JSON Schema 实现；新增不支持的关键字直接失败，不能静默忽略。
所有 `$ref` 仅在本地已登记的四份契约中解析，不从网络取 schema。
额外检查 UTC 时间、产物路径重复与账本引用、配方阶段引用。
错误仅输出字段位置和校验关键字，不回显输入值。

校验单个 JSON：`python3 pack/contracts/validate.py request <文件>`。
校验事件文件：`python3 pack/contracts/validate.py event <文件> --ndjson`。
空事件流判失败；此命令检查每行形状，不把它当作完整性、单调序号或完成状态验收。
这些生命周期保证由既有 worker 负责，journal / 恢复语义由 J10 接续。

## iOS 委托与事件

`target_main.py` 只在显式调用时启用 `TargetContext` 和 iOS adapter。
它通过旧 worker 新增的可选入口参数注入；旧 CLI 的默认 `Context` 和操作表不变。
adapter 调用现有 `ipa.build()`，即 `pack/oneclick/oneclick.sh → pack/ipa.sh`，
不改它的命令、环境、阶段键、产物、签名或文件选择规则。两个入口不能并发构建同一游戏库。

原事件中的中文 `stage`、`message`、数量、状态、别名均保留。
机器阶段 `stageId` 映射既有 milestone，无法细分时用 `job`，不靠解析中文猜步骤。
错误 `code` 与 `nextAction` 直接复用既有 diagnostic 的稳定代码与建议；
非错误用 `job.stage` / `job.progress` / `job.heartbeat` / `job.succeeded` 等。
新入口产生的 stdout 和本地 events 文件都带新增字段；旧入口继续写原格式。

| code | 含义 | nextAction 来源 / 动作 |
|---|---|---|
| `artifact_invalid` | 本次 IPA / 资源包账本不完整或不合法 | 上游 diagnostic：查看任务日志并修复后重试；产物保留 |
| `keys_missing` / `keys_invalid` | 玩家密钥缺失 / 无效 | 上游 diagnostic：重新导入自行导出的密钥 |
| `disk_full` / `permission_denied` | 磁盘空间 / 文件权限失败 | 上游 diagnostic：释放空间 / 修复权限后重试 |
| `tool_exit` / `tool_missing` | 构建工具失败 / 缺失 | 上游 diagnostic：检查失败阶段 / 补齐工具 |
| `job_failed` | 上游未细分的失败 | 上游 diagnostic：检查已脱敏错误摘要和日志 |
| `job.stage` / `job.progress` / `job.heartbeat` | 阶段 / 进度 / 心跳 | 等待或取消任务 |
| `job.succeeded` / `job.cancelled` | 成功 / 已取消 | 使用交付 / 按需重新发起 |

失败的 result 取最后一条 error diagnostic 的 code，不生成 `job.failed`；
原 worker 的完整稳定错误码与建议仍以 `pack/jobs/errors.py` 为准。

目标清单中的 `observation:declared` 仅声明现有间接调用，**不声称有独立进度、可重试阶段或完成检查点**。
`widen.auto` 沿用原来的异步触发，因此标为可能起游戏，不能据此说本任务已完成宽屏判定。
refresh 阶段与 `pack/refresh.sh` 同名同序：`rewrite / sysdata / uilayout / aoc /
caps / romfsidx / shaders / direct`。前四段同属 `refresh.independent` 并行组；等待它们完成后，
先出能力清单（`caps`，读改写产物的轻阶段，键独立于改写），再做索引、着色器与条件直连库。配方数组是阶段声明，不把并行流程改成串行执行器。
`shader.*` 是 `shaders` 的观察子阶段，不表示每次都要全部重做。
出包缺省直连单轨（10-30 jhz：`S2A_DUAL` 缺省 1，只出直连库，不带通用离线库 / 管线归档 / 通用兜底；`S2A_DUAL=0` = 兼容模式，显式只出通用）：
`direct_profile` 先零配置推导，手写档只当可选的加速提示。推导或出库做不成一律报红「直连单轨停在 <哪一步>」、refresh.sh 退出 1；抽取只缺直连用的那两份（11-05 总指挥：直连库编不出也照出包）时照常提交、写 `extract/direct_gap.txt`，直连库阶段出运行时现编空库（离线 0 支、`runtime_only.txt`），宿主首遇现编，
不退成通用包（没有退出 3 这条路了）。着色器阶段在直连出成后只记键（`S2A_SHADER_LAZY=1`）；兼容模式照旧通用全量，按现行口径复用、不因 main 前进固定重烘。
双轨包允许 `S2A_SHADER_NO_PSO=1` 省略完整管线归档，归档不是无条件必有的步骤。
`direct` 声明 `stage_direct.sh` 的实际出库；`direct.library` 声明现有 App 静态链接；
`direct.shader.package` 只声明双轨时实际已有的 shaders/direct 子目录随包。
`direct.ready.collect` 是运行时接缝，当前记录的实现只读就绪状态，
不放进出包 recipe、不启动采集、不假报收集成功。后续由对应主线填补生产者。
Windows / Linux 宿主变体由 J05 / #179 接续，清单 `host.variants` 明列
`windows` / `linux` 两个 `available:false` 占位；当前适配器仍直接拒绝这两种宿主。

## 产物账本与证据边界

只有旧 `ipa.build()` 成功且本次 IPA 和同名资源目录确实存在时，才生成
`result.artifactManifest`；旧结果字段原样保留。账本以输出目录为根记录相对路径、
完整 SHA-256 和大小，不向输出目录写文件，不改签名、内容或 mtime；逐文件与每个读取块检查取消。
拒绝符号链接、越界路径、重复路径与缺失资源包；账本校验失败的任务不能报成功。
账本是本地任务结果，包含本机产物摘要，不应作为公开诊断附件上传。

### 内容指纹与构建输入（交付线接续接口）

按 #190 的 16:57 UTC 评审，`artifact.v2` 增加 `inputs` 与 `fingerprint` 两个
可选字段。旧账本可以都不带；**当前 adapter 尚不生产这两个字段**。
本次只定义接口与共享摘要算法，交付线接续实际生产者以及 sched / auto_formal 的迁移，
不能把契约已定义说成调度已按包内容触发。消费者遇到缺少字段的旧账本应走显式迁移路径，
不能用源码 SHA 或空摘要伪装内容指纹。

`inputs` 记录本次实际构建输入，不参与内容摘要：

| 字段 | 来源与含义 |
|---|---|
| `stageKeys` | 原样记录产物根 `.stage_rewrite / .stage_sysdata / .stage_uilayout / .stage_aoc / .stage_romfsidx / .stage_shaders / .stage_direct` 的完整键；全部属性须列出，阶段未运行或无记录用 `null`，不能编造空串或取当前源码键代替 |
| `dual` | 本次构建实际采用的双轨布尔值；不能仅凭包里是否有直连库推断，因为双轨也可能没有配置可出库 |
| `directChain` | 实际随包直连库的 `b-<链版本>` 目录名；没有随包直连库用 `null`，不能从当前工具源码推算 |

生产者必须在本次构建所用的版本化产物根上读取输入；先解析固定版本，再取阶段键，
不得事后读可能已被切换的共享「现行」并嫁接到旧包。多链版本的表示尚未定义，
不能任取第一项；需要时先扩展契约。

`fingerprint` 的子格式为 `s2a.content-fingerprint.v1`，结构如下：

```json
{
  "schema": "s2a.content-fingerprint.v1",
  "components": {
    "executableSha256": "<主程序完整字节的64位小写SHA256>",
    "resourceIndexSha256": "<资源包manifest中的index_sha256>",
    "pipelineArchives": [
      {"path": "shaders/gal_pso.<目标>.bin", "sha256": "<归档完整字节的64位小写SHA256>"}
    ]
  },
  "value": "<规范载荷的64位小写SHA256>"
}
```

上面占位示意不是合法样例；单测内有可执行的合法向量。
主程序取 IPA 中 App 的 `CFBundleExecutable` 对应文件，**不取 IPA 容器哈希**。
资源索引摘要要先与实际 `index.tsv` 复核；资源内容须按索引逐项验证后才能信任这个分量。
管线归档数组列出所有实际交付的归档文件（含完整、分片或链接桩归档），路径相对资源包根，
完整 SHA256；没有归档用 `[]`，不使用 `null`，不按固定单个 `pso.metallib` 猜。

唯一摘要实现是 `pack.contracts.fingerprint.content_fingerprint(executable_sha256,
resource_index_sha256, pipeline_archives)`：归档按相对路径字典序排序，拒绝重复路径；
构造只含 `schema` 与 `components` 的载荷，用 Python 标准库
`json.dumps(..., ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False)`
生成无末尾换行的 UTF-8，再取完整 SHA256 为 `value`。不截短摘要，不加入
main / 提交 / 阶段键 / 构建号 / 时间 / 输出目录。校验器检查字段类型、路径、摘要格式、
重复归档及 `value` 与分量一致；它不读取产物，也不替生产者证明分量真实。
调用方应再用 `validate("artifact", manifest)` 检查生成的完整账本。

该版本取主程序和归档原始字节，未剥签名，也不豁免 UUID 或链接桩；这些字节变化会
改变指纹。ZIP 时间等容器元数据不进入主程序摘要；资源索引内的非内容字段若变化，
仍会改变索引摘要。它只覆盖上述约定分量，不能替代整份 IPA 的严格比较或签名验证。
`compare.py` 继续提供逐文件差异解释，当前并未改为读取此指纹。

单测用可公开的合成字节证明委托兼容、哈希与只读行为，不能替代真实对照。
真实对照使用同一输入、目标、工具链与源码，经新旧入口和旧入口独立重复出包，
分别保留输出目录。按 owner 在 #190 的 2026-10-24 首次评审，J06 临时验收为：
**新旧入口差异集 ⊆ 旧入口独立重复差异集**，按文件和 Mach-O section 逐项核对；
两组均用 `compare.py` 默认严格模式，公开 PR 只列差异清单，不上传游戏内容或派生哈希。
该标准不表示逐字节相同；旧管线可重复性由测试出包线另行修复。
同日 07:33 UTC 的接续评审进一步要求：`runtime/repro-link` 与 `test/packrepro`
合入 main 后，在包含这两项修复的新基线上用同一输入重跑默认严格比较，
新旧入口期望只剩签名与 ZIP 元数据差异。保留旧入口独立重复控制，
并逐项核对 Mach-O section 与 UUID；如果仍有代码、链接桩或 UUID 差异，
须保持草稿、提交 section 级差异清单，由测试出包线接续。
不能仅凭两组差异集合相同，代替这一阶段更严格的转 Ready 条件。

严格比较仍保留以下检查，不扩大豁免：

1. 资源包逐文件比较，路径集合与文件内容哈希均须一致，不排除资源包文件。
2. IPA 先比整包哈希；若不同，再比较解压后的成员。ZIP 成员时间戳与容器元数据可单列排除。
3. `_CodeSignature/CodeResources`、`embedded.mobileprovision` 和 Mach-O 内签名须单列报告，
   不能把整个 Mach-O 文件排除；其余可执行内容与资源仍须一致。仅在相同身份/签名条件下比较。
4. 如果编译器生成的非确定性管线归档仍不同，列明路径与原因，保留未通过结论，
   不把整类着色器文件默认排除。

只读对照工具已提供，默认严格比较 IPA 原始哈希、资源文件内容与权限：

```bash
python3 pack/contracts/compare.py --old-ipa <旧入口IPA> --new-ipa <新入口IPA> \
  --old-resources <旧资源目录> --new-resources <新资源目录> --report <私有报告文件>
```

需要按验收规程排除签名与 ZIP 容器元数据时，显式增加 `--allow-signatures --allow-zip-metadata`。
报告逐项保留原哈希、被排除的成员和原因。Mach-O 只在临时副本上经系统 `codesign --remove-signature`
处理，再比较剩余完整字节；不整文件排除。资源目录没有签名豁免。
报告以 0600 新建在两个交付目录之外，不覆盖已有报告，不修改输入。
退出 0 表示在声明的排除项下相同，1 表示不同，2 表示输入/结构/校验工具异常。
报告中有派生产物的逐文件哈希与成员名，仅留本机；公开 PR 只贴计数、结论和必要的非资源差异分类。
本工具不验证装机或游戏可玩，签名可安装性仍须独立校验。

满足上述对照与标准库运行要求、原有出包回归通过后可转正式评审。
维护者负责二级门禁与合入；装机与游戏可玩性不在 J06 当前验收范围。

2026-10-25 整包复验：同步含 `test/repro-objcstubs` 的 main `fd2aa04a1`，
在 `723964f23` 上以原输入经旧 / 新 / 旧控制入口分别出包。三份资源各727文件、
IPA 解压后各29文件内容与权限相同，主程序 / NS2Pro 的全部 section 与 UUID 相同，
三包严格签名校验通过。两组默认严格报告均退出1，仅有37个 ZIP 成员元数据变化；
仅加 `--allow-zip-metadata` 即均退出0，`signatures:false`、`excluded:[]`。
此结果满足后续评审允许的 ZIP 元数据边界，不表示原始 IPA 逐字节相同。
原始包、日志和逐文件摘要仅留本机；完整口径见 PR #190 与性能 / 测试经验记录。
