# Android只读复制的有界权限检查

基线已合入android/integration e389ce14，本地合流619de62b。合流v9的实际小米17
角色确认页仍约5FPS，160个GPU线程样本里133个PC在query/amask_at；不是旧分支遗漏
已合入优化造成的假复现。

原路径每次缓冲复制先按s2a_mem_query寻找完整连续区域，在别名区向两侧并段。
新增s2a_mem_readable只检查请求区间，并按原query优先级处理堆、显式映射、模块、
TLR和别名子页，严格核perm读位。共享g_mu只持有到范围检查结束；原alias复制与
backing前后同步不变。不改guest QueryMemory，不删除校验、不清保护。

本机native-test-svc_mem 78/78：包括新增20000个读权限区间与旧逐段QueryMemory
对拍0差异。64MiB中检查8字节，位图探测旧4099次→新1次。两个破坏性对照有效：
误用mapped-only漏读权限/TLR共6项失败；恢复整段query则性能守卫失败。
真机Bionic4KiB夹具：bounded与legacy各4657断言、private13断言通过，覆盖跨页字节、
保护/dirty保持及冻结配置；夹具的VM范围是明确的测试端点，不等于完整游戏内存验收。

v10保留冷启动s2arm.bounded_readonly_check布尔开关（默认true）用于同APK A/B；
首次copy后禁止改值。原#233的DMA preservation和SME开关独立。
真机游戏性能复测另追加实际读数，不将位图探测倍数换算成FPS提升倍数。

## 最新集成与真机结果

推送前远端又前进到55929f8a，已合入本地8c14f122，保留其Vulkan/VKPB、后台、显示
及启动模式更新。HostUi实际消费继续走本地HostApi broker，保留Accepted/UserCancelled/
HostRevoked及错误区分；上游壳层兼容入口保留，不同时调用两个键盘生产者。
69项键盘协议与234项服务合同通过；244个Ryujinx补丁回放一致。

- v10同APK `7b0975900b8d9a2d55df0f7fb9ec56be263b0eae1639a9f5ae004c5117c45d6c`：
  旧检查在形象选择页截图6、7FPS，160栈样本里s2a_mem_query126次；恢复同一更新前
  缓存快照后启用新检查，同页截图21FPS。开启局后续发生已有GPU读回旧脏态保护错误，
  第二次采样被SIGSEGV中断、只有36条，不能当完整稳定性通过或全程FPS均值。
- v11最终组合APK `009dc4a2f33f4574d99cca2255d950b8d0ac128945e93e44dbde4e152eaaf824`：
  本机NativeAOT/assemble/lint/签名/16KiB对齐通过，安装后base.apk回读相同。形象页截图
  23FPS、用户操作后的角色确认页18FPS；完整160栈样本中query/amask_at/s2a_mem_query均0，
  只读copy链仍有23样本。采样8.1875秒，中断请求到恢复累计107.249ms；它是墙钟栈分布，
  不是GPU执行耗时。两窗口及用户操作不同，不用这些截图计算正式性能提升倍数。
- 新包沿用743文件的同一资源索引；升级前的存档与缓存已私有备份，未清除用户数据。
  仍属通用Ryujinx GPU→Vulkan，未声称已切到安卓直连、达成3.7W或通过长时游戏验收。

一级自检（8c14f122，对55929f8a）：应34、实32，28绿4红，157秒。四项为keepalive、
oneclick、shell_lint、tm_locale；同机未改55929基线分别复跑，四项均同样退出1。工具按27.1检查而
跳过iOS全量及自动native钩子；本机依用户要求继续用Xcode26.3，原生内存78项已单独
实际编译运行，不把自动跳过写成通过。新API未修改Apple既有QueryMemory/mapped语义。
