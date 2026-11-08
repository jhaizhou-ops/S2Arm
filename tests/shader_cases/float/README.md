# T222 第一片：FADD / FMUL

Part of #1160；使用 #1157 / #1168 v1 合同。框架原有的 `add`、`subtract` 两例（`FADD32I`）不动；本片 5 个原创 compute 用例都叫 `float/addmul_*`，由可读指令构成，不含游戏代码、提取的着色器或游戏数据。

## 可读编码（`tests/shader_cases/run.py` 的 `encode()`）

- `FADD[.SAT] Rd A B`：A、B 前可加 `-`（取负）和 `|x|`（绝对值，先取绝对值再取负）。B 为 `Rn`、20 位浮点立即数（取 binary32 的高 20 位，低 12 位必须为零，否则拒绝）或 `c[slot][字节偏移]`。
- `FMUL[.SAT][.D2|.D4|.D8|.M2|.M4|.M8] Rd [-]Ra B`：只有 A 的取负与一个缩放。
- `FMUL32I[.SAT] Rd Ra float`：任意 binary32 立即数。
- 只用缺省舍入（RN）。

## 覆盖

| 用例 | emitter | 内容 |
|---|---|---|
| `addmul_fadd_r` | `FaddR` | `-` / `\|x\|` 各组合、`.SAT`；1 + 2^-24 一类就近偶数舍入；最大值相加溢出到 +inf；inf − 1 |
| `addmul_fadd_i` | `FaddI` | 立即数正负号、`\|imm\|`、`.SAT`，相消得 +0 |
| `addmul_fmul_r` | `FmulR` | A 取负、六种缩放、`.SAT`、(1+2^-23)² 舍入、最大值 × 2 → +inf、inf × −0.75 |
| `addmul_fmul_i` | `FmulI`、`Fmul32i` | 20 位立即数与 32 位立即数、缩放、`.SAT`、舍入 |
| `addmul_cbuf_zero` | `FaddC`、`FmulC` | 常量缓冲形式；框架 C0 恒为 +0.0，只证常量源为 +0 时的运算 |

输入：word 0–7 是 1、−2.5、π、0.001、65504、−0.75、1.5、0.1 的 binary32。特殊位型（2^-24、1+2^-23、+inf、最大有限值）用 `MOV32I` 设。其余 word 用 flow 片同一 guard，没写到的必须原样读回。

## 独立期望

`python3 tests/shader_cases/float/addmul_reference_test.py`（已接进 `tests/shader_cases_test.sh`）按 IEEE 754 binary32、就近偶数舍入解释可读指令，不导入编码器、翻译器、SPIR-V 或实际输出。

- 和 / 积先在 binary64 里算：两 binary32 之积是精确的；之和经 binary64 舍入无害，因为 53 ≥ 2·24+2。再一次舍入到 binary32，超出范围得 ±inf。
- 缩放乘在精确积上。`.SAT` 夹到 [0, 1]：负数得 +0.0，大于 1 得 1.0。
- 立即数必须能精确表示：32 位立即数写成 binary32 的精确十进制值，例如 0x3dcccccd 写作 `0.100000001490116119384765625`。

模型逐例重算 64 word，每个结果 word 翻一位的错误期望都必须被拒，另有舍入 / 溢出的手算锚点。结果为 NaN、非规格化数，或 `.SAT` 的输入恰为 ±0 时，模型直接拒绝：这些地方 FTZ / 有符号零约定可能左右结果，lavapipe 与 Maxwell 可以合法地不同，所以不放进绿用例。`.SAT` 的输入为负数在建模范围内，得 +0.0。

**容差口径**：逐位相等，0 ULP。IEEE 754 规定 binary32 的加、乘在 RN 下正确舍入，结果唯一；Metal 规范对非快速数学的 `x + y`、`x * y` 也是正确舍入（0 ULP）。所以本片的期望与读回按 32 位位型逐 word 比较，不设容差。

## 射程

只覆盖这 7 个 emitter 在 RN 舍入下的规格化 / 无穷结果。RM / RP / RZ 舍入、`.FTZ` / `.FMZ` 与非规格化数、NaN 位型、`FFMA` / `FMNMX` / `FSET(P)`、转换与多功能族不在本片，仍归 #1160 后续片。不是 Metal、真机、游戏或性能验收。

# T222 第二片：FFMA / FMNMX

Part of #1160。4 个原创 compute 用例 `float/fma_*`，输入与第一片相同。

可读编码：
- `FFMA[.SAT] Rd Ra [-]B [-]C`：B 为 `Rn`、20 位浮点立即数或 `c[][]`，C 为 `Rn` 或 `c[][]`；C 是 `c[][]`、B 是寄存器时为 Rc 形式。
- `FFMA32I[.SAT] Rd Ra [-]float [-]Rd`：C 就是 Rd 本身，第 4 个操作数必须写 Rd。
- `FMNMX.<MIN|MAX> Rd A B`：MIN = 谓词 PT、MAX = !PT；`-` / `|x|` 修饰两个源。

| 用例 | emitter | 内容 |
|---|---|---|
| `fma_ffma_r` | `FfmaR` | B / C 取负、`.SAT`、恰好相消、溢出到 +inf、inf 操作数 |
| `fma_ffma_i` | `FfmaI`、`Ffma32i` | 20 位与 32 位浮点立即数、B / C 取负、`.SAT`、C = Rd |
| `fma_fmnmx` | `FmnmxR`、`FmnmxI` | MIN / MAX、`\|x\|` 与 `-`、±inf |
| `fma_cbuf_zero` | `FfmaC`、`FfmaRc`、`FmnmxC` | 常量缓冲形式（含 FFMA 的 Rc 形式：B 取寄存器、C 取常量缓冲），对零 C0 |

独立期望：`python3 tests/shader_cases/float/fma_reference_test.py`（已接进 `tests/shader_cases_test.sh`）。`FFMA` 用有理数精确算 a·b + c 再**一次**就近偶数舍入到 binary32，不经 binary64 中间值；`FMNMX` 按 IEEE minNum / maxNum。容差口径同第一片：逐位相等。

**融合与 Vulkan**：Maxwell `FFMA` 只舍入一次，翻译器也照样出 GLSL.std.450 `Fma`（`CodeGen/Spirv/Instructions.cs` `GenerateFusedMultiplyAdd`）。但 Vulkan 精度规则只保证 `Fma` 与「OpFMul 再 OpFAdd」同精度，Mesa lavapipe 实测就是舍入两次：(1+2^-12)² − (1+2^-11) 得 0、不是 2^-24。这不是翻译器错误，是 Vulkan 不保证融合；Metal 的 `fma()` 是融合的。所以本片的 `FFMA` 输入只取「融合与两次舍入结果相同」的值，参考模型对能区分两者的输入直接拒绝；能区分的那几组记在本片 PR 里。

射程：RM / RP / RZ、`.FTZ` / `.FMZ` 与非规格化数、NaN 与 ±0 的最小 / 最大约定不在本片。

# T222 第三片：FSET R/I（有限正规数与 ±0）

Part of #1160。`fset_{r,i}_{compare,modifiers,zero}.json` 六个原创 compute
用例只测 `FsetR` / `FsetI`；不改变生产翻译器或 native runner。

可读编码：`FSET.<LT|EQ|LE|GT|NE|GE>[.BF] Rd A B`。A 是寄存器，B 是
寄存器或 binary32 高 20 位立即数（低 12 位必须为零）；两源可用 `-`、
`|x|`、`-|x|`，先绝对值后取负。负十进制立即数的符号存于立即数本身，
`-|-1.5|` 另设 negate-B。布尔组合固定 `AND PT`，执行谓词也固定 PT。
不支持 Cbuf、FSETP、非恒真谓词、CC、FTZ、其他比较或布尔组合。

| 用例（R/I 各一份） | 每份结果 / guard word | 内容 |
|---|---|---|
| `compare` | 48 / 16 | 四对输入 × 六比较 × mask/BF；小于、大于、相等、最小正规数与最大有限数 |
| `modifiers` | 32 / 32 | 两个负源的四种修饰各交叉 × mask/BF，用 LT 区分；I 的单独负号用正立即数等值表示 |
| `zero` | 48 / 16 | ±0 的四种配对 × 六比较 × mask/BF |

寄存器源从 SSBO word 56–63 加载，I 源为编码立即数；不把受测 FSET 简化成常量折叠。结果存于
word 0 起，所有未写字（含原输入）保留。每份独立核对全部 64 word，六份
共 384 word，其中 256 个结果、128 个 guard。

## 独立依据与容差

- 编码只按 [envytools 固定版 gm107.c](https://github.com/envytools/envytools/blob/f102b82381f3f11cee113d16374c87091db039d9/envydis/gm107.c)：
  1410–1434 行比较/逻辑表，2036/2154 行 R/I，256 行立即数位段。
  比较位 48–51（LT=1、EQ=2、LE=3、GT=4、NE=5、GE=6），AND=0，
  PT=7 位于 39–41；negA/absB/BF/negB/absA 分别位于 43/44/52/53/54。
- [Strato 固定版语义](https://github.com/strato-emu/shader-compiler/blob/8717c8f6d7deab58032e042b027ed84838833824/frontend/maxwell/translate/impl/floating_point_compare_and_set.cpp#L11-L50)
  仅交叉核结果格式与 abs 后 neg 的顺序，不复制其 GPL 实现。
  这些是独立开源依据，不冒充 NVIDIA 权威 ISA 或 Maxwell 硬件实测。
- 原创 `fset_reference_test.py` 从 binary32 符号、指数、尾数精确构造有理数，
  按数值关系比较；±0 数值相等。真输出 mask `0xffffffff` 或 BF
  `0x3f800000`，假输出 `0`。比较无舍入，结果位型唯一，故逐位相等、0 ULP。
  NaN/Inf/非规格化数、不能精确表示的立即数明确拒绝，不从实际翻译输出造金样。
- `fset_encoding_test.py` 与参考模型分开：六个固定机器字锚点核编码、十个
  域外形式必须拒绝。参考检查含最小/最大正规数、相邻正规数差与 ±0 手算锚点，
  六类非法输入拒绝，并逐字翻一位检验 384 个错期望。

两项检查已登记 `tests/shader_cases_test.sh`；原入口自动发现六个 JSON，真实
Maxwell→当前翻译器→spirv-val→lavapipe 全量读回。隔离负控可把
`fset_r_compare` / `fset_i_compare` 第一条 LT 换成 GT，保持原输入和期望，
须先通过翻译和 SPIR-V 校验，再由同一读回比较器拒绝；编译失败不算负控。

射程：只覆盖此窄域及固定 AND PT，不声称整张 #1160 完成；NaN、Inf、
非规格化、FTZ、Cbuf、FSETP、其他谓词与布尔组合未验。未验 Maxwell 实机、
Metal、手机、游戏或性能；不对既有浮点片扩大结论。

# T222 第四片：I2F R/I（S32/U32 → binary32，RN）

Part of #1160。四个原创 compute 夹具 `i2f_{r,i}_{s32,u32}.json`，只覆盖
`I2fR` / `I2fI` 的 32 位整数到 F32、默认就近偶数舍入；不修改生产翻译器。
可读形式为 `I2F.F32.<S32|U32> Rd Rb|imm20`，执行谓词固定 PT。
立即数编码域为 −524288…524287，先符号扩展成 32 位，再按 S32/U32 解释；
所以 U32 的 −1 是 4294967295，不是 1048575。

- R 两例各 16 个结果：0、1、42、S32 两端、U32 最大值、2^24 两侧及
  halfway 的偶数向下/向上、负 halfway、舍入进位。源从 SSBO word 48–63
  读取，不把寄存器源替换成常量。
- I 两例各 9 个结果：0、正负常规值、signed20 两端和负立即数的 U32
  halfway/进位。I 源本来就是常量，允许生产优化器常量折叠。
- 每例逐字比较全部 64 word，四例共 50 个结果和 206 个未写 guard（含
  原始输入）；容差 0 ULP，结果位型精确相等。

独立编码依据为 [envytools 固定版 gm107.c](https://github.com/envytools/envytools/blob/f102b82381f3f11cee113d16374c87091db039d9/envydis/gm107.c)：
1256–1281 行类型及舍入表，1995/2115 行 R/I 操作码。F32=0x200，
U32=0x800、S32=0x2800；R/I 基数 0x5cb8000000000000 /
0x38b8000000000000，源寄存器位 20–27；立即数低 19 位在 20–38，
符号在 56；RN 位 39–40 为零。该开源表不是 Maxwell 硬件实测。

原创 `i2f_reference_test.py` 不导入编码器或翻译器：对整数绝对值用
bit_length 找指数，用整数商/余数判断半途及偶数舍入，再处理尾数进位。
13 个手算锚点独立核对正负舍入与极值；四个夹具的每个 word 翻一位均须
拒绝（256 个错期望）。`i2f_encoding_test.py` 另核六个固定机器字和十种
域外形式。两项登记原测试入口，JSON 由既有 runner 自动发现。

有效运行负控可将 R/S32 夹具的 I2F 改为 U32，保持输入及期望不变：
须通过真实翻译与 spirv-val，然后由相同 lavapipe 读回比较器拒绝。
编码器分支撤回则新编码测试必须重新报 unsupported instruction。

不覆盖 Cbuf、8/16/64 位源、F16/F64、abs/neg/CC、非 PT 谓词或其他
舍入模式；不声称整张 #1160 完成。Linux CPU Vulkan 结果不是 Metal、
Maxwell 实机、手机、游戏或性能结论。

# T222 第五片：F2I R/I（binary32 → S32/U32，RN/RZ）

Part of #1160。八个原创 compute 夹具 `f2i_{r,i}_{s32,u32}_{rn,rz}.json`，
只覆盖 `F2iR` / `F2iI` 的有限正规 F32 与 ±0，且输入和舍入结果都在
目标整数范围内；U32 输入非负（−0 数值为零）。不修改生产翻译器。
可读形式 `F2I.<S32|U32>.F32.<RN|RZ> Rd Rb|float20`，谓词固定 PT。
RN 为就近偶数，RZ 为向零；立即数必须能以 binary32 高20位精确表示，
低12位非零则拒绝，不将立即数悄悄舍入成另一测试输入。

- R 四例各16个结果，源来自 SSBO word48–63：±0、正负半途值、偶数
  向下/向上、1.5 两侧相邻 binary32、S32 最小值和最大可表示域内值、
  U32 的 2^31 与最大可表示域内值；U32 另含最小正规数与普通分数。
- I 四例各12个结果：±0、半途偶数/奇数、正负常规值、该立即数格式
  在 S32/U32 域内的边界。I 本来就是常量，允许生产优化器常量折叠。
- 每例比较全部64word：总计112个结果、400个未写 guard（含输入），
  全部精确整数位型相等，没有浮点输出容差。

编码独立依据为 [envytools 固定版 gm107.c](https://github.com/envytools/envytools/blob/f102b82381f3f11cee113d16374c87091db039d9/envydis/gm107.c)：
1283–1307行类型/舍入表、1996/2116行R/I、256行浮点立即数位段。
R/I基数 `0x5cb0000000000000` / `0x38b0000000000000`；S32/U32
目标格式 `0x1200` / `0x200`，F32源格式 `0x800`；位39–40为
RN=0、RZ=3。源寄存器位20–27；立即数低19位放20–38，符号位56。
该开源编码表不是 NVIDIA 官方 ISA 或 Maxwell 实机验证。

原创 `f2i_reference_test.py` 不导入编码器或生产翻译器：直接解析 IEEE
符号/指数/尾数，构造精确有理数，按整数商余数与奇偶性计算 RN/RZ；
立即数十进制文本也先用精确有理数验证可表示性。16个手算输入分别核
RN/RZ；NaN/Inf/非规格化/域外输入18项拒绝；8例/512字逐字核期望，
逐字翻转最低位均与参考不符（不冒充 runner 的真实读回负控）。
每例 RN↔RZ 都必须改变输出，避免负控无区分度。
`f2i_encoding_test.py` 另核10个固定机器字和17种不支持的指令形式。
两项登记原 `shader_cases_test.sh`，8个 JSON 由既有 runner 自动发现。

运行负控：对八个夹具分别将 RN 换 RZ（或反向），保持输入和期望不变，
须通过真实 Maxwell 翻译、spirv-val 与 lavapipe 执行，再由同一比较器
拒绝数值结果；编译/校验异常不算有效负控。halfway 1.5 / 3.5（及负数）
能抓错模式，2.5 则核 ties-to-even 的另一方向；另核错期望拒绝。
撤回 encoder 分支时新编码测试必须重新 unsupported instruction 报红。

不覆盖 NaN/Inf、非规格化、溢出、负 U32 输入、Cbuf、其他位宽、
abs/neg/CC/FTZ、非 PT 谓词或 RM/RP。发现生产数值错误按 #1160
另开「已知红」，不在本片修生产。不代表整张 #1160 完成，也不宣称
Maxwell 实机、Metal、手机、游戏或性能已验证。
