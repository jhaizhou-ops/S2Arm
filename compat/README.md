# compat/：Ryujinx 锁版本源码（服务接入线归属）

| 路径 | 内容 |
|---|---|
| `tree/` | 树内源码 = 上游原样 + `patches/series` 依序打补丁。构建只引用这里（如 `tree/src/Ryujinx.HLE/Ryujinx.HLE.csproj`） |
| `UPSTREAM` | 锁定的上游提交与 35 个导入路径的 git 对象号 / 模式（`import_upstream.sh` 生成） |
| `patches/` | 每条改动一个补丁 `<生成时刻>-名字.patch`（10-28 前的是 `NNNN-名字.patch`），`series` 定顺序；理由写在 `compat/改动清单.md` |
| `packages/` | 收录的 NuGet 包（LibHac 预发布包，上游包源在我方机器不通；ZstdSharp.Port 0.8.8：nx_unpack 解 nsz / xcz 的 zstd，纯托管、MIT，nuget.org 原包 sha256 f6797192deebf4535f0601c2273e750da0c02062e30a3e4a3c4011b9ac22403a） |
| `verify.sh` | 门禁项：上游 + 补丁 = 树内源码，外加 series / 补丁文件 / 改动清单三者一致 |
| `patch_new.sh` | 把 `tree/` 的未入补丁改动生成新补丁、登 series、追加清单一行，并自动核对 |
| `import_upstream.sh` | 锁 / 升上游版本时导入原样源码，自检逐字节一致 |

## 锁定版本
Ryubing 主干 `475615f0`（2026-08-26，「revert "Add raw copy dependencies for incompatible textures" (#181)」）。
旧库与验证线一直称之为「1.3.2」，因为 CHANGELOG 最后一条是 1.3.2；实际是主干快照。本机副本 `~/xbl/build/cache/sw/ryujinx-src` = 475615f0 + 验证线改过的 31 个文件（Headless / 调试器 / 加载器 / AppleHv 等），显卡部分与 475615f0 零差。
上游对象可从镜像取（官方 git.ryujinx.app 在我方机器 TLS 不通）：`github.com/Stella-sea/ryujinx-admin` 分支 canary 含此提交。

## 改 Ryujinx 的流程（所有线通用）
1. 直接改 `compat/tree/...`。
2. `compat/patch_new.sh <名字> "<一句话理由>" [只收的路径…]` → 生成 `patches/<YYYYMMDD-HHMM>-名字.patch`、登 series、清单加一行、自动跑核对。
3. tree 改动 + 补丁 + series + 清单同一笔提交；提交前 `compat/verify.sh` 必须绿。
4. 改已有补丁：改 tree 后删掉该补丁及其 series / 清单行，重新 `patch_new.sh`（新补丁登在 series 末尾；若顺序有依赖，手工调整 series 后再核对）。

## 门禁
`compat/verify.sh --rev <待合入提交>`：退出码 0 一致、1 不一致（打印差异文件 / 缺登记项）、2 环境错。秒级，不依赖网络（上游对象在仓库历史里：「引入上游原样」那一笔）。
