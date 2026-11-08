// GAL 第 4 块测试语料生成：Maxwell 机器码 → Ryujinx 翻译器 → SPIR-V（TargetApi.Vulkan）+ 程序资源布局（与 Gpu 层 ShaderInfoBuilder 同口径）。
// 与 sw/gfx/tools/swsh_xlate 的区别：资源的 (集, 绑定号) 按 Gpu 层 GpuAccessorBase 的 Vulkan 分配（集 0 常量 / 1 存储 / 2 贴图 / 3 图像 / 4+ 额外集，
//   绑定号 = 阶段段号 × 每阶段上限 + 序号，见 sw/third_party/ryujinx_gpu/src/Ryujinx.Graphics.Gpu/Shader/GpuAccessorBase.cs），能力表取 cs/NxRenderer.cs GetCapabilities。
// 用法：gal_spvgen <着色器目录（含 index.tsv 与 src/）> <输出目录> <顶点数> <片元数>
//   选法：index.tsv 里按键排序，取前 N 个 vs、前 N 个 ps、全部 cs；第 i 个 vs 与第 i 个 ps 配成一个图形程序（配对是人造的，只为凑「多阶段共享描述符集」的程序布局），每个 cs 一个计算程序。
// 输出：<键>.spv；prog_<序号>.txt 每个程序一份：
//   stage <ShaderStage 整数> <键>.spv
//   fragmap <FragmentOutputMap>
//   desc <集> <绑定> <个数> <ResourceType 整数> <ResourceStages 位>     （= ShaderInfo.ResourceLayout.Sets[集].Descriptors 拍平，顺序同 NxProgram.cs）
//   local x y z（计算）
//   另写 failed.txt：翻译失败的键与异常首行
using Ryujinx.Common.Memory;
using Ryujinx.Graphics.Shader;
using Ryujinx.Graphics.Shader.Translation;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;

static class GalSpvGen
{
    // 能力表（与 cs/NxRenderer.cs GetCapabilities 一致）
    const int UniformSet = 0, StorageSet = 1, TextureSet = 2, ImageSet = 3, ExtraSetBase = 4, MaxExtraSets = 4;
    const int MaxUbo = 18, MaxSsbo = 16, MaxTex = 64, MaxImg = 16;
    const int ShaderStages = 5;   // Ryujinx.Graphics.Shader.Constants.ShaderStages

    // 一个程序内各阶段共享的计数（= Gpu 层 ResourceCounts）
    sealed class Counts { public int Textures, Images, Sets; }

    sealed class Accessor : IGpuAccessor
    {
        readonly byte[] _code, _c1; readonly int _stageIndex; readonly Counts _rc; readonly Dictionary<int, AttributeType> _attr; readonly int[] _local;
        int _staticTex, _staticImg;
        public Accessor(byte[] code, byte[] c1, int stageIndex, Counts rc, Dictionary<int, AttributeType> attr, int[] local)
        { _code = code; _c1 = c1; _stageIndex = stageIndex; _rc = rc; _attr = attr; _local = local; }

        public void Log(string message) { }
        public uint ConstantBuffer1Read(int offset) => offset >= 0 && offset + 4 <= _c1.Length ? BitConverter.ToUInt32(_c1, offset) : 0;
        public ReadOnlySpan<ulong> GetCode(ulong address, int minimumSize) => MemoryMarshal.Cast<byte, ulong>(new ReadOnlySpan<byte>(_code)[(int)address..]);

        // ---- 绑定分配：照抄 GpuAccessorBase（Api == Vulkan 分支），保留数 = ResourceReservations(false, false)：常量 1、其余 0 ----
        static int StageIndex(int s) => s switch { 4 => 1, 3 => 2, 1 => 3, 2 => 4, _ => 0 };
        int FromIndex(int index, int maxPerStage) => StageIndex(_stageIndex) * maxPerStage + index;
        public SetBindingPair CreateConstantBufferBinding(int index) => new(UniformSet, FromIndex(index, MaxUbo) + 1);
        public SetBindingPair CreateStorageBufferBinding(int index) => new(StorageSet, FromIndex(index, MaxSsbo));
        public SetBindingPair CreateTextureBinding(int count, bool isBuffer)
        {
            int b;
            if (count == 1) { int i = _staticTex++; if (isBuffer) i += MaxTex; b = FromIndex(i, MaxTex * 2); }
            else b = MaxTex * ShaderStages * 2 + _rc.Textures++;
            return new(TextureSet, b);
        }
        public SetBindingPair CreateImageBinding(int count, bool isBuffer)
        {
            int b;
            if (count == 1) { int i = _staticImg++; if (isBuffer) i += MaxImg; b = FromIndex(i, MaxImg * 2); }
            else b = MaxImg * ShaderStages * 2 + _rc.Images++;
            return new(ImageSet, b);
        }
        public int CreateExtraSet() => _rc.Sets >= MaxExtraSets ? -1 : ExtraSetBase + _rc.Sets++;

        // ---- 能力查询：与 NxRenderer.GetCapabilities 一致 ----
        public int QueryHostGatherBiasPrecision() => 0;
        public bool QueryHostReducedPrecision() => false;
        public bool QueryHostHasFrontFacingBug() => false;
        public bool QueryHostHasVectorIndexingBug() => false;
        public int QueryHostStorageBufferOffsetAlignment() => 16;
        public int QueryHostSubgroupSize() => 32;
        public bool QueryHostSupportsBgraFormat() => true;
        public bool QueryHostSupportsFragmentShaderInterlock() => false;
        public bool QueryHostSupportsFragmentShaderOrderingIntel() => false;
        public bool QueryHostSupportsGeometryShader() => false;
        public bool QueryHostSupportsGeometryShaderPassthrough() => false;
        public bool QueryHostSupportsImageLoadFormatted() => true;
        public bool QueryHostSupportsLayerVertexTessellation() => true;
        public bool QueryHostSpirvLayerExt() => true; // Metal SPIR-V conversion accepts the legacy EXT form.
        public bool QueryHostSupportsNonConstantTextureOffset() => false;
        public bool QueryHostSupportsScaledVertexFormats() => false;
        public bool QueryHostSupportsSeparateSampler() => true;
        public bool QueryHostSupportsShaderBallot() => false;
        public bool QueryHostSupportsShaderBarrierDivergence() => true;   // 同 cs/caps/NxCaps.cs
        public bool QueryHostSupportsShaderFloat64() => false;
        public bool QueryHostSupportsShaderNonUniformIndexing() => true;
        public bool QueryHostSupportsSnormBufferTextureFormat() => true;
        public bool QueryHostSupportsTextureGatherOffsets() => false;
        public bool QueryHostSupportsTextureShadowLod() => false;
        public bool QueryHostSupportsTransformFeedback() => false;
        public bool QueryHostSupportsViewportIndexVertexTessellation() => true;   // 同 cs/caps/NxCaps.cs
        public bool QueryHostSupportsViewportMask() => false;
        public bool QueryHostSupportsDepthClipControl() => false;

        // ---- 游戏状态查询：没有真实客体状态，取缺省（贴图按 2D、池长 32）----
        public int QuerySamplerArrayLengthFromPool() => 32;
        public int QueryTextureArrayLengthFromBuffer(int slot) => 32;
        public int QueryTextureArrayLengthFromPool() => 32;
        public int QueryComputeLocalSizeX() => _local[0];
        public int QueryComputeLocalSizeY() => _local[1];
        public int QueryComputeLocalSizeZ() => _local[2];
        public int QueryComputeSharedMemorySize() => 0x8000;
        public GpuGraphicsState QueryGraphicsState()
        {
            Array32<AttributeType> attr = default; Array8<AttributeType> fout = default;
            foreach (var kv in _attr) attr[kv.Key] = kv.Value;
            // Vulkan：originUpperLeft = true（GpuAccessor：_isVulkan || YNegateEnabled）；Gpu 层对 Vulkan 不让宿主做 alpha 测试（着色器里做）
            return new GpuGraphicsState(false, InputTopology.Triangles, false, TessPatchType.Triangles, TessSpacing.EqualSpacing,
                false, false, false, false, false, 1f, AlphaTestOp.Always, 0f, attr, false, fout, false, false, true, false);
        }
    }

    // ShaderInfoBuilder 同口径的描述符（只取 Descriptors，不含 Usages）
    sealed record Desc(int Set, int Binding, int Count, int Type, int Stages);
    enum RT { UniformBuffer = 0, StorageBuffer = 1, Texture = 2, Sampler = 3, TextureAndSampler = 4, Image = 5, BufferTexture = 6, BufferImage = 7 }

    static void AddRange(List<Desc> l, int set, RT type, int binding, int count, int stages) { for (int i = 0; i < count; i++) l.Add(new Desc(set, binding + i, 1, (int)type, stages)); }
    static RT TexType(TextureDescriptor t, bool isImage)
    {
        bool isBuffer = (t.Type & SamplerType.Mask) == SamplerType.TextureBuffer;
        if (isBuffer) return isImage ? RT.BufferImage : RT.BufferTexture;
        if (isImage) return RT.Image;
        if (t.Type == SamplerType.None) return RT.Sampler;
        return t.Separate ? RT.Texture : RT.TextureAndSampler;
    }
    static List<Desc> BuildLayout(IEnumerable<ShaderProgramInfo> infos)
    {
        var l = new List<Desc>();
        AddRange(l, UniformSet, RT.UniformBuffer, 0, 1, 1 | 2 | 32);   // 支撑缓冲：Compute | Vertex | Fragment
        foreach (var info in infos)
        {
            int si = info.Stage switch { ShaderStage.TessellationControl => 1, ShaderStage.TessellationEvaluation => 2, ShaderStage.Geometry => 3, ShaderStage.Fragment => 4, _ => 0 };
            int sidx = si switch { 4 => 1, 3 => 2, 1 => 3, 2 => 4, _ => 0 };
            int stages = 1 << (int)info.Stage;   // ResourceStages 位 = 1 << ShaderStage
            AddRange(l, UniformSet, RT.UniformBuffer, 1 + sidx * MaxUbo, MaxUbo, stages);
            AddRange(l, StorageSet, RT.StorageBuffer, sidx * MaxSsbo, MaxSsbo, stages);
            AddRange(l, TextureSet, RT.TextureAndSampler, sidx * MaxTex * 2, MaxTex, stages);
            AddRange(l, TextureSet, RT.BufferTexture, sidx * MaxTex * 2 + MaxTex, MaxTex, stages);
            AddRange(l, ImageSet, RT.Image, sidx * MaxImg * 2, MaxImg, stages);
            AddRange(l, ImageSet, RT.BufferImage, sidx * MaxImg * 2 + MaxImg, MaxImg, stages);
            foreach (var t in info.Textures) if (t.ArrayLength > 1) l.Add(new Desc(t.Set, t.Binding, t.ArrayLength, (int)TexType(t, false), stages));
            foreach (var t in info.Images) if (t.ArrayLength > 1) l.Add(new Desc(t.Set, t.Binding, t.ArrayLength, (int)TexType(t, true), stages));
        }
        // NxProgram.cs 按集号顺序拍平（集内保持加入顺序）
        return l.OrderBy(d => d.Set).ToList();
    }

    static int Main(string[] args)
    {
        string dir = args[0], outDir = args[1]; int nvs = int.Parse(args[2]), nps = int.Parse(args[3]);
        Directory.CreateDirectory(outDir);
        var index = File.ReadAllLines(Path.Combine(dir, "index.tsv")).Where(l => !l.StartsWith('#')).Select(l => l.Split('\t')).Where(f => f.Length >= 2).ToList();
        var vs = index.Where(f => f[1] == "vs").Select(f => f[0]).OrderBy(k => k, StringComparer.Ordinal).Take(nvs).ToList();
        var ps = index.Where(f => f[1] == "ps").Select(f => f[0]).OrderBy(k => k, StringComparer.Ordinal).Take(nps).ToList();
        var cs = index.Where(f => f[1] == "cs").Select(f => f[0]).OrderBy(k => k, StringComparer.Ordinal).ToList();
        var failed = new StringBuilder(); int ok = 0, bad = 0, nprog = 0;
        // S2Arm 抽取的着色器字节在 <抽取目录>/src/*.pk（graphics/tools/shbake/srcpack.py 同一格式）：u16 键长 | 键 | u32 控制段长 | u32 机器码长 | 控制段 | 机器码，同键取第一条
        var src = new Dictionary<string, (byte[] Code, byte[] Ctl)>(StringComparer.Ordinal);
        foreach (string pk in Directory.EnumerateFiles(Path.Combine(dir, "src"), "*.pk").OrderBy(x => x, StringComparer.Ordinal))
        {
            byte[] d = File.ReadAllBytes(pk); int i = 0;
            while (i + 2 <= d.Length)
            {
                int kl = BitConverter.ToUInt16(d, i), h = i + 2 + kl + 8; if (h > d.Length) break;
                int cl = BitConverter.ToInt32(d, i + 2 + kl), dl = BitConverter.ToInt32(d, i + 6 + kl); if ((long)h + cl + dl > d.Length) break;
                src.TryAdd(Encoding.ASCII.GetString(d, i + 2, kl), (d[(h + cl)..(h + cl + dl)], d[h..(h + cl)])); i = h + cl + dl;
            }
        }

        (ShaderProgram, int[]) Xlate(string key, ShaderStage stage, Counts rc)
        {
            var (code, ctl) = src[key];
            uint c1o = BitConverter.ToUInt32(ctl, 0x700), c1t = BitConverter.ToUInt32(ctl, 0x704);   // 同 nxsh_build.py：c1 = code[ctl+0x700 处的值 : ctl+0x704 处的值]
            byte[] c1 = c1o < c1t && c1t <= code.Length ? code[(int)c1o..(int)c1t] : Array.Empty<byte>();
            bool compute = stage == ShaderStage.Compute;
            byte[] body = compute ? code : code[0x30..];   // 图形：去 0x30 字节头，剩 0x50 SPH + 指令（同 nxsh_build.py）
            int[] local = { 1, 1, 1 };
            if (compute && ctl.Length >= 0x754) for (int i = 0; i < 3; i++) local[i] = Math.Max(1, BitConverter.ToInt32(ctl, 0x748 + i * 4));
            var attr = new Dictionary<int, AttributeType>();
            string af = Path.Combine(dir, "miss", key + ".attr");
            if (stage == ShaderStage.Vertex && File.Exists(af))
                foreach (var ln in File.ReadAllLines(af)) { var p = ln.Split(' ', StringSplitOptions.RemoveEmptyEntries); if (p.Length >= 2 && int.TryParse(p[0], out int loc) && loc < 32) attr[loc] = p[1] == "sint" ? AttributeType.Sint : p[1] == "uint" ? AttributeType.Uint : AttributeType.Float; }
            int stageIndex = stage switch { ShaderStage.Fragment => 4, ShaderStage.Geometry => 3, _ => 0 };
            var acc = new Accessor(body, c1, stageIndex, rc, attr, local);
            var flags = TranslationFlags.DebugMode | (compute ? TranslationFlags.Compute : 0);   // = ShaderCache.DefaultFlags
            var ctx = Translator.CreateContext(0, acc, new TranslationOptions(TargetLanguage.Spirv, TargetApi.Vulkan, flags));
            ShaderProgram p2 = ctx.Translate();
            File.WriteAllBytes(Path.Combine(outDir, key + ".spv"), p2.BinaryCode);
            return (p2, local);
        }

        void Emit(List<(string key, ShaderStage st, ShaderProgram p, int[] local)> stages)
        {
            var sb = new StringBuilder();
            foreach (var s in stages) sb.Append($"stage {(int)s.st} {s.key}.spv\n");
            int fmap = stages.FirstOrDefault(s => s.st == ShaderStage.Fragment).p?.Info.FragmentOutputMap ?? -1;
            sb.Append($"fragmap {fmap}\n");
            foreach (var s in stages) if (s.st == ShaderStage.Compute) sb.Append($"local {s.local[0]} {s.local[1]} {s.local[2]}\n");
            foreach (var d in BuildLayout(stages.Select(s => s.p.Info))) sb.Append($"desc {d.Set} {d.Binding} {d.Count} {d.Type} {d.Stages}\n");
            File.WriteAllText(Path.Combine(outDir, $"prog_{nprog++:D4}.txt"), sb.ToString());
        }
        (ShaderProgram, int[])? Try(string key, ShaderStage st, Counts rc)
        {
            try { var r = Xlate(key, st, rc); ok++; return r; }
            catch (Exception e) { bad++; failed.Append($"{key}\t{st}\t{e.GetType().Name}: {e.Message.Split('\n')[0]}\n"); return null; }
        }
        for (int i = 0; i < Math.Max(vs.Count, ps.Count); i++)
        {
            var rc = new Counts(); var list = new List<(string, ShaderStage, ShaderProgram, int[])>();
            if (i < vs.Count && Try(vs[i], ShaderStage.Vertex, rc) is var (pv, lv)) list.Add((vs[i], ShaderStage.Vertex, pv, lv));
            if (i < ps.Count && Try(ps[i], ShaderStage.Fragment, rc) is var (pf, lf)) list.Add((ps[i], ShaderStage.Fragment, pf, lf));
            if (list.Count > 0) Emit(list);
        }
        foreach (var k in cs)
            if (Try(k, ShaderStage.Compute, new Counts()) is var (pc, lc)) Emit(new() { (k, ShaderStage.Compute, pc, lc) });
        File.WriteAllText(Path.Combine(outDir, "failed.txt"), failed.ToString());
        Console.WriteLine($"翻译：顶点 {vs.Count} + 片元 {ps.Count} + 计算 {cs.Count} = {vs.Count + ps.Count + cs.Count} 支；成功 {ok}，失败 {bad}；程序 {nprog} 个");
        return 0;
    }
}
