# Android 普通前台键盘接线草案

基于 `android/integration@31fc9e8e`，协作位置为 #199 / #78。当前仅本地候选，
不是已审定的公共 UI 协议，也不代表完整 W4、inline 键盘或游戏验收通过。

## 范围与实际触发

小米17（25113PN0EC，Android16/API36，4KiB）运行宝可梦朱4.0.0，
`d6634833` / v4 APK `792265d35579269e3383aae14510719eea029a74c202adcf72a4fd5114f33c80`，
仅 SME 上下文实验开启。补齐开放字体后，644 个资源文件通过正常导入器，
从语言选择进入形象选择，虚拟 A 键与摇杆有效；累计 gamePresents=2158。
命名时 `AndroidHostUi.DisplayInputDialog` 明确抛出 software keyboard 未接入，
随后服务清理 error=-105。累计帧数不是稳定 FPS，清理错误单独保留。

v6 首个接线候选（APK `ea16106ffab245be5a4c2d5632aace97faca1309bc21b0250df82444f001442f`）
实际请求 mode=5，被尚未实现的模式检查拒绝；没有伪装输入或确认。后续候选补接
简体中文 IME hint，仍由真正的输入框取得用户文字，不改变系统语言/默认输入法。
模式含义参考 [libnx swkbd.h](https://switchbrew.github.io/libnx/swkbd_8h_source.html)。

## 文件与所有权

- `core-runtime/AndroidHostApi.cs`：按原 HostApi v1 布局委托 begin/wait/cancel；一次请求复用等待缓冲。
- `core-runtime/AndroidKeyboard.cs`、`AndroidHostUi.cs`、`AndroidGameRuntime.cs`：映射实际 SoftwareKeyboardUIArgs，验证应答，再返回真正确认/取消；其他 applet 保持 Unsupported。
- `runtime/host_ui_android.{h,c}`：显式委托原 broker，绝不把 `api.host=&g` 强转成 broker；Activity 代际和停止所有权。
- `runtime/host_android.{h,c}`：注册前 producer-ready 才提供 UI capability；stop 先撤销 broker 等待。
- `runtime/host_ui_jni.cpp`、`app/.../NativeBridge.java`：有界 UTF-8 byte[] 通路，保留原 request ID。
- `app/.../HostKeyboard.java`、`MainActivity.java`：主线程弹框；Activity 失活撤销，旧代际/重复完成被拒绝；不记录输入内容。
- `w4-tests/keyboard_owner_test.c`、`core-runtime/keyboard-tests/`：所有权、取消、传输、UTF-8、边界与错误负控。
- `core-link/audit.py`、`test_audit.py`：接受 NativeAOT 含空格的合法原符号名，保持 provider/导出/启动节检查。
- `CMakeLists.txt` 与 `core-runtime/tests/AndroidServices.Tests.csproj`：上述文件接入原构建/测试入口。

## 私有键盘消息草案

仅支持 `version=1,type=software-keyboard`，请求字段 `mode,min,max,header,subtitle,guide,initial,submit`，
映射对应 SoftwareKeyboardUIArgs。已实现 mode 0/1/2/3/5；未知模式显式报错。
数字模式只接受数字/点，ASCII 模式拒绝非 ASCII，文字拒绝 NUL 和不成对代理项。
min/max 采用上游 UTF-16 长度单位，范围 0..1024；request 最多4096 UTF-8字节，reply最多8192字节。
不依赖反射序列化，适用于 NativeAOT。

应答 `version,type,status`，`status=ok` 必须带经约束验证的 `text`；
`status=cancel` 仅来自真正的取消按钮/BACK。未知状态/坏 JSON/越界文字均报错。
broker 在本进程单一游戏会话中终态停止，Activity 代际与不复用 request ID 拒绝旧回答。
broker wait 的 TIMEOUT 继续等；UNSUPPORTED 记录为 HostRevoked，不能记录为用户点击取消；
ARGUMENT 可能是未知、已消费或竞争撤销，保守作为传输错误，不吞成取消。

主线程按100ms非阻塞检查队列，空队列不新建 byte[]，request ID 数组复用；
游戏服务线程复用一次分配的8193字节缓冲，等待500ms后继续或被broker唤醒。
`gate.c` 原 IPC 路径已经释放虚拟核，出 C# 在途账后才重取，停止时不重取；
本切片不再调用 leave/enter。`HostUITheme` 保持 Unsupported，不扩大到 inline/headless。

## 当前验证与未覆盖

- 原 broker 主机199断言通过；服务组合主机234断言通过。
- 键盘协议/传输69断言通过，包含用户取消与宿主撤销区分、坏类型/版本、未知ID报错、中文/emoji和边界。
- Activity所有权夹具在Mac ASan/UBSan与小米17 Bionic上通过；去掉撤销、放开旧owner两份变异均被拒绝。
- core-link真实含空格符号目标文件在旧解析上失败；修复后22项测试中20通过，2项平台条件跳过。
- v6 NativeAOT、APK、Lint、签名/16KiB对齐通过，但真实键盘未弹出（mode5明确拒绝）；不算游戏通过。
- v7源码58d733b8，APK `3c08450f09a4be500e9d9f0ec75ce1c968ac1ef2c648f3f4dc7b99e3302c27c0`，完整资源root仍为`sha256-019ecd2d844d70e46e2b751573386785aeb70514fc475dc122969ba8f779e1c8`。构建/Lint/签名/对齐通过；contrib第一层4/4绿，Mac使用本机Xcode26.3，不因固定27.1诊断阻止实际检查。
- v7两次独立冷启动均实际显示mode5、min1/max6的命名输入框和系统IME。第一局BACK：Java cancel/result0，托管UserCancelled；第二局通过系统输入框输入AT01、点OK：托管Accepted。未自动注入默认名字或修改guest返回。
- 两局在键盘应答后均首次缺 `0100000000000823 OpenDataStorageByDataId`（名字检查用NgWord档案），游戏Break；退出guest/fault errno125。不能把这里与启动时的MountSystemData缺项混淆。玩家下载目录和已核常用系统数据目录未找到该档案，等待玩家自有固件/系统数据路径，未造空词表。
- 第三局（2026-10-25）在命名框真正等待时通过HostApi请求stop0：托管HostRevoked，原生记录优雅退出完成0.496秒，随后PID消失。期间打印过0823缺项，但没有据此把前两局的失败退出改判通过；仅此键盘等待停止场景得到正向证据。
- 待继续：后台/Activity快速替换竞态；Java UUID/native session明确绑定；单虚拟核场景。三局分别验证确认、取消、停止，不代表完整W4或游戏通过。
- 原broker缺乏错误原因历史，快速detach/attach后未知ID仍保守报错；不把此项说成无缝Activity恢复已通过。
- `-105` 服务清理、Mi11 Ultra writer errno110、读回generation、存档重载、完整关卡和长时运行仍各自独立。

游戏、密钥、资源、存档、APK和原始私有日志都不随本草案提交。

## 10-25 附件与最新远端复核

已逐页提取并渲染阅读用户提供的四页《S2Arm_快速通用模式_1024.pdf》，
SHA256 `cf43e23309a80b45cbbc6d25189ad6fce7988ad1825a4eaac7677f72acf3b116`，附件不入仓库。
第1–3页的安全网针对图形接口、着色器及管线；第4页明确Android仍需NVN→Vulkan直连层。
这些路线不生成游戏直接请求的NgWord系统档案，也不构成当前Android可直接切换的已验收修复。

实际fetch后 `origin/android/integration` 仍为31fc9e8e，`origin/main` 为5d89ee53。
本地 `pack/sysdata_need.py`、`pack/sysdata_need.tsv`、
`compat/tree/src/Ryujinx.HLE/HOS/Services/Fs/IFileSystemProxy.cs` 与该main逐字节一致。
没有发现能补齐0823数据的新候选可合入；未将缺少Android接线的main服务组合覆盖当前候选。

[#99测试出包线的既有结论](https://github.com/jhaizhou-ops/S2Arm/issues/99#issuecomment-6380750779)
区分了启动MountSystemData与游戏直接OpenDataStorageByDataId：前者可继续，后者缺档会使游戏中止。
现有sysdata预检/`--sysdata`只提前报告或复制玩家提供的数据，不生成替代档案。
[#199最新owner回复](https://github.com/jhaizhou-ops/S2Arm/issues/199#issuecomment-6386448340)
继续要求NgWord明确报缺输入、禁止空数据假成功；没有另一个键盘实现可拉取。

已复核原始游戏输入catalog不包含0100000000000823；有界检查下载目录和nx2ios/data未找到
该系统档案或Switch固件NCA，常用Ryujinx系统内容目录亦不存在。当前缺项仍须由玩家提供
自己的固件NCA或解出的 `systemdata/0100000000000823/`，之后沿现有解包、manifest与资源绑定链路复验。
这是未完成的输入依赖，不能把读取PDF、fetch成功或前置检查通过写成游戏问题已解决。

## 10-25 iOS 与 Android 实际处理链对照

复核Apple main@6a64a2d9与Android本地候选：IFileSystemProxy、HorizonFsClient、
Ngc ContentsReader三个生产文件逐字节相同，未发现iOS专用NgWord替代/绕过实现。
共同路径是Host.SystemDataRoot → SystemDataDir(id) →目录构造RomFS；没有目录时再找已安装系统NCA，仍无则OpenDataStorageByDataId报缺。
Ngc启动MountSystemData失败可继续的上游兼容行为也由两端共享，不能用它解释游戏直接读档成功。

| 环节 | iOS/Apple路径 | 本轮Android |
|---|---|---|
| 数据准备 | seed_root.sh复制原始systemdata；stage_sysdata.sh可从S2A_SYSDATA/--sysdata补指定系统档案；ipa.sh:101把整个systemdata放进独立资源包 | make_pack.py同样收整个systemdata；已验证的实际index没有0823，源目录仅fonts与010000000000080E |
| 命名交互 | Host.cs:350自动确认InitialText，空文本用Player或数字0 | AndroidHostUi调用真实输入框，确认/取消/宿主撤销分开记录 |
| 游戏自行检查 | SoftwareKeyboardApplet.cs:248仍按CheckText把输入交回游戏检查；自动确认不等于跳过NgWord | 相同上游检查协议；实机确认后由游戏直接请求0823 |
| 测试存档 | ipa.sh:126–129按main构建号附测试存档；dev_run.sh推到Documents并设S2A_SAVE_DIR | 独立持久存档目录，不执行Apple seed覆盖路径；当前实际走新建角色 |

由这些代码可以确定存在资源准备与测试路线差异，不能在没有对应证据时断言用户所述的
iOS正常包一定带0823或一定使用存档。本机当前已知nx2ios产物目录没有可对照的iOS游戏包/资源包/局日志。
应优先核对那份正常iOS局的游戏版本/main构建号、配套资源包index中
`systemdata/0100000000000823/`及host.log里的`在/缺 OpenDataStorageByDataId`、带存档记录。
若已有同用户的真实系统数据，可经当前Android输入manifest和资源生产者重新绑定复用，
不需要把Apple自动姓名应答搬来掩盖资源缺项，也不必重复要求另行导出同一份已有数据。

### 用户确认同资源后的对照（10-25）

用户补充两端资源相同；据此前提，资源包差异不再作为当前根因。
上节列出的资源准备/存档机制只是代码事实，不是用户正常iOS局的原因认定。

- 保持Android v7/APK及资源root不变，真实输入框使用Apple空初始文本时的默认Player；
  Accepted后仍在0823 OpenDataStorageByDataId失败并guest Break，不能靠默认名字消除差异。
- 主机夹具实际调用Apple HostUi与AndroidKeyboard，再调用真正的
  SoftwareKeyboardApplet.PushForegroundResponse：UTF-8/UTF-16、普通/交互四组回包字节相同；
  改用AT01的四个负控均不同。夹具只覆盖回调与回包编码，不代表iOS真机执行。
- 核Exports.Svc：FileNotFoundException经共同catch报红并回失败码；Android当前实机日志
  没有Android session failed或额外HostApi fatal，随后是guest Break。
  HorizonHost.ObserveFailures确有平台差异，但其服务启动线程观察路径不是本轮调用栈，未据此修改它。
- 本机配对iPhone12当前不可用，没有同款同版本同起点的iOS日志可直接比对。
  后续需要定位正常iOS局是否实际发出同一数据请求及其结果，不能用“iOS其他游戏正常”推导本游戏免除该调用。

## 按现成iOS链路补Android出包（10-25）

用户明确要求复用 `--sysdata` → 共享需求表 → `systemdata/<号>/` 方案。
已在Android make_pack.py接入该参数及S2A_SYSDATA默认值；委托原sysdata_need.py做
身份/构建匹配、缺项诊断和COPY选择，不另建需求表。朱4.0.0的实测0823依赖补入共享表。
外部所需档案与既有系统数据在临时目录合并，整个树进入原index/SHA-256/artifact链。
原产物根优先，不覆盖玩家输入；缺项在改写/替换旧输出前失败。未知构建保持共享黄字策略。

实际验证：14项新回归、共享系统数据阶段原测试、原stage_a0/BootContract/输入身份检查通过；
另以合成NSO走真实改写与外部数据合包，版本目录激活/校验后字节一致。
完整旧输入的12个输出文件在旧/新打包器之间逐字节相同；真实朱缺项CLI退出1且旧输出不变。
这是出包接线修复，运行时HLE没有改动；当前手机仍装原v7，未拿合成数据伪造新的游戏资源。

本批生产提交 `988d63fae6708030dbda60e34c1f8332a531fd96`，本地未发布。
contrib第一层实际跑29/29，25绿4红（153秒）；四项为keepalive_test、oneclick_test、
shell_lint_test、tm_locale_test。隔离的未修改31fc9e8e工作树在相同本机环境下复跑四项均退出1，
分别同现LC_TERMINAL残留、Apple oneclick依赖检查未过、host/build.sh既有美元变量/非ASCII问题、
计时包装器区域设置用例失败。故不能宣称全门禁绿，也未把它们误归为新增sysdata回归。
本次14项新回归、共享sysdata阶段、Android钩子、A0/BootContract及真实缺项预检均通过。
