// 转计算程序进缓存的单测（S2A.ShBake selftest-vtg；graphics/tools/shbake/tests/t_vtg.sh 调）：期望值全手算，不跑被测实现推期望。
//   ① 保留布局（ResourceReservations.S2ARead / S2AWrite）：按手拼字节重建，绑定号 / 每顶点输入输出字数与手算一致，写回逐字节相同；
//   ② 复合宿主二进制（S2AVtg.Pack / Unpack）往返：三段字节、标志、保留布局、直通顶点信息原样回来；坏魔数 / 截断返回 null；
//   ③ 磁盘缓存阶段掩码（DiskCacheHostStorage.AddShader）：顶点 / 几何阶段的信息是计算版时掩码仍含这两位（手算 0b110010 = 50），读回三段客体代码各归其位。
//      反证：上游口径「信息是计算就跳过」掩码只剩片元位（32），读回时片元拿到的是顶点的代码（本测试第 ③ 项在旧口径下必红）。
//   ④ 按需实化（开局只登记）读出转计算程序：三段宿主二进制分别装载、不翻译（渲染器代理计数）。反证：按需实化不认复合二进制时整段只装载一次、程序没有计算段（必红）。
//   ⑤ 直通几何转计算（异度神剑3 10-23 程序 8447：几何转计算核带 [[stage_in]]、Metal 编不过）：手拼客体代码（顶点只写自定义位置 0、直通几何无指令、片元无输入），
//      阶段独立翻译下几何直通全部 32 个位置。期望（手算）：转计算翻译零条 Invalid、几何计算核零个 Location 修饰（不留 Input / Output 变量）、
//      几何每顶点输入 4+1+4 = 9 字 / 输出 4+1+32×4 = 133 字、直通顶点输出 32 个位置。反证：旧口径（输出表只并顶点输出、读不到的输入留着）Invalid 744 条
//      （位置 1–31 × 3 顶点 × 4 分量，输入输出各 372）、计算核 62 个 Location、输出 9 字（本项必红）。
//   ⑥ 层输出通路（9000 Mali-G710 generic Z-A DeviceLost）：顶点写 gl_Layer、本程序无客体几何时，翻译把层值走私到通用属性、
//      靠追加硬件直通几何转成真 gl_Layer；旧判定只查 SupportsLayerVertexTessellation，漏了 SupportsGeometryShader——
//      A-GSOCC 关掉 Arm 的 geometryShader 后照样追加，管线里塞进硬件 GS、一画设备就丢。
//      {无几何着色器, 无顶点/细分层输出} 下翻译不得产出硬件几何阶段：明确拒建（抛异常）或走合法通路。本项修前必红。
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Gpu;
using Ryujinx.Graphics.Gpu.Shader;
using Ryujinx.Graphics.Gpu.Shader.DiskCache;
using Ryujinx.Graphics.Shader;
using Ryujinx.Graphics.Shader.Translation;
using System;
using System.Buffers.Binary;
using System.IO;
using System.Linq;
using System.Reflection;

namespace S2A.ShBake
{
    // 渲染器代理：只记程序装载 / 创建，能力表照给，其余成员返回缺省值
    public class FakeRenderer : System.Reflection.DispatchProxy
    {
        public Capabilities Caps;
        public System.Collections.Generic.List<byte[]> Loaded = new();
        public int Created;
        protected override object Invoke(System.Reflection.MethodInfo m, object[] a)
        {
            switch (m.Name)
            {
                case "GetCapabilities": return Caps;
                case "LoadProgramBinary": Loaded.Add((byte[])a[0]); return System.Reflection.DispatchProxy.Create<IProgram, FakeProgram>();
                case "CreateProgram": Created++; return System.Reflection.DispatchProxy.Create<IProgram, FakeProgram>();
            }
            return m.ReturnType.IsValueType && m.ReturnType != typeof(void) ? Activator.CreateInstance(m.ReturnType) : null;
        }
    }
    public class FakeProgram : System.Reflection.DispatchProxy
    {
        protected override object Invoke(System.Reflection.MethodInfo m, object[] a)
            => m.Name == "CheckProgramLink" ? ProgramLinkStatus.Success : m.Name == "GetBinary" ? Array.Empty<byte>() : null;
    }
    // 后端合法拒绝给宿主二进制（Vulkan ShaderCollection.GetBinary：最小布局 / VKPB v1 不支持的阶段集合返回 null）
    public class NullBinaryProgram : System.Reflection.DispatchProxy
    {
        protected override object Invoke(System.Reflection.MethodInfo m, object[] a)
            => m.Name == "CheckProgramLink" ? ProgramLinkStatus.Success : m.Name == "GetBinary" ? null
                : m.ReturnType.IsValueType && m.ReturnType != typeof(void) ? Activator.CreateInstance(m.ReturnType) : null;
    }

    static class VtgSelfTest
    {
        static int _fail, _n;
        static void Ck(bool ok, string what) { _n++; if (!ok) _fail++; Console.WriteLine($"{(ok ? "✓" : "不通")} {what}"); }

        // 截住 stderr 的报红行（GetBinary 空二进制每进程只报一次）
        static string CaptureError(Action action)
        {
            StringWriter writer = new();
            TextWriter old = Console.Error;
            Console.SetError(writer);
            try { action(); } finally { Console.SetError(old); }
            return writer.ToString();
        }

        static byte[] ResBytes(bool tfe, bool hasInput, byte inClip, byte outClip, uint inFeat, int inUdm, uint outFeat, int outUdm)
        {
            byte[] b = new byte[ResourceReservations.S2ASerializedSize];
            b[0] = 1; b[1] = (byte)((tfe ? 1 : 0) | (hasInput ? 2 : 0)); b[2] = inClip; b[3] = outClip;
            BinaryPrimitives.WriteUInt32LittleEndian(b.AsSpan(4), inFeat); BinaryPrimitives.WriteInt32LittleEndian(b.AsSpan(8), inUdm);
            BinaryPrimitives.WriteUInt32LittleEndian(b.AsSpan(12), outFeat); BinaryPrimitives.WriteInt32LittleEndian(b.AsSpan(16), outUdm);
            return b;
        }

        // Maxwell 指令（SPH 后每 32 字节第一个 8 字节是调度字，解码器跳过）：AST a[0x80]（自定义位置 0 的 x）← R0、EXIT；谓词 PT（位 16–18 = 7）
        internal const ulong Sched = 0x001F8000FC0007E0UL;
        internal const ulong Exit = 0xE30000000007000FUL;
        const ulong AstAttr0X = 0xEFF0000000000000UL | (0xFFUL << 39) | (0x80UL << 20) | (7UL << 16) | (0xFFUL << 8);

        internal static byte[] Guest(uint w0, uint w2, uint w3, uint w4, uint w18, params ulong[] ops)
        {
            byte[] b = new byte[0x50 + 0x40];
            BinaryPrimitives.WriteUInt32LittleEndian(b.AsSpan(0), w0);
            BinaryPrimitives.WriteUInt32LittleEndian(b.AsSpan(8), w2);
            BinaryPrimitives.WriteUInt32LittleEndian(b.AsSpan(12), w3);
            BinaryPrimitives.WriteUInt32LittleEndian(b.AsSpan(16), w4);
            BinaryPrimitives.WriteUInt32LittleEndian(b.AsSpan(72), w18);
            ulong[] code = { Sched, Exit, Exit, Exit, Sched, Exit, Exit, Exit };
            for (int i = 0; i < ops.Length; i++) code[1 + i] = ops[i];
            for (int i = 0; i < code.Length; i++) BinaryPrimitives.WriteUInt64LittleEndian(b.AsSpan(0x50 + i * 8), code[i]);
            return b;
        }

        // SPIR-V 里 OpDecorate（71）… Location（30）的个数：MSL 里就是 [[stage_in]] / 输出结构体的成员
        static int SpvLocations(byte[] spv)
        {
            int n = 0;
            for (int i = 20; i + 12 <= spv.Length;)
            {
                uint w = BinaryPrimitives.ReadUInt32LittleEndian(spv.AsSpan(i));
                int len = (int)(w >> 16);
                if ((w & 0xFFFF) == 71 && len >= 3 && BinaryPrimitives.ReadUInt32LittleEndian(spv.AsSpan(i + 8)) == 30) n++;
                i += Math.Max(len, 1) * 4;
            }
            return n;
        }

        static void GsPassthrough()
        {
            Ck(TranslatorContext.S2AStageIndep, "直通几何：阶段独立翻译开着（S2A_STAGE_INDEP 未设为 0；本项前提）");
            // SPH 公共字 0：类型 1/2（顶点几何 / 片元）、版本 3（位 5）、阶段（位 10：顶点 1、几何 4、片元 5）、几何直通（位 24）；
            // 几何：字 2 位 24 每图元线程 1、字 3 位 24 输出拓扑 7（三角带）、字 4 最多输出 3 个顶点；片元：字 18 = 渲染目标 0 的 RGBA
            byte[] vs = Guest(1 | (3 << 5) | (1 << 10), 0, 0, 0, 0, AstAttr0X, Exit);
            byte[] gs = Guest(1 | (3 << 5) | (4 << 10) | (1u << 24), 1u << 24, 7u << 24, 3, 0, Exit);
            byte[] fs = Guest(2 | (3 << 5) | (5 << 10), 0, 0, 0, 0xF, Exit);
            GuestCodeAndCbData?[] g = { null, new GuestCodeAndCbData(vs, Array.Empty<byte>()), null, null, new GuestCodeAndCbData(gs, Array.Empty<byte>()), new GuestCodeAndCbData(fs, Array.Empty<byte>()) };

            int invalid = 0;
            void OnLog(object o, Ryujinx.Common.Logging.LogEventArgs e)
            {
                if (e.Message.Contains("Invalid input") || e.Message.Contains("Invalid output")) System.Threading.Interlocked.Increment(ref invalid);
            }
            Ryujinx.Common.Logging.Logger.Updated += OnLog;
            try
            {
                GpuContext ctx = ShaderBake.MakeContext(out _);
                GpuChannelGraphicsState st = default;
                st.Topology = PrimitiveTopology.Triangles;   // 几何输入图元三角形 = 每图元 3 个输入顶点
                ShaderSpecializationState spec = new(ref st, null, null);
                ShaderSpecializationState newSpec = new(ref st, null, null);
                ResourceCounts counts = new();
                DiskCacheGpuAccessor[] acc = new DiskCacheGpuAccessor[5];
                TranslatorContext[] tcs = new TranslatorContext[6];
                TranslatorContext next = null;
                for (int si = 4; si >= 0; si--)
                {
                    if (!g[si + 1].HasValue) continue;
                    acc[si] = new DiskCacheGpuAccessor(ctx, g[si + 1].Value.Code, g[si + 1].Value.Cb1Data, spec, newSpec, counts, si, true);
                    TranslatorContext cur = ShaderCache.DecodeGraphicsShader(acc[si], ctx.Capabilities.Api, ShaderCache.DefaultFlags, 0);
                    if (next != null) cur.SetNextStage(next);
                    tcs[si + 1] = cur; next = cur;
                }
                Ck(S2AVtg.IsVtg(ctx, tcs), "直通几何：后端无几何着色器，走转计算");
                S2AVtg.Translation t = S2AVtg.Translate(ctx, tcs, acc, g, false);
                Ck(invalid == 0, $"直通几何：转计算翻译零条 Invalid input / output（旧口径 744），实得 {invalid}");
                int loc = t.GeometryCompute != null ? SpvLocations(t.GeometryCompute.BinaryCode) : -1;
                Ck(loc == 0, $"直通几何：几何计算核 Location 修饰 0 个（不留 Input / Output 变量；旧口径 62），实得 {loc}");
                ResourceReservations gr = t.GeometryReservations;
                Ck(gr != null && gr.InputSizePerInvocation == 9 && gr.OutputSizePerInvocation == 133,
                    $"直通几何：几何每顶点输入 9 字、输出 133 字（旧口径输出 9），实得 {gr?.InputSizePerInvocation} / {gr?.OutputSizePerInvocation}");
                Ck(t.VertexReservations?.OutputSizePerInvocation == 9, $"直通几何：顶点每顶点输出 9 字（位置 4 + 点大小 1 + 位置 0 的 4；顶点不因直通多写），实得 {t.VertexReservations?.OutputSizePerInvocation}");
                int ptLoc = t.GraphicsStages.Count > 0 ? SpvLocations(t.GraphicsStages[0].BinaryCode) : -1;
                Ck(ptLoc == 32, $"直通几何：直通顶点输出 32 个位置（旧口径 1），实得 {ptLoc}");
            }
            catch (Exception e) { Ck(false, $"直通几何：抛异常 {e.GetType().Name}: {e.Message}"); }
            finally { Ryujinx.Common.Logging.Logger.Updated -= OnLog; }
        }

        // ⑥ 顶点写层属性（AST a[0x64]，AttributeConsts.Layer 是 Shader 程序集内部常量、这里写字面值）+ 片元、无客体几何 —— Z-A 程序形状。
        //    三种宿主能力组合各跑一遍 S2AVtg.Translate（与 GetGraphicsShader / 加载器 / 烘焙同一追加判定的转计算实现）：
        //    {无几何, 无顶点层输出}：不得产出硬件几何阶段——明确拒建（抛异常）或走合法通路；修前这里把直通几何塞进图形阶段（必红）。
        //    {有几何, 无顶点层输出}：直通几何是合法通路，照旧补（行为不变的对照）。
        //    {无几何, 有顶点层输出}：顶点自己写层，不补几何（对照）。
        static void LayerRoute()
        {
            ulong astLayer = (AstAttr0X & ~(0x7ffUL << 20)) | (0x64UL << 20);   // AST 属性索引字段在位 20–30（11 位）
            byte[] vs = Guest(1 | (3 << 5) | (1 << 10), 0, 0, 0, 0, AstAttr0X, astLayer, Exit);
            byte[] fs = Guest(2 | (3 << 5) | (5 << 10), 0, 0, 0, 0xF, Exit);
            GuestCodeAndCbData?[] g = { null, new GuestCodeAndCbData(vs, Array.Empty<byte>()), null, null, null, new GuestCodeAndCbData(fs, Array.Empty<byte>()) };

            (bool gs, bool layerVt, string name)[] cases =
            {
                (false, false, "无几何 + 无顶点层输出（9000 Mali）"),
                (true, false, "有几何 + 无顶点层输出（直通几何合法）"),
                (false, true, "无几何 + 有顶点层输出（顶点直接写层）"),
            };

            foreach ((bool gs, bool layerVt, string name) in cases)
            {
                GpuContext ctx = ShaderBake.MakeContext(LayerCaps(gs, layerVt));
                GpuChannelGraphicsState st = default;
                st.Topology = PrimitiveTopology.Triangles;
                ShaderSpecializationState spec = new(ref st, null, null);
                ShaderSpecializationState newSpec = new(ref st, null, null);
                ResourceCounts counts = new();
                DiskCacheGpuAccessor[] acc = new DiskCacheGpuAccessor[5];
                TranslatorContext[] tcs = new TranslatorContext[6];
                TranslatorContext next = null;
                for (int si = 4; si >= 0; si--)
                {
                    if (!g[si + 1].HasValue) continue;
                    acc[si] = new DiskCacheGpuAccessor(ctx, g[si + 1].Value.Code, g[si + 1].Value.Cb1Data, spec, newSpec, counts, si, false);
                    TranslatorContext cur = ShaderCache.DecodeGraphicsShader(acc[si], ctx.Capabilities.Api, ShaderCache.DefaultFlags, 0);
                    if (next != null) cur.SetNextStage(next);
                    tcs[si + 1] = cur; next = cur;
                }
                System.Collections.Generic.List<ShaderProgram> stages = null;
                bool rejected = false;
                string rejection = null;
                try { stages = S2AVtg.Translate(ctx, tcs, acc, g, false).GraphicsStages; }
                catch (Exception e) when (e is InvalidOperationException || e is NotSupportedException) { rejected = true; rejection = e.Message; }

                // LayerOutputWritten 在翻译发射期置位（解码时不置）：宿主认顶点写层→顶点自己写 gl_Layer（false）；
                // 不认→走私标记（true），即便走私分不到空自定义属性也置位（追加判定只认这个标记）
                Ck(tcs[1] != null && tcs[1].LayerOutputWritten == !layerVt, $"层输出通路（{name}）：顶点层写按宿主能力{(layerVt ? "原生" : "走私")}落地");

                bool hasHwGs = stages != null && stages.Any(p => p.Info.Stage == ShaderStage.Geometry);
                if (!gs && !layerVt)
                {
                    Ck(rejected && !hasHwGs && rejection != null && rejection.Contains("no legal route"),
                        $"层输出通路（{name}）：必须明确拒建且不产出硬件几何阶段；异常={rejection ?? "无"}");
                }
                else if (gs && !layerVt)
                {
                    Ck(!rejected && hasHwGs, $"层输出通路（{name}）：仍补硬件直通几何（合法通路，行为不变）；异常={rejection ?? "无"}");
                }
                else
                {
                    Ck(!rejected && !hasHwGs, $"层输出通路（{name}）：顶点直接写层，不补几何；异常={rejection ?? "无"}");
                }
            }
        }

        // 照 NxCaps.Build 的能力表翻三位：几何着色器 / 顶点层输出（视口位随层位，发射器用合并能力，两个位同授权口径）
        static Capabilities LayerCaps(bool gs, bool layerVt)
        {
            Capabilities c = NxGal.NxCaps.Build(new ulong[] { 0, 32 * 1024 });
            return new Capabilities(
                api: c.Api, vendorName: c.VendorName, memoryType: c.MemoryType,
                hasFrontFacingBug: c.HasFrontFacingBug, hasVectorIndexingBug: c.HasVectorIndexingBug,
                needsFragmentOutputSpecialization: c.NeedsFragmentOutputSpecialization, reduceShaderPrecision: c.ReduceShaderPrecision,
                supportsAstcCompression: c.SupportsAstcCompression, supportsBc123Compression: c.SupportsBc123Compression,
                supportsBc45Compression: c.SupportsBc45Compression, supportsBc67Compression: c.SupportsBc67Compression,
                supportsEtc2Compression: c.SupportsEtc2Compression, supports3DTextureCompression: c.Supports3DTextureCompression,
                supportsBgraFormat: c.SupportsBgraFormat, supportsR4G4Format: c.SupportsR4G4Format,
                supportsR4G4B4A4Format: c.SupportsR4G4B4A4Format, supportsScaledVertexFormats: c.SupportsScaledVertexFormats,
                supportsSnormBufferTextureFormat: c.SupportsSnormBufferTextureFormat, supports5BitComponentFormat: c.Supports5BitComponentFormat,
                supportsSparseBuffer: c.SupportsSparseBuffer, supportsBlendEquationAdvanced: c.SupportsBlendEquationAdvanced,
                supportsFragmentShaderInterlock: c.SupportsFragmentShaderInterlock,
                supportsFragmentShaderOrderingIntel: c.SupportsFragmentShaderOrderingIntel,
                supportsGeometryShader: gs, supportsGeometryShaderPassthrough: c.SupportsGeometryShaderPassthrough,
                supportsTransformFeedback: c.SupportsTransformFeedback, supportsImageLoadFormatted: c.SupportsImageLoadFormatted,
                supportsLayerVertexTessellation: layerVt, supportsMismatchingViewFormat: c.SupportsMismatchingViewFormat,
                supportsCubemapView: c.SupportsCubemapView, supportsNonConstantTextureOffset: c.SupportsNonConstantTextureOffset,
                supportsQuads: c.SupportsQuads, supportsSeparateSampler: c.SupportsSeparateSampler,
                supportsShaderBallot: c.SupportsShaderBallot, supportsShaderBarrierDivergence: c.SupportsShaderBarrierDivergence,
                supportsShaderFloat64: c.SupportsShaderFloat64, supportsShaderNonUniformIndexing: c.SupportsShaderNonUniformIndexing,
                supportsTextureGatherOffsets: c.SupportsTextureGatherOffsets, supportsTextureShadowLod: c.SupportsTextureShadowLod,
                supportsVertexStoreAndAtomics: c.SupportsVertexStoreAndAtomics,
                supportsViewportIndexVertexTessellation: layerVt, supportsViewportMask: c.SupportsViewportMask,
                supportsViewportSwizzle: c.SupportsViewportSwizzle, supportsIndirectParameters: c.SupportsIndirectParameters,
                supportsDepthClipControl: c.SupportsDepthClipControl,
                uniformBufferSetIndex: c.UniformBufferSetIndex, storageBufferSetIndex: c.StorageBufferSetIndex,
                textureSetIndex: c.TextureSetIndex, imageSetIndex: c.ImageSetIndex,
                extraSetBaseIndex: c.ExtraSetBaseIndex, maximumExtraSets: c.MaximumExtraSets,
                maximumUniformBuffersPerStage: c.MaximumUniformBuffersPerStage, maximumStorageBuffersPerStage: c.MaximumStorageBuffersPerStage,
                maximumTexturesPerStage: c.MaximumTexturesPerStage, maximumImagesPerStage: c.MaximumImagesPerStage,
                maximumComputeSharedMemorySize: c.MaximumComputeSharedMemorySize,
                maximumSupportedAnisotropy: c.MaximumSupportedAnisotropy, shaderSubgroupSize: c.ShaderSubgroupSize,
                storageBufferOffsetAlignment: c.StorageBufferOffsetAlignment, textureBufferOffsetAlignment: c.TextureBufferOffsetAlignment,
                gatherBiasPrecision: c.GatherBiasPrecision, maximumGpuMemory: c.MaximumGpuMemory,
                s2aVertexPull: c.S2AVertexPull, requiresLinkedVaryingInterface: c.RequiresLinkedVaryingInterface,
                maximumVertexOutputComponents: c.MaximumVertexOutputComponents, maximumFragmentInputComponents: c.MaximumFragmentInputComponents,
                unsupportedUniformTexelBufferFormats: c.UnsupportedUniformTexelBufferFormats,
                supportsImageStoreFormatted: c.SupportsImageStoreFormatted,
                s2aSpirv15: c.S2ASpirv15, s2aSpirvLayerExt: c.S2ASpirvLayerExt, s2aSpirvLayerNv: c.S2ASpirvLayerNv);
        }

        public static int Run()
        {
            // ① 输出：位置 4 + 点大小 1 + 裁剪距离 0、1 各 1 + 层号 1 + 自定义位置 0、2 各 4 = 16 字；输入：位置 4 + 点大小 1 + 位置 0 的 4 = 9 字
            byte[] rb = ResBytes(false, true, 0, 0b11, 0, 0b1, (uint)FeatureFlags.RtLayer, 0b101);
            ResourceReservations r = ResourceReservations.S2ARead(rb);
            Ck(r != null, "保留布局：手拼字节能重建");
            Ck(r.OutputSizePerInvocation == 16 && r.OutputSizeInBytesPerInvocation == 64, $"保留布局：每顶点输出 16 字 / 64 字节（实得 {r.OutputSizePerInvocation} / {r.OutputSizeInBytesPerInvocation}）");
            Ck(r.InputSizePerInvocation == 9, $"保留布局：每顶点输入 9 字（实得 {r.InputSizePerInvocation}）");
            // 绑定：常量缓冲 0 = 支持缓冲、1 = 顶点信息；存储缓冲 0 / 1 / 2 = 顶点输出 / 几何顶点 / 几何索引；贴图 0 = 索引、1 = 拓扑重排、2 起 = 顶点属性（属性 3 → 5），共 2 + 32 = 34
            Ck(r.VertexInfoConstantBufferBinding == 1 && r.ReservedConstantBuffers == 2, "保留布局：顶点信息常量缓冲绑定 1、保留常量缓冲 2");
            Ck(r.VertexOutputStorageBufferBinding == 0 && r.GeometryVertexOutputStorageBufferBinding == 1 && r.GeometryIndexOutputStorageBufferBinding == 2 && r.ReservedStorageBuffers == 3, "保留布局：存储缓冲 0 / 1 / 2、共 3");
            Ck(r.IndexBufferTextureBinding == 0 && r.TopologyRemapBufferTextureBinding == 1 && r.GetVertexBufferTextureBinding(3) == 5 && r.ReservedTextures == 34, "保留布局：贴图 0 / 1、属性 3 → 5、共 34");
            byte[] wb = new byte[ResourceReservations.S2ASerializedSize]; r.S2AWrite(wb);
            Ck(wb.SequenceEqual(rb), "保留布局：写回逐字节相同");
            ResourceReservations rt = ResourceReservations.S2ARead(ResBytes(true, false, 0, 0, 0, 0, 0, 0));
            // 变换反馈模拟占存储缓冲 0–3，顶点输出移到 4；无输入用法 → 输入 0 字；输出只有位置 4 + 点大小 1 = 5 字
            Ck(rt.VertexOutputStorageBufferBinding == 4 && rt.ReservedStorageBuffers == 7 && rt.InputSizePerInvocation == 0 && rt.OutputSizePerInvocation == 5,
                $"保留布局（变换反馈模拟、无输入）：顶点输出绑定 4、存储缓冲 7、输入 0 字、输出 5 字（实得 {rt.VertexOutputStorageBufferBinding} / {rt.ReservedStorageBuffers} / {rt.InputSizePerInvocation} / {rt.OutputSizePerInvocation}）");
            Ck(ResourceReservations.S2ARead(new byte[ResourceReservations.S2ASerializedSize]) == null, "保留布局：版本 0 拒读");

            // ②
            ShaderProgramInfo pt = new(new[] { new BufferDescriptor(0, 1, 1) }, new[] { new BufferDescriptor(1, 0, 0) }, Array.Empty<TextureDescriptor>(), Array.Empty<TextureDescriptor>(),
                ShaderStage.Vertex, 0, 0, 0, false, true, false, true, 0b101, -1);
            byte[] g = { 1, 2, 3 }, v = { 4, 5, 6, 7 }, s = { 8, 9 };
            byte[] pk = S2AVtg.Pack(true, g, v, r, s, rt, pt);
            S2AVtg.Unpacked u = S2AVtg.Unpack(pk);
            Ck(S2AVtg.IsPacked(pk) && u != null, "复合二进制：认得出、拆得开");
            Ck(u.TfEnabled && u.Graphics.SequenceEqual(g) && u.Vertex.SequenceEqual(v) && u.Geometry.SequenceEqual(s), "复合二进制：标志与三段字节原样");
            byte[] a = new byte[20], c = new byte[20]; u.VertexReservations.S2AWrite(a); u.GeometryReservations.S2AWrite(c);
            Ck(a.SequenceEqual(rb) && c.SequenceEqual(ResBytes(true, false, 0, 0, 0, 0, 0, 0)), "复合二进制：两份保留布局原样");
            ShaderProgramInfo q = u.PassthroughInfo;
            Ck(q.Stage == ShaderStage.Vertex && q.CBuffers.Count == 1 && q.CBuffers[0].Binding == 1 && q.SBuffers.Count == 1 && q.UsesInstanceId && q.UsesRtLayer && q.ClipDistancesWritten == 0b101 && q.FragmentOutputMap == -1,
                "复合二进制：直通顶点信息原样");
            S2AVtg.Unpacked u2 = S2AVtg.Unpack(S2AVtg.Pack(false, g, v, r, null, null, pt));
            Ck(u2 != null && u2.Geometry == null && u2.GeometryReservations == null && !u2.TfEnabled, "复合二进制：无几何段");
            byte[] bad = (byte[])pk.Clone(); bad[0] ^= 1;
            Ck(!S2AVtg.IsPacked(bad) && S2AVtg.Unpack(bad) == null && S2AVtg.Unpack(pk[..(pk.Length - 3)]) == null && !S2AVtg.IsPacked(new byte[] { 0x47, 0x41, 0x4c, 0x50, 1, 0, 0, 0, 0, 0, 0, 0 }),
                "复合二进制：坏魔数 / 截断 / 普通 GALP 不认");
            // ②b 后端不给二进制（最小布局 / VKPB v1 不支持的阶段集合会返回 null）：打包返回 null，不空引用；GetBinary 任一段为空也返回 null。
            Ck(S2AVtg.Pack(true, null, v, r, null, null, pt) == null, "复合二进制：图形段为空不打包");
            Ck(S2AVtg.Pack(true, g, null, r, null, null, pt) == null, "复合二进制：顶点计算段为空不打包");
            Ck(S2AVtg.Pack(true, g, v, null, null, null, pt) == null, "复合二进制：顶点保留布局为空不打包");
            Ck(S2AVtg.Pack(true, g, v, r, s, null, pt) == null, "复合二进制：几何段在、保留布局为空不打包");
            ShaderProgramInfo ci = new(Array.Empty<BufferDescriptor>(), Array.Empty<BufferDescriptor>(), Array.Empty<TextureDescriptor>(), Array.Empty<TextureDescriptor>(),
                ShaderStage.Compute, 0, 0, 0, false, false, false, false, 0, -1);
            byte[] code1 = { 1 }, code2 = { 2 }, code3 = { 3 };
            CachedShaderStage[] stages = { null, new(ci, code1, Array.Empty<byte>()), null, null, new(ci, code2, Array.Empty<byte>()), new(pt, code3, Array.Empty<byte>()) };
            var gss = default(GpuChannelGraphicsState);
            var spec2 = new ShaderSpecializationState(ref gss, null, null);
            var okVertex = new ShaderAsCompute(DispatchProxy.Create<IProgram, FakeProgram>(), ci, r);
            var nullGeom = new ShaderAsCompute(DispatchProxy.Create<IProgram, NullBinaryProgram>(), ci, r);
            var vtgNullGeom = new CachedShaderProgram(DispatchProxy.Create<IProgram, FakeProgram>(), okVertex, nullGeom, spec2, stages);
            string geomLog = CaptureError(() => Ck(S2AVtg.GetBinary(vtgNullGeom) == null,
                "复合二进制：几何段 GetBinary 为空时整条不落盘（不打出缺几何段的记录）"));
            Ck(geomLog.Contains("【红】") && geomLog.Contains("几何计算"), "复合二进制：几何段为空报红并点名几何计算");
            Ck(geomLog.Split("【红】").Length == 2, "复合二进制：空二进制红行每进程只打一次");

            var nullVertex = new ShaderAsCompute(DispatchProxy.Create<IProgram, NullBinaryProgram>(), ci, r);
            var vtgNull = new CachedShaderProgram(DispatchProxy.Create<IProgram, FakeProgram>(), nullVertex, (ShaderAsCompute)null, spec2, stages);
            string vertexLog = CaptureError(() => Ck(S2AVtg.GetBinary(vtgNull) == null,
                "复合二进制：顶点计算段 GetBinary 为空时 GetBinary 返回 null"));
            Ck(!vertexLog.Contains("【红】"), "复合二进制：空二进制红行不重复打印");

            // ③
            string dir = Path.Combine(Path.GetTempPath(), "s2a_vtg_" + Environment.ProcessId);
            if (Directory.Exists(dir)) Directory.Delete(dir, true);
            try
            {
                GpuContext ctx = ShaderBake.MakeContext(out _);   // 与烘焙同一个上下文（只取能力表，不建 Metal 设备）
                ShaderProgramInfo Ci() => new(Array.Empty<BufferDescriptor>(), Array.Empty<BufferDescriptor>(), Array.Empty<TextureDescriptor>(), Array.Empty<TextureDescriptor>(), ShaderStage.Compute, 0, 0, 0, false, false, false, false, 0, -1);
                ShaderProgramInfo Fi = new(Array.Empty<BufferDescriptor>(), Array.Empty<BufferDescriptor>(), Array.Empty<TextureDescriptor>(), Array.Empty<TextureDescriptor>(), ShaderStage.Fragment, 0, 0, 0, false, false, false, false, 0, 1);
                byte[] cv = Enumerable.Range(0, 64).Select(i => (byte)i).ToArray(), cg = Enumerable.Range(0, 64).Select(i => (byte)(i + 100)).ToArray(), cf = Enumerable.Range(0, 64).Select(i => (byte)(255 - i)).ToArray();
                CachedShaderStage[] st = { null, new(Ci(), cv, Array.Empty<byte>()), null, null, new(Ci(), cg, Array.Empty<byte>()), new(Fi, cf, Array.Empty<byte>()) };
                GpuChannelGraphicsState gs = default;
                ShaderSpecializationState spec = new(ref gs, null, null);
                DiskCacheHostStorage hs = new(dir);
                hs.AddShader(ctx, new CachedShaderProgram(null, spec, st), pk);
                using (FileStream toc = File.OpenRead(Path.Combine(dir, "shared.toc")), dat = File.OpenRead(Path.Combine(dir, "shared.data")))
                {
                    toc.Seek(32, SeekOrigin.Begin); BinarySerializer tr = new(toc), dr = new(dat); ulong off = 0; tr.Read(ref off);
                    dat.Seek((long)off, SeekOrigin.Begin); dr.BeginCompression(); uint mask = 0; dr.Read(ref mask); dr.EndCompression();
                    Ck(mask == 50, $"磁盘缓存：阶段掩码 = 50（顶点 2 + 几何 16 + 片元 32；上游口径只剩 32），实得 {mask}");
                }
                System.Collections.Generic.List<GuestCodeAndCbData?[]> back;
                try { back = ShaderBake.S2AReadCacheForTest(dir); } catch (Exception e) { Ck(false, $"磁盘缓存：读回抛异常 {e.GetType().Name}: {e.Message}"); back = new(); }
                Ck(back.Count == 1 && back[0].Length == 6 && back[0][1]?.Code.SequenceEqual(cv) == true && back[0][4]?.Code.SequenceEqual(cg) == true && back[0][5]?.Code.SequenceEqual(cf) == true,
                    "磁盘缓存：读回顶点 / 几何 / 片元客体代码各归其位");
            }
            finally { if (Directory.Exists(dir)) Directory.Delete(dir, true); }

            // ④ 按需实化（补丁 shader-cache-lazy：开局只登记、首次查找时从缓存读出建宿主程序）：转计算程序要按复合二进制建三个宿主程序、不翻译。
            //    渲染器用代理（只记 LoadProgramBinary / CreateProgram 调用，其余成员返回缺省值），写一个转计算程序进临时缓存，再按开局登记的口径实化。
            //    反证：按需实化不认复合二进制时整段交给 LoadProgramBinary 一次、程序没有顶点 / 几何计算段（本项必红）
            string dir2 = Path.Combine(Path.GetTempPath(), "s2a_vtg_lazy_" + Environment.ProcessId);
            if (Directory.Exists(dir2)) Directory.Delete(dir2, true);
            try
            {
                GpuContext baseCtx = ShaderBake.MakeContext(out Capabilities caps);
                FakeRenderer fr = System.Reflection.DispatchProxy.Create<IRenderer, FakeRenderer>() as FakeRenderer;
                fr.Caps = caps;
                GpuContext ctx2 = new((IRenderer)(object)fr, new Ryujinx.Common.Configuration.DirtyHacks(Array.Empty<ulong>())) { Capabilities = caps };
                ShaderProgramInfo Ci2() => new(Array.Empty<BufferDescriptor>(), Array.Empty<BufferDescriptor>(), Array.Empty<TextureDescriptor>(), Array.Empty<TextureDescriptor>(), ShaderStage.Compute, 3, 4, 1, false, false, false, false, 0, -1);
                ShaderProgramInfo Fi2 = new(Array.Empty<BufferDescriptor>(), Array.Empty<BufferDescriptor>(), Array.Empty<TextureDescriptor>(), Array.Empty<TextureDescriptor>(), ShaderStage.Fragment, 0, 0, 0, false, false, false, false, 0, 1);
                byte[] cv2 = Enumerable.Range(0, 64).Select(i => (byte)(i * 3)).ToArray(), cg2 = Enumerable.Range(0, 64).Select(i => (byte)(i * 5)).ToArray(), cf2 = Enumerable.Range(0, 64).Select(i => (byte)(i * 7)).ToArray();
                CachedShaderStage[] st2 = { null, new(Ci2(), cv2, Array.Empty<byte>()), null, null, new(Ci2(), cg2, Array.Empty<byte>()), new(Fi2, cf2, Array.Empty<byte>()) };
                GpuChannelGraphicsState gs2 = default;
                DiskCacheHostStorage hs2 = new(dir2);
                hs2.AddShader(ctx2, new CachedShaderProgram(null, new ShaderSpecializationState(ref gs2, null, null), st2), pk);
                byte[] toc = File.ReadAllBytes(Path.Combine(dir2, "shared.toc"));
                ulong ts = BinaryPrimitives.ReadUInt64LittleEndian(toc.AsSpan(16)), off = BinaryPrimitives.ReadUInt64LittleEndian(toc.AsSpan(32));
                GuestCodeAndCbData?[] gg = { null, new GuestCodeAndCbData(cv2, Array.Empty<byte>()), null, null, new GuestCodeAndCbData(cg2, Array.Empty<byte>()), new GuestCodeAndCbData(cf2, Array.Empty<byte>()) };
                CachedShaderProgram mp = new S2ALazyProgram(hs2, ctx2, 0, off, ts, false, hs2.S2ARegisterGuests(gg)).Materialize();
                Ck(mp != null && mp.VertexAsCompute != null && mp.GeometryAsCompute != null, "按需实化：转计算程序建出图形 + 顶点计算 + 几何计算三个宿主程序");
                Ck(fr.Loaded.Count == 3 && fr.Created == 0, $"按需实化：LoadProgramBinary 3 次、CreateProgram 0 次（不翻译），实得 {fr.Loaded.Count} / {fr.Created}");
                Ck(fr.Loaded.Count == 3 && fr.Loaded[0].SequenceEqual(g) && fr.Loaded[1].SequenceEqual(v) && fr.Loaded[2].SequenceEqual(s), "按需实化：三段二进制按图形 / 顶点 / 几何原样交给渲染器");
                byte[] a2 = new byte[20]; mp?.VertexAsCompute?.Reservations.S2AWrite(a2);
                Ck(mp != null && a2.SequenceEqual(rb) && mp.VertexAsCompute.Info.Stage == ShaderStage.Compute && mp.GeometryAsCompute.Info.GeometryMaxOutputVertices == 4 && mp.S2APassthroughInfo?.Stage == ShaderStage.Vertex,
                    "按需实化：顶点保留布局、计算段信息（几何最大输出 4）、直通顶点信息对得上");
            }
            catch (Exception e) { Ck(false, $"按需实化：抛异常 {e.GetType().Name}: {e.Message}"); }
            finally { if (Directory.Exists(dir2)) Directory.Delete(dir2, true); }

            GsPassthrough();
            LayerRoute();

            Console.WriteLine($"t_vtg：{_n} 项，失败 {_fail}");
            return _fail == 0 ? 0 : 1;
        }
    }
}
