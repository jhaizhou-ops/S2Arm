# Metal 3 运行时归档回归（#116）

运行时仅在 `NXGAL_BE=mtl3 NXGAL_M3_ARCHIVE=1` 时读取 Metal 3 包归档；设备收录还需现有 `NXGAL_PSO_DEV=1`。默认关闭新能力。设备目录在包指纹、XC 版本、GPU 架构和系统 build 后追加 `.mtl3`，与 Metal 4 分开。

Metal 4 后端行为保持原样。Metal 3 默认关闭时仍按完整描述现编，但启动预热和设备归档查找不再打开用不上的 Metal 4 归档片，因此不再产生这些片的映射和低区账本登记；不能将此概括为所有后端「默认关闭时零行为变化」。

## 执行

需 Apple GPU、Xcode Metal 工具链、glslangValidator、spirv-val 和项目既有编译依赖。在仓库根执行：

```sh
make -C graphics/metal "$PWD/build/gal/t_m3archive" "$PWD/build/gal/gal_xc"
build/gal/t_m3archive
make -C graphics/metal test-m3archive
```

第一个测试使用自有 MSL，经 `fixture.h` 的真实离线编译生成函数库。父进程依次启动独立子进程，覆盖首次收录、跨进程重载、关闭开关、真实文件系统阻止索引提交及解除后的重载。每条管线由生产 GAL 创建入口生成，再用真实 Metal 编码器绘制或计算并读回；测试自己的私有设备归档目录在结束时删除。

`test-m3archive` 通过 `m3archive_pack.py` 将两份自有 GLSL 程序送入正式 `gal_offline.py`、`pso_gen.py` 和 `pso_chunk.sh`，不手造 GALI 或替换编译器。每程序各出 RGBA8、BGRA8 完整描述；运行时要求四条真命中，随后两条改变混合及写掩码的描述必须真未命中，并校验像素。`FailOnBinaryArchiveMiss` 用于区分归档命中与现场编译。

`graphics/gate.sh` 登记此入口并保留 `build/gate_gfx/m3archive.log`，退出码参与门禁判定。成功结论为 `m3archive pack: PASS hit=4 miss=0 changed-hit=0 changed-miss=2`；两组读数分别来自完整描述和改变状态后的真实缓存统计。

需要保留原始产物时，指定尚不存在的输出目录：

```sh
python3 graphics/metal/tests/m3archive_pack.py --gal-xc build/gal/gal_xc --output build/m3archive-input
build/gal/t_m3archive --pack build/m3archive-input/pack build/m3archive-input/manifest.tsv
```

输出包含源快照、命令与退出码、正式索引和归档、工具及产物 SHA-256。归档按本机真实 GPU 与系统版本生成；不能把其他系统上未命中的归档算作工具链成功命中。

## 验收边界

这是生产管线创建入口与真实 GPU 测试，未运行完整 NVN / Maxwell 翻译或游戏渲染循环。强制 Metal 3 的 macOS 27 结果不替代 macOS 15 / iOS 18 设备验收，也不证明帧率、能耗或游戏首遇卡顿收益。M3 预取、特化及独立动态链接描述不在本增量内；后者明确拒绝。设备归档写盘失败会报红，只有归档与索引都提交成功才计入写盘数。
