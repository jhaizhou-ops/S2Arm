# TextureView 比较（#270）

`nvnTextureViewCompare(const NVNtextureView *, const NVNtextureView *)` 返回两个视图的显式设置是否相同。先比较六个设置标志；标志不同时返回 false。标志相同时，仅比较已设置的 levels（base/count）、layers（min/count）、format、四通道 swizzle、depth-stencil mode、target；全部一致返回 true。显式 identity swizzle 或 DEPTH 与未设置不同。

## SDK 依据

核对自有游戏实际 SDK 的比较入口，未执行 SDK、未上传游戏数据：

| 样本 | SDK SHA-256 | 比较入口 |
|---|---|---|
| 怪物猎人：崛起 16.0.2 | `1c9f198a91c0bcfee5cf8f5b53fb941895e91334dfb766ce79fc68576797f017` | `0x475a20` |
| 超级马力欧兄弟 惊奇 1.2.1 | `73bec5989030d4d9f056503066180a6100bb7937370a4d818c8ba53960dfa2f3` | `0x45c070` |

两份实现均先检查六个显式设置标志，再按标志判断是否比较对应字段；任一有效字段不同返回 false。前者读取独立字段，后者采用较紧凑的位域布局；语义一致。SDK 标志顺序与宿主 `view_t` 的 `target/swizzle/depth-stencil` 顺序不同，因此实现使用命名字段，不复制 SDK 的位掩码或偏移。

沿用宿主已有 16 字节 `view_t`，不新增状态或修改 ABI。保留位与未设置字段不参与比较，不对整个对象做 `memcmp`。

## 真实 API 回归

复用 `graphics/nvn/tests/t_nvn_a.c` 和 `native-test-nvn_a`，经生产 `h_nvnBootstrapLoader`、`swnvn` 注册表与计数跳板调用，包括所有状态构造的 `SetDefaults` 和六个 setter。链接实际原生宿主、NVN 直连库、Widen NativeAOT 库；没有测试替身，也不手改内部 payload。

覆盖：

- 默认相等、自比较、双向比较。
- 六个 setter 分别只设置一侧时不等、设置同值后相等。
- levels/layers 两个分量分别变化；layers 用相差 256 的值检查高字节；swizzle 每个通道分别变化；其余字段值变化。
- 六个 setter 的正序与逆序得到相等状态；`SetDefaults` 清除全部显式设置。
- 显式 identity swizzle、显式 DEPTH 与默认未设置状态不等。
- 每个视图实际存储 16 字节，两个对象外侧使用不同 guard，比较前后核对对象与 guard 的完整快照。后侧 24 字节为外部存储，确保错误的旧头文件 40 字节比较可被安全反证。

未设置字段的 payload 被忽略只能由实现中的条件读取和 SDK 分支静态确认：公开 setter 设置 payload 时也会设置标志，`SetDefaults` 同时清除标志与 payload，本回归不通过修改内部字节制造无法公开构造的状态。外侧 guard 检查越界写；不同 guard 的相等用例也能识别错误的 40 字节整对象比较，但不代替通用内存访问检查。

运行命令：

```sh
make native-test-nvn_a NVN_A_TEST_QUERY=nvnTextureViewCompare
make native-test-nvn_a
python3 graphics/nvn/tools/nvn_func_table.py
```

本次为 Apple Silicon Mac 主机 API 验证；游戏 0 局，未启动 GPU、游戏或真机任务。主机生产启动代码会报告缺少游戏 `main.npdm` 与地址窗口护栏库，本测试不加载游戏，也不申请游戏地址窗口；这些启动诊断不是游戏验证结果。

## 实跑结果（2026-10-25）

arm64 / macOS 27.0（26A428）。恢复生产实现后的过滤回归通过 216 条真实 API 断言，全组通过 576 条。常量 true、常量 false、按旧头文件对 40 字节做 `memcmp` 三种临时错误实现均经生产入口重编链后被断言拒绝：true 在 `levels` 的单边设置阶段失败；false 与 40 字节比较在默认相等阶段失败；测试进程均退出 1（`make` 退出 2）。反证完成后恢复逐字段实现。

本机日志保留于 `build/texture-view-compare/`，不作为游戏或设备读数。仓库 `nvn_func_table.py` 实跑分类为 `nvnTextureViewCompare 已实现 0`，最后的 0 是未提供游戏局日志，不是游戏中调用 0 次的证据。
