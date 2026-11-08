# T223 首批单线程内存边界用例

Part of #1161；使用 #1157 / #1168 v1 合同。只放 `flow/`、id 用 `flow/`，不移动框架原 `memory/` 两例。8个原创JSON由可读指令构成，不含游戏代码、提取的着色器或游戏数据。

## 独立期望

`python3 tests/shader_cases/flow/reference_model.py` 用字节数组解释本片有限指令域，不导入编码器、翻译器、SPIR-V或实际输出。输入guard为 `((i+1)*0x9e3779b9+0x31415926) mod 2^32`，各JSON显式列出完整64word输入/期望和例外。load/store为对齐32位位复制，IADD32I仅作加1回绕脚手架；C0明确为框架真实绑定的64KiB零uniform。每例的错误期望翻一位必须被该独立模型拒绝；模型自证不代替真实Vulkan读回负控。

本片核存储缓冲首/末word、0/全1/符号边界位模式、相邻字、单线程写后读链、就地回绕、C0首64位对/有符号立即数的最大正向对齐64位对及未修改guard。所有访问均对齐且在范围内，不用未定义越界行为判通过。参考域不支持的指令/输入/未初始化寄存器明确拒绝。

LDC的CbufOffset虽然在 `Decoders/InstDecoders.cs` 以无符号16位字段读取，`Instructions/InstEmitMemory.cs` 的 Ldc 随后会用 Imm16ToSInt 做符号扩展。当前编码基址固定RZ=0，故本参考域只用非负位移0..32767；最后一个对齐64位对起点32760。原始位型0xfff8代表-8，不能当65528使用；需要非零基址的负位移不在本参考域。零C0只能证明两目标都被写零，不证明混合高低半字序或任意常量内容。

## 执行与射程

框架合入后运行 `bash tests/shader_cases_test.sh`，现有glob/门禁声明收集本目录。依赖未合入时只能在明确记录的框架+本片组合树验证，分别写基线/组件提交与实际源码hash，不将组件验证冒为已合入。输入→真实Maxwell→当前Translator→spirv-val→Linux Mesa lavapipe→全部64word读回；Khronos校验和同一compare的错期望/发射突变负控各报真实结果。

`rules` 只解释目的，不能计覆盖率；真实分母由框架从源码解码/IR证据算。本首片不声称整个约44发射函数100%，不声称未有IR改动证据的GlobalToStorage/其他遍或patch通过。SHFL/VOTE/BAR、多线程、局部/共享/原子以及其他修饰位等后续能力归 #1157 协调，未执行不计覆盖。不是Metal、Mac colima包装器、ARM设备、游戏或性能验收。
