# IMUL 低 32 位回归（#1159 窄片）

只测 `IMUL.<U32|S32>.<U32|S32> Rd Ra B`，两个类型依次对应 A/B。
B 是寄存器、**有符号 20 位立即数**或现有全零 `c[0][对齐字节偏移]`。
没有 HI、CC、IMUL32I、IMAD、XMAD、非零常量输入、谓词修饰或多线程扩展。

## 独立依据

编码根据 [envytools 固定 gm107.c](https://github.com/envytools/envytools/blob/f102b82381f3f11cee113d16374c87091db039d9/envydis/gm107.c)：
1371–1379 行给两源类型位 40/41；2010、2084、2130 行分别给 R/C/I
`0x5c38` / `0x4c38` / `0x3838` 前缀、HI 位 39 和 CC 位 47。
该文件还给寄存器位置、C0 字偏移及有符号 20 位立即数布局。
`mul_encoding_test.py` 独立列出十个固定机器字，检查类型位、负立即数、C0 末端偏移、RZ，
并拒绝十个域外形式。没有复制该第三方文件入仓，也没有把 Ryujinx 输出当编码金样。

算术参考 `mul_reference_test.py` **不导入编码器、翻译器、SPIR-V 或运行输出**。
对任意 32 位 A/B，低字定义为 `(A * B) & 0xffffffff`；有符号解释只是减去
`2**32` 的倍数，故四种类型组合的低字相同。立即数先符号扩展到 32 位。
七组手算锚点 × 四种类型组合验证参考解释器，包括
`0xffffffff * 0xffffffff → 1`、`0x80000000 * 2 → 0`、
`0x10001 * 0x10001 → 0x20001`、`0x12345678 * 3 → 0x369d0368`。
这不是 Maxwell 硬件执行证明，也不声称低字结果能区分高字的有符号语义。

## 原创用例

| 文件 | 有效结果字 | 射程 |
|---|---:|---|
| `mul_register.json` | 15 | 零、一、全1、符号边界、回绕、非平凡双源；Rd=A / Rd=B；RZ 读与丢弃写 |
| `mul_immediate.json` | 12 | imm20 最小/最大、0/1/-1、非平凡乘积、Rd=A |
| `mul_cbuf_zero.json` | 4 | C0 偏移 0/256/4096/65532 的零乘子；非零目的初值 |

输入全部原创。主要操作数从 storage0 读取，避免所有乘积被常量折叠而只测常量路径。
每例比较**全部 64 字**，包括未改输入及 guard；每例分别把 64 个期望字翻转一位，
独立参考必须逐项拒绝。三例共 31 个结果字、192 个错期望负控。
C0 按既有 runner 合同固定全零，不能证明非零常量、不同常量槽或类型语义。

## 执行与边界

```sh
python3 tests/shader_cases/integer/mul_reference_test.py
python3 tests/shader_cases/integer/mul_encoding_test.py
bash tests/shader_cases_test.sh
```

两个 host 检查已接入原门禁入口；JSON 由原入口自动发现，沿现有真实
Maxwell → Translator → SPIR-V → `spirv-val` → Linux lavapipe compute 链执行。
已有全套错期望/真实 FADD32I 发射突变负控保留。IMUL 专项错误运算实测方法：
在独立二进制副本仅把 IMUL opcode 替成相应 IADD，保留输入、寄存器、写回与正确期望，
再用同一 translator/validator/runner/比较器执行；必须成功执行且因数值不同报红，
不能把编码失败、编译失败或工具缺失当作有效负控。PR 记录该实测读数。

本片补的是回归缺口：旧 encoder 明确拒绝 IMUL，而非已发现生产乘法错误。
不修改生产 emitter、runner、超时、公共执行合同；不增加补丁归因分子，
不宣称 #1159 整族完成。这里只验证 Linux CPU Vulkan；未测 Maxwell 硬件、Metal、
Apple ARM64、真机、游戏或性能。
