# NSO 解析复用夹具

`fixture.nso` 是本目录 0BSD C 程序和链接脚本经真实工具链生成的 377 字节 NSO，含三个由 ELF 得到的压缩段。夹具没有 GPU 着色器；门禁通过 cProfile 观测生产读取、解压和扫描函数，覆盖重复路径、符号链接别名、独立文件和后根错误传播。非空 BNSH 来源及配对保持由 `tools/shader_split_ab.py` 的真实游戏 A/B 覆盖。

生成环境为 Apple Clang 21.0.0、LLD 23.1.2、LZ4 1.10.0，以及 [switchbrew/switch-tools](https://github.com/switchbrew/switch-tools/tree/22756068dd0ed6ff9734c59cb4f99ebd3f62555b) 的 `elf2nso`。未手写 NSO 容器或替换解析函数；未执行 Switch loader 或客体程序。

- ELF SHA-256：`1ba0621ba6f316a6a692d1a8c9374b00f305946d45c2d07534c20f717068a422`
- NSO SHA-256：`e9f6092a7b4ea5c02aff49100a8a121174a8f267612fd68baeaad12f9ce3bc78`
- `elf2nso.c` SHA-256：`268db50e351c5efed0c562a2b8466b16403f120dba3a4169eb19b75677d5b137`

门禁直接读已提交的夹具，不需要 Clang / LLD / 转换器或网络。

配置源使用唯一文件名 `shader_split_reuse_profile.tsv`，测试时复制为临时 profile 的 `game.tsv` 交给生产入口；避免门禁按裸文件名关联到其他 profile 测试。

手动重建需要本地上述固定版本的 switch-tools 源码、Clang、LLD、pkg-config 和 LZ4：

```sh
bash tests/fixtures/shader_split_reuse/rebuild.sh <本地switch-tools源码> <全新输出目录>
```

重建先检查工具提交号，最终逐字节比较已提交 NSO；不自动下载工具、改写夹具或接受新哈希。运行 `bash tests/shader_split_reuse_test.sh` 执行门禁；追加一个旧版 `shader_split.py` 路径可作同一计数断言的反证。
