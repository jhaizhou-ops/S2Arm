# C 改写器依赖与致谢

C 版使用 Python 真值相同的发行源码，固定压缩包 SHA-256；不用宿主系统里任意版本的库。`prepare_deps.py` 是显式联网准备步骤，构建与测试都不调用它、不联网。

| 来源 | 固定版本 | SHA-256 | 许可 |
|---|---|---|---|
| [Capstone Python sdist](https://pypi.org/project/capstone/5.0.7/#files)，内含完整 C 核心 | 5.0.7 | `796bdd69b05fa124fc2aa2e74b9a0b3d4c4e7f3e02add5e583cf2f3bca282ede` | BSD-3-Clause，见 `LICENSES/capstone.txt`；LLVM 派生部分另有 LLVM Release License，全文 `LICENSES/capstone-llvm.txt`（取自本 sdist 的 `src/LICENSE_LLVM.TXT`）；源码内各原始声明保留 |
| [python-lz4 sdist](https://pypi.org/project/lz4/4.4.5/#files)，仅编译 `lz4libs/lz4.c` | 4.4.5，内含 LZ4 1.9.4 | `5f0b9e53c1e82e88c10d7c180069363980136b9d7a8306c4dca4f760d60c39f0` | LZ4 BSD-2-Clause，见 `LICENSES/lz4.txt` |

Capstone 反汇编文本参与认形态，不能只看 C API major/minor 升级库；必须重新逐字节对拍。Python lz4 的发行版本和底层 C LZ4 版本不是同一个编号。

改写算法按 `patch_nso.py`（10-31 已删）语义移植。原 Python 实现对 the reference port / d2r-mobile 的 MIT 算法致谢继续适用；不拷贝游戏代码、不引入按游戏配置。
