# 原生会话重载 probe

## 主线接合：Break 通知与画幅退休

`make -j2 S2A_CS=0 native-main-merge-probe` 后运行
`build/probe_main_merge <已有合法改写模块目录> <模块名…>`。
入口链接完整生产HOST_SRCS，原始模块/表只读，不启动guest、服务或GPU。
它调用生产画幅start/reset且要求reset返回0，再切换宽屏能力关/开，检查1920/2560宽度、
自动narrow清理和显式启动narrow保留；随后调用生产`svc_mem`的仅通知Break，
要求处理返回1、结果0，日志只记普通通知、没有Break红行或回溯。
此入口需要合法模块，不加入自动门禁；未独立观测scanner线程创建/join，不验证致命Break、完整会话重建或设备画面。
运行前须清除`S2A_WIDEN_VERIFIED`、`S2A_WIDEN_NARROW`；探针内设置只作用于自身进程，退出后不改变调用者环境。

## 初启前真实重建能力

`make -j2 S2A_CS=0 native-session-failure-probe` 后运行
`build/probe_session_failure capability`。它链接完整生产原生对象，先在没有guest登记、
尚未prepare时两次调用真实能力入口，再prepare并再次查询；Apple各次支持应为1，prepare为0。
查询先经原幂等线程键初始化建立实际停止边界，不能因初启尚未登记guest而误报不支持。
此例不占游戏窗口、不启动游戏/服务/GPU，也不证明Android运行时无owner路径；
Android按产品合同返回不支持，真实join状态也只返回未join。

## 帧步状态跨会话退休

`make -j2 S2A_CS=0 native-fps-reload-probe` 编译完整生产原生宿主源码。
随后运行 `build/probe_fps_reload <已有合法改写模块目录> <模块名…>`。
目录须已有与模块构建号匹配、包含 `speed` 行的正式 `fps.tsv`，不接受表路径覆盖。
探针只读原始映像与表，通过真实装载器映射模块，再运行生产 FPS start/reset 三次；
要求退休后状态页解绑且全零，下一局 `S2A_FSTEP=0` 保持未接页，再开启时重新接页。
运行前后核对输入与二进制散列。没有调用 SDK 初始化、客体、服务或 GPU，不打开存档，
不能代替完整会话协调器、宿主帧步调度、游戏或设备重启验收。此入口需要用户合法模块，
不加入自动 `TEST_TARGETS`；不能用临时假表或假模块替代缺失输入。

当前 `gtop=0` 安全边界排除宿主入口强停；旧十轮 probe 的 sleeper 按这种入口登记，因此下文十轮入口只保留作历史复现，不能再作为当前实现的通过证据。不得只填写一个并未使用的 guest 栈值来解除保护。

## boot 临时输入与正常装载

```sh
make -j2 S2A_CS=0 S2A_MAC_FRONTEND=0 native-boot-input-probe
build/probe_boot_inputs raw "$PWD/runtime"
build/probe_boot_inputs table "$PWD/runtime"
build/probe_boot_inputs <已有改写模块目录> modules main subsdk0 sdk
```

前两例用现有真实目录触发文件类型拒绝和 stdio 读取错误；table 例只在私有临时目录建一个指向原目录的符号链接，不伪造模块表内容。要求生产 boot 边界返回 −1、实际已开 FD 前后相等，探针退出 0。它们不需要地址窗口，构造期读不到 NPDM 的提示不代表游戏启动检查通过。

modules 例把真实模块目录放在第一参数，构造函数按实际 NPDM 保留窗口；模块名按已有文件提供。要求原生映射、门登记和重定位完成、boot 返回 0、模块数符合且 FD 保持。输入只读，不启动 guest、服务、GPU 或存档；不检查完整退休、全部分配/权限失败或第二局画面。

## 失败装载的映射与注册回滚

```sh
make -j2 S2A_CS=0 S2A_MAC_FRONTEND=0 native-boot-abort-probe
S2A_IPHONE_VA=0 S2A_GFX=generic build/probe_boot_abort <已有合法改写模块目录> first main subsdk0 sdk
S2A_IPHONE_VA=0 S2A_GFX=generic build/probe_boot_abort <已有合法改写模块目录> last main subsdk0 sdk
S2A_IPHONE_VA=0 S2A_GFX=generic build/probe_boot_abort <已有合法改写模块目录> after-load main subsdk0 sdk
```

按实际模块名提供参数。探针仅在私有临时目录创建指向原件的符号链接，将指定模块的 `gates.tsv` 链接到原输入目录，触发生产 `fgets` 的真实目录读取错误。原映像、NPDM、表、存档及缓存不修改；不启动 guest、服务或 GPU，也不替换运行时、分配器或文件 API。临时链接在探针结束时删除。

`first` 检查尚未增加 `g_nmod` 的映射和符号表；`last` 检查此前完整模块及当前部分模块。两例要求 boot 返回 −1，实际 FD/线程数保持、所有部分模块和门登记清空；Mach VM 遍历完整客体区，要求无空洞且全部仍为 `PROT_NONE`，宿主尾页的首尾哨兵保持。退出 0 才是通过。旧实现可使用同一测试源编译：在冻结基线的顶层 Makefile 后额外加载本文件对应的 `runtime/tests/mk/boot_abort.mk`，并使用独立 BUILD 目录。

`after-load` 保留全部真实门表，完成装载/重定位后调用生产画幅与FPS启动入口，再把已有目录交给原生内存初始化，触发真实NPDM读取错误。必须实测线程数已经增加，回滚后回到初始值；它检查真实扫描线程先退出再释放映射。是否存在FPS写入线程取决于实际输入，本例不能据此声称覆盖了FPS写入者。它也没有启动完整宿主协调器或guest。

这些例没有触发 iOS 中途 `vm_remap` 失败、读取者退出失败或所有 OOM/VM 错误，不能替代完整协调器故障、游戏连续重启或设备验收。

当前双补丁岛装载器在boot独占期按每个模块槽记录实际成功分配的起点/长度：
iOS在`vm_allocate`后、Mac在FAR/near两种`mmap`后立即记录，包含前/后岛与空隙，
不再从`base/patch_off/load_bias/size`反推单岛范围。重复槽在分配前拒绝，避免覆盖旧所有权；
成功boot把映像交给进程owner并清临时记录，回滚失败只清已成功归还项，保留剩余记录并禁止重试。
装载器复位还释放模块表（按本局容量分配的全部槽的符号表）与待绑定导入数组，释放NRO表、自动/手动链头及槽游标；
这些操作仍在所有读取者退出后进行。本次三模块实测没有双岛/NRO追加实例，
不能用它声称验证了硬件remap失败、窗口外映射或运行中NRO加载失败。

## 实际 SDK 等待与 TLS 阻塞

新增两个显式 Apple arm64 CPU 入口；不加入 `make test` 或自动 gate，因为需要调用者自己的合法改写模块。当前测试支持同一目录的 `main`、`subsdk0`、`sdk` 及源码中逐指令核对的 SDK wrapper ABI；缺模块、模板不符或无法核实真实等待均失败，不补造输入。

```sh
sdk_probe_modules=/已有合法改写模块目录
sdk_probe_run="$PWD/build/sdk-stop-cpu-new"
test ! -e "$sdk_probe_run" || exit 2
make -j2 S2A_CS=0 S2A_MAC_FRONTEND=0 BUILD="$sdk_probe_run" \
  native-sdk-stop-probe native-tls-join-block-probe || exit $?

for sdk_probe_case in sleep wait-infinite wait-timed; do
  mkdir -p "$sdk_probe_run/$sdk_probe_case/documents" || exit $?
  S2A_DOCS="$sdk_probe_run/$sdk_probe_case/documents" S2A_WAIT_DIAG=1 \
    S2A_DET=0 S2A_WORKGROUP=0 tools/bin/timeout -s KILL 35 \
    "$sdk_probe_run/probe_sdk_stop" "$sdk_probe_modules" "$sdk_probe_case" \
    "$sdk_probe_run/$sdk_probe_case/raw.log" \
    >"$sdk_probe_run/$sdk_probe_case/raw.log" 2>&1 || exit $?
done

mkdir -p "$sdk_probe_run/tls-block/documents" || exit $?
S2A_DOCS="$sdk_probe_run/tls-block/documents" S2A_WAIT_DIAG=1 \
  S2A_DET=0 S2A_WORKGROUP=0 tools/bin/timeout -s KILL 35 \
  "$sdk_probe_run/probe_tls_join_block" "$sdk_probe_modules" \
  "$sdk_probe_run/tls-block/raw.log" >"$sdk_probe_run/tls-block/raw.log" 2>&1
```

每次使用新的输出根，并清除已有运行时覆盖变量；模块输入只读，运行前后核对源码、模块和二进制身份。原地址窗口护栏必须可用，`libs2a_vaguard.dylib` 由构建放在可执行文件旁，不能跳过它。原始日志路径须与 stderr/stdout 重定向目标一致，探针需要读回生产线程 dump。每例都应退出 0；超时、信号退出、缺前置或 FAIL 都是红，不能把外层观察器结束当通过。

三个普通例实际在 NPDM Stack/RW 映射执行本机胶水，再调用原 SDK SleepThread / WaitSynchronization wrapper；由 SDK gate LR、生产 dump 与 Mach WAITING 核实等待后，生产 `s2a_thread_stop_all(5000)` 必须得到 stop 0、joined 1、TLS 析构一次。两个同步例还需核对未触发的真实事件、kind4 阻塞和取消返回 `0xec01`；不由探针自己 join 客体。

TLS 例在真实析构中用 pthread 条件变量阻塞。首次原生 stop 必须在 5–6 秒调度观察范围内返回 −1，joined/TLS 均为 0；两次实际查询中栈页、数据、线程和事件身份保留。解除条件后，以完整 Mach 快照确认原 joiner 已消失，才串行调用原生 stop 完成组件收尾；joined 1 / TLS 1 后释放自有资源。pthread 的实际栈边界须在 bootstrap / TLS 阶段保持一致，不能把请求 8 MiB 当作实际报告大小。该例不启动完整协调器，不表示 FAILED 会话会重试，也不证明 `hstk=NULL` 之外的尾部分配器栈回收。

这些入口只验证当前等待停止和 TLS 截止/所有权边界；不覆盖普通建退线程的回收锁竞争、全部 svc、CPU 循环、封门、其余四类故障、服务/图形完整资源账、游戏或设备重启。

## 历史十轮入口

`runtime/tests/probe_session_reload.c` 链接完整生产原生宿主实现，使用已有合法改写模块目录中的真实 NPDM、映像、符号和门表。它不调用 SDK 初始化或 `nnMain`，不启动服务层或 GPU，不打开存档，也不改输入模块。

```sh
make -j2 S2A_CS=0 S2A_MAC_FRONTEND=0 native-session-probe
S2A_DOCS="$PWD/build/session-probe-data" S2A_GFX=generic S2A_IPHONE_VA=0 \
  build/probe_session_reload <已有改写模块目录> main subsdk0 sdk
```

模块名按目录实际内容提供，不能补造空模块。CPU 循环用例要求实际 SDK 导出 `memset`；关闭门用例从实际 `.gates.tsv` 读取 SleepThread 门。缺少这些前置会失败。

十轮中交替执行原生定时等待、实际 SDK CPU 循环、无限及定时 WaitSynchronization、已关闭的 SVC 门五条路径。等待用例先通过 Mach 查询观察 pthread 已阻塞，再请求停止；每轮要求生产 roster/reaper 确认 join 完成、TLS 析构已执行、句柄清空、重载模块地址和原始数据一致。另在真实宿主尾部分配一页并跨十轮读回，检查重映射客体区没有覆盖宿主保留区。输入模块只读；数据修改仅发生在 probe 进程自己的映射中。

可选 `S2A_PROBE_WIDEN_RELOAD=1` 使用同一目录已有的 `widen_verified.tsv`，交替核对宽屏设置和自动窄屏项，不接受验证覆盖变量。社区 FPS 行数在末行如实报告；行数为零不构成社区补丁覆盖。

服务等待另用真实 OfflineSocket 组件验证，不安装测试工程默认的 FakeNative：

```sh
dotnet build services/S2A.Services.Tests/S2A.Services.Tests.csproj -c Release -m:2
dotnet services/S2A.Services.Tests/bin/Release/net10.0/S2A.Services.Tests.dll --offline-socket-shutdown
```

该入口做十轮实际 Accept、ReceiveFrom、Poll 阻塞及取消，要求线程 join、返回 Interrupted，并在 Reset 后读回实际离线 UDP 数据。它不启动游戏、服务主机或渲染器。

这些组件检查不证明完整 `s2a_host_restart`、UIKit scene 时序、第二局画面、九款游戏、存档保持或联机对端收到断开。完整重启仍需真实服务/GPU组合和设备游戏验收。`s2a_host_restart` 的立即返回 0 只表示受理，异步成功只表示新 guest 线程已登记启动。
