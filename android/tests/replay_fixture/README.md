# replay_fixture（S2RF）：回放核心共用测试夹具

#784（回放核心抽离 D2–D7）的宿主侧回归夹具。不依赖 Metal / Vulkan / 真机 / 游戏数据：
一台能跑 `cc` 的机器就够。

**问题**：D2–D7 每步要把一段 `nvn_be_*` 上沿行为搬进后端，判据是「同一命令流，下沿
`nvn_gpu_*` 调用序列逐字节不变」。此前没有可复用记录，各步各自搭一次性测试，期望
容易顺手由被测实现算出（§8 明令禁止）。

**改动**：一套二进制记录格式（`.in.rfx` / `.exp.rfx`）+ 7 对合成样例 + 0 容差比对器
+ 宿主单测。输入侧 OP 流直接复用 `nvn_obj.h` 的 `op_hdr`/`p_*` 载荷，与 `hle_nvn.c`
录出的记录同构；期望流手写钉死在生成器里，不经任何被测实现产出。

## 1. 文件

| 文件 | 作用 |
|---|---|
| `rfx.h` / `rfx.c` | 格式常量、函数 ID 表、写 / 读 / 比对库（纯 C11，无外部依赖） |
| `FORMAT.md` | 字节级规范：容器、记录族、规范化编码、钉法、CHK 语义 |
| `rfx_cmp.c` | 比对器 CLI：`rfx_cmp <期望> <实际> [--funcs 逗号表]`；`--dump` 人读转储 |
| `rfx_gen.c` | 样例生成器：7 对 .in/.exp 全原创合成数据 |
| `t_rfx.c` | 宿主单测（格式往返、比对器自证、样例解析） |
| `run_test.sh` | 一条命令：编译 + 单测 + 重生成与金样逐字节对拍 |
| `samples/` | 提交的金样（`.in.rfx` / `.exp.rfx` 各 7 份） |

## 2. 跑法

```sh
bash android/tests/replay_fixture/run_test.sh      # 单测 + 金样可重现
```

门禁：`android/CMakeLists.txt` 宿主段注册了两个 ctest——
`android_replay_fixture`（t_rfx + 样例解析）与 `android_replay_fixture_repro`
（run_test.sh 全量）。随安卓宿主测试一同跑（macOS `test.sh` 与 colima `linux_ctest.sh` 两边）。

## 3. 样例表

| 样例 | 覆盖 | 对应 §8 用例形状 |
|---|---|---|
| `s00_buf` | 池包装（pool_add→buf_wrap→OK）、fill_buf 32 位、copy_buf、commit/signal/fence_wait、BUF 读回 | C01、C26 形（提交时序） |
| `s01_clear` | 窗口面 attach、懒建 tex/view、单附件 `load=CLEAR`、present/ticket、presented CHK | C09–C12 形的正例支路 |
| `s02_triangle` | vs/fs 程序快照、shader_load+layout、pipe_get、通道内 set_pipe/set_dyn/set_vbuf/draw | C16 C17 C20 形 |
| `s03_texture` | dpool/采样图 tex_init、reg_tex/reg_samp、tex_upload（行距/镜像）、bind TEX_SAMP | C22 C25 形 |
| `s04_depth` | color+depth 双附件、depth `load=CLEAR` 1.0、ds_st 开深度 | C20 形 |
| `s05_mrt` | 三颜色附件同一通道（ncolor=3） | MRT 面 |
| `s06_dispatch` | 无通道：cpipe_get、SSBO bind、dispatch 4×1×1 | D5 派发形 |

样例间共用骨架（`fx_*`）：固定三段 guest 内存（OBJ/CMD/DATA）、serial 单调、
`signal` = 提交序、窗口样例结尾统一 present。

## 4. D2–D7 维护者怎么用

后端每步落地后做两件事：

1. **记录器**：实现 `nvn_gpu_*` 打点版——按 FORMAT.md §4 规范化（句柄换 hid、块数据
   换 len+CRC32、时刻归 0），把调用流写成 `.act.rfx`。
2. **回放 + 比对**：回放器读 `.in.rfx`（REGION 映射、DATA 预置、RES 建对象、CALL
   依序驱动前端→后端），记录器产出 `.act.rfx`，然后
   `rfx_cmp samples/sNN.exp.rfx out.act.rfx`。
   绿 = 本步行为不变；红 = 第一处差异（记录号 + 函数名 + 字节偏移）直接定位。

`--funcs` 可按函数族切回归（例 `--funcs 9,10,16` 只比 tex_create/release/upload）。

CHK 记录给执行器用：done/presented/retired 回调的次序与参数、栅栏读数、BUF 段内容，
回放执行器逐一断言；它们不进字节比对（FORMAT.md §8）。

## 5. 支持的 §5 验收读数

- **判据 3「纯重构不夹带行为改动」**：给出下沿逐字节级回归面，比「逐像素相同」更早、
  更细——任何一步动了调用顺序 / 参数 / 句柄配对立即红。
- **D2**：s00（fill/copy/提交/栅栏/读回；C01、C26 形）。
- **D3**：s03（tex/view/samp 懒建 + 上传；C22 C25 形）、s04/s05 附件路径。
- **D4**：s02–s06 的 shader_load+layout、pipe_get/cpipe_get（C16 C19 C20 正例支路）。
- **D5**：s02/s04/s05 draw 链、s06 dispatch、bind/push 编码（C17 C25 形）。
- **D6**：s01–s05 的 surface/drawable/present 正例支路（C09–C14 形的成功侧）。

## 6. 限制（明说不替什么）

- 样例是**契约形状**回归，不是像素回归：§5 判据 1 的「逐像素一致 / 帧时差 <5%」
  仍靠 D1 基准（真实游戏截图回放）。本夹具让每步先证明调用级行为没变，再去跑基准。
- §8 反例支路（C02–C08 失败 / 生命周期、C09–C14 异常面、C23 通道内序、C24 FAULT）
  格式全部可表达（rc 字段、CHK DONE/RETIRED/PRESENTED、粘滞 E_*），但 7 个样例
  只例示正例骨架；反例样例随各步落地时按同一格式补，期望仍须手写。
- ASSUME 只有 REF 档一种；多能力档（GPL / 动态 ds / 高 push 上限）的差分期望留给
  D4–D6 各自的能力矩阵用例。
