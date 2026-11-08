# 配对 varying 接口回归

运行器快照真实 Shader 源、GAL 能力表、Metal NxCaps、GraphicsConfig 与 host cache identity，再在独立目录离线编译。受控边界只有 authored Maxwell 字节、设备能力与绑定返回；实际 Decoder、SetNextStage、VertexA Combine、最终 IR、VTG 和声明器来自生产源。

```sh
python3 graphics/vulkan/runtime/varying-tests/run.py \
  --dotnet /path/to/dotnet --deps /path/to/compiled/dependencies \
  --out /tmp/varying-positive
# 第二组：固定功能、Layer/辅助 GS、稀疏 XFB、恒假谓词、发射顺序与 GLSL 原行为
# 同一命令加 --late-interface，并使用另一个新的 --out。
```

依赖须提供兼容的 Ryujinx.Common.dll、Spv.Generator.dll；输入 SHA 和实际命令保存在输出目录。没有下载步骤。输出须在源码、依赖、测试目录之外；创建目录前检查，防止遍历复制自己的输出。

语义 oracle 只还原 SPIR-V 宿主 Location，再比较整个模块；逻辑索引、分量、插值、值、默认输出及 VTG 内存布局不能改变。GLSL 保留原 paired / stage-independent 行为及 NonWritable：新映射和声明预算仅实际 SPIR-V 启用。实际选择语言与策略进入 host cache identity。cache-tests 另测真实 storage/admission 的变化拒绝和同值复用。

另用 --vtg-layer 运行真实 STG 触发 HasStore 的 VTG＋Layer 组合（独立新输出目录）：compute→生成 VS→后补 GS→FS。检查跨阶段集合、四模块完整字节、实际39/38分量预算边界和生成失败不发布producer；该 VS 的实际声明含额外 Layer 内置分量。--mutation omit-vtg-producer 复现漏发布真实 VS 接口；此时须同时传 --vtg-layer。该 authored 复现来自独立 Spec review，不将手工顺序称作执行了完整 GPU cache。

补充组覆盖真实 Fog/固定颜色生成，Layer 路线原模块恒等和辅助 GS 双端；另显式调用真实辅助 GS API 的 compact 接缝验证继承（游戏 Layer 路线使用 identity）。XFB Location2/5 保留逻辑编号，真正超限由预算拒绝。恒假 !PT AST/ALD 的对称例使用真实 Maxwell 解码；PT、动态谓词和固定功能需求经过实际 IO 登记函数。NoPred 是该函数入口的受控 flag 边界，不能宣称这些 opcode 的原编码带 NoPred。晚 Fog 两种发射顺序保留接口；已发射 compact 后要求 identity 必须明确诊断。

--mutation 支持 omit-input-map / omit-passthrough-map / omit-producer-union / omit-cache-policy / collide-locations / omit-budget / omit-language / omit-indexed-domain。补充组另有 omit-decoder-predicate / omit-gs-map / omit-identity / omit-late-guard / omit-language-policy，需同时加 --late-interface。负控只改私有快照，要求编译成功、实际运行红且命中对应原因。

这是主机 Release JIT 语义/身份测试，生成成功不等于格式、GPU 或游戏通过。SPIR-V 预算取实际声明类型与数组长度；动态接口按现有 Constants.MaxAttributes 的真实数组域准入。发现的旧限制保留：direct indexed AST 与默认输出组成的两个模块，candidate 与 legacy paired 字节相同，但 spirv-val 报 OpAccessChain 类型错误；本改动未修该旧访问链，也不把它们算合法 SPIR-V 正控。原生 GS 的对应动态模块应独立验证。

.spv 用 spirv-val --target-env vulkan1.1 验证；GLSL 用 glslangValidator -V --target-env vulkan1.1 编译后再验证。GLSL29路控制保持原源码，实际编译预算为116用户分量端点+7内置=123/128，不再套用不准确的14预留。所有主机通过都不能替代 Android NativeAOT、驱动链接、像素或真实游戏验收。
