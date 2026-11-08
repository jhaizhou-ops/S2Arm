# 分辨率与宽屏兼容检查

直接检查生产页判据、视口 / 裁剪 / 拷贝坐标、客体屏幕尺寸常量与 GameWide。随后在真实 Metal 后端创建纹理和视图，录制 / 回放五个倍率，最后用已有真实游戏 RGBA 捕获走 CPU 图片换分辨率 storage 的复制路径并读回，核对尺寸、颜色内容与 1x 原始字节。无 mock renderer。

```sh
dotnet build tests/visual/resolution_unit/resolution_unit.csproj -c Release \
  --artifacts-path /tmp/s2a-resolution-dotnet -p:OutDir=/tmp/s2a-resolution-native/bin/
NXGAL_LIB="$PWD/build/gal/libnxgal.dylib" \
  dotnet /tmp/s2a-resolution-native/bin/resolution_unit.dll \
  /absolute/path/to/recorded-present.rgba 1920 1080 /tmp/s2a-resolution-native
```

输入必须是已有真实捕获的连续 RGBA8 字节，宽高必须与捕获元数据一致。库必须由当前源码构建；初始化时会核对原生 ABI 指纹。

着色器检查另用 `tests/visual/resolution_shader_check.py`，输入为真实客体代码经 ShBake 重烘的 `spv/`。`--baseline` 可配对同一批客体阶段的两套翻译结果；原有失败仍完整报告、退出失败，不将“无新增失败”伪装成全库通过。

这些检查覆盖坐标策略、资源与录像路径，实际游戏各场景仍需独立截图 / 帧录制验收。

整数最大坐标矩形同时检查客体常量不叠加宿主倍率，以及五档实际尺寸的整段 / 增量改写均指向目标最后一列。景深分层图集按八方2已有布局的客体尺寸检查五档源、目标倍率的全部25种组合，包含任意一侧被缩放黑名单保留为1×。

支持缓冲连续上传的承重检查另需完整真实游戏GAL录像，且录像中须有写出非零`s2a_widen`的绘制：

```sh
NXGAL_LIB="$PWD/build/gal/libnxgal.dylib" \
  dotnet /tmp/s2a-resolution-native/bin/resolution_unit.dll \
  --support-upload /absolute/path/to/real-game/gal.rec
```

该模式先完整检查录像接口和能力表，再回放到实际非零外推绘制；调用生产`SupportBufferUpdater`，使脏区从第一个成员延续到最后一个`render_scale_y`元素，两次覆盖同一Metal缓冲中的`s2a_widen`。每次重复该笔真实绘制后，用`GetBufferData`逐字节核对外推参数恢复。未知操作、缺对象、程序链接失败、截断及没有非零外推绘制都会失败；不会把不完整录像当成通过。
