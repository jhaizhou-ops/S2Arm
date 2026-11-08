# 真实 writer 准入与 SVC 返回回归

> 合流说明（2026-10-28）：本页合并双方已有说明与原验证记录；相关源码冲突尚待解决，原记录不代表本次候选重新通过。进度见 [合并分析 §13](../../../docs/direct-main-merge-analysis-20261028.md)。

在已有 Linux ARM64 环境离线运行，不安装依赖：

```sh
python3 android/core-link/runtime-tests/writers-gate/run.py --out <仓库外私有输出>
```

需要 C 编译器、Python 3 和原生 ARM64 Linux 内核；不启动 Android、Docker daemon、ADB 或游戏。

`--two-guest-only` 单独跑两条真实 guest 线程并发 MapMemory、UnmapMemory、同尺寸 SetHeapSize：第一条在释放 g_mu 的 host_write / backing_begin 回调内停住，第二条须撞上真实 writer 串行准入并等待；核对返回码和最终映射。三项也对只删除私有副本中的串行等待做负控，必须命中指定的准入失败。此模式已接 Linux Android 默认 gate；仍是 Linux/glibc 主机夹具，不是 Android/Bionic 或游戏验证。
输出完整命令、退出码、编译器依赖文件与源 SHA。`--case` 可选择单项，默认 32 个进程；每次都运行八个私有源码负控。

夹具直接包含生产 `runtime/src/thread.c`，链接生产 `gate.c`、`svc_mem.c`、det、时钟、VM、tracker、fault/xstack 和内核映射。注册一个实际 gate 后，由真实登记 pthread 发起 SVC，另一真实 owner 占用 writer serial。只在 `pthread_mutex_trylock` 的真实返回处观察或延迟，以固定 epoch 发布前后及取得 serial 后的竞争窗口；睡眠用例另在真实 `nanosleep` 外观察进入和EINTR，仍执行内核睡眠，不制造返回值。不替换 writer 准入、roster、barrier 或停止状态。

覆盖：MapPhysicalMemory、UnmapPhysicalMemory、MapMemory 在两个窗口中的成功与实际 metadata/读写；持虚拟核时释放和重取；查询与真实参数错误同样经过返回屏障；准入超时撤销安全承诺后不能越过活动 epoch；嵌套 owner 明确 fatal；停止发生在等待中、取得 serial 后、查询返回屏障中时均不能返回 guest，且不映射并允许 host owner 继续清理。停止用例观察永久 park 后结束测试进程，不声称已逐线程销毁。

负控只在输出目录的副本删掉真实 `android_vm_wait_serial` 调用，再运行同一并发正例。必须命中宿主协调错误 `errno=16` 且退出 134，任意崩溃或超时不算通过。正常超时和嵌套测试也分别核对真实 errno，不把非零退出一律算绿。

边界：测试自行建立布局与线程元数据；module PC 范围、TSD offset、未执行 loader/其它服务端点为显式 provider。未执行端点误入即失败。复用现有 `thread_guest.S` 与测试栈切换。部分对象使用 `S2A_UNIT_TEST`；实际内核是 Linux/glibc，未执行 Bionic、NativeAOT、managed GPU 或 APK，也不等于全虚拟核饱和压力或游戏通过。普通 VM 映射/回滚的 27 项仍由相邻 `vm/` 覆盖。


线程生命周期增量：`lifetime-peer` 与 `lifetime-wake` 调用真实 CreateThread、StartThread、ExitThread、CloseHandle 和 wake。仅把该线程对象的 calloc 放到独立页，实际 thr_free 执行 free 时用 mprotect(PROT_NONE) 延迟回收；对象释放后若生产 peer 消费再读它，SIGSEGV 必须落在这块页并退出 87。未知崩溃退出 89，不算已复现。`lifetime-publication` 包装真实 pthread_create，拒绝其输出参数直接指向共享 pt（退出 86），并观察调用者在 G 内发布实际 pthread 标识；没有以假 pthread 替代真实创建。`lifetime-reused-handle` 仅将句柄代际计数置到回绕窗口，再用真实 h_new 分配同号不同 id，旧 peer 必须立即失效，不能等待新线程。

这几个用例的 guest 入口是显式 authored host 函数；runtime 准入 provider 只允许该测试模式，不证明完整 runtime 加载。对象以真实线程退出路径释放，pthread 仍走当前 Android 尾栈缺失时的 detached 回退；测试不声称执行了 Apple 尾栈 join 回收。default 用例取消 S2A_CORES 环境变量，ondemand 用例用 mask=7/percore=0 的真实非参与者；两者仍须停在实际 Android epoch，停止不能返回 guest。显式 full（S2A_CORES=1）用例保留。

另两个私有负控分别去掉 peer 的 id 校验、去掉 Android 父线程的 G 发布，必须分别由同号不同线程用例、真实发布观察用例以具体断言拒绝（退出 1）；崩溃不能代替正确断言。

`lifetime-priority` 在第一次 wake 后执行实际 SetThreadPriority，再唤醒另一较低优先级线程；选择应保留目标当前优先级，不能用旧采样优先级替代。


续期回归：`renew-budget` 检查未发布/false原2s、同epoch保留、后台暂停、恢复及serial后的独立roster期限；实际 `progress-published`/`progress-stall-published` 分别检持续推进与停止推进。`publication_revoke.py` 两臂后台4.2s、恢复后350ms放writer；`roster_handoff.py` 在取得serial后由第三方持G锁350ms，前台/后台均须成功。owner/writer权限另由host_android_test与下面完整WSI模型覆盖。

单权威版本：完整协议和验收边界见 [换页等待状态机](../../../../docs/换页等待状态机.md)。托管只报告推进与读取原生裁决；原生 WSI 租约 mutex 同时保护外壳前后台写入与 CLOCK_MONOTONIC 取时，恢复回调当场重置。

`renew_model.py --out <目录>` 执行完整生产 WSI 与 gate 适配器，20事件深6；`--negative-cap` 和 `--negative pause|resume|observation-reset|stale-clock|owner|epoch|withdrawal` 只改隔离编译副本，必须以 `REGRESSION events=` 报红。`authority_races.c` 覆盖时钟采样内部外壳回调竞争。托管发布模型只枚举阶段/关闭/不透明裁决；不再重复建模时钟。

control-tests 的 run.py 额外编译生产 WSI 的 native 测试绑定；独立重跑 DLL 时将输出 `runtime/` 加入 LD_LIBRARY_PATH（macOS用DYLD_LIBRARY_PATH）。Mac测试不会调用租约条件等待，测试翻译单元只对该未使用的条件时钟设置作显式shim；Linux用实际实现。可设 `S2A_NATIVE_WRITERS=<真实ARM64 gate二进制>` 联合 `BackingNativeLifecycle`、`BackingPublicationHandoff`、`PublicationClockOrigin`、`PublicationFailureBoundary` 与 `DelayedResumeObservation`，共享256字节测试页，仅host边界使用进程共享锁，期限函数仍为原生生产代码。没有Android/Vulkan/游戏执行。
睡眠增量：`sleep-interrupt`（含full cores变体）通过真实gate调用600ms的SleepThread，内核睡眠中由writers begin发送SIGURG；census必须在100ms内完成、真实epoch获得目标ack、目标不持虚拟核且不能提前返回guest。VM持有200ms后释放，总睡眠仍须不少于600ms且不延长超过100ms。`sleep-expired`的200ms截止点落在350ms的VM持有期间，释放后应在100ms内返回，不能重启睡眠；`sleep-signals`发送五次没有VM事务的SIGURG，也不能使SleepThread少睡。三个新增私有负控分别删barrier、恢复单次nanosleep、把VM停车时长加回deadline，必须命中对应的等待过长/少睡/多睡断言。定时器上界是低负载Linux主机回归边界，不是设备帧率验收。

暂停增量：`sleep-pause`请求3.2秒睡眠，真实thr_pause必须在100ms内成功并得到SVC上下文ack，而非等满两秒超时；含full cores变体。`sleep-pause-expired`覆盖暂停跨过原睡眠截止点，恢复后不得重启计时。`sleep-pause-vm-first`在VM epoch仍被owner持有时发暂停，必须立即ack；`sleep-pause-vm-after`先暂停再启动writer，恢复时仍不得穿过活动epoch。另两份负控分别完全省掉pause poll、仅在VM停车前poll一次而不在停车中复查，必须命中具体暂停超时断言。暂停只用现有pause/ack/CV合同，不接入#325候选；信号入口固定NULL poll，不得在handler中拿宿主锁。

`det-poison` 在确定性共享内存的真实 alias 路径注入权限设置与目标保留恢复双失败，要求生产代码在目标所有权无法保证时直接终止；不得继续把目标交给备用映射。测试使用 Linux ARM64 内核及平台故障注入点，不代表 Android/Bionic 真机执行。

W3 增量（0x2C 全空宿主页增页免全体停稳）：`callback-map` 让真实登记线程 A 停在宿主回调（`off_guest`、不持虚拟核），线程 B 走生产 gate→0x2C→内核映射；B 必须由只串行 epoch 完成，A 仍未退出。`callback-unmap` 在同样条件下走 0x2D，释放 A 前 B 不得完成。`callback-unmap-stuck` 不释放 A：B 必须在唯一预算到期时先输出 `writer协调到期`（SVC、epoch/owner、预算、未停稳线程、callback=unknown），再以 errno=110 终止。`callback-map-adjacent`/`callback-map-16k-adjacent` 在 4 KiB 与模拟 16 KiB 宿主页下检查相邻活页内容保留、新页为零；`map-partial16`/`callback-map-partial16` 用 `--wrap=plat_page_size` 模拟 16 KiB 宿主页，验证部分页不被只串行接住；`fast-map-rollback` 注入真实 `mmap` 分配失败，要求 metadata/epoch 回滚后重试成功；`fast-stop` 验证 Stop 先于只串行入口取消；`race-map-map`/`race-map-unmap` 让两条真实 guest 线程并发走不同内存 SVC。

负控：把 `svc_mem.c` 的 0x2C 选择改回全体停稳，`callback-map` 必须因预期的协调超时失败（errno=110）；把 0x2D 错改成只串行，`callback-unmap` 的“释放前不完成”断言必须失败。两者都调用真实生产 gate/VM，不只 mock 返回值。

真机入口：`run_android.py --serial <arm64 设备> --out <仓库外私有输出>` 用 NDK clang 编同一源清单/链接参数，经 adb 在 Android/Bionic aarch64 上跑同一批用例和上述两份 W3 负控。`--all` 跑宿主默认全部用例（跳过 `external-published`），默认只跑 W3/核心准入子集。它不替代 `run.py`（Linux/glibc ARM64）；`--wrap=plat_page_size` 只是 16 KiB 模型，不是真实 16 KiB 设备。APK/游戏、managed GPU 和真实 16 KiB 设备仍不在本夹具内。

2026-10-29 本机证据：x86_64 宿主无原生 Linux ARM64，qemu-user 在 `race-stack` 的 SIGURG/altstack 路径 SIGSEGV（不是测试断言）；同一候选在 Redmi 22081212C（Android 16、aarch64、4 KiB 页）上用 `run_android.py` 跑完 W3 子集、既有准入/停止/生命周期子集及三份负控，全部 PASS。未执行 APK 游戏五局与真实 16 KiB 设备。
