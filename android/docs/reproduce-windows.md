# 在干净的 Windows 上复现 Android 门禁

本文给出从一台干净 Windows 到「一份可追溯的 QA 报告」的完整路径，供 W10（Android QA / 构建门禁）复核。
入口是一条命令：`android/tests/qa.sh`。

## 0. 验收标准

在仓库根跑完 `bash android/tests/qa.sh`，应看到：

```text
▶ 无设备单测 + 契约（test.sh）
  ✅ 无设备单测 + 契约（test.sh）（8s）
▶ APK 构建（assembleDebug + lintDebug + verify-apk + apksigner）
  ✅ APK 构建（assembleDebug + lintDebug + verify-apk + apksigner）（23s）
▶ APK 静态校验（verify-apk + apksigner）
  ✅ APK 静态校验（verify-apk + apksigner）（1s）

# Android QA 报告
- 结果：✅ 全绿
- 步数：跑了 3 步 / 应跑 3 步
- 提交：`1ecbd9ea6786`（android/qa-gate）
- 镜像：`s2arm-android-build:1` · `sha256:d8180629a3fb`

报告：build/qa/report.md  /  build/qa/report.json
门禁 绿：跑了 3 步 / 应跑 3 步
```

产出 `build/qa/report.md`（人读）与 `build/qa/report.json`（机器读），失败步骤的日志尾部直接抄进报告，
不用再去翻 `logs/`。

退出码（与 `tools/contrib_check.sh` 同一口径）：

| 码 | 含义 |
|---|---|
| `0` | 全绿**且没有跳过**——三步都跑了且都过 |
| `1` | 有步骤失败（优先于不完整） |
| `2` | 环境不满足（缺 Docker / daemon 没起 / 缺镜像 / 跑在 Windows 原生 shell / CRLF 脚本），**或有步骤被跳过** |

**跳过不是绿**：`--skip-apk` / `--skip-build` 跑出来的报告会写「🟡 不完整：跳过 …」，
`report.json` 里 `complete: false`、`skipped: [...]`，末行固定打「门禁 不完整：跑了 N 步 / 应跑 3 步」。
CI 只看退出码也不会把「只跑了一半」当成全绿。

## 1. 前置

| 项 | 要求 |
|---|---|
| Windows | 10 21H2+ 或 11，开启 WSL2 |
| 发行版 | 任一 WSL2 Linux 发行版（本文按 Ubuntu 写） |
| Docker | Docker Desktop，使用 WSL2 backend |
| 磁盘 | 镜像要装 SDK 36 / NDK 29 / CMake 3.31.6 / Gradle 9.8.1，预留数 GB |
| 宿主机 | **不需要** JDK / CMake / Android SDK——全在镜像里 |

## 2. 仓库必须放在 WSL 的 ext4 上

克隆到 `~/` 下，**不要放 `/mnt/c`**。9p 层（Windows 盘挂进 WSL）会带来三个问题：
容器 bind mount 语义不一致、文件权限异常（改已有文件被拒）、`git status` 的 index 刷不新（见 §7 坑 4）。
性能也差一个量级。

```sh
git clone <repo> ~/S2Arm && cd ~/S2Arm
```

## 3. 打开 Docker Desktop 的 WSL 集成

Docker Desktop → Settings → Resources → WSL Integration → 勾选目标发行版 → Apply & Restart。
不打开的话，WSL 里没有 `docker` 命令，或者有命令但连不上 daemon。

```sh
docker info --format '{{.ServerVersion}} {{.OSType}}/{{.Architecture}}'
# 期望：29.9.1 linux/x86_64
```

## 4. 先确认换行符

仓库的脚本必须是 LF。若这份工作区曾被 Windows 侧 Git 以 `core.autocrlf=true` checkout 过，
`.sh` 会带 CRLF，bash 会把 `set -euo pipefail` 读成 `pipefail\r` 并报 `invalid option name`。

```sh
git config core.autocrlf false        # WSL 里的仓库配置；Windows 侧共用这份 .git/config
git ls-files --eol | grep -c 'w/crlf' # 期望 1，且只应是 android/gradlew.bat
```

若多于 1，把 index 存 LF、工作区被写成 CRLF 的文件转回来（`core.quotePath=false` 不能省，
否则中文路径会被 git 转义成 `"docs/\346..."`，`sed` 找不到文件）：

```sh
git -c core.quotePath=false ls-files --eol \
  | awk -F'\t' '/^i\/lf.*w\/crlf/ {print $2}' \
  | while IFS= read -r f; do sed -i 's/\r$//' "$f"; done
```

`qa.sh` 的 preflight 也会检查这一条，带 CRLF 时直接拒绝并给出修法。

## 5. 构建镜像（只做一次）

```sh
docker build -t s2arm-android-build:1 android/docker
```

首次要联网拉 SDK / NDK / Gradle，几分钟。`services.gradle.org` 偶发 `SSL_ERROR_SYSCALL`，
直接重跑即可命中已完成的层。

`qa.sh` 不会自动构建镜像：门禁不该在背后偷偷联网。缺镜像时它把上面这条命令原样打出来。

## 6. 跑门禁

```sh
bash android/tests/qa.sh                 # 全量，报告写 build/qa/
bash android/tests/qa.sh --skip-apk      # 只跑无设备单测与契约（约 10s，退出 2）
bash android/tests/qa.sh --skip-build    # 复用已有 APK，只重跑静态校验（约 2s，退出 2）
bash android/tests/qa.sh --offline       # APK 构建加 --offline，不联网
```

三个步骤各自独立，失败不中断——门禁要一次看全，不是撞到第一个红就停。

两条 `--skip-*` 是给人快速自查用的（改文档、只动校验逻辑时），**它们不是门禁结论**：
结果不完整，退出码 2。要给 PR 贴结论，跑全量。

## 7. 已知坑

按实际踩到的顺序。前四条与 Windows / WSL 强相关，后四条是容器本身。

| # | 现象 | 原因 | 处理 |
|---|---|---|---|
| 1 | `qa.sh` 在 Git Bash 里直接退出 2 | MSYS 会把 `--workdir /src` 改写成 `D:/...`；`\\wsl.localhost\...` 这类 UNC 路径 bind mount 进去是**空目录**（不报错） | 在 WSL 里跑。`qa.sh` 主动拒绝 Windows 原生 shell，不静默降级 |
| 2 | 进不去 WSL（`wsl.exe` 被拒） | 安全软件的**程序黑名单**拦了 `wsl.exe`，提权也绕不过 | 直接在 Windows Terminal 里开 Ubuntu 标签页，或把 `wsl.exe` 从黑名单移除 |
| 3 | 上千个文件显示 modified | `core.autocrlf=true` 来自 PortableGit 的**系统级** gitconfig（Windows 侧），checkout 出 CRLF | 见 §4 |
| 4 | 修完 CRLF 后 `git status` 仍报上千个 modified，但 `git diff` 只有几十个 | index 里的 stat 缓存是**文件还是 CRLF 时**写进去的（`.clang-format` 记 size 182，转 LF 后实际 176），大小对不上 → git 每次都要重判；刷新后的 stat 又没能写回 index | 重建 index：`mv .git/index .git/index.stale && git reset`。实测 `git status` 从 1037 条降到 33 条（28 个真实改动 + 未跟踪）。index 里的 blob 哈希一直是对的，所以 `git diff` 从始至终准确 |
| 5 | `test.sh` 报找不到 `cmake` / `ctest` | 镜像把 CMake 装在 `$ANDROID_HOME/cmake/3.31.6/bin`，没进 PATH | `qa.sh` 已把该目录注入容器 PATH |
| 6 | `GameInstallTest` 报 "stored objects are read-only" 失败 | 容器里以 root 跑，`File.canWrite()` 对只读文件也返回 true，断言失效 | `qa.sh` 用 `--user $(id -u):$(id -g)` 跑 test.sh |
| 7 | 报告里没有提交 SHA | 镜像里没有 `git` | `qa.sh` preflight 提前报缺 git，不在中途炸 |
| 8 | `docker/build.sh` 在 Windows 原生 Git Bash 跑不了 | MSYS 把 `--workdir /src/platforms/android` 改写成 `D:/App/...` | 同上，用 WSL；或直接跑 `qa.sh` |

判断「到底是真改动还是 stat 缓存脏」的方法（不用猜）：

```sh
git status --porcelain=v2 -- <file>   # 两个哈希（HEAD / index）相同时，工作区内容就是干净的
git hash-object <file>                # 与 git rev-parse :<file> 相同即内容一致
git ls-files --debug <file>           # 看 index 记的 size / ctime 与实际 stat 的差
```

## 8. 本机实测记录

2026-10-23，Windows + WSL2 Ubuntu + Docker Desktop 29.9.1，镜像 `s2arm-android-build:1`
（`sha256:d8180629a3fb…`），分支 `android/qa-gate@988011ae`：

| 步骤 | 结果 | 耗时 |
|---|---|---|
| 无设备单测 + 契约（test.sh） | ✅ | 8s |
| APK 构建（assembleDebug + lintDebug + verify-apk + apksigner） | ✅ | 23s（缓存命中；首次约 4–6 分钟） |
| APK 静态校验（verify-apk + apksigner） | ✅ | 1s |

APK：`android/app/build/outputs/apk/debug/app-debug.apk`，10,578,758 字节。

## 9. 尚未覆盖

- **真机矩阵**：安装 / 升级、资源包激活 v1→v2→v3 拒绝、设备身份记录（型号 / 系统 / 页大小 / GPU / 驱动 / 刷新率）、
  手柄输入。手上有 Redmi K80、联想拯救者 Y700 五代（平板），尚未开始。
- 报告尚未接 CI（当前靠本地或人工触发）。
- 16 KB 页设备单独协助验证。

## 10. 相关文件

- 门禁脚本：`android/tests/qa.sh`
- 脚本自测（26 项 fixture，已接进 `test.sh`）：`android/tests/qa_self_test.sh`
- 无设备单测与契约：`android/test.sh`
- 镜像与构建：`android/docker/`
