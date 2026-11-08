# 壳清单与版本缓存

`manifest.py` 负责 `s2a.artifact.v2` / `ios-shell` / `s2a.artifact.shell.v1` 清单的 seal、verify、require；`cache.py` 按请求的 `shellId` 下载同一版本，供单款模式和 S2Arm 多游戏模式共用。此处不负责发版、组装 App、签名、安装或启动游戏。

## 调用

```python
from pack.shell.cache import ensure

result = ensure(shell_id, cache_dir, base_url, offline=False)
# result.root: pathlib.Path，已核验的壳目录
# result.manifest: pathlib.Path，位于 root 外的清单
# result.hit: bool，是否复用了已有完整版本（含并发发布的赢家）
```

`shell_id` 必须是游戏要求的 16 位小写十六进制原值。本工具不推断游戏包格式、不访问 `latest`、不拿其他版本顶替。`cache_dir=None` 时读 `S2A_SHELL_CACHE`，未设置则用 `<S2A_RUN_ROOT 或 ~/.s2arm/run>/s2arm/cache/shells`。`base_url` 由调用者显式传入，没有内置地址或自动回退地址；命中缓存或离线请求可传 `None`。

```sh
python3 -I -B pack/shell/cache.py --shell-id <壳编号> --cache-dir <缓存目录> --base-url <HTTPS发布根> --json
python3 -I -B pack/shell/cache.py --shell-id <壳编号> --cache-dir <缓存目录> --offline --json
```

缺省输出人读摘要；`--json` 成功时 stdout 仅含一个 UTF-8 对象：`shellId`、`root`、`manifest`、`hit`。错误在 UTF-8 stderr，退出 1；参数错误退出 2。导入模块不会调整调用者输出流、请求网络、下载或安装。只有明确调用在线 ensure、且指定版本不存在时才下载；不执行下载内容。

## 发布协议与信任边界

```text
BASE_URL/<shellId>/manifest.json
BASE_URL/<shellId>/files/<清单 files[].path>
```

文件路径以 `/` 分段，每段分别按 UTF-8 百分号编码；中文、空格和字面 `%` 不作为 URL 语法。只接受 HTTPS，以及字面主机为 `127.0.0.1` / `localhost` / `[::1]` 的 HTTP（维护方本机验收）。拒绝其他 HTTP、`file://`、账号、查询和片段。重定向不得改变协议/主机，也不得离开请求所在目录或含有解码后的父目录跳转。

先取清单，用原 `load` / `require` 精确对号，校验全部下载路径后才取载荷。逐文件流式核大小和 SHA-256，清单最多 16 MiB。路径拒绝父目录/绝对路径/盘符/空段/Windows 保留名和字符/尾点尾空格/大小写冲突（包括父目录）/文件目录重叠。清单格式、壳编号公式和代表宿主 ABI 的 `chain` 不变；下载路径校验由独立 helper 执行，不改已有清单格式。

逐文件 SHA 只证明内容与来源清单一致，来源可信靠调用者选定的 HTTPS 发布根；shellId 不是内容摘要。本卡不要求额外可信清单摘要，也不验证密码学签名或 Apple 信任链。回环 HTTP 是本机验收接缝，不提供 HTTPS 的来源认证。清单不描述文件权限位，不能据此推断签名、可执行性或可安装性。

## 缓存与发布

```text
<cache>/<shellId>/
    root/           # 壳的全部载荷
    manifest.json   # 清单位于 root 外
```

先在同一缓存根下的唯一暂存目录建好相同结构，所有内容通过大小/SHA 和整目录 verify 后才改名发布，再 verify 成品。普通失败清理本次暂存，不改其他版本。调用者持有缓存根；本工具的并发进程发布非空版本目录，改名失败或发现目标已存在时只核验已有版本，合格直接使用，否则报红，不覆盖。

每次复用都重新核验整个版本；缺件、多件、被改、链接、Windows 重解析点或不完整版本均报红，不静默修复或重新下载。需要重新取得损坏版本时，由调用者明确清理该版本后再次调用。离线不创建任何网络请求：正确缓存可用，缺版报红并写明缺哪个 shellId。

## 验证

```sh
python3 -I -S -B tests/test_shell_cache.py
bash tests/shell_cache_test.sh
bash tests/shell_manifest_test.sh
```

缓存单测使用原创非可执行字节、独立计算的固定身份/SHA、注入读取器；禁止实际联网，覆盖两个版本、坏缓存、离线、路径、线程与真实独立进程发布、CLI 编码、符号链接和 Windows junction。Ubuntu 的 Windows junction 专项明确跳过。传输层的重定向策略单测不替代真实 HTTP 服务验收。

出包线在同提交负责 Mac 与其 Windows 主机上的真实壳/本机 HTTP 五项：下载、重复使用不下载、单字节篡改报红、换 ID 取对版、断网缺版报红。正式壳尚未发布时，模拟源测试和真实发布下载必须分开记录；正式发布下载以后验，不把本卡通过当作完整 Windows IPA、签名、安装或游戏运行通过。
