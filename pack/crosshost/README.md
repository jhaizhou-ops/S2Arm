# Linux → Mac 中间检查点（#704 首片）

这是显式调用的私有检查点封存 / 核验工具，不是出包执行器。它不解包、不改写、不运行
索引器，不调用 shader / Xcode / 签名，也不接入现有 ios adapter。输入必须是调用方已冻结、
不会并发写入的私有阶段快照；原始游戏、派生文件、账本及逐文件摘要均不上传。

外层复用 artifact.v2 的 files 校验与现有 compare 摘要/差异实现。新子合同
s2a.crosshost.prepared.v1、目标 ios-prepared 由 #704 出包运维线确认。
它不代表 target=ios 的最终 IPA / 资源包，改成 ios 会被既有契约拒绝。
新增命令只核对格式/文件角色/内容一致性，不证明文件内部格式正确或已经可运行。

## 输入布局

工具投影下列角色文件。仅已知生产者记账旁证（.stage_unpack / .stage_rewrite /
.stage_romfsidx 及各自的 .deps 实际读入记录、.root_base / .root_base_stages / .root_src 及已知阶段日志）
不入账本、不改写；根管理旁证的内容变动或缺失不影响账本，仍拒绝旁证软链。未知其他文件（包括密钥、脚本）明确拒绝，
不自动删减或猜选。空目录不进账本；RomFS 目录必须存在。路径使用规范相对路径，
拒绝链接、特殊文件、大小写冲突、冒号、反斜线、空/点/父路径段。

- 共用输入：unpack.tsv、exefs/main、exefs/main.npdm、实际 exefs/、romfs/、
  可选 ctl/ 与 aoc/ 文件集合。exefs 模块通过 NSO0 魔数识别；这里只检查魔数，
  **不是完整 NSO 格式验证**。
- extract：上述解包快照。这里的名字不代表 pack/stage_extract.sh 的 shader 抽取
  或 .stage_extract 已完成。
- rewrite：另含每个实际 NSO 模块的 patched.bin / fixups.tsv / gates.tsv /
  sites.tsv / gaps.tsv 五件必需组；widen.tsv 按实际存在入账（无宽屏候选时生产者不生成），
  不允许其他模块的孤儿 widen.tsv 或其他孤儿改写文件；模块名不固定为 main/sdk。
  rtld 按当前 stage_rewrite.sh 跳过改写，但作为输入保留。
  另必须有 main.npdm、widen_sites.tsv、addr_need.tsv。已有 gpu_drivers.tsv、
  nro_exports.tsv、fps.tsv、widen_verified.tsv 作为附加消费数据入账本。
- romfs-index：共用输入加 romfs.s2aidx；完整输入文件集合与索引一起核验；前序已产生的上述 rewrite 角色可保留并入账，
  但本 profile 不要求它们存在、不声称已验证 rewrite 阶段完成。
- pre-metal / shader 等其他 profile 拒绝，不假报支持。

调用方提供冻结的本阶段快照；已知旁证由工具只读投影，不要求删除原件。
尚不支持带其他阶段产物（例如 shader/pkg/build）的整根，遇到明确报红，不能当整链完成。
本工具不改变生产根、
不写 .stage_*，不读取游戏库、补丁目录或主机私有配置。真实输入由拥有者本地处理。

## 命令

仅 Python 标准库，无隐式下载。SOURCE 为生产这些文件时的完整 40 位源码提交号，
不是任意新 HEAD。身份固定为源码提交号 + 实际 unpack.tsv 的完整 SHA256；
该来源声明不等于工具能证明文件是由该提交生产。所有文件自身另有完整摘要。

```sh
python3 -I -S -B pack/crosshost/prepared.py seal \
  --root /private/frozen --manifest /private/checkpoint.json \
  --profile rewrite --source-commit "$SOURCE"
python3 -I -S -B pack/crosshost/prepared.py verify \
  --root /private/frozen --manifest /private/checkpoint.json
python3 -I -S -B pack/crosshost/prepared.py compare \
  --left-root /private/linux --left-manifest /private/linux.json \
  --right-root /private/mac --right-manifest /private/mac.json
bash tests/crosshost_prepared_test.sh
```

账本必须在输入目录外；seal 以 0600 临时文件写入并 fsync，重新 verify 后原子 link
发布，不覆盖已有账本。异常时删除本次临时文件，不发布完成账本。它不复制或传输文件，
也不提供断点续传；SHA256 完整性不提供来源认证。输入需要调用方保持冻结，不能将
两次检查当作对敌对并发文件系统的隔离或锁。

verify 重读每个文件而不复用 mtime 缓存。compare 先验证两边，并要求 profile 和输入
身份一致，再比较完整文件集合/大小/摘要；不是 IPA 签名比较。命令不打印私人路径、
文件名、摘要；compare 只打印差异数量。退出码 0 成功/相同，1 两边内容不同，2 无效输入。
库 compare 返回本地差异路径，仅供私有分析，不上传原始结果。

### Windows 权限与宿主工具

Windows 的 `st_mode` / `chmod(0600)` 不等同于 POSIX 所有者权限，访问隔离由
输出目录继承的 Windows ACL 决定。调用者须使用仅向授权用户开放的本地私有目录。
Windows 测试核对当前进程可读写、发布不覆盖已有账本、失败不发布以及临时文件清理；
`os.access` 不能证明其他用户没有访问权，本工具不设置 ACL，也不宣称已验证这种隔离。
Mac / Linux 继续核对账本模式为 `0600`，两端都不以权限检查替代内容完整性检查。

资源包 Python 入口在 Windows 用文件复制与 `spawn`，Mac 保留 `clonefile`，支持
`fork` 的平台保留原多进程上下文。
与主线 `jmem` 内存定并发接口对齐：Windows 通过 `GlobalMemoryStatusEx` 取得
`avail_phys` / `total_phys`，不调用 POSIX 的 `os.sysconf`；Mac 的内核余量口径保留。
本次资源打包器的文本产物使用显式 UTF-8 与 LF，不依赖本地代码页。
Python 改写器即将由上游移除，按出包线评审撤下其文本 IO 适配；此前的编码对照
仅作为历史实验，不证明当前分支的 Python 改写器在默认代码页下可用。
后续 C 改写器的 Windows 验收独立接续，不用 Python 结果替代。
这些宿主组件通过不代表 Shell 阶段、Mac 接续、IPA、签名或真机游戏通过。

## 验证边界

合成测试覆盖命令运行、独立 abc 摘要、实际模块闭包、同长篡改（保留 mtime）、
缺件、额外件、截断、链接、角色/路径/身份错误、输入变化及 fsync/link 故障不发布。
它们是在 Linux 上用原创字节运行，不是 Mac 或真实游戏对拍。

出包运维线负责 clonedir.py 私有冻结同输入的 Mac 对拍及后续 Metal、链接/NativeAOT、
签名验收。未取得这部分证据前 PR 保持 Draft；本工具不声明整卡完成。
