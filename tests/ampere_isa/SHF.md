# #1590 Maxwell SHF 零值回归

`cases.py` 中 `maxwell_shf_` 共98组，34组零值缺陷（`new=True`），64组非零正控（虽随本PR新增，`new=False`表示不要求旧DLL负控击中，不是按新增时间分类；实际读回见下表）。左右分别检查高/低结果字，常量缓冲读入运行期数据，立即数和寄存器计数分开。输入是原创合成指令，不含游戏代码。原有64组GPU用例的指令/输入/期望和21组反射条目保留。

- 编码：本仓库 Maxwell `InstShfLR/RR/LI/RI`、`InstLopC`；普通NVN控制段经原 `dsh_cmp --fn ampere_compile` 到共用IR、SPIR-V，再到MSL；128位Ampere编码不会经过本片方法。
- 独立期望：以64位整数字段拼合再取字，不调用翻译器。32位取模口径见 [NVIDIA PTX shf](https://docs.nvidia.com/cuda/archive/13.0.0/parallel-thread-execution/index.html#logic-and-shift-instructions-shf)；Maxwell高低取字、U64/S64须另核 [Mesa NAK OpShf.fold](https://chromium.googlesource.com/external/gitlab.freedesktop.org/mesa/mesa/+/b1fe47e94409d81924c8663f58fac97e66ab4527/src/nouveau/compiler/nak/ir.rs#4501)，不能把PTX.b32当作所有SASS模式的依据。
- `shf_ir_test.py` 直接调用真实四个发射入口，严格解释实际IR；任何32位移位计数≥32（包括select未选分支）立即失败。1040项覆盖左右、立即数/寄存器、wrap/clamp、三类宽度和CC开关，并比对结果与ZN标志。它是CPU检查，**不替代GPU验收**。
- [维护方已明确本片范围](https://github.com/jhaizhou-ops/S2Arm/pull/1653#issuecomment-6709283920)：仅修 Maxwell `EmitShf` 零值/超宽移位。`XModeShf.Hi/X/Xhi`、独立 Ampere `AShf` 四组合、默认32位clamp端点均另单处理，本片不纳入，也不声称已修或验收；保留原端点规则。本片两版各98组M1实际读回已按下表补齐，转Ready前仍须完整contrib摘要。

## M1实际读回（原/修各一次）

| 预先固定的独立期望 | 原版 | 修复版 |
| --- | --- | --- |
| 34组零值缺陷 | 0/34 | 34/34 |
| 64组非零正控 | 64/64 | 64/64 |
| 共98组 | 64/98 | 98/98 |

196个被测进程均exit0、输出均为4个uint32；旧版34红是数值错，并非执行失败。按同一期望比较，原版exit1，修复版exit0。例：`maxwell_shf_l_hi_u32_wrap_reg_0` 期望 `89abcdef 12345678 00000000 ffffffff`，原读回 `89abcdef 92345679 ffffffff ffffffff`，修复版与期望一致。

路径：Intel上经原 `ampere_compile` 冻结原/修两版MSL，传输前后核完整SHA；M1只执行Intel预编译的原 `frag_run.m` 一像素程序，读回带回Intel逐项比对事先期望。被测修复DLL实际源码为 `fcb8e1861`，生产与断言相对文档头 `9aa46d951` 相同；旧DLL基线 `0e74ebe11`。没有在M1开发构建、装工具或运行游戏；此拆分验证不冒充原整套 `contrib_check.sh`，也不覆盖独立SPIR-V执行、未改模式或游戏表现。

在资源准入下只跑CPU检查（`S2A_CPU_GATE=1`限制内部构建）：

```sh
S2A_CPU_GATE=1 DOTNET_PROCESSOR_COUNT=1 bash tools/mem_admit.sh dsh shf-zero-ir --cores 1 -- python3 tests/ampere_isa/shf_ir_test.py
DSH_CMP_DLL=/absolute/path/to/old/dsh_cmp.dll S2A_CPU_GATE=1 DOTNET_PROCESSOR_COUNT=1 bash tools/mem_admit.sh dsh shf-zero-ir-old --cores 1 -- python3 tests/ampere_isa/shf_ir_test.py
```

GPU仍用原 `bash tests/ampere_isa_test.sh`，或在已构建配套库/小程序后用 `cases.py <frag_run> --filter '^maxwell_shf_'` 单列本片。`DSH_CMP_DLL` 指旧DLL跑同一批例；CPU红不会提前省略GPU负控。Intel上生成的MSL可交给Apple Silicon上预编译的一像素小程序运行；须单列机器、程序/翻译器身份、分母和未测项。不要把导出MSL、交叉编译或严格IR通过写成GPU读回通过。
