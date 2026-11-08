# Android 设备内 C 改写验证（#416 第 2 件）

2026-10-26，vivo X Fold（V2178A）/ Android 13（API 33）直接运行 arm64/API 28 的 C CLI，对《异界锁链》的真实 `main` 改写。与相同源码、固定依赖构建的 Mac C CLI 比较：两端退出码均 0，`PFRW need=5476 gaps=0 fatal=0`，完整五份产物文件集、逐字节内容和 SHA-256 全同。未传入宽屏候选，因此两端均无 `widen.tsv`。

## 源码、工具链与输入身份

- C 源码基线：`73d6e3cc3e4832d9bca93efd3f514bfd95dbaf4e`（当次拉取的 `origin/main`）；本交付不修改改写算法、C ABI、CMake、Python 真值或任何出包入口。
- 宿主：Apple Silicon arm64、macOS 14.8.5、Apple Clang 16.0.0、CMake 4.1.2，Release。
- Android：vivo V2178A，`ro.product.cpu.abi=arm64-v8a`、`uname -m=aarch64`；USB ADB 36.0.0。不是模拟器或兼容层。
- 交叉构建：本机已有 Android NDK `27.0.12077973`（r27）、Clang 18.0.1，`ANDROID_ABI=arm64-v8a ANDROID_PLATFORM=android-28`，Release。设备系统 API 33，不是 API 28 实机覆盖。
- 两份构建共用重新校验、离线解出的 Capstone 5.0.7 / python-lz4 4.4.5 源码；压缩包 SHA-256 与 [固定依赖表](THIRD_PARTY.md)一致。Android ELF 的依赖只有系统 `libm.so`、`libdl.so`、`libc.so`，解释器为 `/system/bin/linker64`。
- 模块名固定 `main`，原始 NSO 7,700,590 字节；构建号前 16 字节 `4b159f0f7a360669738390ee8657b4f0`。
- 输入 SHA-256：`dc47cae835866379c597e1c507bf52ee0f865ec4412930dfdf1bbc20b6bb9c3b`。
- 宿主 CLI SHA-256：`489af97853ce4b1d1b45809e9d2bc0f00fb1a31667dca85d0d7794256e5def6d`。
- Android CLI SHA-256：`aecdc3d88d9c215490902ecd779a5c877f4ce3fcfbfdb09bae3a3988c893994e`。
- `rewriter.c` SHA-256：`0481d8c1f39b2ede6e333788f9b27e7b905bb7e41b76be306a8318b0967e6142`。

设备序列号、个人路径、输入、映像与伴随表、完整日志和命令清单均只保留在私有目录。本报告只包含可复核的身份、命令形状和读数。

## 复现命令

以下变量由调用方设置，`RW_WORK` 为仓库外的独立工作目录，`RW_INPUT` 为自备输入；`RW_DEPS` 指按 `prepare_deps.py` 准备的固定依赖，`ANDROID_NDK_HOME` 指已安装 NDK。所有目录都不能借用别人正在构建或运行的产物。

```sh
cmake -S runtime/rewriter -B "$RW_WORK/build/host" \
  -DS2A_REWRITER_DEPS="$RW_DEPS" -DCMAKE_BUILD_TYPE=Release
cmake --build "$RW_WORK/build/host" --parallel 4

cmake -S runtime/rewriter -B "$RW_WORK/build/android" \
  -DS2A_REWRITER_DEPS="$RW_DEPS" \
  -DCMAKE_TOOLCHAIN_FILE="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake" \
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-28 -DCMAKE_BUILD_TYPE=Release
cmake --build "$RW_WORK/build/android" --parallel 4

# 两份构建成功退出以后运行；RW_SERIAL 只用于本机选择已授权手机。
python3 tests/rewrite_android_compare.py \
  --host "$RW_WORK/build/host/s2a-rewrite" \
  --android "$RW_WORK/build/android/s2a-rewrite" \
  --serial "$RW_SERIAL" --output "$RW_WORK/private/validation" "$RW_INPUT"
```

工具实际执行的两条改写命令形状如下。`DEVICE_WORK` 是本次用 `mktemp` 新建的设备私有目录，命令中路径不会写入公开报告。

```sh
# 宿主：继承的其他 S2A_* 被清除，CLI 和输入均为独立快照。
S2A_TARGET=android S2A_REWRITE_SPIN=0 S2A_SDK_ADDR_CUT=1 \
  "$HOST_C_SNAPSHOT" "$INPUT_SNAPSHOT" "$HOST_OUTPUT" main

# 手机：通过 adb -s "$RW_SERIAL" shell 执行，退出码由 adb 返回。
env -i PATH=/system/bin:/system/xbin \
  S2A_TARGET=android S2A_REWRITE_SPIN=0 S2A_SDK_ADDR_CUT=1 \
  "$DEVICE_WORK/s2a-rewrite" "$DEVICE_WORK/main" "$DEVICE_WORK/out" main
```

上传后分别在设备上执行 `sha256sum "$DEVICE_WORK/main"` 与 `sha256sum "$DEVICE_WORK/s2a-rewrite"`，均与宿主快照哈希一致，之后才运行 CLI。输出目录为本次新建；`adb pull` 拉回全部产物，再检查文件集与每一字节，不复用旧结果。

## 完整产物读数

下列哈希在宿主与设备两端相同；五份文件都实际存在，`gates.tsv` 的 0 字节同样参与完整性检查。

| 文件 | 字节数 | 两端相同的 SHA-256 |
|---|---:|---|
| `main.patched.bin` | 14,691,348 | `e857dba96a454f472004a510b34ede2f83375467b83b32f90d3d935366a08e36` |
| `main.fixups.tsv` | 340 | `b0b74f04a6f67ddfda4a6c121d7091f6caf125343c5766d06b53b7451db87c95` |
| `main.gates.tsv` | 0 | `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855` |
| `main.sites.tsv` | 70,967 | `d43e0892c2d76bda8353a988cdd037d54fb02e885577176729b8aa4ee011d8ec` |
| `main.gaps.tsv` | 82 | `e90edfc979f23c78b876328e2361d6195175ca213c4d8bf63dac6967ad82efef` |

本轮验收是单款主程序的 Android/spin=0 静态改写及完整产物一致性；未执行改写后的游戏代码，未验证安装、起局、图形、帧率或能耗。二进制以 API 28 为构建下限，本次只测 Android 13 / API 33 的这台设备。#416 第 1 件仍由 #420 单独推进，本交付不关闭同时包含两项的原 issue。

## 比较判据自检

`S2A_PY=<Python3> bash tests/rewrite_android_compare_test.sh`，11 项离线测试通过：包含修改一个字节、强制哈希相同时仍检查实际字节、两端同时缺必需文件、单侧多文件、可选宽屏文件差异、合法 / 截断 / 非 AppleDouble 元数据、子目录、设备临时目录边界，以及缺失 / 重复 / 失败的 PFRW。它们只验证测试工具能拒绝错误证据；本节不能代替上面的真实设备运行。
