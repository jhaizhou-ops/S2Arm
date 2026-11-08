# Android NgWord共用生成器接线与真机边界

## 实现来源

共用格式实现原样取自main `82471149b7d5f9a0405db759ed543a4aa9dce182`，
`pack/sysdata_synth.py` / `sysdata_mii.py`。XCI只读导出与真实来源优先解析来自本地
公共层 `07b42cc8`，没有采用此前54文件的独立实验生成器。

Android `make_pack.py` 消费共用 `sysdata_resolve.py` 的COPY/SYNTH/DROP：
真实产物/玩家目录优先，再探测本款XCI，最后调用同一合成器；合成旁记 `<号>.synth`。
真实来源替换合成内容时先去掉旧目录/标记，避免旧文件残留。删除仅发生在私有暂存树，
原产物、玩家来源和旧输出不变。资源依旧进入原逐文件索引与APK绑定校验。

## 真机资源对照

小米17/API36/4KiB/Adreno840，朱4.0.0、main Build ID
`421c5411b487eb4d049dd065fec95477`；v7 APK SHA256
`3c08450f09a4be500e9d9f0ec75ce1c968ac1ef2c648f3f4dc7b99e3302c27c0`。
原644个资源字节/SHA均不变，只增加98个上游合成文件及1个.synth标记，资源root
`sha256-6ab0aaea1398c7f3a4b0a875173716f4391cf33a99a738dfba16d400ac557941`。
使用正常导入器激活，未改current.json、未删存档。

2026-10-25第一局SME开、DMA实验关：系统IME真实提交AT01，日志Accepted与
0823在OpenDataStorageByDataId，画面到角色姓名/「以这样开始！」确认页。
越过旧缺档/占位guest Break；继续确认后约109秒，DmaCopy+0x888→Memmove访问违例
并signal6。这个后续故障不能写成NgWord解析仍失败，也不能把命名通过称整款可玩。
已按#199既有6382989871/#233记录安排同APK的DMA preservation开关复验；结果另补。

第二局同APK/同资源，SME与DMA preservation均开：再次确认AT01并到角色确认页，
随后推进到入学资料页面（姓名AT01）。本局未见DmaCopy栈，但约260秒在
`GPFifoProcessor.ProcessCore+0x40`访问违例并signal6，仍未到可控关卡/保存重载验收。
两局实际选中的角色外观不同，且复用了逐步积累的缓存；它们不是严格同输入性能A/B，
不能从运行秒数推断稳定性收益。只能分别记录旧故障与本局推进/新首错。

## 本机检查

上游sysdata_synth_test通过，含98文件确定性、真实Ngc解析/Check/Mask与Mii结构负控；
本机无真实固件对照数据，该对照跳过。Android资源测试16项通过；公共XCI选择6项、
真实LibHac人工容器24项、Apple阶段事务11组通过。不宣称真实XCI、iOS游戏或全门禁通过。
