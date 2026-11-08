# 发布预编译翻译器

在 Apple Silicon Mac 上使用项目要求的 .NET SDK。默认取 `~/.dotnet/dotnet`；自定义安装可设置 `DOTNET_ROOT` 和 `DOTNET`。以下发布及换链命令由维护方在列车换链窗口执行：

```sh
export DOTNET_ROOT="${DOTNET_ROOT:-$HOME/.dotnet}"
bash translator/dmsh_xlate/publish.sh
python3 translator/dmsh_chain.py --update-lock
python3 translator/dmsh_chain.py --header
python3 translator/dmsh_chain.py --check-tools
```

`publish.sh` 发布到同级 `dmsh_xlate_bin/`，最多使用 2 个 CPU，关闭共享编译与常驻 MSBuild 节点。`ContinuousIntegrationBuild=true` 交由 SDK 规范源码路径；保留原有符号配置和输出，不通过删除符号清除路径。发布后仍需检查 DLL 的 CodeView/PDB 引用、Portable PDB 文档名及 SourceLink 映射，确认最终符号不含本机路径。

本入口未钉死 SDK 补丁版本，也未覆盖 Git 远端提供的 SourceLink 信息；不同 SDK 或远端环境可能生成不同工具哈希。`3fa6432e26da` 仅是先前环境的参考链号，正式链号以列车换链窗口统一重建、更新锁与 header 后的结果为准。本地重建不能证明与该参考链逐字节一致，也不直接决定已排批次的换链版本。

重建会改变工具指纹和直连链版本。源码、正式发布脚本、重建产物、`dmsh_chain.lock` 与生成的 `dmsh_chain.h` 应一起交付；受影响的游戏着色器库需要按新链重出。核对时同时保留旧失败记录，并按公开仓扫描约定检查新提交的增量。
