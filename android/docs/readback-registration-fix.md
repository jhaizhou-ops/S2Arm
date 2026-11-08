# Android读回完成检查与新动作登记

## 实际故障

小米17/API36/4KiB，朱4.0.0，v16 APK `8ea3b6c864d46beb`，校长书写场景约640秒：
`generation=2925/2925 requested=1 unresolved=1 reprotected=0 state=1 protection=0`，
随后signal6/退出134。清屏优化保持开启；用户确认画面闪动早于该优化。
这次先修退出合同，几何拉伸另行排查，不能证明两者同源。

## 可确定复现的机制

`RegionHandle.Signal`执行回调时释放TrackingLock，在PreActionLock中完成旧动作并撤销，
再重新取得TrackingLock做最终保护更新。另一线程能在此间登记新动作。
如果`VirtualRegion._lastPermission`仍为None，普通权限去重会省掉新的native通知；
托管新回调已存在，native的generation却仍为旧值，原有保护会判“旧读回没完成”。
实际生产类的控制实验旧源得到1→1，新回调留待下一次读；与native完成判据冲突。

只强制None通知仍有缺口：若动作指针在取得TrackingLock之前发布，读线程可以先看到
新动作却仍读到旧native代次。因此动作发布和通知需要处于同一TrackingLock临界区。

修复：新增实例策略`ReprotectOnActionRegistration`，默认false，Android在guest执行前
开启。新激活的读动作在PreActionLock→TrackingLock中发布，guest区域即使None未变
也通知一次。普通Signal/Reprotect不制造epoch；不改native guard、不直接清dirty、不
读取旧数据兜底。其他宿主默认路径保持原权限去重，未宣称Apple真机回归通过。

## 验证结果与边界

- 主机真实MemoryTracking/RegionHandle/VirtualRegion：35项通过；三种破坏性副本
  （漏通知、动作提前发布、每次None都虚构epoch）分别触发2/1/5个失败用例。
- 原有TrackingTests/MultiRegionTrackingTests：79通过、0失败、0跳过。
  首次未恢复测试SDK时dotnet test虽退出0但没有执行测试，不计绿；单独准备依赖后
  用`--no-restore`重跑并取得上述真实计数。
- 小米17独立进程：生产track.c + Android平台实现 + 真实MemoryTracking + NativeAOT，
  实际mprotect、memfd共享页与mremap别名。正常、部分页、新动作并发共17项通过且退出0；
  关闭新合同仍复现`generation=1/1 ... unresolved=1`退出134；真正无进展的负例也仍退出134。
  此为native/managed联合合同验证，不含Vulkan或游戏信号解析器，不能替代游戏长时验证。
- v17 APK `16958de40d479db31c2cca69425e916b85379caee9c8ad34cf8e89363f0b963a`
  已完成本机NativeAOT、构建、签名、对齐和lint，并在用户后续禁止安装前装到设备。
  用户反馈暂未再闪退，随后主动退出并换另一款游戏处理；本轮原路线/长时验证未完成。
  用户曾暂停设备操作，随后明确重新授权合入/构建后仅操作已绑定的小米17，不操作其他手机。

入口：[`readback-registration-tests`](../../graphics/vulkan/runtime/readback-registration-tests/README.md)。
原日志、设备标识、APK、缓存、存档与图像不进入仓库。

后续已将本修复与#341的fa23f28d候选合流为v18，并按用户重新授权安装到固定小米17。
读回修复的确定性测试结论保留，游戏长期稳定性未因此补记通过。用户要求先提交推送，
几何闪动降低但仍存在的反馈及冻结版本见[几何排查记录](scarlet-geometry-diagnosis.md)。
