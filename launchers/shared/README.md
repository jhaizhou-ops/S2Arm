# 四端共享体验规格（launchers/shared/）

「一套体验」的数据文件：状态机、文案、错误码、任务事件到界面的映射只在这里定义一次。Mac（SwiftUI）、iOS、Android、鸿蒙四个前端只负责画，不各写一套措辞。任务单：[#187](https://github.com/jhaizhou-ops/S2Arm/issues/187)。

## 文件

| 文件 | 作用 |
|---|---|
| `experience.v1.json` | 规格本体。契约名 `s2a.experience.v1`，`revision` 是口径号 |
| `check_experience.py` | 规格自检。四端改完都要跑，见下 |
| `../../tests/experience_spec_test.sh` | 门禁入口；规格或比对源文件改动时自动运行自检 |

## 规格里有什么

- `pack_graphics_mode`：出包画面模式（#389 iOS「关于本包」、#387 Mac 启动器），两句文案（直连 / 未知）与 `S2AGraphicsMode` / `S2ADirectLibVersion` / `S2APackTime` / `S2ABuildID` 四个契约键同源于 IPA 的 `Info.plist`；包只出直连（11-07 拆掉通用模式，revision 20 删 `graphics_modes` 段与「仅通用」两句），`S2AGraphicsMode` 不是 `direct` 一律按未知。字面必须与 `ios/settings.m` 的 `s2a_ios_publish_bundle_info`、`PackMode.swift` 的 `PackGraphicsMode.title` 逐字相同。
- `states`：`idle → keys_missing → importing → preparing → ready → running`，外加 `failed`、`recovering`（进度中断后「继续上次的准备」）。每态带中文 / 英文标题、说明、语气（`neutral` / `busy` / `ok` / `warn` / `error`）和主按钮。
- `transitions`：允许的迁移与触发条件（`when` 是机器可读短名，`note` 给读的人看）。从 `idle` 走不到的状态会被自检判死。
- `event_map`：`s2a.job-event.v1` 的事件落到哪个界面状态。字段含义表在 `fields` 里。任务终态 `job.succeeded` / `job.cancelled` **不是错误码**，放在 `terminal_results`，不查 `errors` 表。
- `stage_labels`：`stageId` 到中文 / 英文阶段名。键集合必须与 `pack/contracts/protocol.py` 的 `STAGES` 右值一致（外加 `job` 这个兜底值）。
- `errors`：错误码表。**码集合的唯一来源是 `pack/jobs/errors.py` 的 `RECOVERY`**，自检直接 import 那个文件比集合，多一个少一个都红。每条只写 `title` / `detail` / `severity` / `retryable` / `recoverable`；**「下一步」不在这里写第二份文案**，只留来源指针 `"next_action": {"from": "pack/jobs/errors.py"}`，四端显示时去读 `RECOVERY[code]`（`errors.py` 的 `recovery()` 已含 packaged / 开发版的回落与 `job_failed` 兜底）。唯一的例外是 `artifact_invalid`（`pack/targets/ios/adapter.py` 抛，`RECOVERY` 里没有），指针指向 `pack/contracts/README.md` 的恢复口径。
- `prompts`：`items` 是游戏内横幅文案，与 `runtime/include/s2a_direct_prompt.h` 的宏**逐字**相同——那个头文件仍是 iOS / Mac 游戏窗口的唯一实现来源，这里只是把它们列进同一份规格，方便四端对齐；宏集合也一一对应，头文件新增一条横幅而规格没跟上同样判红。（10-26 维护者改定直连运行中不切换，「已切回通用」横幅、直连失败确认弹窗与 #366 退回原因正文一并删掉，revision 3。）每条都带 `en`，头文件同时有 `<宏>_EN` 与之逐字相同：iOS 宿主按 App 语言取中 / 英（`ios/s2a_l10n.h` 的 `S2APICK`，#316 在 revision 39 补齐）。
- `init_fail_page`：iOS 人手局初启失败提示页（审计 #1534 P1-4）的文案与错误码归类。`items` 与 `runtime/include/s2a_init_fail.h` 的文案宏**逐字**相同（游戏进程不读本 JSON，头文件是实现来源）；`codes` 与头文件 `S2A_INIT_FAIL_CODES` 一一对应（码 id、枚举名、映射到哪句玩家话术），码表外按 `unknown` 用通用句。上屏只放玩家话术，内部摘要只进「复制诊断」（11-02 维护者：内部词不上屏）。每句带中英文，不复制进 `Localizable.json`。英文同样落在头文件 `<宏>_EN`，与 `en` 逐字相同（iOS 按 App 语言显示）。
- `selfcheck_page`：iOS 起局自检不过时的提示页文案（`runtime/src/selfcheck.c` `s2a_selfcheck_screen`）。`items` 与 `runtime/include/s2a_selfcheck_page.h` 的宏**逐字**相同、宏集合一一对应（头文件是实现来源）；NPDM 地址空间类型 0–2（32 / 36 位）上屏说「暂不支持」，不再落到「游戏资源不完整」。每句带中英文，不复制进 `Localizable.json`。英文同样落在头文件 `<宏>_EN`，与 `en` 逐字相同（iOS 按 App 语言显示）。
- `actions`：按钮 id 与文案。

## 口径号（revision）怎么改

- 改文案措辞、加一个错误码、加一条 `stage_label`、改 `pack_graphics_mode` 的字面：`revision + 1`，同一提交里改各端；改 `pack_graphics_mode` 的中文字面还要同一次改 `ios/settings.m`，Mac 的 `PackMode.swift` 按标签 id 读取。
- 改状态集合、改迁移含义、改 `event_map` 语义、改字段含义：开 `experience.v2.json`，旧文件保留一个版本周期，别在原地改语义。（`revision 2` 把 `errors[].next_action` 从文案改成来源指针，是「错误码下一步只有一个来源」这条口径本身，四端要改成读 `RECOVERY`；`errors` 的码集合与显示字段没变。）
- 改 `prompts` 里的字面：必须同一提交改 `runtime/include/s2a_direct_prompt.h`，否则自检直接红。
- 改 `init_fail_page` 的字面或码归类：同一提交改 `runtime/include/s2a_init_fail.h`（`revision + 1`），否则自检直接红。
- 改 `selfcheck_page` 的字面：同一提交改 `runtime/include/s2a_selfcheck_page.h`（`revision + 1`），否则自检直接红。

## 自检

```bash
python3 launchers/shared/check_experience.py        # 退出码 0 = 全过
bash tests/experience_spec_test.sh                 # 门禁同一入口，支持 S2A_PYTHON / S2A_PY
```

查六件事：结构引用不留悬空 id；六个要求的状态 + 失败 / 恢复分支都在且从 `idle` 可达；`errors` 的码集合与 `pack/jobs/errors.py` 的 `RECOVERY` 相同且「下一步」只写来源指针（终态码不在错误表里）；`prompts` 与 C 头文件、`pack_graphics_mode` 中文与 `settings.m` 逐字相同；Mac 的标签消费、启动校验和构建资源接入有效，`Localizable.json` 不复制共享文本；`stage_labels` 与出包契约的阶段集合相同。

所有比对都从源文件读（`errors.py` 直接 import，`.m` / `.swift` / `.h` 现场解析），脚本里不手抄一份字符串表——源文件改了字面而规格没跟上，自检就红。

门禁通过薄壳头部的「门禁覆盖」登记上述源文件，包括 Mac 的 `Localizable.json`；改动任一来源都必须选中这份自检，不能只在改规格时手工运行。

反证（脚本坏了看不出来时要能自证）：把任一条横幅文案改一个字、删掉 `recovering`、重复一个错误码，三处都会让自检退出码变 1。

## 各端怎么用

- **Mac（`launchers/macos`）**：`SharedExperience.swift` 在启动时解码和校验实际资源。任务 `running` / `failed` 取同义状态标题，`completed` / `cancelled` 取任务终态标题；协议 stageId 与同名中文阶段标签从 `stage_labels` 读取。旧 GUI 的里程碑正文、排队 / 取消中 / 中断、完成但有报错 / 警告保留原含义，不把中断冒充恢复中。引导页、游戏就绪徽标等已有专用表达不换成规格的概括性状态说明，布局不变。
- **Mac 的资源与语言**：适配层包（`launchers/macos/adapter`，新旧两个 Mac 前端共用）的 SwiftPM `SharedExperienceResource` 构建插件声明本目录原件为输入，将普通 JSON 文件生成到构建目录并与作业层文字对照表 `Localizable.json` 一起纳入适配层资源 bundle（翻译与加载在 `BackendText`）；源码资源目录不存副本或符号链接。`build_app.py` 同时兼容 native 与默认 swiftbuild 的资源目录布局，复制后核对普通文件及其字节与原件一致。开发版读 `Bundle.module`，`.app` 必须读包内 `S2ArmAppleAdapter_S2ArmAppleAdapter.bundle`；缺 bundle、缺 JSON、缺消费字段、非法合同或缺中英文均明确失败，不回落到源码路径。资源 loader 抛错供调用方处理，应用启动层写诊断并退出；Mac 门禁动态列举并逐例核对 XCTest 已执行完。中英字段是共享文本唯一来源，现有其它 `L()` 调用合入这些真实字段，不维护重复字符串表。revision 4 将 Completed / Unpack / Asset index 三处英文对齐接入前的 Mac 译法，不改变状态含义。
- **错误下一步**：四端都不在自己的字符串表里再写一遍，显示时取 `pack/jobs/errors.py` 的 `RECOVERY[code]`（`recovery(code, packaged=…)` 已处理开发版差异与 `job_failed` 兜底）；规格里的 `next_action.from` 只是指路。
- **出包画面模式**：模式证据仍只读 IPA 的 `Info.plist`，Mac 展示的两句标签从 `pack_graphics_mode.labels` 读取。
- **iOS / Android / 鸿蒙（后续接入）**：本 Mac 消费分片尚未让这些前端读取 JSON，继续留在 #187。接入时同名字段同一含义，字符串表按 `languages` 取；新增语言时四端同一次 `revision` 内补齐，缺语言按源语言（`zh-Hans`）回落，不自造译名。
- **游戏内横幅**：仍由 `runtime/include/s2a_direct_prompt.h` 出，不读这个 JSON（那条路径在游戏进程里，不能依赖应用资源）。

## 边界

- 这个文件只管「说什么、什么时候说」，不含布局、颜色、图标和动画参数。
- 不含任何游戏相关的专用文案或特判。
