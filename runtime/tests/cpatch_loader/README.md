# 社区 FPS 准入的实际装载夹具

`module.nso` 来自本目录 0BSD 的 `module.S` / `module.ld`，没有游戏代码或资源。Clang 编译 AArch64 指令，LLD 生成 ELF 动态符号表与 EH 表，固定版本 switch-tools 的 `elf2nso` 生成压缩 NSO；没有手写 NSO 容器。模块有 64 个返回 30 的可调用函数，以及映像偏移 `0x8000` 开始的 256 个 `0x11` 数据字节。

`make native-test-cpatch_loader` 用出包默认 C 改写器，把函数首条 `mov w0,#30` 编成由键页槽 2046 分路的 30 / 60 双路点。测试链接完整生产原生对象，通过 `load_modules` 读正式随行表、映射、封代码页、安装真实 TSD 键页、解析符号并重定位；随后经 `s2a_fps_start` 与 `s2a_fps_set_enabled` 检查启动和三次开关往返。每一状态调用两模块共 128 个实际函数并核对两模块全部 256 字节。未替换 loader、module、rewriter 或 follow；不需要服务层、GPU 或游戏资源。

四个独立进程场景覆盖：缺省开与缺省关的合法项，原值不符项与后段不符项，`none` 后 FPS 启动开启，非法位（含十进制正 / 负溢出）与非法数据格式，以及 64 个数据登记后另一模块整份拒绝、纯代码项继续可用。已有 `t_cpatch` 保留普通画面项的行为回归。测试不执行游戏或服务调用，不代表设备画面、目标帧率、性能或稳定性验收。

生成环境：Apple Clang 21.0.0、LLD 23.1.2、LZ4 1.10.0；switch-tools 提交 `22756068dd0ed6ff9734c59cb4f99ebd3f62555b`。手工复建使用本地已备工具源码，不联网，最终逐字节比较已提交的 NSO：

```sh
bash runtime/tests/cpatch_loader/rebuild.sh <switch-tools源码目录> <全新输出目录>
```

- ELF SHA-256：`aae2161ec0edf8c97279589fdf0d18c1adb1a98b4ceca9ff4c3427869dd21d0d`
- NSO SHA-256：`2387bf7917e2a680115c802fb10c7023052aa10aef4f8e3cc73f4bfd7799fdaf`
- `elf2nso.c` SHA-256：`268db50e351c5efed0c562a2b8466b16403f120dba3a4169eb19b75677d5b137`
