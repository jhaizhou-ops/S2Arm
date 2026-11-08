using Ryujinx.Common;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Gpu.Shader.DiskCache;
using Ryujinx.Graphics.Shader;
using Ryujinx.Graphics.Shader.Translation;
using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.IO;
using System.Threading;

namespace Ryujinx.Graphics.Gpu.Shader
{
    /// <summary>
    /// S2A：顶点 / 几何转计算（后端不支持几何着色器或顶点阶段存储写时，Ryujinx 把它们翻成计算着色器跑，见 ShaderCache.GetGraphicsShader）的程序进磁盘缓存。
    /// 上游不缓存这类程序（写入跳过、加载器丢弃），每局首遇都要当场翻译 + 后端现编。这里补三件事：
    ///   1. 翻译：与 GetGraphicsShader 同一顺序同一调用（加载器按客体代码重建、出包烘焙 shbake 共用），得到各阶段缓存条目、顶点 / 几何计算着色器与保留布局、宿主图形程序（直通顶点 + 片元）；
    ///   2. 宿主程序二进制：一个程序有三个宿主程序（图形、顶点计算、几何计算），打成一个复合二进制（魔数 S2AV），各段是后端自己的程序二进制，另带保留布局与直通顶点的着色器信息；
    ///   3. 加载：按复合二进制分段 LoadProgramBinary，重建 ShaderAsCompute，不翻译。
    /// </summary>
    static class S2AVtg
    {
        public const uint Magic = 0x56413253;   // "S2AV"
        public const uint Version = 1;

        public sealed class Translation
        {
            public CachedShaderStage[] Shaders;
            public readonly List<ShaderProgram> GraphicsStages = new();
            public ShaderProgram VertexCompute;
            public ShaderProgram GeometryCompute;
            public ResourceReservations VertexReservations;
            public ResourceReservations GeometryReservations;
            public ShaderProgramInfo PassthroughInfo;
            public bool TfEnabled;
        }

        /// <summary>程序是否要转计算（与 GetGraphicsShader / 加载器同一判据）。tcs 按 Ryujinx 阶段下标（0 = VertexA，1 顶点 … 5 片元）。</summary>
        public static bool IsVtg(GpuContext context, TranslatorContext[] tcs)
        {
            bool hasGs = tcs[4] != null;
            bool vsStore = tcs[1] != null && tcs[1].HasStore;
            bool gsStore = hasGs && tcs[4].HasStore;

            return ShaderCache.ShouldConvertVertexToCompute(context, vsStore, gsStore, hasGs);
        }

        /// <summary>
        /// 按 GetGraphicsShader 的转计算路径翻译（调用顺序逐条对应：先设几何的顶点输出表、逐阶段 InitializeReservedCounts、顶点翻成计算后立刻取保留布局并生成直通顶点、
        /// 几何翻成计算后取保留布局）。guest：各阶段客体代码与常量段 1（下标同 tcs）。
        /// </summary>
        public static Translation Translate(GpuContext context, TranslatorContext[] tcs, GpuAccessorBase[] accessors, GuestCodeAndCbData?[] guest, bool tfEnabled)
        {
            bool hasGs = tcs[4] != null;
            bool gsStore = hasGs && tcs[4].HasStore;
            bool vertexToCompute = IsVtg(context, tcs);
            bool geometryToCompute = ShaderCache.ShouldConvertGeometryToCompute(context, gsStore);

            Translation t = new() { Shaders = new CachedShaderStage[guest.Length], TfEnabled = tfEnabled };

            if (geometryToCompute && tcs[4] != null)
            {
                tcs[4].SetVertexOutputMapForGeometryAsCompute(tcs[1]);
            }

            TranslatorContext previousStage = null;

            for (int stageIndex = 0; stageIndex < Constants.ShaderStages; stageIndex++)
            {
                TranslatorContext currentStage = tcs[stageIndex + 1];

                if (currentStage != null)
                {
                    accessors[stageIndex].InitializeReservedCounts(tfEnabled, vertexToCompute);

                    bool asCompute = (stageIndex == 0 && vertexToCompute) || (stageIndex == 3 && geometryToCompute);
                    GuestCodeAndCbData g = guest[stageIndex + 1].Value;
                    ShaderProgram program;

                    if (stageIndex == 0 && tcs[0] != null)
                    {
                        program = currentStage.Translate(tcs[0], asCompute);
                        t.Shaders[0] = new CachedShaderStage(null, guest[0].Value.Code, guest[0].Value.Cb1Data);
                        t.Shaders[1] = new CachedShaderStage(program.Info, g.Code, g.Cb1Data);
                    }
                    else
                    {
                        program = currentStage.Translate(asCompute);
                        t.Shaders[stageIndex + 1] = new CachedShaderStage(program.Info, g.Code, g.Cb1Data);
                    }

                    if (asCompute)
                    {
                        if (stageIndex == 0)
                        {
                            t.VertexCompute = program;
                            t.VertexReservations = currentStage.GetResourceReservations();

                            TranslatorContext lastInVertexPipeline = geometryToCompute ? tcs[4] ?? currentStage : currentStage;

                            program = lastInVertexPipeline.GenerateVertexPassthroughForCompute();
                            ShaderCache.S2ACheckLayerPassthrough(context, program);
                            t.PassthroughInfo = program.Info;
                        }
                        else
                        {
                            t.GeometryCompute = program;
                            t.GeometryReservations = currentStage.GetResourceReservations();
                            program = null;
                        }
                    }

                    if (program != null)
                    {
                        t.GraphicsStages.Add(program);
                    }

                    previousStage = currentStage;
                }
                else
                {
                    switch (ShaderCache.S2ALayerRouteFor(context, previousStage, stageIndex))
                    {
                        case ShaderCache.S2ALayerRoute.GeometryPassthrough:
                            S2AGsDiag.NotePassthrough("S2AVtg");   // #1456：追加点来源
                            t.GraphicsStages.Add(previousStage.GenerateGeometryPassthrough());
                            break;
                        case ShaderCache.S2ALayerRoute.Unsupported:
                            ShaderCache.S2ARejectLayerRoute();
                            break;
                    }
                }
            }

            return t;
        }

        /// <summary>按翻译结果建三个宿主程序（与 GetGraphicsShader 同一组 ShaderInfo）。</summary>
        public static CachedShaderProgram CreatePrograms(GpuContext context, Translation t, ShaderSpecializationState specState, ProgramPipelineState? pipeline, bool fromCache)
        {
            ShaderInfoBuilder infoBuilder = new(context, t.TfEnabled, vertexAsCompute: true);
            ShaderSource[] sources = new ShaderSource[t.GraphicsStages.Count];

            for (int i = 0; i < sources.Length; i++)
            {
                sources[i] = ShaderCache.CreateShaderSource(t.GraphicsStages[i]);
                infoBuilder.AddStageInfo(t.GraphicsStages[i].Info);
            }

            IProgram hostProgram = context.Renderer.CreateProgram(sources, infoBuilder.Build(pipeline, fromCache));
            ShaderAsCompute vertexAsCompute = CreateCompute(context, t.VertexCompute, t.VertexReservations, t.TfEnabled, fromCache);
            ShaderAsCompute geometryAsCompute = t.GeometryCompute != null ? CreateCompute(context, t.GeometryCompute, t.GeometryReservations, t.TfEnabled, fromCache) : null;

            return new CachedShaderProgram(hostProgram, vertexAsCompute, geometryAsCompute, specState, t.Shaders) { S2APassthroughInfo = t.PassthroughInfo };
        }

        private static ShaderAsCompute CreateCompute(GpuContext context, ShaderProgram program, ResourceReservations reservations, bool tfEnabled, bool fromCache)
        {
            ShaderSource source = new(program.Code, program.BinaryCode, ShaderStage.Compute, program.Language);
            ShaderInfo info = ShaderInfoBuilder.BuildForVertexAsCompute(context, program.Info, tfEnabled, fromCache);

            return new ShaderAsCompute(context.Renderer.CreateProgram([source], info), program.Info, reservations);
        }

        /// <summary>
        /// 复合宿主二进制（小端）：u32 魔数 "S2AV"、u32 版本、u32 标志（位 0 变换反馈、位 1 有几何计算段），
        /// 图形段 {u32 长, 后端程序二进制}、顶点计算段 {u32 长, 后端程序二进制, 保留布局 ResourceReservations.S2ASerializedSize 字节}、
        /// [几何计算段 同上]、{u32 长, 直通顶点着色器信息（DiskCacheHostStorage 着色器信息同格式）}。
        /// </summary>
        public static byte[] Pack(bool tfEnabled, byte[] graphics, byte[] vertex, ResourceReservations vertexReservations, byte[] geometry, ResourceReservations geometryReservations, ShaderProgramInfo passthroughInfo)
        {
            // 后端可以合法地不给宿主二进制（最小布局 / 阶段集合在 VKPB v1 之外）：
            // 这时不存这条记录，返回 null；不能在 Pack 里取 Length / S2AWrite 空引用。
            if (graphics == null || vertex == null || vertexReservations == null ||
                (geometry != null && geometryReservations == null))
            {
                return null;
            }

            using MemoryStream infoStream = new();
            BinarySerializer infoWriter = new(infoStream);
            DiskCacheHostStorage.S2AWriteShaderProgramInfo(ref infoWriter, passthroughInfo);
            byte[] info = infoStream.ToArray();

            using MemoryStream ms = new();
            using BinaryWriter w = new(ms);
            w.Write(Magic);
            w.Write(Version);
            w.Write((tfEnabled ? 1u : 0u) | (geometry != null ? 2u : 0u));
            w.Write(graphics.Length);
            w.Write(graphics);
            WritePart(w, vertex, vertexReservations);

            if (geometry != null)
            {
                WritePart(w, geometry, geometryReservations);
            }

            w.Write(info.Length);
            w.Write(info);
            w.Flush();

            return ms.ToArray();
        }

        private static void WritePart(BinaryWriter w, byte[] code, ResourceReservations reservations)
        {
            Span<byte> r = stackalloc byte[ResourceReservations.S2ASerializedSize];
            reservations.S2AWrite(r);
            w.Write(code.Length);
            w.Write(code);
            w.Write(r);
        }

        public static bool IsPacked(ReadOnlySpan<byte> hostCode) => hostCode.Length >= 12 && BinaryPrimitives.ReadUInt32LittleEndian(hostCode) == Magic;

        public sealed class Unpacked
        {
            public bool TfEnabled;
            public byte[] Graphics;
            public byte[] Vertex;
            public ResourceReservations VertexReservations;
            public byte[] Geometry;
            public ResourceReservations GeometryReservations;
            public ShaderProgramInfo PassthroughInfo;
        }

        /// <summary>拆复合二进制；格式坏或版本不符返回 null。</summary>
        public static Unpacked Unpack(byte[] hostCode)
        {
            try
            {
                using MemoryStream ms = new(hostCode, writable: false);
                using BinaryReader r = new(ms);

                if (r.ReadUInt32() != Magic || r.ReadUInt32() != Version)
                {
                    return null;
                }

                uint flags = r.ReadUInt32();
                Unpacked u = new() { TfEnabled = (flags & 1) != 0 };
                u.Graphics = ReadExact(r);
                (u.Vertex, u.VertexReservations) = ReadPart(r);

                if ((flags & 2) != 0)
                {
                    (u.Geometry, u.GeometryReservations) = ReadPart(r);
                }

                // 着色器信息的读法（BinarySerializer）遇流尾会死等：长度先核对，截断的复合二进制在这里就拒掉
                byte[] info = ReadExact(r);

                if (info == null || u.Graphics == null || u.Vertex == null || ((flags & 2) != 0 && u.Geometry == null) || info.Length < 8 || ms.Position != ms.Length)
                {
                    return null;
                }

                using MemoryStream infoStream = new(info, writable: false);
                BinarySerializer infoReader = new(infoStream);
                u.PassthroughInfo = DiskCacheHostStorage.S2AReadShaderProgramInfo(ref infoReader);

                return u.VertexReservations != null && (u.Geometry == null || u.GeometryReservations != null) && infoStream.Position == infoStream.Length ? u : null;
            }
            catch (Exception e) when (e is EndOfStreamException || e is IOException || e is ArgumentException || e is DiskCacheLoadException)
            {
                return null;
            }
        }

        // 读「u32 长 + 字节」：长度为负或剩余字节不够返回 null
        private static byte[] ReadExact(BinaryReader r)
        {
            int n = r.ReadInt32();

            if (n < 0 || n > r.BaseStream.Length - r.BaseStream.Position)
            {
                return null;
            }

            return r.ReadBytes(n);
        }

        private static (byte[], ResourceReservations) ReadPart(BinaryReader r)
        {
            byte[] code = ReadExact(r);

            if (code == null)
            {
                return (null, null);
            }

            byte[] res = r.ReadBytes(ResourceReservations.S2ASerializedSize);

            return (code, ResourceReservations.S2ARead(res));
        }

        /// <summary>
        /// 按复合二进制建三个宿主程序（不翻译）。shaders：各阶段缓存条目（ReadHostCode 读出，顶点 / 几何的着色器信息就是它们计算版的信息，与运行时同一对象口径）。
        /// </summary>
        public static CachedShaderProgram Load(GpuContext context, Unpacked u, CachedShaderStage[] shaders, ShaderSpecializationState specState)
        {
            // 三段都是渲染器程序二进制，资源布局在二进制里，载入不读 ShaderInfo（DiskCacheHostStorage.S2AHostBinaryInfo）
            ShaderInfo none = DiskCacheHostStorage.S2AHostBinaryInfo;
            bool hasFragmentShader = shaders.Length > 5 && shaders[5] != null;
            IProgram hostProgram = context.Renderer.LoadProgramBinary(u.Graphics, hasFragmentShader, none);

            if (hostProgram is IProgramBinaryLoadFailure { ProgramBinaryLoadFailure: not null })
            {
                hostProgram.Dispose();
                return null;
            }

            ShaderProgramInfo vertexInfo = shaders[1].Info;
            IProgram vertexHost = context.Renderer.LoadProgramBinary(u.Vertex, false, none);

            if (vertexHost is IProgramBinaryLoadFailure { ProgramBinaryLoadFailure: not null })
            {
                hostProgram.Dispose();
                vertexHost.Dispose();
                return null;
            }

            ShaderAsCompute vertexAsCompute = new(vertexHost, vertexInfo, u.VertexReservations);
            ShaderAsCompute geometryAsCompute = null;

            if (u.Geometry != null)
            {
                ShaderProgramInfo geometryInfo = shaders[4].Info;
                IProgram geometryHost = context.Renderer.LoadProgramBinary(u.Geometry, false, none);

                if (geometryHost is IProgramBinaryLoadFailure { ProgramBinaryLoadFailure: not null })
                {
                    hostProgram.Dispose();
                    vertexHost.Dispose();
                    geometryHost.Dispose();
                    return null;
                }

                geometryAsCompute = new(geometryHost, geometryInfo, u.GeometryReservations);
            }

            return new CachedShaderProgram(hostProgram, vertexAsCompute, geometryAsCompute, specState, shaders) { S2APassthroughInfo = u.PassthroughInfo };
        }

        private static int _runtimeN;

        /// <summary>
        /// 运行时当场翻译出一个转计算程序（缓存 / 离线包没覆盖到）：打一行点名各阶段客体代码指纹（SHA-256 前 16 位，同 shbake dump），前 32 个。
        /// 出包配对规则漏的哪支、实际配的是哪几支，局日志里直接查（grep「转计算程序当场翻译」）
        /// </summary>
        public static void NoteRuntime(CachedShaderStage[] shaders)
        {
            int n = System.Threading.Interlocked.Increment(ref _runtimeN);

            if (n > 32)
            {
                return;
            }

            string[] names = { "vs_a", "vs", "tcs", "tes", "gs", "fs" };
            System.Text.StringBuilder sb = new();

            for (int i = 0; i < shaders.Length && i < names.Length; i++)
            {
                if (shaders[i] != null)
                {
                    sb.Append(' ').Append(names[i]).Append('=').Append(Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(shaders[i].Code))[..16].ToLowerInvariant());
                }
            }

            Console.Error.WriteLine($"[gal] 转计算程序当场翻译 #{n}：{sb}");
        }

        // S2A：多线程渲染器的程序取渲染线程编完时顺手取好的二进制，不发命令等渲染线程（ThreadedRenderer.S2ABinary）
        private static byte[] Bin(IProgram program) => Ryujinx.Graphics.GAL.Multithreading.ThreadedRenderer.S2ABinary(program);

        private static int _s2aNullBinaryRed;

        // 空宿主二进制会悄悄少一条缓存记录（下次开机现编），每个进程只报一次并点名缺哪段。
        private static void S2ANullBinaryRed(string detail)
        {
            if (Interlocked.Exchange(ref _s2aNullBinaryRed, 1) == 0)
            {
                Console.Error.WriteLine($"[gal] 【红】转计算程序宿主二进制缺失（{detail}），本条不落盘");
            }
        }

        /// <summary>程序的宿主二进制：转计算程序 = 复合二进制（三个宿主程序各取 GetBinary）；其余 = 宿主程序 GetBinary。</summary>
        public static byte[] GetBinary(CachedShaderProgram program)
        {
            if (program.VertexAsCompute == null)
            {
                return Bin(program.HostProgram);
            }

            byte[] graphics = Bin(program.HostProgram);
            byte[] vertex = Bin(program.VertexAsCompute.HostProgram);
            byte[] geometry = program.GeometryAsCompute == null ? null : Bin(program.GeometryAsCompute.HostProgram);

            // 任一段后端不给二进制（Vulkan 的 GetBinary 在不能落盘时返回 null）：整条记录跳过，
            // 与非转计算程序的 null 语义一致；不能再送进 Pack 空引用。
            if (graphics == null || vertex == null || (program.GeometryAsCompute != null && geometry == null))
            {
                List<string> missing = new(3);
                if (graphics == null) missing.Add("图形");
                if (vertex == null) missing.Add("顶点计算");
                if (program.GeometryAsCompute != null && geometry == null) missing.Add("几何计算");
                S2ANullBinaryRed(string.Join("、", missing));
                return null;
            }

            return Pack(
                program.SpecializationState.TransformFeedbackDescriptors != null,
                graphics,
                vertex,
                program.VertexAsCompute.Reservations,
                geometry,
                program.GeometryAsCompute?.Reservations,
                program.S2APassthroughInfo);
        }

        /// <summary>程序各宿主程序的链接状态合起来：任一失败 = 失败，任一未完成 = 未完成，否则成功。</summary>
        public static ProgramLinkStatus CheckLink(CachedShaderProgram program, bool blocking) => CombineLink(program, p => p.CheckProgramLink(blocking));

        /// <summary>同 CheckLink，但不等渲染线程（多线程渲染器取渲染线程已得出的结果，见 ThreadedRenderer.S2ALinkStatusNoWait）：GPU 模拟线程上补查按需实化的程序用</summary>
        public static ProgramLinkStatus LinkStatusNoWait(CachedShaderProgram program) => CombineLink(program, Ryujinx.Graphics.GAL.Multithreading.ThreadedRenderer.S2ALinkStatusNoWait);

        private static ProgramLinkStatus CombineLink(CachedShaderProgram program, System.Func<IProgram, ProgramLinkStatus> status)
        {
            ProgramLinkStatus s = status(program.HostProgram);

            foreach (ShaderAsCompute c in new[] { program.VertexAsCompute, program.GeometryAsCompute })
            {
                if (c == null)
                {
                    continue;
                }

                ProgramLinkStatus cs = status(c.HostProgram);

                if (cs == ProgramLinkStatus.Failure || s == ProgramLinkStatus.Failure)
                {
                    s = ProgramLinkStatus.Failure;
                }
                else if (cs == ProgramLinkStatus.Incomplete)
                {
                    s = ProgramLinkStatus.Incomplete;
                }
            }

            return s;
        }
    }
}
