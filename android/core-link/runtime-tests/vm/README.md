# Android VM 实际页回归

> 合流说明（2026-10-28）：本页合并双方已有说明与原验证记录；相关源码冲突尚待解决，原记录不代表本次候选重新通过。进度见 [合并分析 §13](../../../docs/direct-main-merge-analysis-20261028.md)。

在原生Linux ARM64离线环境运行 `python3 android/core-link/runtime-tests/vm/run.py --out <私有输出>`。链接生产svc_mem、tracker、registry、plat_vm_alias、os.c时钟/熵源、redlog和内核映射；其它core/NPDM/handle及writers安全点是明确合成端点，writers_ready保持0，因此通过不等于真实Android全线程停车或GPU已验。thread.c端点（硬件核数）按生产语义合成，真thread.c平台绑定太深不进此夹具。

`check_endpoints.py` 是宿主端点核对（mac / Linux 都跑，已挂 test.sh）：把 run.py 实际编译的 svc_*.c 产物经 nm 的未定义符号，与链接清单各源（含 core_endpoints.inc 等 #include 进来的夹具源）的顶层定义核对；svc_* 新增引用没登记的当场【红】，不等 Linux 链接期。run.py 开头自动先跑它；weak 未定义（`s2a_alias_drop` 这类可选接缝）只点名不判红，libc / 工具链引用在脚本 SYSTEM_EXTERNALS 逐名登记。

合成端点固定没有停止请求，意外进入永久 park 即失败。`quiesce-fail` 注入的 ENOTSUP 必须由生产 SVC 宿主协调错误诊断并终止，不能再转换成 guest D401。真实 writer 准入竞争、epoch、虚拟核与停止返回边界在相邻 `writers-gate/` 单独运行。

P1/P2 之前的 38 个进程覆盖：已有五类alias/代码/transfer映射、内核失败恢复与poison退出，stack复制的同步GPU回调重入VM；heap/physical真实共享零页、W2真实alias、4K子页替换保留相邻页和仍存活的旧alias、重新增长不保留旧内容、实际内核分配失败及旧内容释放失败终止。`physical-host16-partial`与`shared-model16-*`只包装page-size返回值来验证16KiB宿主页准入/跨度合同，实际内核仍为4KiB，不能称为真实16KiB设备测试。

`shared-4k`与`shared-4k-unmap-fail`直接走SVC 0x13/0x14，源/目标都位于16KiB边界后4KiB，请求仅4KiB；双向写穿、相邻页内容/权限不变、正常unmap及真实内核失败后的旧映射恢复分别验收。`code-4k`、`transfer-4k`覆盖共用alias原语的直接消费者，并记录再调用真实保护通知hook，确保通知范围不会左移到16KiB分组基址。`--case`可选择窄用例，`--svc-source`可对旧源运行相同夹具；旧源必须在上述4KiB成功预期上失败。

生产按实际宿主页处理状态改变的连续段，4KiB子页元数据仍复用原HPG位图。16KiB宿主的部分页变化在任何mapping/回调前返回真实错误，原映射保持；不通过扩大范围破坏邻居。全不变的Map/Unmap幂等返回。新堆与物理页使用MAP_SHARED匿名零页；释放回MAP_PRIVATE/PROT_NONE自有reservation。GPU before在旧页有效且无VM锁时完成，真实metadata更新后才end。

新增页失败可恢复PROT_NONE与旧metadata；释放旧有效内容失败无法证明完整回滚时明确终止。若一个多段SVC已提交前段，后段内核/事务异常也终止，不能返回部分成功伪装原状态。正常路径不持g_mu回调managed；实际guest writers仍必须由生产thread owner暂停。

旧private窗口+mprotect源码用同fixture的heap/physical真实alias断言应失败；保留的负控不是假的“期望异常即PASS”。Apple原路径保留并另跑现有t_svc_mem。未运行APK/真游戏/真实Vulkan设备，不宣称所有guest内存（主栈/TLR等）已迁成shared。

`protect-4k` 与 `stack-4k` 使用真实 Linux 4 KiB 宿主页核验权限收紧、放宽和栈映射/解除，检查相邻宿主页不被误改；它们对旧固定 16 KiB 对齐实现分别按实际权限断言报红。该 Linux 夹具需 T 组生产 tracker，N 独立阶段应注明隔离叠加的依赖，不能当成 Android 设备结论。

改表断言（#619 P1-1 加固）另有独立单测 `run_owner.sh`（owner_test.c，只链生产 svc_mem.c + 最小桩，不依赖 graphics/track）：Linux 上 `bash android/core-link/runtime-tests/vm/run_owner.sh`；给旧源路径时第 ③ 项应红。

## 常驻镜像回归（Linux 实际内核）

镜像夹具沿用真实 SVC、tracker、平台别名和 `readonly_copy`，只把非本测核心端点与 guest writer 停车作为合成端点；其中串行入口桩不证明真实线程停稳。`physical-mirror` 检查四种映射调用数与跨页字节；`physical-mirror-syscall` 在预热后的子进程用 seccomp 限制复制窗口中全部系统调用（退出本身除外）；`physical-mirror-fallback` 注入镜像保留失败、要求一条红行及原逐页别名仍可读。

`physical-mirror-split` 用两次独立映射建立相邻不同 backing；`physical-mirror-race` 做 10,000 次 0x2C/0x2D 对 10,000 次读取，只允许完整旧/新内容或 EFAULT；`physical-mirror-snapshot` 在两页 memcpy 中间替页，要求整段重试；`private-stack-mirror` 检查私有栈页仍返回 EINVAL 而不是读到镜像零页。对应负控是分别去掉读后世代复核、位图检查、写回世代复核。原先的 `physical-mirror-writeback-stale`（同线程在 `restore_precise` 的 memcpy 中替页）在 D1 写者计数之后会等自己持有的计数直到超时，预期已过时：D1 的 `mirror_begin` 会等在途写者归零，同页替换不能与 `restore_precise` 的 memcpy 重叠；`writer-timeout` 用例证明等待有上限、超时报红。`tracking/tests/run.py` 的 `mirror_estale precise` 只覆盖全局世代 `ESTALE` 的重试与记账（搅动页与恢复页不相交），不覆盖「正在写的这一页被换掉」；`restore_precise` 的释放失败也没有专门用例。这些主机用例不证明 Android 设备内核、真实 GPU 队列或游戏性能。

## 背板纯接口（P1）

`backing-api` 只链 `android/native/runtime/vm/backing.c`，不经过 `svc_mem`/tracker，也没有生产调用方。它覆盖单一 memfd 的 open（含启动自检）、同一 pgoff 的双视图共享、按页 punch、deferred 出参、refs 区间拆合与下溢拒绝、打洞世代号、reset 的 EBUSY 与整文件打洞、512 GiB 末端 map/punch、1 万页逐页直映后的 VMA 段数，并打印空洞页与已填充页的单次 punch 耗时（p50/mean，只记录读数，不设判红阈值）。`--wrap=fallocate` 在真实打洞回调里断言世代号为奇数；`backing-api-16k` 用 `fake_page16` 模型跑同一套逻辑，并断言 4K 偏移/长度在 16K 粒度下回 `EINVAL`。`plat_backing_refs` 对非法区间回 `UINT32_MAX`（fail-closed），不能当成无引用。主机读数与内核版本相关，不能当作 Android GKI 的实测。

## P2 主修复（背板接入）

P2 的默认用例共 60 个进程。`backing-vma-merge` 在别名区逐页 0x2C 提交 1 万页（写 0x5a），VMA 必须 ≤ 基线+8；随后逐页 0x2D→0x2C，重映射页读回 0 且 VMA 仍 ≤ 基线+8。旧源（`--svc-source` 指 P1 之前的 `svc_mem.c`）同一夹具读到 `VMA=10000`。`physical-unmap-borrowed` 检查 0x2C→0x4B 借出→0x2D 必须回 `0xD401` 且 A/B 不变；它覆盖的是共享修复 `dbcb99865`，旧于该提交的源才红。`nvn-remap-ref` 覆盖长寿别名 ref 下的延迟打洞、同 VA 增长回 `0xD401`、部分重叠 ref/unref、`vm_remap` 注入失败后的撤销、`s2a_vp_alias_table` 的切段与 release；旧源没有 refs，增长成功，因此红。`nvn-dead-tail` 检查逐宿主页核活：首页活、尾页死时整体回 `-EFAULT`，后续增长仍能成功。

`backing-alias-shared` 检查两个代码内存映射共用背板源、解掉一个后另一个仍读到 0x5a；`backing-alias-merge` 用 2 MB 逐 4K NONE→RW，VMA ≤ 基线+2；`tmem-close-mapped` 对齐 Ryujinx：传输内存映射期间关最后一个句柄，源保持借出，0x2D 回 `0xD401`、0x52 回 `0xE401`；`stray-alias-refill` 用裸 `plat_vm_alias` 往已释放页回填 0x77，0x2C 提交前打洞必须丢掉它；`readonly-punch-race` 在两页只读拷贝中间做 0x2D/0x2C，靠背板打洞世代号整段重试，并另起线程压 `s2a_track_read_untracked`；`nvn-ref-race` 在 `backing_begin_locked` 放锁窗口注入 ref，0x2C 必须回 `0xD401` 而不是 die；`deferred-report` 让死页带 ref 被释放，`背板 … deferred=1`；`va-report-lock` 打开 `S2A_VMA_REPORT` 后先调 `s2a_guest_va_report` 再查 g_mu，证明 VMA 采样在放掉 g_mu 之后解析 `/proc/self/maps`（采样器入口对「持 g_mu 解析」直接 die）；`punch-stats` 断言 `背板` 行的提交前 / 释放 / 最后 unref 补打三类计数与累计 ns 随操作增加、deferred 不计入；`vma-far` 在窗口上方放宿主匿名映射与 guest 背板页，检查宿主映射只进 `host`、只有 guest 背板越窗才进 `far`；`nvn-alias-16k` 在 `fake_page16` 下验证 4K 对齐、16K 不对齐的 NVN 请求只进页表、别名表与 refs 不变，并断言 `s2a_vp_alias_add` 对这类区间 SIGABRT；`unmap-madvise-private` 注入 `madvise` 失败，检查红字与解除成功；`transfer-model16-source` / `code-model16-source` 在 16K 模型下检查 0x51/0x4C 源只按 4K 对齐时回 `0xD401` 而不是 die。`nvn-stopworld` 是并发 ref/unref 冒烟，不再宣称真实停世界互锁；`lockorder-abort` 在子进程里持 `g_mu` 再调 `s2a_mem_lockorder_vp_enter`，Debug 构建必须 SIGABRT；`run.py` 另做 `lockorder-wired` 源码检查，确认 `hle_nvn.c` 的 `vp_lock()` 真的先调断言再取 `g_vp_mu`；`vpalias-wired` 检查 `vpool_map` 的「只进页表」早退在别名表 / ref 之前，且 `s2a_vp_alias.c` 保留入口对齐断言。

`physical` / `heap` 已按 P2 语义调整：堆页由 memfd 提交，增长后是零页，缩掉再长回来仍是零；`physical` 的第二视图必须显式 `s2a_mem_backing_alias_ref` 才能在 0x2D 打洞时保住内容（0x4C/0x51/NVN 都走这条记账，裸别名没有 ref 会被提交前打洞清零）。`physical-map-fail` / `heap-grow-fail` / `physical-unmap-fail` / `heap-unmap-fail` 现在都要求背板映射失败后 `SIGABRT`，不再回 `0xD401` 或回退匿名映射。

负控（本机实测）：撤掉 `readonly_copy.c` 的背板世代号检查，`readonly-punch-race` 报 `mixed/stale byte 0=11`；把 `backing_prepare_locked` 改成空操作，`stray-alias-refill` 报 `committed page kept stray alias data 77`；把 deferred 改回直接 `abort()`，`nvn-ref-race` 收到 SIGABRT（证明该夹具真的覆盖放锁窗口）。`--svc-source` 旧源三项分别报 `VMA=10000 baseline=1`、`0x2D borrowed page returned 0`、`grow over ref'd page returned 0`。这些都是 Linux 4K 主机读数；16K 仍只是 `fake_page16` 模型，NVN 真实后端与真机 GKI 未验。
