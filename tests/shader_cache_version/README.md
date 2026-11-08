# 旧着色器包保留运行时缓存回归

使用设备拉回的真实7360缓存和真实7359离线包，引用生产 `S2A.Gfx`，初始化真实 `NxRenderer`，反射调用内部 `ShaderPack.Mount()` 两次。每次检查缓存文件集合、全部字节和SHA256未改变，版本仍是7360，旧包程序计数及预热表未启用。测试不生成或修改TOC，不使用mock，不启动游戏，不连接设备，不清理缓存。

测试先在二进制旁创建全新的 `portable/`，调用生产 `AppDataManager.Initialize(null)` 并验证数据根、游戏目录和日志目录全部隔离。macOS的Custom模式会把日志放到用户全局目录，因此这里使用Portable模式。运行产物和缓存副本保留供复查；重新运行请使用新的输出目录。

在仓库根执行，提供从设备只读拉回的真实7360缓存及真实7359着色器包目录：

```sh
dotnet build tests/shader_cache_version/ShaderCacheVersionTest.csproj -c Release \
  --artifacts-path "$PWD/build/shader-cache-version-dotnet" \
  -p:OutDir="$PWD/build/shader-cache-version-run/bin/"
NXGAL_LIB="$PWD/build/gal/libnxgal.dylib" \
  dotnet build/shader-cache-version-run/bin/ShaderCacheVersionTest.dll \
  "<真实7360缓存目录>" \
  "<真实7359着色器包目录>" \
  010015100b514000
```

原生库必须与当前生产ABI一致。Metal设备不可用或初始化失败会直接失败，不跳过或冒充通过。真实iOS包在macOS上可能无法打开其离线Metal库；生产Mount仍会继续进行翻译版本检查，因此这种运行只验证缓存保留分支，不证明iOS库可用、着色器绘制或实机帧率。测试输出保留原生错误，不能把缓存断言通过当作跨平台离线库验收。

2026-10-23实测：Apple M5 Pro真实Metal初始化成功，旧离线库20567支、127片载入成功。两次挂载均拒绝种入7359程序，7个真实缓存文件（包括原包指纹）与输入原件字节及SHA256完全相同，仍是7360，`PackPrograms=0`、`WarmList=null`。构建0错误，4个已有依赖警告。运行日志在 `build/shader-cache-version-run.log`，构建日志在 `build/shader-cache-version-build.log`。旧包没有本机 `applegpu_g17s/macos27` 归档，原生红行保留；未验证实机PSO或绘制。
