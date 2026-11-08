# Android实时帧率浮窗

冷启动或运行中传 `--es s2arm.fps on` 开启，`off` 关闭；每款应用自己的display偏好
记住选择。浮窗在顶部中央，每秒更新一次，后台暂停采样，回前台先显示等待样本。

计数直接复用 `AndroidVulkanRuntime.FramePresented` 成功提交回调，由GPU线程以
Interlocked发布64位累计数；JNI只读，Java按两次计数差/实际单调时钟间隔计算速率。
停帧窗口显示0，不持续显示旧FPS。没有开启 `metrics.enable`、逐帧磁盘写入或
诊断清屏presenter；不把Android面板刷新、屏幕120Hz当游戏帧。

这里显示的是游戏成功queue-present的提交速率，不是GPU执行时长或屏幕扫描完成率，
也不能替代正式帧率/卡顿验收。原有逐帧采集回调仍保留。

本机检查：真实原子计数器初值/64位/并发单调读/最终值/零逐帧托管分配检查，Java
9项采样（含停帧、暂停、时钟和计数重置）通过；既有metrics生产者/接线及负控通过。
命令：`bash android/core-runtime/fps-tests/test.sh`。

小米17真机v8安装后base.apk回读SHA256
`2316fdbc16efa5bf79c2a6590a004d2c542e8f17b7c8ca549a1207ea94c573e1`。
NativeAOT、assembleDebug、离线lint、APK签名/16KiB对齐通过。
资源逐文件索引与v7共用生成器包相同，仍为6ab0aaea资源root，正常导入器刷新APK绑定。
前台语言选择页，UI树读到FPS29.9、随后截图显示FPS30.0；这是当前菜单的实时提交速率，
不能作为玩法帧率验收或宣称后续GPU访问违例已修复。浮窗已开启，游戏留给用户继续操作。
