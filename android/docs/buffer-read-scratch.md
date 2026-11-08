# 缓冲只读上传暂存复用实验

默认关闭。Android 冷启动传 `--ez s2arm.experimental_buffer_read_scratch true`，JNI 在
host 创建前设置 `S2A_BUFFER_READ_SCRATCH=1`；实际托管策略写入启动日志。
独立PR基线尚无下游A0冻结启动事实接口，不为此引入整套采集分支。
未显式开启（含非法环境值）保持独立 MemoryOwner 租用。苹果默认路径保持关闭。

仅替换 PhysicalMemory 的缓冲上传暂存租约；原平台 readonly-copy 回调、GPU owner
检查、溢出检查、脏区/GPU-owned 排除、SetBufferData 消费边界不变。纹理暂存不变。
不省略数据复制，不发额外 tracking signal，也不改 guest 权限或写回时机。

每个 PhysicalMemory 最多四个槽，每槽最多 256 KiB，按需增长且总保留不超过 1 MiB。
嵌套租用使用不同槽；槽满或超限回到原 MemoryOwner。值租约记录槽代次，重复/旧副本
Dispose 不会释放后续租用，过期访问拒绝；代次耗尽的槽不再复用。池租还及访问要求原
GPU 线程。与原 Span 一样，调用方不能在 Dispose 后继续使用先前取得的 Span/Memory；
当前两个调用点均在同步 SetBufferData 返回后释放。不会复用公开 MemoryOwner 对象。

## 已验证与限制

Linux x64 .NET 10 JIT，离线编译实际 GPU 源码和现有 backing/control 夹具通过；
290 项 backing 断言及五种 frame-wake 策略回归通过。实际 Buffer.SyncAction /
whole-buffer → BufferHolder.SetData 消费者关闭/开启各九种正控通过，包括真实 None
源页复制、GPU-owned 排除、copy/upload 异常、错误线程、租约失效、无重复跟踪。
Linux 四种 AV 负控均在实际 Memmove/BufferHolder.SetData 以 SIGABRT 失败；
本轮没有重跑 Mac 负控，不能称 Mac 或在途 GPU 提交验收。

源码 `8dd128ee` 的 Android NativeAOT、assembleDebug、lintDebug、签名及16KiB
对齐检查通过；APK `94158d2fcd4a` 已安装并验证完整哈希，1775 项游戏资源复用、
RomFS 网络传输为0，存档保留。Windows贡献者总检仍因 Python3入口/固定venv/
Xcode 缺失记不完整；以上局部通过不能替代总门禁。

独立编译生产暂存类及生产 Common DLL：嵌套数据独立、重复释放、旧副本、槽满/超大
回退、异常清理、空/负长度、错误线程拒绝均通过；预热后十万次 256B 租还线程分配
为 0B。该读数是主机 JIT 机制结果，Android 整进程分配/GC/FPS 改善仍需同包真机 A/B。

```sh
dotnet build android/core-link/runtime-tests/buffer-scratch/BufferScratch.Tests.csproj \
  --configfile "$OFFLINE_CONFIG" -p:Dependencies="$PRODUCTION_DLL_DIR" -p:ArtifactsPath="$OUT"
S2A_BUFFER_READ_SCRATCH=1 dotnet "$OUT/bin/BufferScratch.Tests/debug/BufferScratch.Tests.dll"
```

## 小米17 Max 下游同包实测（未达标，非独立PR头APK）

以下验证在含采集/身份的下游分支完成，仅暂存机制源码相同；独立PR基线56d42633
的代码提交`5716014c`已完成NativeAOT、assembleDebug、lintDebug、签名与16KiB
检查，APK SHA256 `d020ceb9ec8bbe7862a8a7b83f50f38ea73c3f103662719347b9da9e480b34d3`。
此后只补本文档；该包未安装真机，不把下游A/B冒充独立PR头真机验证，保持Draft。

`8dd128ee` / APK `94158d2fcd4a`，2605EPN8EC/API36/4KiB/Adreno840，原存档
1560-05-16 石山城镇静止。冷启动仅切换 bufferReadScratch，SME/DMA/触点沿既有
实验开启，audio sort cache/frame wake/分配拆账均关。逐帧文件采集相同，实际策略
False/True 与冻结启动事实均核对。MARK后1秒起固定80秒，无窗内截图、CPU采样或输入。

| 诊断窗口 | 关 | 开 |
|---|---:|---:|
| 成功QueuePresent节拍FPS |55.491|55.425|
| >25ms慢帧 |7.997%|8.142%|
| 整进程总分配/帧 |7687B|6728B|
| 最大帧区间GC累计暂停增量 |6.500ms|6.210ms|

分配约下降12.5%，未证明FPS收益；60FPS、慢帧、2048B/帧和4.167ms暂停判据仍超标。
两局均无宿主红项、正常退出；关局电池32.1→32.7°C，开局起始33.1°C；充电来源均关。
开局固定窗口结束后，可选只读休眠观察器误按nx-1选线程而未执行；finally正常收局，
从原PID完整生产frames与completed元数据恢复统计，原失败保留。开局结束电池读数在
恢复时延迟取得（33.1°C），不据此称等温对照。当前源的首guest线程ID实际从0x51起。
单对窗口不代表稳定收益、扫描输出FPS、GPU时间、功耗或正式A0验收。

随后关闭逐帧采集、单独开启既有分配拆账，保持scratch开。在已完成的相邻汇总中，
GPFIFO分派增量1614344B，缓冲绑定130952B；同时renderer Present830168B/1111次。
缓冲绑定已不再占首位，但整进程与已挂点线程仍有较大差额；需补GPU整圈（含Poll、
PreFrame等）而非把阶段累计当整线程总量。该诊断在第三次快照前由230秒PID守卫正常
收局，前两次35秒快照及完整收局日志保留；不能写成105秒场景采集完成。

## PR #390 独立头整改与真机复验（2026-10-25）

代码提交 `84408c28cd6633dc181798882417b8e00b2ac657` 普通合并
`android/integration@5e9fd3f6b1e1a189d2799ae01ce6484803a3c225`；保留双方
series、改动清单和性能经验条目，补丁由与 #302 冲突的0264续为
`0268-buffer-read-scratch.patch`。`bash compat/verify.sh --rev 84408c28`
通过：262个补丁与树内源码一致。Windows工作区CRLF直读曾导致UPSTREAM模式解析
失败，未改验收脚本；使用其原有`--rev`入口读取Git对象完成核对。

该独立源码离线重建NativeAOT、assembleDebug、lintDebug、签名及16KiB对齐均通过。
APK完整SHA256：`f518ca20f3bf796d2729f458cb0a6c0a90e50c40174ff3b9b278023802458520`。
安装前重建及安装后`pm path`对应APK的SHA256均核对一致。没有加入下游采集身份、
声音排序、帧唤醒、CPU待传镜像池或帧队列诊断实验；不声称有嵌入式A0冻结身份。
后续记录提交只改文档，运行时代码与上述代码提交相同。

2605EPN8EC（小米17 Max/API36/4KiB/Adreno840），复用原资源和存档进入
1560-05-16石山城镇。相同APK、掌机模式、SME/DMA/触点配置和同步逐帧metrics，
仅切换本机制。关局不传scratch extra，开局显式传true；实际托管策略日志分别为
False/True。场景核图后MARK+1秒起各固定80秒，窗内无截图、输入或CPU采样。

| 独立PR头诊断窗口 | 默认关 | 显式开 |
|---|---:|---:|
| 成功QueuePresent节拍/秒 |56.0000|55.6375|
| >25ms慢帧 |7.2098%|7.9757%|
| 整进程分配B/帧 |8368.9554|6728.9885|
| 最大帧区间GC累计暂停增量 |8.594ms|6.206ms|
| 80秒窗口GC暂停增量之和 |261.745ms|289.131ms|
| 窗前TOTAL PSS（KiB） |1813790|1803378|
| 电池温度 |30.6→31.1°C|31.1→31.1°C|

仅单对局部分配约下降19.6%，没有FPS、慢帧或累计GC收益证据；两局原四项判据
（≥59.4FPS、慢帧≤1%、分配≤2048B/帧、GC≤4.167ms）均未通过。
两局均放电、所有充电来源关闭，但不称等温；没有三局功耗采集、功耗达标或长期内存
收益结论。PSS只在MARK前取一次，不能据此判池化的内存收益。
两局均20条宿主红项，逐条均为着色器缓存缺主机代码而作废/按需实化；未删除、
未改判，不称全绿。两局均正常退出，结束后无游戏进程；1775项资源复用，RomFS
网络传输0，未重新提取或写入原存档。本条是独立头局部真机复验，不替代历史下游
组合包结论，也不是扫描输出FPS、GPU耗时、画面/音频真值或正式A0验收。

使用该次生产DLL及独立源码，Linux x64/.NET10离线复验290项backing断言、
暂存生命周期（环境值0/1/非法true）及关闭/开启各9种实际上传消费者均通过；
4个保护源/目的负控均在生产调用链AccessViolation/SIGABRT失败。预热十万次租还
0B仅为主机JIT机制读数，不代替上述NativeAOT整进程实测。未做Mac/iPhone复验。
贡献者检查仍在Windows doctor阶段exit2（Python入口/固定venv/Xcode缺失），
不完整，未生成路由门禁摘要。保持默认关闭和Draft，待维护者复审及完整列车门禁。
原始帧表、宿主日志、截图、包与游戏材料仅保留在本地私有证据目录。
