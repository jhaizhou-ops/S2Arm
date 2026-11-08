// 包内特化核对单测：ShaderSpecializationState.S2AVerify（首次命中全字段核对）与报红规则。期望值全部按字段语义手算（见各条注释），不跑被测实现推期望。
// 退出 0 = 全过；最后一行「期望 → 真结果」。
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Gpu;
using Ryujinx.Graphics.Gpu.Engine.Threed;
using Ryujinx.Graphics.Gpu.Image;
using Ryujinx.Graphics.Gpu.Shader;
using Ryujinx.Graphics.Gpu.Shader.DiskCache;
using Ryujinx.Graphics.Shader;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using TextureDescriptor = Ryujinx.Graphics.Gpu.Image.TextureDescriptor;

namespace S2A.SpecTest
{
    sealed class Bytes : Ryujinx.Graphics.Gpu.Shader.HashTable.IDataAccessor
    {
        readonly byte[] _b; public Bytes(byte[] b) => _b = b;
        public ReadOnlySpan<byte> GetSpan(int offset, int length) => _b.AsSpan(offset, Math.Max(0, Math.Min(length, _b.Length - offset)));
    }

    // 只答按需实化要用到的几个调用的假渲染器 / 假程序（DispatchProxy：其余调用返回缺省值）
    class Fake : System.Reflection.DispatchProxy
    {
        protected override object Invoke(System.Reflection.MethodInfo m, object[] a)
        {
            if (m.Name == nameof(IRenderer.LoadProgramBinary)) return Program();
            if (m.Name == nameof(IProgram.CheckProgramLink)) return ProgramLinkStatus.Success;
            if (m.Name == nameof(IProgram.GetBinary)) return new byte[] { 1, 2, 3, 4 };
            return m.ReturnType.IsValueType && m.ReturnType != typeof(void) ? Activator.CreateInstance(m.ReturnType) : null;
        }
        public static IRenderer Renderer() => Create<IRenderer, Fake>();
        public static IProgram Program() => Create<IProgram, Fake>();
    }

    sealed class FakeRt : S2ASpecRuntime
    {
        public Dictionary<(int, int, int), uint> Formats = new();
        public Dictionary<(int, int), int> Ubo = new();
        public Dictionary<int, byte[]> Cb1 = new();

        public override TextureDescriptor GetTextureDescriptor(int stageIndex, int handle, int cbufSlot)
        {
            TextureDescriptor d = default;
            d.Word0 = Formats.TryGetValue((stageIndex, handle, cbufSlot), out uint f) ? f : 0;
            return d;
        }

        public override int UniformBufferSize(int stageIndex, int slot) => Ubo.TryGetValue((stageIndex, slot), out int n) ? n : 0;

        public override bool TryGetCb1(int stageIndex, int size, out ReadOnlySpan<byte> data)
        {
            if (!Cb1.TryGetValue(stageIndex, out byte[] b)) { data = default; return false; }
            data = b.AsSpan(0, Math.Min(size, b.Length));
            return true;
        }
    }

    static class Program
    {
        static int pass, fail;
        static void Check(bool ok, string what) { if (ok) pass++; else fail++; Console.WriteLine($"{(ok ? "✓" : "✗ 不通")} {what}"); }

        // Maxwell 纹理描述符格式码（FormatTable：A8B8G8R8 | 四分量 Unorm = 0x24908 → R8G8B8A8Unorm；R32 | 四分量 Uint = 0x4920f → R32Uint）
        const uint FmtRgba8 = 0x24908, FmtR32Uint = 0x4920f;

        static CachedShaderStage St(byte[] cb1 = null) => new(null, new byte[16], cb1 ?? Array.Empty<byte>());

        // 图形程序：顶点 + 片元（下标 1 / 5），可选曲面细分求值（3）
        static CachedShaderStage[] Gfx(bool tes = false, byte[] vsCb1 = null) => new[] { null, St(vsCb1), null, tes ? St() : null, null, St() };

        static GpuChannelGraphicsState Base()
        {
            GpuChannelGraphicsState g = default;
            g.Topology = PrimitiveTopology.Triangles;
            g.PointSize = 1.0f;
            return g;
        }

        static ShaderSpecializationState G(GpuChannelGraphicsState g, uint readBits, TransformFeedbackDescriptor[] tf = null)
        {
            ShaderSpecializationState s = new(ref g, (ProgramPipelineState?)null, tf);
            if (readBits != uint.MaxValue) s.S2ARecordUsage(readBits, 0);
            s.S2AMarkLoaded(7);
            return s;
        }

        static List<ShaderSpecializationState.S2ASpecMismatch> V(ShaderSpecializationState s, FakeRt rt, CachedShaderStage[] sh, bool supportsQuads = false)
        {
            List<ShaderSpecializationState.S2ASpecMismatch> m = new();
            s.S2AVerify(rt, sh, isVulkan: true, supportsQuads, m);
            return m;
        }

        static FakeRt Rt(GpuChannelGraphicsState g) => new() { Graphics = g, TexturePoolLength = 2, SamplerPoolLength = 2 };

        static string Fields(List<ShaderSpecializationState.S2ASpecMismatch> m) => string.Join(",", m.Select(x => x.Field));

        static int Main()
        {
            const uint None = 0, Old = uint.MaxValue;

            // 1 全同：翻译读过早期深度 / 点大小，运行时同值 → 0 项不符；核过后不再待核、也没作废
            {
                var s = G(Base(), S2AStateRead.EarlyZ | S2AStateRead.PointSize);
                Check(s.S2ANeedsVerify, "1 磁盘条目核对前待核");
                var m = V(s, Rt(Base()), Gfx());
                Check(m.Count == 0 && !s.S2ANeedsVerify && !s.S2ARejected, $"1 全同 → 0 项不符、记相符（实得 {Fields(m)}）");
            }
            // 2 早期深度：条目 false，运行时 true，翻译读过 → 不符 EarlyZForce，条目作废
            {
                var s = G(Base(), S2AStateRead.EarlyZ); var r = Base(); r.EarlyZForce = true;
                var m = V(s, Rt(r), Gfx());
                Check(Fields(m) == "EarlyZForce" && m.FirstOrDefault().Entry == "False" && m.FirstOrDefault().Runtime == "True" && s.S2ARejected, $"2 早期深度不同且读过 → EarlyZForce False/True、作废（实得 {Fields(m)}）");
            }
            // 3 同上但第二代记录里没读（如运行时化后）→ 不比，不误杀
            {
                var s = G(Base(), S2AStateRead.PointSize); var r = Base(); r.EarlyZForce = true;
                var m = V(s, Rt(r), Gfx());
                Check(m.Count == 0 && !s.S2ARejected, $"3 早期深度不同但没读 → 0 项（实得 {Fields(m)}）");
            }
            // 4 旧条目（无使用记录）：有片元阶段 = 读过早期深度（保守）→ 不符
            {
                var s = G(Base(), Old); var r = Base(); r.EarlyZForce = true;
                var m = V(s, Rt(r), Gfx());
                Check(Fields(m) == "EarlyZForce", $"4 旧条目早期深度不同 → 保守判 EarlyZForce（实得 {Fields(m)}）");
            }
            // 5 点大小：零配置包缺省 0，运行时 1 → 不符 PointSize 0 / 1；红行格式固定
            {
                var e = Base(); e.PointSize = 0f;
                var s = G(e, S2AStateRead.PointSize);
                var m = V(s, Rt(Base()), Gfx());
                Check(Fields(m) == "PointSize" && m.FirstOrDefault().Entry == "0" && m.FirstOrDefault().Runtime == "1", $"5 点大小 0 vs 1 → PointSize 0/1（实得 {Fields(m)} {m.FirstOrDefault()}）");
                string red = ShaderSpecializationState.S2AFormatRed(m.FirstOrDefault(), 7, false, true);
                Check(red == "[gal] 【红】包内特化不符：PointSize 程序 #7（图形） 包内=0 运行时=1", $"5 红行 = {red}");
            }
            // 6 拓扑：读过；三角形 vs 三角带 → 翻译器看到的都是 Triangles，不判；三角形 vs 线 → 判 Topology
            {
                var s = G(Base(), S2AStateRead.Topology); var r = Base(); r.Topology = PrimitiveTopology.TriangleStrip;
                Check(V(s, Rt(r), Gfx()).Count == 0, "6a 三角形 vs 三角带（同为输入拓扑 Triangles）→ 0 项");
                var s2 = G(Base(), S2AStateRead.Topology); var r2 = Base(); r2.Topology = PrimitiveTopology.Lines;
                var m = V(s2, Rt(r2), Gfx());
                Check(Fields(m) == "Topology", $"6b 三角形 vs 线 → Topology（实得 {Fields(m)}）");
            }
            // 7 折半图元号：主机不支持四边形、无几何阶段时 = 拓扑是不是四边形；读过 → 三角形 vs 四边形判不符；没读 → 不判
            {
                var r = Base(); r.Topology = PrimitiveTopology.Quads;
                var m = V(G(Base(), S2AStateRead.HalvePrim), Rt(r), Gfx(), supportsQuads: false);
                Check(Fields(m) == "HalvePrimitiveId", $"7a 折半图元号读过、三角形 vs 四边形 → HalvePrimitiveId（实得 {Fields(m)}）");
                Check(V(G(Base(), None), Rt(r), Gfx(), supportsQuads: false).Count == 0, "7b 没读 → 0 项");
            }
            // 8 曲面细分模式：有曲面求值阶段的旧条目 = 读过；模式不同 → TessellationMode
            {
                var r = Base(); r.TessellationMode = new TessMode { Packed = 0x1 };
                var m = V(G(Base(), Old), Rt(r), Gfx(tes: true));
                Check(Fields(m) == "TessellationMode", $"8 曲面模式不同 → TessellationMode（实得 {Fields(m)}）");
            }
            // 9 变换反馈：条目关、运行时开 → TransformFeedback 关/开
            {
                var rt = Rt(Base()); rt.TransformFeedback = new TransformFeedbackDescriptor[4];
                var m = V(G(Base(), None), rt, Gfx());
                Check(Fields(m) == "TransformFeedback" && m.FirstOrDefault().Entry == "关" && m.FirstOrDefault().Runtime == "开", $"9 变换反馈关 vs 开（实得 {Fields(m)}）");
            }
            // 10 贴图格式：查询过格式（第 4 阶段句柄 0x10）RGBA8 vs 运行时 R32Uint → TextureFormat[4:10:-1]；只登记没查询格式的不比
            {
                var s = G(Base(), None);
                s.RegisterTexture(4, 0x10, -1, FmtRgba8, false, TextureTarget.Texture2D, true); s.RecordTextureFormat(4, 0x10, -1);
                s.RegisterTexture(4, 0x20, -1, FmtRgba8, false, TextureTarget.Texture2D, true);
                var rt = Rt(Base()); rt.Formats[(4, 0x10, -1)] = FmtR32Uint; rt.Formats[(4, 0x20, -1)] = FmtR32Uint;
                var m = V(s, rt, Gfx());
                Check(Fields(m) == "TextureFormat[4:10:-1]" && m.FirstOrDefault().Entry == "R8G8B8A8Unorm" && m.FirstOrDefault().Runtime == "R32Uint", $"10 查询过格式的贴图 RGBA8 vs R32Uint、没查询的不比（实得 {Fields(m)} {m.FirstOrDefault()}）");
            }
            // 11 常量缓冲算的数组长度：登记 8，运行时第 0 阶段 c3 绑 128 字节 / 8 字节句柄 = 16 → 不符 8/16；登记 1 vs 运行时 0 → 都取下限 2，不判
            {
                var s = G(Base(), None); s.RegisterTextureArrayLengthFromBuffer(0, 0, 3, 8);
                var rt = Rt(Base()); rt.Ubo[(0, 3)] = 128;
                var m = V(s, rt, Gfx());
                Check(Fields(m) == "TextureArrayFromBuffer[0:c3]" && m.FirstOrDefault().Entry == "8" && m.FirstOrDefault().Runtime == "16", $"11a 数组长度 8 vs 16（实得 {Fields(m)} {m.FirstOrDefault()}）");
                var s2 = G(Base(), None); s2.RegisterTextureArrayLengthFromBuffer(0, 0, 3, 1);
                Check(V(s2, Rt(Base()), Gfx()).Count == 0, "11b 1 vs 0（都取下限 2）→ 0 项");
            }
            // 12 贴图池算的数组长度：登记 2，运行时池 4096 → TextureArrayFromPool 2/4096
            {
                var s = G(Base(), None); s.RegisterTextureArrayLengthFromPool(false, 2);
                var rt = Rt(Base()); rt.TexturePoolLength = 4096;
                var m = V(s, rt, Gfx());
                Check(Fields(m) == "TextureArrayFromPool" && m.FirstOrDefault().Runtime == "4096", $"12 池长度 2 vs 4096（实得 {Fields(m)}）");
            }
            // 13 c1：顶点读过 8 字节 {1,2}，运行时第 0 阶段 c1 = {1,3} → 第一处不同在 +0x4，包内 00000002；没绑 c1 → 核不了，不判
            {
                byte[] e1 = { 1, 0, 0, 0, 2, 0, 0, 0 };
                var rt = Rt(Base()); rt.Cb1[0] = new byte[] { 1, 0, 0, 0, 3, 0, 0, 0 };
                var m = V(G(Base(), None), rt, Gfx(vsCb1: e1));
                Check(Fields(m) == "Cb1Data[vs]" && m.FirstOrDefault().Entry.StartsWith("+0x4=00000002") && m.FirstOrDefault().Runtime == "+0x4=00000003", $"13a c1 第 2 字不同（实得 {Fields(m)} {m.FirstOrDefault()}）");
                Check(V(G(Base(), None), Rt(Base()), Gfx(vsCb1: e1)).Count == 0, "13b 运行时没绑 c1 → 0 项");
            }
            // 14 计算：线程组 8x8x1 vs 16x8x1 → ComputeLocalSize；共享内存 32768 vs 0：旧条目按读过 → 判；第二代记录没读共享内存 → 不判
            {
                var e = new GpuChannelComputeState(8, 8, 1, 0, 32768, false);
                var s = new ShaderSpecializationState(ref e); s.S2AMarkLoaded(3);
                var rt = new FakeRt { Compute = new GpuChannelComputeState(16, 8, 1, 0, 0, false) };
                var m = new List<ShaderSpecializationState.S2ASpecMismatch>(); s.S2AVerify(rt, new[] { St() }, true, false, m);
                Check(Fields(m) == "ComputeLocalSize,ComputeSharedMemorySize" && m.FirstOrDefault().Entry == "8x8x1" && m.FirstOrDefault().Runtime == "16x8x1", $"14a 线程组 + 共享内存（旧条目）（实得 {Fields(m)}）");
                var s2 = new ShaderSpecializationState(ref e); s2.S2ARecordUsage(0, 0); s2.S2AMarkLoaded(3);
                var rt2 = new FakeRt { Compute = new GpuChannelComputeState(8, 8, 1, 0, 0, false) };
                var m2 = new List<ShaderSpecializationState.S2ASpecMismatch>(); s2.S2AVerify(rt2, new[] { St() }, true, false, m2);
                Check(m2.Count == 0, $"14b 第二代记录没读共享内存 → 0 项（实得 {Fields(m2)}）");
                var s3 = new ShaderSpecializationState(ref e); s3.S2ARecordUsage(S2AStateRead.SharedMem, 0); s3.S2AMarkLoaded(3);
                var m3 = new List<ShaderSpecializationState.S2ASpecMismatch>(); s3.S2AVerify(rt2, new[] { St() }, true, false, m3);
                Check(Fields(m3) == "ComputeSharedMemorySize", $"14c 读过共享内存 32768 vs 0 → 判（实得 {Fields(m3)}）");
            }
            // 15 报红规则：同一字段前 16 个程序逐行，第 17–31 个不打，第 32 个打一行累计
            {
                var lines = new List<string>();
                var one = new List<ShaderSpecializationState.S2ASpecMismatch> { new("S2ATestField", "a", "b") };
                for (int i = 0; i < 32; i++) ShaderSpecializationState.S2AReport(one, i, false, true, lines.Add);
                Check(lines.Count(l => l.Contains("【红】")) == 17 && lines.Where(l => l.Contains("【红】")).ElementAt(15).Contains("程序 #15") && lines.Last(l => l.Contains("【红】")) == "[gal] 【红】包内特化不符：S2ATestField 累计 32 个程序（前 16 例已逐行列出，之后只计数）", $"15 32 次不符 → 16 行明细 + 1 行累计（实得 {lines.Count} 行，末行 {lines.LastOrDefault()}）");
                lines.Clear(); ShaderSpecializationState.S2AReport(one, 99, false, false, lines.Add);
                Check(!lines.Any(l => l.Contains("【红】")), "15b 第 33 次（非 2 的幂）不打");
            }
            // 16 序列化：第二代读位写盘读回不丢；按「去掉使用记录」写出的与无记录条目同字节（缓存合并去重口径不变）
            {
                var s = G(Base(), S2AStateRead.PointSize | S2AStateRead.EarlyZ);
                var bytes = Ser(s, false); var back = Des(bytes);
                var r = Base(); r.PointSize = 2f;
                var m = V(back, Rt(r), new[] { null, St(), null, null, null, null });
                Check(Fields(m) == "PointSize", $"16a 写盘读回后读位还在（无片元：早期深度不判，点大小判）（实得 {Fields(m)}）");
                var plain = G(Base(), Old);
                Check(Ser(s, true).SequenceEqual(Ser(plain, false)), "16b 去掉使用记录写出 = 无记录条目");
            }

            // 17 按需实化路径（0100 shader-cache-lazy）：真写一份磁盘缓存（一个计算程序，线程组 8x8x1），走 ParallelDiskCacheLoader 开局只登记，
            //    客体代码查到组后 TryFindForCompute 才实化：期望实化出的条目带磁盘标记（序号 0、待核）；运行时线程组 16x8x1 → 核对不符、作废；
            //    再查同组 → 找不到（作废的跳过）= 走现翻
            {
                string dir = Path.Combine(Path.GetTempPath(), "s2a_spec_lazy_" + Environment.ProcessId); if (Directory.Exists(dir)) Directory.Delete(dir, true); Directory.CreateDirectory(dir);
                try
                {
                    var ctx = new GpuContext(Fake.Renderer(), new Ryujinx.Common.Configuration.DirtyHacks(Array.Empty<ulong>()));
                    // 宿主缓存文件名按 Api_VendorName 拼：给个固定值
                    object caps = default(Capabilities);
                    typeof(Capabilities).GetField("Api").SetValue(caps, Ryujinx.Graphics.Shader.Translation.TargetApi.Vulkan); typeof(Capabilities).GetField("VendorName").SetValue(caps, "spectest");
                    ctx.Capabilities = (Capabilities)caps;
                    byte[] code = Enumerable.Range(0, 256).Select(i => (byte)(i * 7 + 3)).ToArray();
                    var info = new ShaderProgramInfo(Array.Empty<BufferDescriptor>(), Array.Empty<BufferDescriptor>(), Array.Empty<Ryujinx.Graphics.Shader.TextureDescriptor>(), Array.Empty<Ryujinx.Graphics.Shader.TextureDescriptor>(), ShaderStage.Compute, 0, 0, 0, false, false, false, false, 0, 0);
                    var e = new GpuChannelComputeState(8, 8, 1, 0, 0, false);
                    var spec = new ShaderSpecializationState(ref e);
                    var hs = new DiskCacheHostStorage(dir);
                    hs.AddShader(ctx, new CachedShaderProgram(Fake.Program(), spec, new CachedShaderStage(info, code, Array.Empty<byte>())), new byte[] { 1, 2, 3, 4 });
                    var cc = new ComputeShaderCacheHashTable(); var gc = new ShaderCacheHashTable();
                    new ParallelDiskCacheLoader(ctx, gc, cc, new DiskCacheHostStorage(dir), (_, _, _) => { }, default).LoadShaders();
                    var table = typeof(ComputeShaderCacheHashTable).GetField("_cache", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance).GetValue(cc);
                    object[] args = { new Bytes(code), null, null };
                    bool found = (bool)table.GetType().GetMethod("TryFindItem").Invoke(table, args);
                    var list = (ShaderSpecializationList)args[1];
                    bool hit = found && list.TryFindForCompute(null, default, new GpuChannelComputeState(16, 8, 1, 0, 0, false), out CachedShaderProgram prog);
                    prog = hit ? list.First() : null;
                    Check(hit && prog.SpecializationState.S2ANeedsVerify && prog.SpecializationState.S2ADiskIndex == 0, $"17a 按需实化出的条目带磁盘标记（命中 {hit}，待核 {prog?.SpecializationState.S2ANeedsVerify}，序号 {prog?.SpecializationState.S2ADiskIndex}）");
                    var m = new List<ShaderSpecializationState.S2ASpecMismatch>();
                    if (prog != null) prog.SpecializationState.S2AVerify(new FakeRt { Compute = new GpuChannelComputeState(16, 8, 1, 0, 0, false) }, prog.Shaders, true, false, m);
                    Check(Fields(m) == "ComputeLocalSize" && prog.SpecializationState.S2ARejected, $"17b 线程组 8x8x1 vs 16x8x1 → 不符、作废（实得 {Fields(m)}）");
                    Check(!list.TryFindForCompute(null, default, new GpuChannelComputeState(16, 8, 1, 0, 0, false), out _), "17c 作废后再查同组 → 找不到（走现翻）");
                }
                catch (Exception ex) { Check(false, $"17 按需实化路径抛异常：{ex}"); }
                finally { try { Directory.Delete(dir, true); } catch { } }
            }

            // 18 透明测试「有没有代码」（GpuChannelGraphicsState.S2AAlphaTestEmitted，特化核对用）：
            //   开关位真 + 比较方式 Always / AlwaysGl = 没代码（与开关位假同一份着色器）；开关位真 + 其余比较方式 = 有代码；主机支持透明测试 = 一律没代码。
            //   一致性：全部开关位 × 比较方式 × 主机能力，判据 = 翻译端 CreateShaderGraphicsState 换算出的 AlphaTestCompare != Always（不另写一套）
            {
                GpuChannelGraphicsState A(bool en, CompareOp op) { var g = Base(); g.AlphaTestEnable = en; g.AlphaTestCompare = op; return g; }
                Check(!A(false, CompareOp.Less).S2AAlphaTestEmitted(false), "18a 关 → 没代码");
                Check(!A(true, CompareOp.Always).S2AAlphaTestEmitted(false) && !A(true, CompareOp.AlwaysGl).S2AAlphaTestEmitted(false), "18b 开 + Always / AlwaysGl → 没代码");
                Check(A(true, CompareOp.Less).S2AAlphaTestEmitted(false) && A(true, CompareOp.NeverGl).S2AAlphaTestEmitted(false), "18c 开 + Less / NeverGl → 有代码");
                Check(!A(true, CompareOp.Less).S2AAlphaTestEmitted(true), "18d 主机支持透明测试 → 没代码");
                int bad = 0, n = 0;
                foreach (bool en in new[] { false, true })
                    foreach (CompareOp op in Enum.GetValues<CompareOp>())
                        foreach (bool host in new[] { false, true })
                        {
                            var g = A(en, op); n++;
                            bool tr = g.CreateShaderGraphicsState(host, true, false, true).AlphaTestCompare != AlphaTestOp.Always;
                            if (tr != g.S2AAlphaTestEmitted(host)) bad++;
                        }
                Check(bad == 0, $"18e 与翻译端换算一致（{n} 种组合，不一致 {bad}）");
            }

            // 19 贴图「是不是缓冲」（S2ARecordTextureIsBuffer，TEX / TLDS 一维整数取元）：只比缓冲与否；完整类型查询（TXQ）照旧比类型。期望手算：
            //   19a 记缓冲 vs 运行时缓冲 → 中；19b 记缓冲 vs 运行时一维贴图 → 不中、拒因「贴图是否缓冲」；
            //   19c 记一维贴图（非缓冲）vs 运行时二维（也非缓冲）→ 中（原先按完整类型比会误拒）；19d 完整类型查询二维 vs 运行时二维数组 → 不中「贴图类型」
            {
                static Ryujinx.Graphics.Gpu.Image.TextureDescriptor Desc(TextureTarget t) => new() { Word4 = (uint)t << 23 };
                var s = G(Base(), None);
                s.RegisterTexture(4, 0x6A, -1, FmtRgba8, false, TextureTarget.TextureBuffer, true); s.S2ARecordTextureIsBuffer(4, 0x6A, -1);
                Check(s.S2ATestMatchesTexture(4, 0x6A, -1, Desc(TextureTarget.TextureBuffer)), "19a 记缓冲 vs 运行时缓冲 → 中");
                bool b = s.S2ATestMatchesTexture(4, 0x6A, -1, Desc(TextureTarget.Texture1D));
                Check(!b && ShaderSpecializationState.S2AMissWhy == "贴图是否缓冲", $"19b 记缓冲 vs 运行时一维 → 不中、拒因「贴图是否缓冲」（实得 {b} {ShaderSpecializationState.S2AMissWhy}）");
                var s2 = G(Base(), None);
                s2.RegisterTexture(4, 0x70, -1, FmtRgba8, false, TextureTarget.Texture1D, true); s2.S2ARecordTextureIsBuffer(4, 0x70, -1);
                Check(s2.S2ATestMatchesTexture(4, 0x70, -1, Desc(TextureTarget.Texture2D)), $"19c 记一维 vs 运行时二维（都不是缓冲）→ 中（实得拒因 {ShaderSpecializationState.S2AMissWhy}）");
                var s3 = G(Base(), None);
                s3.RegisterTexture(4, 0xB0, -1, FmtRgba8, false, TextureTarget.Texture2D, true); s3.RecordTextureSamplerType(4, 0xB0, -1);
                bool d = s3.S2ATestMatchesTexture(4, 0xB0, -1, Desc(TextureTarget.Texture2DArray));
                Check(!d && ShaderSpecializationState.S2AMissWhy == "贴图类型", $"19d 完整类型二维 vs 二维数组 → 不中「贴图类型」（实得 {d} {ShaderSpecializationState.S2AMissWhy}）");
            }
            // 20 继承条目贴图查询收窄（S2ATrimTextureQueries，10-23 暗黑2 包 4052 个程序带旧「坐标归一化」查询、运行时判不符重翻）。期望手算：
            //   参照条目 0x6A 记了 类型 + 坐标归一化（值 1），0x80 记了格式；再翻只查了 0x6A 的类型、没登记 0x80
            //   20a 收窄 2 位（0x6A 的归一化 + 0x80 的格式）；20b 收窄后 0x6A 对「非归一化、二维」描述符 → 中（原先拒因「贴图坐标归一化」）；
            //   20c 0x6A 类型查询保留：对二维数组 → 不中「贴图类型」；20d 反证：收窄前同一描述符 → 不中「贴图坐标归一化」
            {
                static Ryujinx.Graphics.Gpu.Image.TextureDescriptor Desc2(TextureTarget t, bool norm) => new() { Word4 = (uint)t << 23, Word5 = norm ? 1u << 31 : 0u };
                ShaderSpecializationState Mk()
                {
                    var r = G(Base(), None);
                    r.RegisterTexture(4, 0x6A, -1, FmtRgba8, false, TextureTarget.Texture2D, true); r.RecordTextureSamplerType(4, 0x6A, -1); r.RecordTextureCoordNormalized(4, 0x6A, -1);
                    r.RegisterTexture(4, 0x80, -1, FmtRgba8, false, TextureTarget.Texture2D, true); r.RecordTextureFormat(4, 0x80, -1);
                    return r;
                }
                var before = Mk();
                bool b0 = before.S2ATestMatchesTexture(4, 0x6A, -1, Desc2(TextureTarget.Texture2D, false));
                Check(!b0 && ShaderSpecializationState.S2AMissWhy == "贴图坐标归一化", $"20d 反证：收窄前 非归一化描述符 → 不中「贴图坐标归一化」（实得 {b0} {ShaderSpecializationState.S2AMissWhy}）");
                var inh = Mk();
                var re = G(Base(), None);
                re.RegisterTexture(4, 0x6A, -1, FmtRgba8, false, TextureTarget.Texture2D, true); re.RecordTextureSamplerType(4, 0x6A, -1);
                int n = inh.S2ATrimTextureQueries(re);
                Check(n == 2, $"20a 收窄 2 位（实得 {n}）");
                Check(inh.S2ATestMatchesTexture(4, 0x6A, -1, Desc2(TextureTarget.Texture2D, false)), $"20b 收窄后 非归一化二维 → 中（实得拒因 {ShaderSpecializationState.S2AMissWhy}）");
                bool c = inh.S2ATestMatchesTexture(4, 0x6A, -1, Desc2(TextureTarget.Texture2DArray, true));
                Check(!c && ShaderSpecializationState.S2AMissWhy == "贴图类型", $"20c 类型查询保留：二维数组 → 不中「贴图类型」（实得 {c} {ShaderSpecializationState.S2AMissWhy}）");
            }
            // 21 片元输出类型只比片元着色器写到的目标（S2AFoutMatches，10-24 xc3 冷局：条目全浮点、运行时没写的 3 号槽绑着 R8Uint → 原先判不符现翻）。期望手算：
            //   片元写 0 号目标（输出映射 0xF）、条目全浮点：21a 运行时 3 号 = Uint → 中；21b 运行时 0 号 = Uint → 不中；
            //   21c 开双源混合（翻译器另写 1 号）：运行时 1 号 = Uint → 不中；21d 不知道写了哪些（输出映射 -1）：3 号 = Uint → 不中（整组比）；21e 没有片元着色器：任何类型 → 中
            {
                ShaderProgramInfo Fo(int map) => new(Array.Empty<BufferDescriptor>(), Array.Empty<BufferDescriptor>(), Array.Empty<Ryujinx.Graphics.Shader.TextureDescriptor>(), Array.Empty<Ryujinx.Graphics.Shader.TextureDescriptor>(), ShaderStage.Fragment, 0, 0, 0, false, false, false, false, 0, map);
                ShaderProgramInfo Vo() => new(Array.Empty<BufferDescriptor>(), Array.Empty<BufferDescriptor>(), Array.Empty<Ryujinx.Graphics.Shader.TextureDescriptor>(), Array.Empty<Ryujinx.Graphics.Shader.TextureDescriptor>(), ShaderStage.Vertex, 0, 0, 0, false, false, false, false, 0, -1);
                ShaderSpecializationState Prog(bool dsb, CachedShaderStage fs)
                {
                    var g = Base(); g.DualSourceBlendEnable = dsb;
                    var sp = new ShaderSpecializationState(ref g, null, null);
                    _ = new CachedShaderProgram(Fake.Program(), sp, null, new CachedShaderStage(Vo(), new byte[16], Array.Empty<byte>()), null, null, null, fs);
                    return sp;
                }
                GpuChannelGraphicsState Rt(int slot) { var g = Base(); if (slot >= 0) g.FragmentOutputTypes[slot] = AttributeType.Uint; return g; }
                CachedShaderStage Fs(int map) => new(Fo(map), new byte[16], Array.Empty<byte>());
                var g3 = Rt(3); var g0 = Rt(0); var g1 = Rt(1);
                Check(Prog(false, Fs(0xF)).S2AFoutMatches(ref g3), "21a 只写 0 号、运行时没写的 3 号是 Uint → 中");
                Check(!Prog(false, Fs(0xF)).S2AFoutMatches(ref g0), "21b 只写 0 号、运行时 0 号是 Uint → 不中");
                var gd = Rt(1); gd.DualSourceBlendEnable = true;
                Check(!Prog(true, Fs(0xF)).S2AFoutMatches(ref gd), "21c 双源混合（另写 1 号）、运行时 1 号是 Uint → 不中");
                Check(!Prog(false, Fs(-1)).S2AFoutMatches(ref g3), "21d 不知道写了哪些、运行时 3 号是 Uint → 不中（整组比）");
                Check(Prog(false, null).S2AFoutMatches(ref g1), "21e 没有片元着色器 → 中");
            }
            Console.WriteLine($"期望 21 组 {pass + fail} 项全过 → 真结果 过 {pass}、不通 {fail} {(fail == 0 ? "✓" : "✗")}");
            return fail == 0 ? 0 : 1;
        }

        static byte[] Ser(ShaderSpecializationState s, bool withoutUsage)
        {
            using MemoryStream ms = new(); BinarySerializer w = new(ms);
            if (withoutUsage) s.S2AWriteWithoutUsage(ref w); else s.Write(ref w);
            return ms.ToArray();
        }

        static ShaderSpecializationState Des(byte[] b) { BinarySerializer r = new(new MemoryStream(b)); var s = ShaderSpecializationState.Read(ref r); s.S2AMarkLoaded(7); return s; }
    }
}
