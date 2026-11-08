# 真实上屏驻留集成测试（关联 #298）

`t_present_residency.sh` 链接真实 Mac 前端、完整生产宿主、NVN、GAL 和生产 Widen，不使用宿主替身。需要 Apple 芯片 Mac、可显示窗口的桌面会话、支持 Metal 4 的设备 / 系统及仓库要求的 Xcode。一次运行覆盖 Metal 4 / 强制 Metal 3 × `DM_PRESENT_LINK=0/1` 四个独立进程。

main `777962e5` 已在外部纹理登记时发布驻留集并关闭 #298；本片增加上屏提交前统一发布驻留集和集成回归。原 `t_nvn_m3` 按 main 保留。

## 准备生产依赖

在仓库根目录，用现有 `runtime/build.mk` 的生产目标单独准备 Widen。该步骤需要仓库要求的 .NET SDK 和已准备好的 NuGet 依赖，不属于 GPU 测试：

```bash
make -j1 S2A_CS=0 BUILD="$PWD/build/tests/present-residency/deps" \
  "$PWD/build/tests/present-residency/deps/tests/nvn/widen/S2Arm.Gfx.Widen.dylib"
```

也可用 `PRESENT_WIDEN_LIB` 指向已核对与当前源码一致的生产 Widen。显式路径不由 runner 检查源码新旧，调用者须先核对；runner 会把实际链接输入的 SHA-256 写进 `link-inputs.sha256`。

## 运行与门禁判据

在同一仓库根目录执行：

```bash
bash graphics/nvn/tests/t_present_residency.sh
```

使用已有生产库时执行：

```bash
PRESENT_WIDEN_LIB="$PWD/build/tests/nvn/widen/S2Arm.Gfx.Widen.dylib" \
  bash graphics/nvn/tests/t_present_residency.sh
```

runner 在本树私有输出目录重新构建 NVN / GAL 和完整宿主对象，不发布 Widen、不执行 NuGet 还原。缺 Widen、显式路径不可读或默认库比源码旧时打印原因并退出 2，属于未完成 / 红，不能计作通过或跳过；构建、链接和运行失败也须判红。

链接参数读取 `runtime/build.mk` 的 `NVN_TEST_WEAK`，保留生产声明的可选宿主弱引用；前端与 GAL 仍链接真实实现，不提供自动玩家或其他宿主替身。

这项集成测试单独运行，尚未接入 `graphics/gate.sh` 或 `tools/contrib_check.sh`；正式验证须额外执行上述 runner，并在 PR 附退出码与四路日志。仅通过现有一级自检不代表本项通过。

每张新纹理登记后直接上屏三次，不插主提交；检查 300 ms 外部生产者事件、每次呈现回调以及每张纹理至少一次实际显示。系统丢弃的 drawable 记为 -1，不算实际显示。四路均须 39/39、最终 `present residency matrix: 4/4 passed` 且退出 0；runner 还核对实际后端选路，并拒绝 GPU 命令缓冲错误、PageFault 与 Metal 验证错误日志。

默认输出目录为 `build/tests/present-residency`，日志为 `mtl{4,3}-link{0,1}.log`。`PRESENT_RESIDENCY_BUILD` 可指定独立输出目录；未指定显式库时，其生产 Widen 应预先准备在该目录的 `deps/tests/nvn/widen/` 下。

默认开启 Metal API validation、关闭 shader validation，因为后者实测可掩盖驻留缺页。`PRESENT_SHADER_VALIDATION=1` 仅用于附加运行，不能替代默认矩阵。测试不需要游戏输入，也不证明游戏、移动设备、老系统、性能或能耗通过。
