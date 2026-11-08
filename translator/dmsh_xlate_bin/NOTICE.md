# dmsh_xlate_bin 第三方归属

本目录是预先编译好的 .NET 程序集，给出包时的着色器翻译用。各包许可与 Apache-2.0 兼容。二进制本身没有附上各自的 LICENSE 全文，以下按 `dmsh_xlate.deps.json` 里的版本和上游公开许可记录。`dmsh_xlate.pdb` 里有构建机路径，见仓库根目录说明里的「待决定」项；本文件不删除这些二进制。

| 程序集 | 版本 | 许可 | 来源 |
| --- | --- | --- | --- |
| Ryujinx.Common、Ryujinx.Graphics.Shader | 1.0.0（随本仓库 Ryujinx 树） | MIT | https://github.com/Ryujinx/Ryujinx |
| Spv.Generator | 1.0.0 | MIT（Khronos） | 随 Ryujinx；SPIR-V 语法为 Khronos |
| S2Arm.Gfx.Widen.Shader、dmsh_xlate | 1.0.0 | Apache-2.0（本仓库） | 本仓库源码编出 |
| Humanizer 及 Humanizer.Core.* | 3.0.10 | MIT | https://github.com/Humanizr/Humanizer |
| Gommon | 2.8.1.2 | MIT | https://github.com/Remora/Gommon |
| Microsoft.IO.RecyclableMemoryStream | 3.0.1 | MIT | https://github.com/Microsoft/Microsoft.IO.RecyclableMemoryStream |
| MsgPack.Cli（MsgPack.dll） | 1.0.1 | Apache-2.0 | https://github.com/msgpack/msgpack-cli |
| System.CodeDom | 4.4.0 | MIT | https://github.com/dotnet/runtime |

这些 DLL 随 Mac 出包工具从源码树调用，不链进 iPhone IPA 的游戏进程。
