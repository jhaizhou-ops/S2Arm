// 着色器离线全量翻译进包（S2Arm graphics/tools/shbake，10-19 由旧库 a7276a3 ryu_judge/core/ShaderBake.cs 搬入；原 10-19 架构线）：游戏文件抽出集（nxsh_extract 的 rows.tsv + src/）→ Ryujinx 磁盘缓存条目（guest + shared，设备 shcache 直接读）+ 每支 SPIR-V（SW_GAL_SPV_DUMP 同格式，交 gal_offline.py 出 metallib）。
// 不另写翻译：两段都调 Ryujinx 原代码——
//   甲段（只对已有缓存里没出现过的程序）：BakeGpuAccessor 按「游戏级缺省特化状态」翻一遍，记下 Ryujinx 自己登记的特化状态（纹理登记 / 查询标记 / 数组长度）与客体代码实际长度、c1 用量；
//   乙段（全部程序）：照 ParallelDiskCacheLoader.RecompileGraphicsFromGuestCode / RecompileComputeFromGuestCode 原样，用 DiskCacheGpuAccessor 从（客体代码 + 特化状态）再翻 = 设备加载时走的同一条路，
//        出的 SPIR-V 就是设备渲染器会收到的那份；乙段翻不过的不写（设备加载也会报错）。
// 写盘用 Ryujinx 的 DiskCacheHostStorage.AddShader（不写宿主程序二进制，设备照 Ryujinx 重建）。
// 配对（vs 配哪支 ps）：BNSH 容器（bfsha / bnsh / ptcl 内）同一来源 + 同一变体号 = 一个程序；BAHS（sharcb）与偏移头文件：按记录顺序 vs 紧跟 ps 为一个程序；计算着色器单支成程序。
// 特化状态：程序（各阶段键）在已有缓存里出现过 → 原样继承那里的条目（客体代码 + 特化状态，全部不同的都带上）；没出现过 → 已有缓存里出现最多的那组（整份状态按字节计票，不写死任何游戏的值）。
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Gpu;
using Ryujinx.Graphics.Gpu.Image;
using Ryujinx.Graphics.Gpu.Shader;
using Ryujinx.Graphics.Gpu.Shader.DiskCache;
using Ryujinx.Graphics.Shader;
using Ryujinx.Graphics.Shader.Translation;
using S2Arm.Backends.Vulkan.ProgramCache;
using System;
using System.Buffers.Binary;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Numerics;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace S2A.ShBake
{
    public static class ShaderBake
    {
        const int NStages = 6; // Ryujinx 磁盘缓存的阶段下标：0 = VertexA，1 顶点，2/3 细分，4 几何，5 片元；计算程序只有 [0]

        // ================= 读已有缓存 =================
        sealed class RefProgram
        {
            public string From;
            public bool Compute;
            public GuestCodeAndCbData?[] Stages;
            public ShaderSpecializationState Spec;
            public byte[] SpecBytes;
            public string[] Keys; // 对到抽出集的键（对不上 = null）
        }

        static List<RefProgram> ReadCache(string dir, bool guestOnly = false)
        {
            List<RefProgram> list = new();
            string toc = Path.Combine(dir, "shared.toc"), dat = Path.Combine(dir, "shared.data");
            if (!File.Exists(toc) || !File.Exists(dat)) return list;
            DiskCacheGuestStorage gs = new(dir);
            using FileStream tocS = File.OpenRead(toc), datS = File.OpenRead(dat);
            using Stream gToc = gs.OpenTocFileStream(), gDat = gs.OpenDataFileStream();
            BinarySerializer tocR = new(tocS), datR = new(datS);
            string bad = guestOnly ? null : CheckFormat(dir);   // 只取客体代码（--ref-cover）：不核口径版本、不读特化状态
            if (bad != null) throw new InvalidDataException(bad);
            tocS.Seek(32, SeekOrigin.Begin);
            while (tocS.Position < tocS.Length)
            {
                ulong off = 0; tocR.Read(ref off);
                datS.Seek((long)off, SeekOrigin.Begin);
                datR.BeginCompression();
                uint mask = 0; datR.Read(ref mask);
                bool compute = mask == 0;
                if (compute) mask = 1;
                GuestCodeAndCbData?[] st = new GuestCodeAndCbData?[compute ? 1 : NStages];
                while (mask != 0)
                {
                    int si = BitOperations.TrailingZeroCount(mask);
                    int gi = 0; datR.Read(ref gi);
                    st[si] = gs.LoadShader(gToc, gDat, gi);
                    mask &= ~(1u << si);
                }
                ShaderSpecializationState spec = guestOnly ? null : ShaderSpecializationState.Read(ref datR);
                datR.EndCompression();
                if (guestOnly) { list.Add(new RefProgram { From = dir, Compute = compute, Stages = st }); continue; }
                list.Add(new RefProgram { From = dir, Compute = compute, Stages = st, Spec = spec, SpecBytes = SpecBytes(spec) });
            }
            return list;
        }

        /// <summary>读客体代码包 .s2gb（graphics/tools/shbake/guest_cache.py 从社区 / 用户自带的 yuzu 系缓存转出，格式见其文件头注释）→ 同 ReadCache 只读客体模式的程序表：
        /// 各阶段客体代码（图形从 SPH 起、计算从第一条指令起）+ 常量段 1，不带特化状态（按当前翻译器缺省状态烘，同 --ref-guest 口径不同时）</summary>
        static List<RefProgram> ReadBundle(string path)
        {
            List<RefProgram> list = new();
            using BinaryReader r = new(File.OpenRead(path));
            if (new string(r.ReadChars(4)) != "S2GB") throw new InvalidDataException("不是客体代码包（文件头不是 S2GB）");
            uint ver = r.ReadUInt32(); if (ver != 1) throw new InvalidDataException($"客体代码包版本 {ver}（只认 1）");
            r.ReadUInt64(); r.ReadUInt32(); uint n = r.ReadUInt32();
            for (uint i = 0; i < n; i++)
            {
                bool compute = r.ReadByte() != 0; int ns = r.ReadByte();
                GuestCodeAndCbData?[] st = new GuestCodeAndCbData?[compute ? 1 : NStages];
                for (int k = 0; k < ns; k++)
                {
                    int slot = r.ReadByte();
                    if (slot >= st.Length) throw new InvalidDataException($"程序 {i} 阶段槽 {slot} 越界");
                    byte[] code = r.ReadBytes(r.ReadInt32()), cb1 = r.ReadBytes(r.ReadInt32());
                    st[slot] = new GuestCodeAndCbData(code, cb1);
                }
                list.Add(new RefProgram { From = path, Compute = compute, Stages = st });
            }
            if (r.BaseStream.Position != r.BaseStream.Length) throw new InvalidDataException($"客体代码包末尾多出 {r.BaseStream.Length - r.BaseStream.Position} 字节");
            return list;
        }

        static byte[] SpecKeyBytes(ShaderSpecializationState s)
        {
            using MemoryStream ms = new();
            BinarySerializer w = new(ms);
            s.S2AWriteWithoutUsage(ref w);
            return ms.ToArray();
        }
        static byte[] SpecBytes(ShaderSpecializationState s)
        {
            using MemoryStream ms = new();
            BinarySerializer w = new(ms);
            s.Write(ref w);
            return ms.ToArray();
        }
        /// <summary>S2A：特化状态字节，去掉 PipelineState（影子判定用）。Write 在 hasPipelineState=false 时不写这部分，
        /// 所以有状态记录去掉后与「其余特化全同的无状态记录」自身写出的字节完全一致；只差管线状态才算影子。</summary>
        static byte[] SpecBytesWithoutPipelineState(ShaderSpecializationState s)
        {
            ProgramPipelineState? p = s.PipelineState;
            s.PipelineState = null;
            try { return SpecBytes(s); }
            finally { s.PipelineState = p; }
        }

        static string Sha(byte[] b, int n = 16) => Convert.ToHexString(SHA256.HashData(b)).ToLowerInvariant()[..n];
        /// <summary>规范 Fp（参考库口径，grokbot_tool/s2rl_extract.py canon_fp 同算法）：客体代码（图形从 SPH 起、计算从第一条指令起）截到第一条无条件 EXIT / KIL
        /// （高 12 位 0xE30 / 0xE33、谓词 PT、条件码恒真；只看指令槽，跳过每 32 字节一个的调度控制字），sha1 前 8 字节按大端读成 u64（= 参考库指纹表的数值）</summary>
        static ulong CanonFp(ReadOnlySpan<byte> code, bool compute)
        {
            int b = compute ? 0 : 0x50, end = code.Length;
            for (int o = b; o + 8 <= code.Length; o += 8)
            {
                if ((o - b) % 32 == 0) continue;
                ulong v = BinaryPrimitives.ReadUInt64LittleEndian(code.Slice(o));
                if (((v >> 52) == 0xE30 || (v >> 52) == 0xE33) && ((v >> 16) & 0xF) == 7 && (v & 0x1F) == 0xF) { end = o + 8; break; }
            }
            return BinaryPrimitives.ReadUInt64BigEndian(SHA1.HashData(code.Slice(0, end)));
        }
        /// <summary>读参考库 .s2rl（格式 1 / 2，未压缩）：每个程序 7 列指纹（0 = 该阶段没有）+ 状态下标 + 状态的来源格式 / 代码生成版本 / 原样字节
        /// （格式 2 状态前 8 字节是来源格式 + 代码生成版本，原样字节是其后部分；格式 1 不带，记 0 / 0、整条当原样字节）</summary>
        static List<(ulong[] Cols, int State, uint Fmt, uint Cg, byte[] Raw)> ReadRefLib(string path)
        {
            byte[] b = File.ReadAllBytes(path); int q = 24;
            if (b.Length < 24 || b[0] != (byte)'S' || b[1] != (byte)'2' || b[2] != (byte)'R' || b[3] != (byte)'L') throw new InvalidDataException("不是 S2RL");
            uint ver = BinaryPrimitives.ReadUInt32LittleEndian(b.AsSpan(4)); if (ver < 1 || ver > 2) throw new InvalidDataException($"参考库格式版本 {ver} 不认识");
            ulong Uv() { ulong n = 0; int s = 0; while (true) { byte x = b[q++]; n |= (ulong)(x & 0x7f) << s; s += 7; if ((x & 0x80) == 0) return n; } }
            int nf = (int)Uv(); ulong[] fps = new ulong[nf]; ulong v = 0; for (int i = 0; i < nf; i++) { v += Uv(); fps[i] = v; }
            int ns = (int)Uv(); uint[] sf = new uint[ns], sc = new uint[ns]; byte[][] sr = new byte[ns][];
            for (int i = 0; i < ns; i++)
            {
                int l = (int)Uv();
                if (ver >= 2 && l >= 8) { sf[i] = BinaryPrimitives.ReadUInt32LittleEndian(b.AsSpan(q)); sc[i] = BinaryPrimitives.ReadUInt32LittleEndian(b.AsSpan(q + 4)); sr[i] = b.AsSpan(q + 8, l - 8).ToArray(); }
                else sr[i] = b.AsSpan(q, l).ToArray();
                q += l;
            }
            int np = (int)Uv(); ulong[][] cols = new ulong[7][];
            for (int c = 0; c < 7; c++) { cols[c] = new ulong[np]; for (int i = 0; i < np; i++) { int x = (int)Uv(); cols[c][i] = x == 0 ? 0 : fps[x - 1]; } }
            var outp = new List<(ulong[], int, uint, uint, byte[])>(np);
            for (int i = 0; i < np; i++) { int st = (int)Uv(); bool okS = st < ns; outp.Add((Enumerable.Range(0, 7).Select(c => cols[c][i]).ToArray(), st, okS ? sf[st] : 0, okS ? sc[st] : 0, okS ? sr[st] : Array.Empty<byte>())); }
            return outp;
        }
        static string Fp(byte[] code, bool compute) => Convert.ToHexString(SHA1.HashData(code.AsSpan(0, Math.Min(code.Length, compute ? 0x200 : 0x250))), 0, 8).ToLowerInvariant();
        static string StageName(int si, bool compute) => compute ? "cs" : new[] { "vs_a", "vs", "tcs", "tes", "gs", "fs" }[si];

        /// <summary>guest-new &lt;候选缓存目录&gt; [&lt;已有缓存目录&gt;…]：候选里有、已有目录里都没有的客体代码组合（各阶段客体代码，不比常量段 / 特化状态）有几个，
        /// 打一行「新 N 总 M」（收集器 shcollect.sh 判这局有没有收回包里没有的代码用；口径与 bake --ref-guest 判「已覆盖 / 同代码变体」相同）。读不了候选退出 1。
        /// codeOnly（--code）：口径一致也只比各阶段客体代码（社区缓存对账 N / M / K 与正对照按代码比，10-22 测试出包线）</summary>
        public static int GuestNewCmd(string cand, string[] have, bool codeOnly = false)
        {
            // 口径版本与当前一致的（候选和已有都一致）按「各阶段客体代码 + 常量段 1 + 特化状态」比：运行时只在翻译时往缓存尾部追加，新条目 = 包里没有的程序（含只差特化的变体）；
            //   有一份口径不同就整体退回只比客体代码（读不了特化状态）。打「新 N 总 M（按 程序 / 代码）」
            static string Cid(RefProgram r) => (r.Compute ? "c" : "g") + string.Concat(r.Stages.Select(s => "|" + (s.HasValue ? Sha(s.Value.Code, 32) : "-")));
            static string Pid(RefProgram r) => (r.Compute ? "c" : "g") + string.Concat(r.Stages.Select(s => "|" + (s.HasValue ? Sha(s.Value.Code, 32) + ":" + Sha(s.Value.Cb1Data, 16) : "-"))) + "|" + Sha(r.SpecBytes, 32);
            if (!File.Exists(Path.Combine(cand, "shared.toc"))) { Console.Error.WriteLine($"shbake guest-new：{cand} 里没有 shared.toc"); return 1; }
            bool full = !codeOnly && CheckFormat(cand) == null && have.Where(d => File.Exists(Path.Combine(d, "shared.toc"))).All(d => CheckFormat(d) == null);
            Func<RefProgram, string> key = full ? Pid : Cid;
            HashSet<string> h = new();
            foreach (string d in have) foreach (RefProgram r in ReadCache(d, !full)) h.Add(key(r));
            List<RefProgram> c;
            try { c = ReadCache(cand, !full); } catch (Exception e) { Console.Error.WriteLine($"shbake guest-new：读不了 {cand}：{e.Message}"); return 1; }
            HashSet<string> all = c.Select(key).ToHashSet();
            Console.WriteLine($"新 {all.Count(x => !h.Contains(x))} 总 {all.Count}（按{(full ? "程序" : "代码")}）");
            return 0;
        }

        /// <summary>ryu_judge --shc-dump &lt;缓存目录（含 shared.toc）&gt; &lt;输出目录&gt;：每个程序一行（阶段、长度、指纹、c1 长度、特化摘要），客体代码落 guest/&lt;sha256 前 16 位&gt;.bin。</summary>
        public static int DumpCmd(string dir, string outDir)
        {
            Directory.CreateDirectory(Path.Combine(outDir, "guest"));
            List<RefProgram> ps = ReadCache(dir);
            using StreamWriter w = new(Path.Combine(outDir, "programs.tsv"), false, new UTF8Encoding(false));
            w.Write("idx\tkind\tstages(阶段:长度:指纹:sha:c1长)\tcbuse\tspec\n");
            int i = 0;
            foreach (RefProgram p in ps)
            {
                StringBuilder sb = new();
                for (int si = 0; si < p.Stages.Length; si++)
                {
                    if (p.Stages[si] is not GuestCodeAndCbData g) continue;
                    string sha = Sha(g.Code);
                    File.WriteAllBytes(Path.Combine(outDir, "guest", sha + ".bin"), g.Code);
                    if (g.Cb1Data.Length > 0) File.WriteAllBytes(Path.Combine(outDir, "guest", sha + ".c1"), g.Cb1Data);
                    sb.Append($"{StageName(si, p.Compute)}:{g.Code.Length}:{Fp(g.Code, p.Compute)}:{sha}:{g.Cb1Data.Length} ");
                }
                string cb = string.Join(",", Enumerable.Range(0, 5).Select(s => (p.Spec.S2ACbUsePerStage >> s & 1) != 0 ? $"{s}={p.Spec.ConstantBufferUse[s]:X}" : null).Where(x => x != null));
                string tex = string.Join(";", p.Spec.S2ATextures().Select(t => $"{t.Stage}:{t.Handle:X}:{t.Slot}=f{t.Format:X}{(t.Srgb ? "s" : "")}t{(int)t.Target}n{(t.Norm ? 1 : 0)}q{t.Queried}"));
                string arr = string.Join(";", p.Spec.S2AArrayFromPool().Select(a => $"pool{(a.IsSampler ? "S" : "T")}={a.Length}").Concat(p.Spec.S2AArrayFromBuffer().Select(a => $"buf{a.Stage}:{a.Slot}={a.Length}")));
                w.Write($"{i++}\t{(p.Compute ? "compute" : "graphics")}\t{sb.ToString().TrimEnd()}\t{cb}\t{p.Spec.S2ADescribe().Replace('\t', ' ')} texall={tex} arrs={arr} pipe={(p.Spec.PipelineState.HasValue ? 1 : 0)}\n");
            }
            Console.WriteLine($"shc-dump：{dir} 程序 {ps.Count} → {outDir}");
            return 0;
        }

        // ================= 抽出集 =================
        sealed class XShader
        {
            public string Key, Stage;
            public byte[] Code, Ctl;
            public bool Compute => Stage == "cs";
            // 客体内存里的样子：图形着色器跳过 NVN 的 0x30 字节头（SPH 起）；计算着色器多数无头，带 79563412 头的（八方2 UE4 全局缓存 680 支全是）跳过 0x100 字节头
            //（10-21 pair：Mac 局真值 6 支的客体代码都在抽取代码 +0x100 处；原先按无头整段翻，包里 654 个计算程序的客体代码与运行时不同、全部当场重翻）
            public ReadOnlyMemory<byte> Mem => Compute ? (Code.Length > 0x100 && BinaryPrimitives.ReadUInt32LittleEndian(Code) == 0x12345679u ? Code.AsMemory(0x100) : Code) : Code.AsMemory(0x30);
            public byte[] C1Raw;   // 收回的运行时缓存（--ref-guest）：常量段 1 原样给（缓存里与客体代码分开存），不经控制段
            public byte[] C1 // NVN 常量段（c1）：控制段 +0x700 / +0x704 = 机器码里常量段的起止（相对机器码开头）
            {
                get
                {
                    if (C1Raw != null) return C1Raw;
                    uint a = BinaryPrimitives.ReadUInt32LittleEndian(Ctl.AsSpan(0x700)), b = BinaryPrimitives.ReadUInt32LittleEndian(Ctl.AsSpan(0x704));
                    return a < b && b <= Code.Length ? Code.AsSpan((int)a, (int)(b - a)).ToArray() : Array.Empty<byte>();
                }
            }
        }

        sealed class Prog
        {
            public string Id, Source;
            public bool Compute;
            public string[] Keys = new string[NStages]; // 按 Ryujinx 阶段下标
            public RefProgram Ref; // 继承来的条目（null = 规则配出的新程序）
            // 产出
            public GuestCodeAndCbData?[] Guest;
            public ShaderSpecializationState Spec;
            public CachedShaderStage[] Shaders;
            public List<byte[]> Spirv = new();   // 乙段产出；落盘（Commit）后置 null，只留下面两组键
            public ulong[] SpvHash; public string[] SpvName;   // 各阶段改写后 SPIR-V：SHA256 前 8 字节（离线索引键）/ SpvKey（文件名）
            public ShaderStage[] SpvStage;   // SpvName[i] 是哪个阶段（Sources 落盘后置 null，--reflib 状态表按阶段取顶点 / 片元函数名用）
            public List<ShaderSource> Sources = new(); // 宿主程序二进制（--host-code）用：Ryujinx Vulkan 口径 = 各阶段 SPIR-V 打包
            public string Status = "ok", Err, Origin;
            public byte[][] ASpirv = new byte[NStages][];
            public uint AttrInt, AttrSint; // 乙段翻译推断：顶点属性当整数用的位置 / 其中带符号的（S2AAttrIntUse），补整数类别变体用
            public bool StageOnly; // 阶段单独翻译（没配进任何程序的顶点 / 片元）：只出 SPIR-V 进离线库，不写成缓存程序
            public VtgOut Vtg;     // 顶点 / 几何转计算的程序（乙段 S2AVtg.Translate）：拼复合宿主二进制要的东西；null = 普通程序
            public bool GeometryPassthrough; // 乙段为「顶点写层、后端不支持层+视口输出」补出来的几何阶段：只有 SPIR-V，没有对应 CachedShaderStage 信息（VKPB 不能拿它重建布局）
            public HashSet<string> FoWant;   // 片元输出类型变体（5c）：观测到的片元函数键（运行时翻出的那份），翻完片元键在其中才收
            public uint FoInt;   // 片元按整数位写的输出位置（FoutStatic，落盘时算；5d 按它静态补 Uint 变体）
            public double Ms;
        }

        // 转计算程序（Ryujinx S2AVtg）：乙段产出里拼复合宿主二进制要的部分（SPIR-V 落盘后只留这些）。
        // 各段在 Spirv / SpvHash 里的顺序：顶点计算、[几何计算]、图形程序各阶段（直通顶点 + 片元）
        sealed class VtgOut
        {
            public bool Tf, HasGs;
            public int GraphicsFom, ComputeFom, GeometryFom;
            public ResourceReservations VRes, GRes;
            public ShaderProgramInfo PassthroughInfo;
            public int NCompute => HasGs ? 2 : 1;
        }

        static int StageIndexOf(string st) => st switch { "vs" => 1, "hs" => 2, "ds" => 3, "gs" => 4, "ps" => 5, "cs" => 0, _ => -1 };

        // ================= 几何着色器静态配对 =================
        // SPH（着色器程序头，机器码 +0x30 起 0x50 字节；NVIDIA 公开的 SPH 布局）里的通用属性接口，逐分量一位：
        //   类型 1（顶点 / 几何）：输入 ImapGenericVector 位 192–319、输出 OmapGenericVector 位 432–559；类型 2（像素）：输入 ImapGenericVector 位 192–447，每分量 2 位（非 0 = 读）
        static (UInt128 imap, UInt128 omap) Sph(XShader x)
        {
            byte[] h = x.Code.AsSpan(0x30, 0x50).ToArray();
            UInt128 Bits(int lo, int n) { UInt128 v = 0; for (int i = 0; i < n; i++) if ((h[(lo + i) >> 3] >> ((lo + i) & 7) & 1) != 0) v |= (UInt128)1 << i; return v; }
            if ((h[0] & 0x1f) == 1) return (Bits(192, 128), Bits(432, 128));
            UInt128 im = 0;
            for (int a = 0; a < 32; a++) for (int c = 0; c < 4; c++) { int b = 192 + a * 8 + c * 2; if (((h[b >> 3] >> (b & 7)) & 3) != 0) im |= (UInt128)1 << (a * 4 + c); }
            return (im, 0);
        }
        static bool Covers(UInt128 written, UInt128 read) => (read & ~written) == 0;

        /// <summary>
        /// 没进任何程序的几何着色器配成「顶点 + 几何 + 片元」程序。同一容器（来源去掉最后一段 @偏移）内按记录偏移排序：
        ///   规则一（相邻）：gs 紧跟的下一条是 ps、且 ps 读的通用属性 ⊆ gs 写的；gs 紧前面连续的一串 vs 里写的 ⊇ gs 读的，各成一个程序；
        ///   规则二（接口唯一）：规则一配不上时，同容器里读接口与 gs 写接口逐分量相同的 ps 恰有一支，配 gs 前面最近的、写 ⊇ gs 读的 vs。
        /// 「相邻 / 接口相容即同一程序」的依据由出包统计给出（bake.json pairing_gs.adjacent_vs_ps：相邻 vs→ps 接口相容率对随机配的相容率）。返回配上的 gs 键数
        /// </summary>
        static int PairGeometry(List<(string key, string st, string src, string v)> rows, Dictionary<string, XShader> xs, HashSet<string> used, Action<string, bool, IEnumerable<(string st, string key)>> add, Dictionary<string, object> rep)
        {
            static (string c, long o) Loc(string src)
            {
                int i = src.LastIndexOf('@'); if (i <= 0) return (src, 0);
                string t = src[(i + 1)..].TrimStart('a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j', 'k', 'l', 'm', 'n', 'o', 'p', 'q', 'r', 's', 't', 'u', 'v', 'w', 'x', 'y', 'z');
                int plus = t.IndexOf('+'); if (plus > 0) t = t[..plus];
                return t.StartsWith("0x") && long.TryParse(t[2..], System.Globalization.NumberStyles.HexNumber, null, out long o) ? (src[..i], o) : (src, 0);
            }
            Dictionary<string, (UInt128 i, UInt128 o)> sph = new();
            (UInt128 i, UInt128 o) S(string k) { lock (sph) { if (!sph.TryGetValue(k, out var v)) sph[k] = v = Sph(xs[k]); return v; } }
            var byC = rows.Where(r => r.st is "vs" or "gs" or "ps").Select(r => { var (c, o) = Loc(r.src); return (c, o, r.st, r.key); }).GroupBy(r => r.c).Where(g => g.Any(r => r.st == "gs"))
                .ToDictionary(g => g.Key, g => g.OrderBy(r => r.o).ThenBy(r => r.st, StringComparer.Ordinal).ToList());
            HashSet<string> gsAll = rows.Where(r => r.st == "gs" && !used.Contains(r.key)).Select(r => r.key).ToHashSet(), gsHit = new();
            int r1 = 0, r2 = 0, r3 = 0, adjOk = 0, adjN = 0, rndOk = 0; Random rnd = new(1);
            HashSet<string> gsFn = new();
            List<string> psAll = rows.Where(r => r.st == "ps").Select(r => r.key).Distinct().ToList();
            bool probeAll = Environment.GetEnvironmentVariable("S2A_GS_PAIR_ALL") == "1";
            foreach (var (c, L) in byC)
                for (int i = 0; i < L.Count; i++)
                {
                    if (L[i].st == "vs" && i + 1 < L.Count && L[i + 1].st == "ps")
                    {   // 规则依据：同容器相邻 vs→ps 的接口相容率（对照：同一 vs 配随机 ps）
                        adjN++; if (Covers(S(L[i].key).o, S(L[i + 1].key).i)) adjOk++;
                        if (Covers(S(L[i].key).o, S(psAll[rnd.Next(psAll.Count)]).i)) rndOk++;
                    }
                    if (L[i].st != "gs" || !gsAll.Contains(L[i].key)) continue;
                    var g = S(L[i].key);
                    if (probeAll)
                    {   // 诊断（S2A_GS_PAIR_ALL=1）：同容器所有接口相容的 vs 各配一次，片元取 gs 后面第一支（转计算后几何 / 顶点核与配哪支片元无关），用来拿局里现编的 SPIR-V 键反查真实配对
                        string pp = L.Skip(i + 1).FirstOrDefault(r => r.st == "ps").key ?? L.FirstOrDefault(r => r.st == "ps").key;
                        if (pp != null) foreach (var vv in L.Where(r => r.st == "vs" && Covers(S(r.key).o, g.i)).Select(r => r.key).Distinct()) add($"gs_probe:{c}@{L[i].o:x}", false, new[] { ("vs", vv), ("gs", L[i].key), ("ps", pp) });
                        gsHit.Add(L[i].key); continue;
                    }
                    List<string> vs = new();
                    for (int j = i - 1; j >= 0 && L[j].st == "vs"; j--) if (Covers(S(L[j].key).o, g.i)) vs.Add(L[j].key);
                    string ps = i + 1 < L.Count && L[i + 1].st == "ps" && Covers(g.o, S(L[i + 1].key).i) ? L[i + 1].key : null;
                    if (ps != null && vs.Count > 0)
                    {
                        foreach (string v in vs) add($"gs_adj:{c}@{L[i].o:x}", false, new[] { ("vs", v), ("gs", L[i].key), ("ps", ps) });
                        r1++; gsHit.Add(L[i].key); continue;
                    }
                    var eq = L.Where(r => r.st == "ps" && S(r.key).i == g.o).Select(r => r.key).Distinct().ToList();
                    string v2 = null; for (int j = i - 1; j >= 0 && v2 == null; j--) if (L[j].st == "vs" && Covers(S(L[j].key).o, g.i)) v2 = L[j].key;
                    if (eq.Count == 1 && v2 != null) { add($"gs_if:{c}@{L[i].o:x}", false, new[] { ("vs", v2), ("gs", L[i].key), ("ps", eq[0]) }); r2++; gsHit.Add(L[i].key); continue; }
                    // 规则三（只出函数）：配不出确定的片元时，顶点取 gs 前面最近的、写接口与 gs 读接口相同（没有则 ⊇）的 vs，片元取 gs 后面最近的读 ⊆ gs 写的 ps 占位。
                    // 转计算后顶点 / 几何计算核与直通顶点只取决于（vs, gs）（片元阶段单独翻译，与配哪支无关，见补丁 S2AStageIndep），所以这三支函数进离线库是对的；
                    // 缓存条目要整组客体代码相同才命中，片元是占位的就不写（status func_only）：运行时当场翻译（xlate），但不现编 Metal。依据：10-21 八方2 局里唯一的转计算程序
                    //（全局着色器 WriteToSlice 类：vs 0x4792e0、gs 0x47a05d、ps 0x5129ba）vs 正是 gs 前面最近的、写 == gs 读的那支，片元与 gs 不相邻
                    string v3 = null;
                    for (int j = i - 1; j >= 0 && v3 == null; j--) if (L[j].st == "vs" && S(L[j].key).o == g.i) v3 = L[j].key;
                    v3 ??= v2;
                    string p3 = L.Skip(i + 1).Concat(L.Take(i)).FirstOrDefault(r => r.st == "ps" && Covers(g.o, S(r.key).i)).key;
                    if (v3 != null && p3 != null) { add($"gs_fn:{c}@{L[i].o:x}", false, new[] { ("vs", v3), ("gs", L[i].key), ("ps", p3) }); r3++; gsFn.Add(L[i].key); }
                }
            rep["pairing_gs"] = new Dictionary<string, object>
            {
                ["gs_unpaired_before"] = gsAll.Count, ["gs_paired"] = gsHit.Count, ["rule_adjacent_sites"] = r1, ["rule_interface_sites"] = r2,
                ["gs_func_only"] = gsFn.Except(gsHit).Count(), ["rule_func_only_sites"] = r3,
                ["adjacent_vs_ps"] = $"相邻 vs→ps 接口相容 {adjOk}/{adjN}，随机配 {rndOk}/{adjN}",
            };
            Console.WriteLine($"shbake：几何着色器静态配对 {gsHit.Count}/{gsAll.Count} 支（相邻规则 {r1} 处、接口唯一 {r2} 处；依据：相邻 vs→ps 接口相容 {adjOk}/{adjN}，随机配 {rndOk}/{adjN}）；只出函数 {gsFn.Except(gsHit).Count()} 支（{r3} 处）");
            return gsHit.Count;
        }

        // ================= 缺省特化状态（已有缓存里出现最多的那组） =================
        sealed class Defaults
        {
            public GpuChannelGraphicsState G;
            public ProgramPipelineState? P;
            public GpuChannelComputeState C;
            public uint?[] CbUse = new uint?[5];
            public uint TexFormat; public bool TexSrgb; public TextureTarget TexTarget; public bool TexNorm;
            public int PoolT, PoolS, BufLen;
            public Dictionary<string, string> Report = new();
            // 各项来自参照缓存的票数（0 = 没有参照，用的是缺省值）：出包报告 spec_sources 写来源用
            public int VotesG, VotesP, VotesC, VotesTexFormat, VotesTexTarget, VotesTexNorm, VotesPoolT, VotesPoolS, VotesBuf;
            public int[] VotesCbUse = new int[5];
        }

        static unsafe byte[] Bytes<T>(ref T v) where T : unmanaged => MemoryMarshal.AsBytes(new ReadOnlySpan<T>(Unsafe.AsPointer(ref v), 1)).ToArray();

        static (T val, int votes, int total) Mode<T>(IEnumerable<T> xs, Func<T, string> key)
        {
            var g = xs.GroupBy(key).OrderByDescending(x => x.Count()).ThenBy(x => x.Key, StringComparer.Ordinal).ToList();
            if (g.Count == 0) return (default, 0, 0);
            return (g[0].First(), g[0].Count(), g.Sum(x => x.Count()));
        }

        // 与 ShaderSpecializationState.MatchesGraphics 比较的字段一致（能力表：MayConvertVtgToCompute 时属性去掉 Packed 标记，不支持缩放格式时 S/Uscaled 不并入 Float）
        static string MatchKey(ref GpuChannelGraphicsState g, Capabilities caps)
        {
            StringBuilder sb = new();
            sb.Append(g.ViewportTransformDisable ? 1 : 0).Append(g.AlphaToCoverageEnable && g.AlphaToCoverageDitherEnable ? 1 : 0).Append(g.DepthMode ? 1 : 0).Append(g.AlphaTestEnable ? 1 : 0);
            if (g.AlphaTestEnable) sb.Append($"/{g.AlphaTestCompare}/{g.AlphaTestReference}");
            bool vtg = ShaderCache.MayConvertVtgToCompute(ref caps);
            sb.Append("|a");
            for (int i = 0; i < 32; i++)
            {
                AttributeType t = g.AttributeTypes[i];
                if (vtg) { t &= ~(AttributeType.Packed | AttributeType.PackedRgb10A2Signed); if (caps.SupportsScaledVertexFormats && (t == AttributeType.Sscaled || t == AttributeType.Uscaled)) t = AttributeType.Float; }
                sb.Append((int)t).Append(',');
            }
            sb.Append($"|cbdp{(g.HasConstantBufferDrawParameters ? 1 : 0)}u{(g.HasUnalignedStorageBuffer ? 1 : 0)}|f");
            if (caps.NeedsFragmentOutputSpecialization) for (int i = 0; i < 8; i++) sb.Append((int)g.FragmentOutputTypes[i]).Append(',');
            sb.Append($"|ds{(g.DualSourceBlendEnable ? 1 : 0)}y{(g.YNegateEnabled ? 1 : 0)}");
            return sb.ToString();
        }

        static Defaults ComputeDefaults(List<RefProgram> refs, Capabilities caps)
        {
            Defaults d = new();
            var gr = refs.Where(r => !r.Compute).ToList();
            var cr = refs.Where(r => r.Compute).ToList();
            // 先按 Ryujinx 查缓存时真正比较的字段（ShaderSpecializationState.MatchesGraphics，顶点属性按 FilterAttributeType 归一）计票取最多的一类，
            // 再在这一类里按整份状态计票取最多的（拓扑 / early_z 等不进比较、但影响翻译的字段也随多数）
            var mk = Mode(gr, r => MatchKey(ref r.Spec.GraphicsState, caps));
            var inK = gr.Where(r => mk.total > 0 && MatchKey(ref r.Spec.GraphicsState, caps) == MatchKey(ref mk.val.Spec.GraphicsState, caps)).ToList();
            var mg = Mode(inK, r => Convert.ToHexString(Bytes(ref r.Spec.GraphicsState)));
            if (mg.total > 0) d.G = mg.val.Spec.GraphicsState;
            d.VotesG = mg.total;
            d.Report["graphics_match_class"] = $"{mk.votes}/{mk.total}（按 MatchesGraphics 比较字段归类，共 {gr.Select(r => MatchKey(ref r.Spec.GraphicsState, caps)).Distinct().Count()} 类）";
            d.Report["graphics_state"] = $"类内 {mg.votes}/{mg.total}：{(mg.total > 0 ? mg.val.Spec.S2ADescribe().Split("\ttex=")[0].Replace('\t', ' ') : "-")}";
            var mp = Mode(gr, r => r.Spec.PipelineState is ProgramPipelineState p ? Convert.ToHexString(Bytes(ref p)) : "none");
            if (mp.total > 0) d.P = mp.val.Spec.PipelineState;
            d.VotesP = mp.total;
            d.Report["pipeline_state"] = $"{mp.votes}/{mp.total} has={(d.P.HasValue ? 1 : 0)}";
            var mc = Mode(cr, r => Convert.ToHexString(Bytes(ref r.Spec.ComputeState)));
            if (mc.total > 0) d.C = mc.val.Spec.ComputeState;
            d.VotesC = mc.total;
            d.Report["compute_state"] = $"{mc.votes}/{mc.total}：local={d.C.LocalSizeX}x{d.C.LocalSizeY}x{d.C.LocalSizeZ} smem={d.C.SharedMemorySize} lmem={d.C.LocalMemorySize}";
            for (int s = 0; s < 5; s++)
            {
                int ss = s;
                var mm = Mode(refs.Where(r => (r.Spec.S2ACbUsePerStage >> ss & 1) != 0).Select(r => r.Spec.ConstantBufferUse[ss]), v => v.ToString("X"));
                if (mm.total > 0) d.CbUse[s] = mm.val;
                d.VotesCbUse[s] = mm.total;
                d.Report[$"cbuse{s}"] = mm.total > 0 ? $"{mm.val:X} {mm.votes}/{mm.total}" : "无记录";
            }
            var tex = refs.SelectMany(r => r.Spec.S2ATextures()).ToList();
            var mf = Mode(tex, t => $"{t.Format:X}{(t.Srgb ? "s" : "")}"); d.TexFormat = mf.val.Format; d.TexSrgb = mf.val.Srgb;
            var mt = Mode(tex, t => ((int)t.Target).ToString()); d.TexTarget = mt.val.Target;
            var mn = Mode(tex, t => t.Norm ? "1" : "0"); d.TexNorm = mn.val.Norm;
            // 没有参照缓存（零配置出包）时不能落到枚举零值：类型零值是 Texture1D、归一化零值是 false，翻译时查询过类型的程序会被烘成一维采样
            // （10-20 动森全屏后处理顶点着色器：二维参数贴图被当一维采样，远景景深失效；运行时匹配已补比类型，猜错只会首遇重翻）。缺省取最常见的二维、归一化坐标
            if (mt.total == 0) d.TexTarget = TextureTarget.Texture2D;
            if (mn.total == 0) d.TexNorm = true;
            d.VotesTexFormat = mf.total; d.VotesTexTarget = mt.total; d.VotesTexNorm = mn.total;
            d.Report["texture"] = $"format={d.TexFormat:X}{(d.TexSrgb ? "s" : "")} {mf.votes}/{mf.total} target={d.TexTarget} {mt.votes}/{mt.total} norm={d.TexNorm} {mn.votes}/{mn.total}";
            var pools = refs.SelectMany(r => r.Spec.S2AArrayFromPool()).ToList();
            var mpt = Mode(pools.Where(p => !p.IsSampler), p => p.Length.ToString()); var mps = Mode(pools.Where(p => p.IsSampler), p => p.Length.ToString());
            var mb = Mode(refs.SelectMany(r => r.Spec.S2AArrayFromBuffer()), b => b.Length.ToString());
            d.PoolT = mpt.total > 0 ? mpt.val.Length : 0; d.PoolS = mps.total > 0 ? mps.val.Length : 0; d.BufLen = mb.total > 0 ? mb.val.Length : 0;
            d.VotesPoolT = mpt.total; d.VotesPoolS = mps.total; d.VotesBuf = mb.total;
            d.Report["array_len"] = $"pool_tex={d.PoolT}({mpt.votes}/{mpt.total}) pool_smp={d.PoolS}({mps.votes}/{mps.total}) buf={d.BufLen}({mb.votes}/{mb.total})";
            return d;
        }

        // ================= 甲段：按缺省状态翻译、让 Ryujinx 自己登记特化状态 =================
        sealed class BakeGpuAccessor : GpuAccessorBase, IGpuAccessor
        {
            readonly ReadOnlyMemory<byte> _data, _c1;
            readonly Defaults _d;
            readonly ShaderSpecializationState _new;
            readonly int _stageIndex;
            readonly string _key;   // 抽取键：翻译告警计数记首个着色器（TrLog）
            readonly bool _isVulkan, _hasGs, _supportsQuads;
            readonly GpuChannelComputeState _cs;
            readonly GpuChannelGraphicsState _g;   // 翻译看到的图形状态 = 程序特化状态里的那份（几何程序的拓扑与缺省不同，见 PhaseA）

            public BakeGpuAccessor(GpuContext context, string key, ReadOnlyMemory<byte> data, ReadOnlyMemory<byte> c1, Defaults d, GpuChannelComputeState cs, ShaderSpecializationState newSpec, ResourceCounts counts, int stageIndex, bool hasGs)
                : base(context, counts, stageIndex)
            {
                _key = key; _data = data; _c1 = c1; _d = d; _cs = cs; _new = newSpec; _stageIndex = stageIndex; _hasGs = hasGs; _g = newSpec.GraphicsState;
                _isVulkan = context.Capabilities.Api == TargetApi.Vulkan;
                _supportsQuads = context.Capabilities.SupportsQuads;
                if (stageIndex == (int)ShaderStage.Geometry - 1) newSpec.RecordPrimitiveTopology();
            }

            public void S2AReportStateUse(uint readFlags, uint attrReadMask) => _new.S2ARecordUsage(readFlags, attrReadMask);   // 只比翻译读过的状态（10-19）

            public uint ConstantBuffer1Read(int offset)
            {
                // 越过常量段读回 0（跳转表取不到）：进翻译告警计数（translator_log.tsv + 烘焙日志汇总行），原先只记进没人读的 Cb1Over（审计 #1534 P1-20）
                if (offset + 4 > _c1.Length) { Tr.Add($"c1 read out of bounds at 0x{offset:X} (c1 length 0x{_c1.Length:X}).", _key); return 0; }
                return MemoryMarshal.Cast<byte, uint>(_c1.Span[offset..])[0];
            }
            public void Log(string message) => Tr.Add(message, _key);   // 翻译告警分类计数（TrLog；原是空体，告警全被吞掉）
            public ReadOnlySpan<ulong> GetCode(ulong address, int minimumSize) => MemoryMarshal.Cast<byte, ulong>(_data.Span[(int)address..]);
            public int QueryComputeLocalSizeX() => _cs.LocalSizeX;
            public int QueryComputeLocalSizeY() => _cs.LocalSizeY;
            public int QueryComputeLocalSizeZ() => _cs.LocalSizeZ;
            public int QueryComputeLocalMemorySize() => _cs.LocalMemorySize;
            public int QueryComputeSharedMemorySize() => _cs.SharedMemorySize;
            public uint QueryConstantBufferUse()
            {
                uint v = _d.CbUse[_stageIndex] ?? 0;
                _new.RecordConstantBufferUse(_stageIndex, v);
                return v;
            }
            public GpuGraphicsState QueryGraphicsState() => _g.CreateShaderGraphicsState(!_isVulkan, _supportsQuads, _hasGs, _isVulkan || _g.YNegateEnabled);
            public bool QueryHasConstantBufferDrawParameters() { _new.S2ARecordUsage(S2AStateRead.Cbdp, 0); return _d.G.HasConstantBufferDrawParameters; }
            public int QuerySamplerArrayLengthFromPool() { _new.RegisterTextureArrayLengthFromPool(true, _d.PoolS); return _d.PoolS; }
            public int QueryTextureArrayLengthFromPool() { _new.RegisterTextureArrayLengthFromPool(false, _d.PoolT); return _d.PoolT; }
            public int QueryTextureArrayLengthFromBuffer(int slot) { _new.RegisterTextureArrayLengthFromBuffer(_stageIndex, 0, slot, _d.BufLen); return _d.BufLen; }
            public SamplerType QuerySamplerType(int handle, int cbufSlot)
            {
                Ensure(handle, cbufSlot);
                _new.RecordTextureSamplerType(_stageIndex, handle, cbufSlot);
                // 取已登记的目标（同一贴图先被 QueryTextureIsBuffer 定成贴图缓冲时，前后答案一致）
                return _new.GetTextureTarget(_stageIndex, handle, cbufSlot).ConvertSamplerType();
            }
            // 一维整数坐标取元（TEX / TLDS 一维、LOD 0、无偏移 / 深度比较 / 数组 / 多重采样）只问「是不是贴图缓冲」：缺省答「是」，并把该贴图登记成贴图缓冲。
            //   与上游无绑定时的假定同理（「一维时贴图缓冲更常见」）；10-22 暗黑2 原按缺省二维答「不是」，运行时 27 个程序全是贴图缓冲、首局全部重翻。
            //   猜错（真是一维贴图）只是首遇重翻一次，由 C① 收回
            public bool QueryTextureIsBuffer(int handle, int cbufSlot)
            {
                Ensure(handle, cbufSlot);
                _new.RegisterTexture(_stageIndex, handle, cbufSlot, _d.TexFormat, _d.TexSrgb, TextureTarget.TextureBuffer, _d.TexNorm);
                _new.S2ARecordTextureIsBuffer(_stageIndex, handle, cbufSlot);
                return true;
            }
            public TextureFormat QueryTextureFormat(int handle, int cbufSlot)
            {
                Ensure(handle, cbufSlot);
                _new.RecordTextureFormat(_stageIndex, handle, cbufSlot);
                return ConvertToTextureFormat(_d.TexFormat, _d.TexSrgb);
            }
            public bool QueryTextureCoordNormalized(int handle, int cbufSlot)
            {
                Ensure(handle, cbufSlot);
                _new.RecordTextureCoordNormalized(_stageIndex, handle, cbufSlot);
                return _d.TexNorm;
            }
            public bool QueryTransformFeedbackEnabled() => false;
            public ReadOnlySpan<byte> QueryTransformFeedbackVaryingLocations(int bufferIndex) => ReadOnlySpan<byte>.Empty;
            public int QueryTransformFeedbackStride(int bufferIndex) => 0;
            public bool QueryHasUnalignedStorageBuffer() => _d.G.HasUnalignedStorageBuffer || _cs.HasUnalignedStorageBuffer;
            public void RegisterTexture(int handle, int cbufSlot) => Ensure(handle, cbufSlot);
            // 运行时 GpuAccessor 的查询都先读描述符；这里按缺省值登记（设备加载时 DiskCacheGpuAccessor 要求每个用到的纹理都已登记）
            void Ensure(int handle, int cbufSlot)
            {
                if (!_new.TextureRegistered(_stageIndex, handle, cbufSlot)) _new.RegisterTexture(_stageIndex, handle, cbufSlot, _d.TexFormat, _d.TexSrgb, _d.TexTarget, _d.TexNorm);
            }
        }

        internal static readonly TrLog Tr = new();   // 甲段翻译告警（每进程一次烘焙）
        static readonly bool KeepPhaseASpirv = Environment.GetEnvironmentVariable("S2A_STAGE_ALL") == "1";
        static void PhaseA(GpuContext ctx, Prog p, Dictionary<string, XShader> xs, Defaults d)
        {
            TargetApi api = ctx.Capabilities.Api;
            ResourceCounts counts = new();
            if (p.Compute)
            {
                XShader x = xs[p.Keys[0]];
                GpuChannelComputeState cs = ComputeStateOf(x, d, ctx.Capabilities.MaximumComputeSharedMemorySize);
                ShaderSpecializationState ns = new(ref cs);
                BakeGpuAccessor a = new(ctx, x.Key, x.Mem, x.C1, d, cs, ns, counts, 0, false);
                a.InitializeReservedCounts(tfEnabled: false, vertexAsCompute: false);
                TranslatorContext tc = ShaderCache.DecodeComputeShader(a, api, 0);
                tc.Translate();
                p.Guest = new GuestCodeAndCbData?[] { Guest(x, tc) };
                p.Spec = ns;
                return;
            }

            GpuChannelGraphicsState g0 = d.G;
            if (p.Keys[5] != null && EarlyZOf(xs[p.Keys[5]], out bool ez)) { g0.EarlyZForce = ez; Interlocked.Increment(ref _earlyZFromCtl); if (ez) Interlocked.Increment(ref _earlyZOn); }
            if (p.Keys[3] != null && TessModeOf(xs[p.Keys[3]], out uint tm)) { g0.TessellationMode.Packed = tm; Interlocked.Increment(ref _tessFromCtl); }
            // 几何程序：翻译读图元拓扑（输入图元），运行时匹配按输入拓扑类比（Ryujinx 补丁 S2AInputTopology）。没有参照时按三角形烘（缺省状态的拓扑是计票值，零配置时是枚举零值「点」）
            if (p.Keys[4] != null)
            {
                g0.Topology = Enum.TryParse(Environment.GetEnvironmentVariable("S2A_GS_TOPO"), out PrimitiveTopology gt) ? gt : PrimitiveTopology.Triangles;   // S2A_GS_TOPO：诊断用，换拓扑反查
            }
            ShaderSpecializationState spec = new(ref g0, d.P, null);
            BakeGpuAccessor[] acc = new BakeGpuAccessor[5];
            TranslatorContext[] tcs = new TranslatorContext[NStages];
            TranslatorContext next = null;
            bool hasGs = p.Keys[4] != null;
            for (int si = 4; si >= 0; si--)
            {
                string k = p.Keys[si + 1];
                if (k == null) continue;
                XShader x = xs[k];
                acc[si] = new BakeGpuAccessor(ctx, x.Key, x.Mem, x.C1, d, default, spec, counts, si, hasGs);
                TranslatorContext cur = ShaderCache.DecodeGraphicsShader(acc[si], api, ShaderCache.DefaultFlags, 0);
                if (next != null) cur.SetNextStage(next);
                tcs[si + 1] = cur; next = cur;
            }
            if (p.StageOnly && tcs[1] != null && tcs[5] == null) tcs[1].S2ASetStandaloneNextFragment();   // 单独的顶点：按「下一阶段是片元」翻（与配对翻译同一结果）

            p.Guest = new GuestCodeAndCbData?[NStages];
            if (S2AVtg.IsVtg(ctx, tcs))
            {
                // 顶点 / 几何转计算（Ryujinx 补丁 S2AVtg，与运行时 GetGraphicsShader 同一路径）：甲段同样按转计算翻，特化状态登记与运行时一致；
                // 客体代码长度 / 常量段 1 长度要翻完才知道，先用整段抽出代码占位
                GuestCodeAndCbData?[] tmp = new GuestCodeAndCbData?[NStages];
                for (int si = 0; si < 5; si++) if (tcs[si + 1] != null) tmp[si + 1] = new GuestCodeAndCbData(xs[p.Keys[si + 1]].Mem.ToArray(), xs[p.Keys[si + 1]].C1);
                S2AVtg.Translate(ctx, tcs, acc, tmp, false);
                for (int si = 0; si < 5; si++) if (tcs[si + 1] != null) p.Guest[si + 1] = Guest(xs[p.Keys[si + 1]], tcs[si + 1]);
                p.Spec = spec;
                return;
            }

            for (int si = 0; si < 5; si++)
            {
                if (tcs[si + 1] == null) continue;
                acc[si].InitializeReservedCounts(false, false);
                byte[] spv = tcs[si + 1].Translate().BinaryCode;   // 甲段（缺省状态）照常翻译（翻译失败 = error_a）；字节只给阶段单独翻译出库、S2A_STAGE_ALL 核对留（大配对时全留会 OOM，10-20 暗黑2 窗口 1024）
                if (p.StageOnly || KeepPhaseASpirv) p.ASpirv[si + 1] = spv;
                p.Guest[si + 1] = Guest(xs[p.Keys[si + 1]], tcs[si + 1]);
            }
            p.Spec = spec;
        }

        // 早期深度（片元着色器 layout(early_fragment_tests)）：NVN 控制段 +0x718 位 0。运行时由驱动按程序写 3D 寄存器 EarlyZForce，翻译器据此给片元加
        // EarlyFragmentTests（编译期属性，不能运行时化）。证据见 bake 报告 spec_sources.EarlyZForce 与 10-21 画面·着色器线报告（怪猎运行时为真的片元该位全 1、其余全 0）
        static int _earlyZFromCtl, _earlyZOn, _computeFromCtl, _computeFallback, _tessFromCtl;
        // 继承条目按再翻收窄掉的贴图查询位数（S2ATrimTextureQueries，进出包报告 spec_trimmed_tex_queries）
        public static int TrimmedTexQueries;

        // 曲面细分模式（域 / 分区 / 绕序，3D 寄存器 TessMode 的打包值：位 0–1 域、4–5 分区、8 起绕序 / 输出图元）：NVN 控制段 +0x744 的 u32，只在曲面求值（ds / TES）上非零
        // （10-21 抽出集：怪猎 ds 32 支 = 0x900 ×17 / 0x901 ×15、暗黑2 ds 1 支 0x901、巫师3 ds 13 支 0x900；hs / vs / ps 全 0）。按驱动原样写寄存器取用；
        // 运行时真值尚未逐支核对（本分支渲染器不支持曲面，九款局缓存里 0 个曲面程序），由 Ryujinx 0092 首次命中核对兜底：不符即作废现翻并报红
        static bool TessModeOf(XShader x, out uint mode)
        {
            mode = x.Ctl.Length >= 0x748 ? BinaryPrimitives.ReadUInt32LittleEndian(x.Ctl.AsSpan(0x744)) : 0;
            return mode != 0 && (mode & ~0xF33u) == 0;
        }
        static bool EarlyZOf(XShader x, out bool earlyZ)
        {
            earlyZ = x.Ctl.Length > 0x718 && (x.Ctl[0x718] & 1) != 0;
            return x.Ctl.Length > 0x718;
        }

        static GuestCodeAndCbData Guest(XShader x, TranslatorContext tc)
        {
            byte[] code = x.Mem.Span[..tc.Size].ToArray();
            byte[] c1 = new byte[tc.Cb1DataSize];
            byte[] src = x.C1;
            Array.Copy(src, c1, Math.Min(src.Length, c1.Length));
            return new GuestCodeAndCbData(code, c1);
        }

        // NVN 控制段里的计算线程组大小（+0x748 起 3 个 u32）与共享内存；读不到就用缺省（已在 shc 数据上核对，见 bake.json compute_ctl_check）
        static GpuChannelComputeState ComputeStateOf(XShader x, Defaults d, int smemMax)
        {
            // 控制段：0x748 / 0x74C / 0x750 线程组尺寸，0x754 共享内存字节数（运行时 QMD 里是它按 256 字节向上对齐，10-20 怪猎 10 对现编 / 出包对拍全对上），0x758 局部内存字节数（原值；怪猎 32 字节 = 现编 8 个 uint）。
            // 再照运行时 ComputeClass 截到后端上限（Math.Min(qmd.SharedMemorySize, Capabilities.MaximumComputeSharedMemorySize)，后端报 48 KB；超出 Apple 32 KB 的由渲染器溢出到设备内存）——出包与运行时同键。
            // 共享内存大小 Ryujinx 运行时查缓存不比（MatchesCompute 只比未对齐存储缓冲），烘错了就带着错的数组长度上屏：没有参考缓存时缺省 0，越界写被丢（怪猎捏人页脸黑根因）
            if (x.Ctl.Length >= 0x75C)
            {
                int lx = BinaryPrimitives.ReadInt32LittleEndian(x.Ctl.AsSpan(0x748)), ly = BinaryPrimitives.ReadInt32LittleEndian(x.Ctl.AsSpan(0x74C)), lz = BinaryPrimitives.ReadInt32LittleEndian(x.Ctl.AsSpan(0x750));
                int sm = BinaryPrimitives.ReadInt32LittleEndian(x.Ctl.AsSpan(0x754)), lm = BinaryPrimitives.ReadInt32LittleEndian(x.Ctl.AsSpan(0x758));
                if (lx > 0 && ly > 0 && lz > 0 && lx * ly * lz <= 1024 && sm >= 0 && sm <= 0x10000 && lm >= 0 && lm <= 0x100000)
                {
                    Interlocked.Increment(ref _computeFromCtl);
                    return new GpuChannelComputeState(lx, ly, lz, lm, smemMax > 0 ? Math.Min((sm + 255) & ~255, smemMax) : (sm + 255) & ~255, d.C.HasUnalignedStorageBuffer);
                }
            }
            Interlocked.Increment(ref _computeFallback);
            return d.C;
        }

        // 出包报告：每个特化字段的取值来源（参照缓存票数 / NVN 控制段 / 运行时化 / 缺省值）与「翻译读过它的程序数」——来源是缺省值、又有程序读过的，就是包内条目可能与运行时不符的地方
        // （运行时首次命中会核对并报「包内特化不符」，见 Ryujinx 0092）。读过的程序数按乙段再翻记下的使用记录（第二代读位）数，旧参照条目没有第二代记录的不计
        static Dictionary<string, object> SpecSources(Defaults d, List<Prog> all, bool runtimeState)
        {
            var ok = all.Where(p => p.Status == "ok" && p.Spec != null).ToList();
            var gfx = ok.Where(p => !p.Compute).ToList(); var cs = ok.Where(p => p.Compute).ToList();
            int Bit(List<Prog> L, uint b) => L.Count(p => p.Spec.S2AUsageV2 && (p.Spec.S2AReadBits & b) != 0);
            int Tex(int q) => ok.Count(p => p.Spec.S2ATextures().Any(t => (t.Queried & q) != 0));
            string V(int votes) => votes > 0 ? $"票数（{votes} 个参照条目）" : "缺省值";
            ref GpuChannelGraphicsState g = ref d.G;
            var r = new Dictionary<string, object>();
            void F(string name, string source, object value, int read) => r[name] = new Dictionary<string, object> { ["来源"] = source, ["值"] = value, ["读过的程序"] = read };
            F("EarlyZForce", $"NVN 控制段 +0x718 位 0（片元 {_earlyZFromCtl} 个程序，其中为真 {_earlyZOn}）；没有片元的程序 {V(d.VotesG)}", g.EarlyZForce, Bit(gfx, S2AStateRead.EarlyZ));
            F("Topology", V(d.VotesG), g.Topology.ToString(), Bit(gfx, S2AStateRead.Topology));
            F("HalvePrimitiveId（由拓扑推）", V(d.VotesG), g.Topology.ToString(), Bit(gfx, S2AStateRead.HalvePrim));
            F("TessellationMode", $"NVN 控制段 +0x744（曲面求值 {_tessFromCtl} 个程序）；取不到 {V(d.VotesG)}", g.TessellationMode.Packed, Bit(gfx, S2AStateRead.Tess));
            F("PointSize", runtimeState ? "运行时化（支持缓冲 s2a_point，翻译不读）" : V(d.VotesG), g.PointSize, Bit(gfx, S2AStateRead.PointSize));
            F("AlphaToCoverageDither", V(d.VotesG) + "；另按观测补变体", g.AlphaToCoverageEnable && g.AlphaToCoverageDitherEnable, Bit(gfx, S2AStateRead.A2c));
            F("DepthMode", runtimeState ? "运行时化（s2a_flags.x 位 0）" : V(d.VotesG), g.DepthMode, Bit(gfx, S2AStateRead.Depth));
            F("AlphaTest", runtimeState ? "运行时化（比较方式 / 参考值走支持缓冲；开 / 关各出一份）" : V(d.VotesG), g.AlphaTestEnable, Bit(gfx, S2AStateRead.Alpha));
            F("HasConstantBufferDrawParameters", runtimeState ? "运行时化（s2a_flags.x 位 1）" : V(d.VotesG), g.HasConstantBufferDrawParameters, Bit(gfx, S2AStateRead.Cbdp));
            F("AttributeTypes", V(d.VotesG) + "；另按观测 / 整数推断补变体", "缺省类型", gfx.Count(p => p.Spec.S2AAttrRead != 0));
            F("FragmentOutputTypes（匹配比）", V(d.VotesG) + "；另按观测补变体（S2A_SPEC_PIPES 整数目标）", "缺省类型", gfx.Count(p => p.Guest.Length > 5 && p.Guest[5].HasValue));
            F("ViewportTransformDisable / DualSourceBlend / YNegate（匹配比）", V(d.VotesG), $"{g.ViewportTransformDisable}/{g.DualSourceBlendEnable}/{g.YNegateEnabled}", gfx.Count);
            F("ComputeLocalSize", $"NVN 控制段 +0x748（{_computeFromCtl} 个程序）；读不到 {_computeFallback} 个用 {V(d.VotesC)}", $"{d.C.LocalSizeX}x{d.C.LocalSizeY}x{d.C.LocalSizeZ}", cs.Count);
            F("ComputeSharedMemorySize", $"NVN 控制段 +0x754（同上）", d.C.SharedMemorySize, Bit(cs, S2AStateRead.SharedMem));
            F("ComputeLocalMemorySize", $"NVN 控制段 +0x758（同上）", d.C.LocalMemorySize, Bit(cs, S2AStateRead.LocalMem));
            F("ConstantBufferUse（匹配比）", string.Join(" ", Enumerable.Range(0, 5).Select(i => $"阶段{i}:{V(d.VotesCbUse[i])}")), string.Join(",", d.CbUse.Select(x => x?.ToString("X") ?? "0")), ok.Count);
            F("TextureFormat", V(d.VotesTexFormat), $"{d.TexFormat:X}{(d.TexSrgb ? "s" : "")}", Tex(1));
            F("TextureTarget（采样器类型，匹配比）", d.VotesTexTarget > 0 ? V(d.VotesTexTarget) : "缺省值（二维）", d.TexTarget.ToString(), Tex(2));
            F("TextureCoordNormalized", runtimeState ? "运行时化（s2a_flags.yzw 位图）" : (d.VotesTexNorm > 0 ? V(d.VotesTexNorm) : "缺省值（归一化）"), d.TexNorm, Tex(4));
            F("TextureArrayFromPool（贴图池）", V(d.VotesPoolT), d.PoolT, ok.Count(p => p.Spec.S2AArrayFromPool().Any(a => !a.IsSampler)));
            F("SamplerArrayFromPool（采样器池）", V(d.VotesPoolS), d.PoolS, ok.Count(p => p.Spec.S2AArrayFromPool().Any(a => a.IsSampler)));
            F("TextureArrayFromBuffer", V(d.VotesBuf), d.BufLen, ok.Count(p => p.Spec.S2AArrayFromBuffer().Any()));
            F("Cb1Data", "NVN 控制段 +0x700 / +0x704 指的机器码常量段", "-", ok.Count(p => p.Guest.Any(x => x.HasValue && x.Value.Cb1Data.Length > 0)));
            F("TransformFeedback", "缺省值（关）", "关", gfx.Count);
            // 缺省值来源单列：来源是缺省值、且有程序读过（核对会比）的字段
            var def = r.Where(kv => kv.Value is Dictionary<string, object> v && ((string)v["来源"]).StartsWith("缺省值") && (int)v["读过的程序"] > 0).Select(kv => $"{kv.Key}（{((Dictionary<string, object>)kv.Value)["读过的程序"]} 个程序读过）").ToList();
            r["缺省值来源"] = new Dictionary<string, object> { ["字段数"] = def.Count, ["字段"] = def, ["程序总数"] = ok.Count, ["有第二代读位的程序"] = ok.Count(p => p.Spec.S2AUsageV2) };
            return r;
        }

        // ================= 乙段：设备加载那条路（DiskCacheGpuAccessor 从客体代码 + 特化状态再翻） =================
        static void PhaseB(GpuContext ctx, Prog p)
        {
            TargetApi api = ctx.Capabilities.Api;
            GuestCodeAndCbData?[] g = p.Guest;
            ShaderSpecializationState spec = p.Spec;
            ResourceCounts counts = new();
            if (p.Compute)
            {
                GuestCodeAndCbData s = g[0].Value;
                ShaderSpecializationState ns = new(ref spec.ComputeState);
                DiskCacheGpuAccessor a = new(ctx, s.Code, s.Cb1Data, spec, ns, counts, 0, false);
                a.InitializeReservedCounts(tfEnabled: false, vertexAsCompute: false);
                ShaderProgram prog = ShaderCache.DecodeComputeShader(a, api, 0).Translate();
                p.Shaders = new[] { new CachedShaderStage(prog.Info, s.Code, s.Cb1Data) };
                p.Spirv.Add(prog.BinaryCode); p.Sources.Add(ShaderCache.CreateShaderSource(prog));
                Interlocked.Add(ref TrimmedTexQueries, spec.S2ATrimTextureQueries(ns));   // 计算程序同样收窄（10-23 暗黑2 剩 8 个计算程序带旧归一化查询）
                return;
            }

            ShaderSpecializationState newSpec = new(ref spec.GraphicsState, spec.PipelineState, spec.TransformFeedbackDescriptors);
            DiskCacheGpuAccessor[] acc = new DiskCacheGpuAccessor[5];
            TranslatorContext[] tcs = new TranslatorContext[NStages];
            TranslatorContext next = null;
            bool hasGs = g[4].HasValue;
            for (int si = 4; si >= 0; si--)
            {
                if (!g[si + 1].HasValue) continue;
                GuestCodeAndCbData s = g[si + 1].Value;
                acc[si] = new DiskCacheGpuAccessor(ctx, s.Code, s.Cb1Data, spec, newSpec, counts, si, hasGs);
                TranslatorContext cur = ShaderCache.DecodeGraphicsShader(acc[si], api, ShaderCache.DefaultFlags, 0);
                if (next != null) cur.SetNextStage(next);
                if (si == 0 && g[0].HasValue)
                {
                    DiskCacheGpuAccessor aa = new(ctx, g[0].Value.Code, g[0].Value.Cb1Data, spec, newSpec, counts, 0, hasGs);
                    tcs[0] = ShaderCache.DecodeGraphicsShader(aa, api, ShaderCache.DefaultFlags | TranslationFlags.VertexA, 0);
                }
                tcs[si + 1] = cur; next = cur;
            }
            if (S2AVtg.IsVtg(ctx, tcs))
            {
                // 转计算程序：设备加载走复合宿主二进制（S2AVtg.Load），回退到客体代码时加载器走同一个 S2AVtg.Translate
                bool tf = spec.TransformFeedbackDescriptors != null;
                S2AVtg.Translation t = S2AVtg.Translate(ctx, tcs, acc, g, tf);
                if (tcs[1] != null) { p.AttrInt = tcs[1].S2AAttrIntMask; p.AttrSint = tcs[1].S2AAttrSintMask; }
                VtgOut v = new() { Tf = tf, HasGs = t.GeometryCompute != null, VRes = t.VertexReservations, GRes = t.GeometryReservations, PassthroughInfo = t.PassthroughInfo };
                v.ComputeFom = ShaderInfoBuilder.BuildForVertexAsCompute(ctx, t.VertexCompute.Info, tf, fromCache: true).FragmentOutputMap;
                p.Spirv.Add(t.VertexCompute.BinaryCode); p.Sources.Add(new ShaderSource(t.VertexCompute.Code, t.VertexCompute.BinaryCode, ShaderStage.Compute, t.VertexCompute.Language));
                if (v.HasGs)
                {
                    v.GeometryFom = ShaderInfoBuilder.BuildForVertexAsCompute(ctx, t.GeometryCompute.Info, tf, fromCache: true).FragmentOutputMap;
                    p.Spirv.Add(t.GeometryCompute.BinaryCode); p.Sources.Add(new ShaderSource(t.GeometryCompute.Code, t.GeometryCompute.BinaryCode, ShaderStage.Compute, t.GeometryCompute.Language));
                }
                ShaderInfoBuilder ib = new(ctx, tf, vertexAsCompute: true);
                foreach (ShaderProgram gp in t.GraphicsStages) { ib.AddStageInfo(gp.Info); p.Spirv.Add(gp.BinaryCode); p.Sources.Add(ShaderCache.CreateShaderSource(gp)); }
                v.GraphicsFom = ib.Build(spec.PipelineState, fromCache: true).FragmentOutputMap;
                p.Vtg = v; p.Shaders = t.Shaders;
                spec.S2AMergeUsage(newSpec);
                Interlocked.Add(ref TrimmedTexQueries, spec.S2ATrimTextureQueries(newSpec));   // 转计算程序同样收窄
                return;
            }

            CachedShaderStage[] shaders = new CachedShaderStage[g.Length];
            TranslatorContext prev = null;
            for (int si = 0; si < 5; si++)
            {
                TranslatorContext cur = tcs[si + 1];
                if (cur != null)
                {
                    acc[si].InitializeReservedCounts(spec.TransformFeedbackDescriptors != null, false);
                    GuestCodeAndCbData s = g[si + 1].Value;
                    ShaderProgram prog;
                    if (si == 0 && g[0].HasValue)
                    {
                        prog = cur.Translate(tcs[0]);
                        p.AttrInt = cur.S2AAttrIntMask; p.AttrSint = cur.S2AAttrSintMask;
                        shaders[0] = new CachedShaderStage(null, g[0].Value.Code, g[0].Value.Cb1Data);
                        shaders[1] = new CachedShaderStage(prog.Info, s.Code, s.Cb1Data);
                    }
                    else
                    {
                        prog = cur.Translate();
                        if (si == 0) { p.AttrInt = cur.S2AAttrIntMask; p.AttrSint = cur.S2AAttrSintMask; }
                        shaders[si + 1] = new CachedShaderStage(prog.Info, s.Code, s.Cb1Data);
                    }
                    if (prog != null) { p.Spirv.Add(prog.BinaryCode); p.Sources.Add(ShaderCache.CreateShaderSource(prog)); }
                    prev = cur;
                }
                else
                {
                    switch (ShaderCache.S2ALayerRouteFor(ctx, prev, si))
                    {
                        case ShaderCache.S2ALayerRoute.GeometryPassthrough:
                            ShaderProgram gp = prev.GenerateGeometryPassthrough(); p.Spirv.Add(gp.BinaryCode); p.Sources.Add(ShaderCache.CreateShaderSource(gp)); p.GeometryPassthrough = true;
                            break;
                        case ShaderCache.S2ALayerRoute.Unsupported:
                            ShaderCache.S2ARejectLayerRoute();
                            break;
                    }
                }
            }
            p.Shaders = shaders;
            spec.S2AMergeUsage(newSpec);   // 写盘用的是 p.Spec（继承条目的原状态）：把这次再翻记下的「读过哪些状态」并进去，缓存匹配才能只比读过的（10-19）
            // 贴图查询记录按这次再翻收窄（10-23）：参照条目里当前翻译器不再查的（坐标归一化等），不进包、运行时不比
            Interlocked.Add(ref TrimmedTexQueries, spec.S2ATrimTextureQueries(newSpec));
        }

        public static string SpvKey(byte[] spv) => BinaryPrimitives.ReadUInt64LittleEndian(SHA256.HashData(spv)).ToString("x16"); // 与 gal_prog.m gal_spv_hash 同口径（SHA-256 前 8 字节按小端读成 u64）

        // 口径核对：常量取本仓 Ryujinx 源码（DiskCacheGuestStorage.TocMagic / VersionPacked，DiskCacheHostStorage.TocsMagic / FileFormatVersionPacked / CodeGenVersion），不在这里另抄数
        static uint RyuConst(Type t, string name) => Convert.ToUInt32(t.GetField(name, System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Static).GetRawConstantValue());

        /// <summary>返回 null = 口径一致；否则返回不一致的说明。</summary>
        static string CheckFormat(string dir)
        {
            string gt = Path.Combine(dir, "guest.toc"), st = Path.Combine(dir, "shared.toc");
            foreach (string f in new[] { gt, st, Path.Combine(dir, "guest.data"), Path.Combine(dir, "shared.data") })
                if (!File.Exists(f)) return $"{dir}：缺 {Path.GetFileName(f)}";
            long gl = new FileInfo(gt).Length, sl = new FileInfo(st).Length;
            if (gl < 32 || sl < 32) return $"{dir}：TOC 头不足 32 字节";
            byte[] g = new byte[32], h = new byte[32];
            using (FileStream f = File.OpenRead(gt)) f.ReadExactly(g);
            using (FileStream f = File.OpenRead(st)) f.ReadExactly(h);
            uint gm = BinaryPrimitives.ReadUInt32LittleEndian(g), gv = BinaryPrimitives.ReadUInt32LittleEndian(g.AsSpan(4));
            uint sm = BinaryPrimitives.ReadUInt32LittleEndian(h), sv = BinaryPrimitives.ReadUInt32LittleEndian(h.AsSpan(4)), cg = BinaryPrimitives.ReadUInt32LittleEndian(h.AsSpan(8));
            Type G = typeof(DiskCacheGuestStorage), H = typeof(DiskCacheHostStorage);
            uint wgm = RyuConst(G, "TocMagic"), wgv = RyuConst(G, "VersionPacked"), wsm = RyuConst(H, "TocsMagic"), wsv = RyuConst(H, "FileFormatVersionPacked"), wcg = RyuConst(H, "CodeGenVersion");
            List<string> e = new();
            if (gm != wgm) e.Add($"客体 TOC 魔数 {gm:X8}≠{wgm:X8}");
            if (gv != wgv) e.Add($"客体版本 {gv >> 16}.{gv & 0xffff}≠{wgv >> 16}.{wgv & 0xffff}");
            if (sm != wsm) e.Add($"共享 TOC 魔数 {sm:X8}≠{wsm:X8}");
            if (sv != wsv) e.Add($"共享版本 {sv >> 16}.{sv & 0xffff}≠{wsv >> 16}.{wsv & 0xffff}");
            if (cg != wcg) e.Add($"CodeGenVersion {cg}≠{wcg}");
            if ((gl - 32) % 16 != 0 || (sl - 32) % 8 != 0) e.Add("TOC 长度不是整条目");
            return e.Count == 0 ? null : $"{dir}：" + string.Join("；", e);
        }



        // 翻译用的 Gpu 上下文：渲染器 = 只答能力表的代理（BakeRenderer），能力表与运行时渲染器同一份（graphics/metal/cs/caps/NxCaps.cs）。设备能力按出包目标固定（不按出包这台 Mac 查）：
        // 缺省 iPhone 17 Pro Max：格式位 31、共享内存 32 KB。其他设备用实测的 S2A_TARGET_DEVICE_CAPS=格式位,共享内存字节；翻译结果依赖能力表，出包与运行时必须同一份。
        internal static List<GuestCodeAndCbData?[]> S2AReadCacheForTest(string dir) => ReadCache(dir).Select(r => r.Stages).ToList();   // VtgSelfTest 用
        internal static List<ShaderSpecializationState> S2AReadSpecsForTest(string dir) => ReadCache(dir).Select(r => r.Spec).ToList();   // FoutSelfTest 用

        internal static GpuContext MakeContext(out Capabilities caps)
        {
            ulong[] deviceCaps = TargetCaps.Parse(Environment.GetEnvironmentVariable("S2A_TARGET_DEVICE_CAPS"));
            Console.WriteLine($"Target device caps: formats={deviceCaps[0]}, shared={deviceCaps[1]}");
            caps = NxGal.NxCaps.Build(deviceCaps);
            return MakeContext(caps);
        }

        // Explicit offline profiles use the same context without inheriting Apple caps.
        internal static GpuContext MakeContext(Capabilities caps)
        {
            IRenderer r = BakeRenderer.Create(caps);
            GpuContext ctx = new(r, new Ryujinx.Common.Configuration.DirtyHacks(Array.Empty<ulong>()));
            ctx.Capabilities = caps;
            return ctx;
        }

        /// <summary>烘焙用渲染器：只答 GetCapabilities，其余任何成员被调用就抛异常——翻译若用到渲染器的别的行为，烘焙当场红，
        /// 不会悄悄依赖渲染器本体（烘焙器因此只引能力表工程，渲染器其余代码改了着色器不重烘）</summary>
        public class BakeRenderer : System.Reflection.DispatchProxy
        {
            Capabilities _caps;
            public static IRenderer Create(Capabilities caps)
            {
                IRenderer r = Create<IRenderer, BakeRenderer>();
                ((BakeRenderer)(object)r)._caps = caps;
                return r;
            }
            protected override object Invoke(System.Reflection.MethodInfo m, object[] args) =>
                m.Name == nameof(IRenderer.GetCapabilities) ? _caps : throw new NotSupportedException($"着色器烘焙不该调到渲染器 IRenderer.{m.Name}");
        }

        // ================= 主命令 =================
        /// <summary>
        /// shbake bake &lt;抽出目录（rows.tsv + src/）&gt; &lt;输出根&gt; --title &lt;程序号&gt; [--ref &lt;缓存目录（含 shared.toc）&gt;]… [--ref-guest &lt;收回的运行时缓存目录&gt;]… [--ref-bundle &lt;客体代码包 .s2gb&gt;]… [-j N] [--limit N] [--xc &lt;gal_xc&gt; [--plat ios|macos]] [--fbr-vars &lt;读帧缓冲变体请求表&gt;]
        ///   [--vulkan-profile &lt;profile.json&gt; --content-root &lt;sha256-…&gt; [--spirv-val &lt;路径&gt;]]
        /// 输出：&lt;输出根&gt;/shcache/&lt;程序号小写&gt;/guest.* shared.*（给了 --xc 再加 vulkan_nxgal_bin.*）、&lt;输出根&gt;/spv/&lt;键&gt;.spv、&lt;输出根&gt;/lib/（gal_xc：msl/ + gal.idx）、programs.tsv、bake.json。
        /// 给了 --vulkan-profile 时改为 &lt;输出根&gt;/vulkan/generic/&lt;profileKey&gt;/{profile.json,manifest.json,shcache/&lt;程序号&gt;/}：宿主记录是 VKPB v1，不跑 gal_xc。
        /// 返回 0 = 无红；1 = 有红（分项见 bake.json red）；2 = 参数 / 输入错
        /// </summary>
        public static int BakeCmd(string[] a)
        {
            string xdir = a[0], outRoot = a[1], title = null; List<string> refDirs = new(), coverDirs = new(), guestDirs = new(), reflibs = new(); int j = Environment.ProcessorCount, limit = int.MaxValue; string xc = null, plat = "ios", fbrVars = null, vulkanProfilePath = null, contentRoot = null, spirvVal = null; bool allowExtrap = true;
            for (int i = 2; i < a.Length; i++)
            {
                switch (a[i])
                {
                    case "--title": title = a[++i].ToLowerInvariant(); break;
                    case "--ref": refDirs.Add(a[++i]); break;
                    case "--ref-cover": coverDirs.Add(a[++i]); break;   // 只作配对覆盖真值：读客体代码组合，不继承、不核版本（旧局缓存也能用）
                    // 收回的运行时缓存（C①）：口径版本与当前一致 → 同 --ref 原样继承（连特化状态：运行时观测到的变体如片元输出类型也进包）；
                    //   不一致 → 只取客体代码 + 阶段组合，缺的按当前翻译器缺省状态重烘（跨版本可用）
                    case "--ref-guest": { string g = a[++i], bad = CheckFormat(g); if (bad == null) refDirs.Add(g); else { guestDirs.Add(g); Console.Error.WriteLine($"shbake --ref-guest：{g} 口径不同（{bad}），只取客体代码"); } break; }
                    case "--ref-bundle": guestDirs.Add("bundle:" + a[++i]); break;   // 客体代码包（社区 / 用户自带的 yuzu 系缓存，guest_cache.py 转出）：同 --ref-guest 只取客体代码，缺的按缺省状态烘
                    case "--reflib": reflibs.Add(a[++i]); break;   // 参考库（社区缓存抽出的组合关系，.s2rl，格式见 grokbot_tool/README）：用静态抽出的着色器按规范 Fp 配出参考库里的程序
                    case "-j": j = int.Parse(a[++i]); break;
                    case "--limit": limit = int.Parse(a[++i]); break;
                    case "--xc": xc = a[++i]; break;       // gal_xc 路径：给了就当场出离线索引，并按索引记录写宿主程序二进制（vulkan_nxgal_bin.*，手机首启不重翻）
                    case "--plat": plat = a[++i]; break;   // ios（缺省）| macos：gal_xc 的目标平台
                    case "--fbr-vars": fbrVars = a[++i]; break;
                    case "--vulkan-profile": vulkanProfilePath = a[++i]; break;   // 设备导出的显式 Vulkan 翻译 profile（graphics/vulkan/cache/VulkanProfile.cs）：给出即走 Android VKPB 出包
                    case "--content-root": contentRoot = a[++i]; break;           // A0 内容根 sha256-…：写进包 manifest，装包时与已安装内容核对
                    case "--spirv-val": spirvVal = a[++i]; break;                 // spirv-val 路径（缺省 PATH）；进记录的每支 SPIR-V 都按 profile 目标环境验
                    // 本款不按原画框外推（游戏自己出宽 / 16:9 款：shader_pack.sh 按产物根 widen_full 表判）：不注入外推代码（SpirvExtrap），着色器同没有外推时
                    case "--no-extrap": allowExtrap = false; break;   // 读帧缓冲变体请求表（graphics/tools/shbake/fbrvars.py 收的 fbr_vars.tsv）：交 gal_xc --fbr 改写 + 预编进包
                    default: Console.Error.WriteLine($"--shbake：不认识的参数 {a[i]}"); return 2;
                }
            }
            if (title == null) { Console.Error.WriteLine("--shbake 要 --title <程序号>"); return 2; }
            VulkanProfile vkProfile = null;
            string packRoot = null, cacheDir;
            if (vulkanProfilePath != null)
            {
                if (xc != null) { Console.Error.WriteLine("--vulkan-profile 与 --xc 互斥：Android VKPB 出包不跑 gal_xc"); return 2; }
                if (contentRoot == null) { Console.Error.WriteLine("--vulkan-profile 要 --content-root <sha256-…>：离线包按内容版本准入"); return 2; }
                try { vkProfile = VulkanProfile.Load(vulkanProfilePath); }
                catch (Exception e) { Console.Error.WriteLine($"🔴 shbake：Vulkan profile 读不了（{vulkanProfilePath}）：{e.Message}"); return 2; }
                if (!SpirvValWorks(spirvVal ?? "spirv-val", out string validatorError))
                {
                    Console.Error.WriteLine($"🔴 shbake：spirv-val 不可用（{spirvVal ?? "spirv-val"}）：{validatorError}");
                    return 2;
                }
                packRoot = Path.Combine(outRoot, "vulkan", ShaderPackManifest.GraphicsMode, vkProfile.Identity.ProfileKey);
                cacheDir = Path.Combine(packRoot, "shcache", title);
                Console.WriteLine($"shbake：Vulkan 出包 {vkProfile.Describe()}，target-env {vkProfile.TargetEnv} → {packRoot}");
            }
            else
            {
                cacheDir = Path.Combine(outRoot, "shcache", title);
            }
            string spvDir = Path.Combine(outRoot, "spv");
            if (Directory.Exists(cacheDir) && Directory.EnumerateFileSystemEntries(cacheDir).Any()) { Console.Error.WriteLine($"{cacheDir} 已有内容：输出根要新目录（不覆盖）"); return 2; }
            Directory.CreateDirectory(cacheDir); Directory.CreateDirectory(spvDir);
            Stopwatch total = Stopwatch.StartNew();
            Dictionary<string, object> rep = new();

            // 1) 已有缓存
            Stopwatch sw = Stopwatch.StartNew();
            List<RefProgram> refs = new();
            List<object> refRep = new();
            foreach (string r in refDirs)
            {
                var l = ReadCache(r); refs.AddRange(l);
                refRep.Add(new Dictionary<string, object> { ["dir"] = r, ["programs"] = l.Count });
            }
            // 去重：客体代码 + 特化状态全同算一个
            Dictionary<string, RefProgram> uref = new();
            foreach (RefProgram r in refs)
            {
                StringBuilder k = new(r.Compute ? "c" : "g");
                foreach (var s in r.Stages) k.Append('|').Append(s.HasValue ? Sha(s.Value.Code, 32) + ":" + Sha(s.Value.Cb1Data, 16) : "-");
                k.Append('|').Append(Sha(r.SpecBytes, 32));
                uref.TryAdd(k.ToString(), r);
            }
            List<RefProgram> refsU = uref.Values.ToList();
            int refsUniqueBefore = refsU.Count;
            // S2A：同一客体代码的旧包记录若没有 PipelineState、而新导出记录有，只保留有 state 的记录。
            // 否则运行时缓存查找会先命中无状态记录，ProgramBinary.Info.State 为空，永远不进
            // BackgroundCompilation，首启仍逐条同步建管线（Wonder 8E：214 条 / 2104 ms）。
            // 比对键要带上「去掉 PipelineState 后的完整特化字节」：同客体代码但别的特化字段不同的
            // 无状态记录是另一个变体，删掉会在设备上首遇重翻。
            var merge = PipelineStatePreference.PreferStateful(
                refsU,
                r => GuestId(r.Compute, r.Stages),
                r => GuestId(r.Compute, r.Stages) + "|" + Sha(SpecBytesWithoutPipelineState(r.Spec), 32),
                r => r.Compute,
                r => r.Spec?.PipelineState.HasValue == true);
            refsU = merge.Items;
            rep["refs"] = refRep; rep["ref_programs_total"] = refs.Count; rep["ref_programs_unique"] = refsU.Count;
            rep["pipeline_state_prefer"] = new Dictionary<string, object>
            {
                ["refs_unique_before"] = refsUniqueBefore,
                ["refs_unique_after"] = refsU.Count,
                ["dropped_no_state"] = merge.DroppedNoState,
                ["no_state_same_guest"] = merge.NoStateSameGuest,
                ["no_state_kept_different_spec"] = merge.NoStateSameGuest - merge.DroppedNoState,
            };
            GpuContext ctx;
            Capabilities caps;
            if (vkProfile != null)
            {
                caps = vkProfile.Capabilities;
                ctx = MakeContext(caps);
                // 离线出包必须写出设备会读的同一份宿主文件名：渲染器策略在 ShBake 里不存在，按同一身份算 discriminator。
                ctx.S2AHostProgramCacheDiscriminator = DiscriminatorOf(vkProfile.Identity);
                Directory.CreateDirectory(packRoot);
                File.WriteAllBytes(Path.Combine(packRoot, "profile.json"), vkProfile.ToJson());
            }
            else
            {
                ctx = MakeContext(out caps);
            }
            Defaults d = ComputeDefaults(refsU, caps);
            rep["defaults"] = d.Report;
            double refMs = sw.Elapsed.TotalMilliseconds;

            // 2) 抽出集
            sw.Restart();
            Dictionary<string, XShader> xs = new();
            List<(string key, string st, string src, string v)> rows = new();
            foreach (string line in File.ReadLines(Path.Combine(xdir, "rows.tsv")))
            {
                if (line.StartsWith('#')) continue;
                string[] f = line.Split('\t');
                rows.Add((f[0], f[1], f[2], f[3]));
            }
            Dictionary<string, string> stageOf = rows.GroupBy(r => r.key).ToDictionary(g => g.Key, g => g.First().st);
            var packed = SrcPack.ReadAll(xdir);   // 着色器字节在 src/*.pk（SrcPack.cs；原先每支两个小文件）
            foreach (var kv in stageOf)
            {
                if (!packed.TryGetValue(kv.Key, out var b)) throw new FileNotFoundException($"抽取目录 {xdir} 的 src/*.pk 里没有键 {kv.Key}（rows.tsv 列了它）");
                xs[kv.Key] = new XShader { Key = kv.Key, Stage = kv.Value, Code = b.Code, Ctl = b.Ctl };
            }

            // 3) 配对规则 → 程序表
            Dictionary<string, Prog> progs = new(); // 键：各阶段键
            int rawPrograms = 0; List<string> unpaired = new();
            void AddProg(string src, bool compute, IEnumerable<(string st, string key)> stages)
            {
                rawPrograms++;
                Prog p = new() { Source = src, Compute = compute };
                foreach (var (st, key) in stages) p.Keys[compute ? 0 : StageIndexOf(st)] = key;
                p.Id = string.Join(",", p.Keys.Select(k => k ?? "-"));
                progs.TryAdd(p.Id, p);
            }
            foreach (var g in rows.Where(r => r.src.Split("//")[^1].Contains('#')).GroupBy(r => (r.src, r.v)))
            {
                var st = g.Select(r => (r.st, r.key)).ToList();
                if (st.Any(s => s.st == "cs")) { foreach (var s in st) AddProg($"{g.Key.src}v{g.Key.v}", true, new[] { s }); continue; }
                if (st.Select(s => s.st).Distinct().Count() != st.Count) { unpaired.Add($"{g.Key.src}v{g.Key.v}：同阶段多支"); continue; }
                AddProg($"{g.Key.src}v{g.Key.v}", false, st);
            }
            // BAHS（sharcb）与偏移头文件：按记录在文件里的顺序，vs 紧跟 ps = 一个程序
            foreach (var g in rows.Where(r => r.src.Contains("@bahs") || r.src.Contains("@hdr")).GroupBy(r => r.src[..r.src.LastIndexOf('@')]))
            {
                var L = g.Select(r => (off: Convert.ToInt64(r.src[(r.src.LastIndexOf('@') + 1)..].TrimStart('a', 'b', 'd', 'h', 'r', 's'), 16), r.st, r.key)).OrderBy(r => r.off).ToList();
                for (int i = 0; i < L.Count; i++)
                {
                    if (L[i].st == "cs") { AddProg($"{g.Key}@{L[i].off:x}", true, new[] { (L[i].st, L[i].key) }); continue; }
                    if (L[i].st == "vs" && i + 1 < L.Count && L[i + 1].st == "ps") { AddProg($"{g.Key}@{L[i].off:x}", false, new[] { ("vs", L[i].key), ("ps", L[i + 1].key) }); i++; continue; }
                    unpaired.Add($"{g.Key}@{L[i].off:x} {L[i].st} {L[i].key}：后面不是 ps");
                }
            }
            // 曲面程序（10-21 tess）：相邻扫描出的同一容器（来源 @adj 前缀相同）按偏移排序，每支 ds 配「它之前最近的 hs、该 hs 之前最近的 vs、ds 之后最近的 ps（中间遇到别的 hs / ds 即止）」
            //   = vs + hs + ds + ps 一个程序。容器里一个通道的阶段按 vs hs ds ps 顺序存放（怪猎 56 支曲面 10-21 实测，同一 hs 后接多支 ds 的各配各的 ps）；
            //   猜多了只多编，猜漏的运行时首遇现编（安全网）
            foreach (var g in rows.Where(r => r.src.Contains("@adj")).GroupBy(r => r.src[..r.src.LastIndexOf("@adj", StringComparison.Ordinal)]))
            {
                if (!g.Any(r => r.st == "ds") || !g.Any(r => r.st == "hs")) continue;   // 容器里没有 hs（如巫师3 一帧一支）：不归这条规则
                var L = g.Select(r => (off: Convert.ToInt64(r.src[(r.src.LastIndexOf("@adj", StringComparison.Ordinal) + 4)..], 16), r.st, r.key)).OrderBy(x => x.off).ToList();
                for (int i = 0; i < L.Count; i++)
                {
                    if (L[i].st != "ds") continue;
                    int h = i - 1; while (h >= 0 && L[h].st != "hs") h--;
                    int v = h - 1; while (v >= 0 && L[v].st != "vs") v--;
                    int q = i + 1; while (q < L.Count && L[q].st != "ps" && L[q].st != "hs" && L[q].st != "ds") q++;
                    if (h < 0 || v < 0 || q >= L.Count || L[q].st != "ps") { unpaired.Add($"{g.Key}@{L[i].off:x} ds {L[i].key}：同容器里配不齐 vs / hs / ps"); continue; }
                    AddProg($"{g.Key}@tess{L[i].off:x}", false, new[] { ("vs", L[v].key), ("hs", L[h].key), ("ds", L[i].key), ("ps", L[q].key) });
                }
            }
            // 外部程序表（S2A_PROG_TABLE=<tsv：vs 键 \t hs 键 \t ds 键 \t gs 键 \t ps 键，缺的阶段写 ->，由按容器格式的读取器出，如 rdhs_programs.py 读巫师3 shadernx.cache 的条目表）：
            //   每行一个程序；键不在抽取里的行不收（计数报出）
            string progTable = Environment.GetEnvironmentVariable("S2A_PROG_TABLE");
            if (!string.IsNullOrEmpty(progTable))
            {
                HashSet<string> have = rows.Select(r => r.key).ToHashSet(); int ok = 0, miss = 0;
                foreach (string line in File.ReadLines(progTable))
                {
                    if (line.StartsWith('#')) continue;
                    string[] f = line.Split('\t'); if (f.Length < 5) continue;
                    string[] st = { "vs", "hs", "ds", "gs", "ps" };
                    var stages = Enumerable.Range(0, 5).Where(i => f[i] != "-").Select(i => (st[i], f[i])).ToList();
                    if (stages.Any(x => !have.Contains(x.Item2))) { miss++; continue; }
                    AddProg($"table:{Path.GetFileName(progTable)}", false, stages); ok++;
                }
                Console.WriteLine($"shbake：外部程序表 {progTable}：{ok} 个程序（{miss} 行有键不在抽取里）");
            }
            // 外部配对表（S2A_PAIR_TABLE=<tsv：vs 文件名 \t ps 文件名 …>，由按引擎的静态推导工具出，如 scripts/d2r_exe_pairs.py 从主程序推）：
            // 表里每对文件，vs 与 ps 在两边共有的排列宏上取值一致即成程序（宏取值来自来源标记 @shad<号>|宏=值,…），按代码键去重
            string pairTable = Environment.GetEnvironmentVariable("S2A_PAIR_TABLE");
            if (!string.IsNullOrEmpty(pairTable))
            {
                var byFile = rows.Where(r => r.src.Contains("@shad") && (r.st == "vs" || r.st == "ps")).Select(r =>
                {
                    int at = r.src.IndexOf("@shad", StringComparison.Ordinal), bar = r.src.IndexOf('|', at);
                    var defs = (bar < 0 ? "" : r.src[(bar + 1)..]).Split(',', StringSplitOptions.RemoveEmptyEntries).Select(kv => kv.Split('=', 2)).ToDictionary(kv => kv[0], kv => kv.Length > 1 ? kv[1] : "");
                    return (file: Path.GetFileName(r.src[..at]), r.key, defs);
                }).GroupBy(x => x.file).ToDictionary(g => g.Key, g => g.ToList());
                int tabPairs = 0, tabMissing = 0;
                foreach (string line in File.ReadLines(pairTable))
                {
                    string[] f = line.Split('\t'); if (f.Length < 2) continue;
                    if (!byFile.TryGetValue(f[0], out var vs) || !byFile.TryGetValue(f[1], out var ps)) { tabMissing++; continue; }
                    tabPairs++;
                    // 第 3 / 4 列（exe_programs.py）：构造调用点上 vs / ps 的宏约束「名=值|值…」，逗号分隔；名 ? / 值 * / 整列 * = 不约束
                    static Dictionary<string, HashSet<string>> Cons(string c) => c == null || c == "*" ? new() : c.Split(',', StringSplitOptions.RemoveEmptyEntries)
                        .Select(kv => kv.Split('=', 2)).Where(kv => kv.Length == 2 && kv[0] != "?" && kv[1] != "*")
                        .GroupBy(kv => kv[0]).ToDictionary(g => g.Key, g => g.SelectMany(kv => kv[1].Split('|')).ToHashSet());
                    var cv = Cons(f.Length > 2 ? f[2] : null); var cp = Cons(f.Length > 3 ? f[3] : null);
                    static bool Ok(Dictionary<string, string> d, Dictionary<string, HashSet<string>> c) => c.All(kv => !d.TryGetValue(kv.Key, out string v) || kv.Value.Contains(v));
                    vs = vs.Where(x => Ok(x.defs, cv)).ToList(); ps = ps.Where(x => Ok(x.defs, cp)).ToList();
                    if (vs.Count == 0 || ps.Count == 0) { tabMissing++; continue; }
                    string[] shared = vs[0].defs.Keys.Intersect(ps[0].defs.Keys).OrderBy(k => k, StringComparer.Ordinal).ToArray();
                    string Tup(Dictionary<string, string> d) => string.Join(",", shared.Select(k => d[k]));
                    var psBy = ps.GroupBy(x => Tup(x.defs)).ToDictionary(t => t.Key, t => t.Select(x => x.key).Distinct().ToList());
                    foreach (var vk in vs.GroupBy(x => Tup(x.defs)))
                        if (psBy.TryGetValue(vk.Key, out var pks))
                            foreach (string kv in vk.Select(x => x.key).Distinct())
                                foreach (string kp in pks) AddProg($"pair:{f[0]}+{f[1]}", false, new[] { ("vs", kv), ("ps", kp) });
                }
                Console.WriteLine($"shbake：外部配对表 {pairTable}：{tabPairs} 对文件（{tabMissing} 对在抽取里找不到）");
            }
            // 几何着色器静态配对（10-21，S2AVtg 让转计算程序能进缓存之后）：没进上面任何程序的 gs，按同一容器内的记录顺序与 SPH 接口配
            int gsPaired = PairGeometry(rows, xs, progs.Values.SelectMany(q => q.Keys).Where(k => k != null).ToHashSet(), AddProg, rep);
            foreach (var r in rows.Where(r => r.src.StartsWith("miss:")))
            {
                if (r.st == "cs") AddProg(r.src, true, new[] { (r.st, r.key) });
                else unpaired.Add($"{r.src} {r.st}：运行时落盘的单支，没有程序表（只靠已有缓存继承）");
            }
            // 计算着色器本身就是完整程序、不需配对：任何来源（含暗黑2 casc 抽取，不带程序表）抽到的都单独成程序（10-19：暗黑2 28 支 cs 没命中来源规则被报红）
            foreach (var r in rows.Where(r => r.st == "cs")) AddProg(r.src, true, new[] { (r.st, r.key) });
            int rulePrograms = progs.Count;
            // 阶段单独翻译（10-19 B 方案一期）：没配进任何程序的顶点 / 片元也各自按缺省状态翻译，SPIR-V 进离线库（运行时组合成程序时函数已在库里，不再现编 Metal）
            HashSet<string> s2aUsed = progs.Values.SelectMany(q => q.Keys).Where(k => k != null).ToHashSet();
            // 阶段单独翻译只跳过「会进包的程序」里的顶点 / 片元：带几何的程序走顶点转计算、Ryujinx 不缓存（甲段 skip_vtg_compute），它的片元运行时照常要 Metal 函数，仍单独翻（10-21 怪猎 SDF 配出 583 个带几何的程序）
            HashSet<string> s2aBaked = progs.Values.Where(q => q.Compute || q.Keys[4] == null).SelectMany(q => q.Keys).Where(k => k != null).ToHashSet();
            bool s2aAll = Environment.GetEnvironmentVariable("S2A_STAGE_ALL") == "1";   // 验证用：已配进程序的也单独翻一遍，和配对翻译比 SPIR-V 键
            List<Prog> stageOnly = rows.Where(r => (r.st == "vs" || r.st == "ps") && (s2aAll || !s2aBaked.Contains(r.key))).GroupBy(r => r.key).Select(g => g.First())
                .Select(r => { Prog q = new() { Source = "stage:" + r.src, Compute = false, StageOnly = true, Origin = "stage" }; q.Keys[StageIndexOf(r.st)] = r.key; q.Id = "stage:" + r.key; return q; }).ToList();
            // 没命中任何配对规则、也没走阶段单独翻译（顶点 / 片元以外）的抽取条目：计入未配对并报红（10-19 总指挥：暗黑2 10858 条全部静默丢掉，静态预编只剩种子里的 96 个程序）
            Func<(string src, string st, string key), bool> s2aNoRule = r => !s2aUsed.Contains(r.key) && r.st != "vs" && r.st != "ps" && !r.src.StartsWith("miss:");
            int noRule = 0, noRuleGs = 0, noRuleTess = 0;
            foreach (var r in rows.Where(r => s2aNoRule((r.src, r.st, r.key))).GroupBy(r => r.key).Select(g => g.First()))
            {
                if (r.st == "gs") noRuleGs++; else if (r.st == "hs" || r.st == "ds") noRuleTess++; else noRule++;   // 几何 / 曲面另计：见下方 known_gap
                if (unpaired.Count < 100000) unpaired.Add($"{r.src} {r.st} {r.key}：没命中任何配对规则");
            }
            if (noRule + noRuleGs + noRuleTess > 0) Console.Error.WriteLine($"【红】shbake：{noRule + noRuleGs + noRuleTess} 条抽取到的着色器没命中任何配对规则，没进全量（其中几何 {noRuleGs}、曲面 {noRuleTess}；例：{rows.First(r => s2aNoRule((r.src, r.st, r.key))).src}）");
            rep["no_rule"] = noRule; rep["no_rule_gs"] = noRuleGs; rep["no_rule_tess"] = noRuleTess;

            // 4) 甲段：规则配出的程序全部按缺省状态翻一遍，得到客体代码实际长度（Ryujinx 按「客体代码」查缓存，不按抽出键：
            //    不同的键去掉指令区之后的常量 / 填充可能是同一份客体代码），并行
            List<Prog> rule = progs.Values.Where(p => Environment.GetEnvironmentVariable("S2A_SHBAKE_GS_ONLY") != "1" || p.Keys[4] != null).OrderBy(p => p.Id, StringComparer.Ordinal).Take(limit).ToList();   // S2A_SHBAKE_GS_ONLY=1：诊断用，只翻带几何的程序
            double prepMs = sw.Elapsed.TotalMilliseconds;
            sw.Restart();
            Parallel.ForEach(rule, new ParallelOptions { MaxDegreeOfParallelism = j }, p =>
            {
                long t0 = Stopwatch.GetTimestamp();
                try { PhaseA(ctx, p, xs, d); }
                catch (Exception e) { p.Status = "error_a"; p.Err = $"{e.GetType().Name}: {e.Message}".Replace('\t', ' ').Replace('\n', ' '); }
                p.Ms = (Stopwatch.GetTimestamp() - t0) * 1000.0 / Stopwatch.Frequency;
            });
            Parallel.ForEach(stageOnly, new ParallelOptions { MaxDegreeOfParallelism = j }, p =>
            {
                try { PhaseA(ctx, p, xs, d); }
                catch (Exception e) { p.Status = "error_a"; p.Err = $"{e.GetType().Name}: {e.Message}".Replace('\t', ' ').Replace('\n', ' '); }
            });
            // 4b) 收回的运行时缓存（--ref-guest，10-21 首局根治 C①：每局遇到包里没有的代码，自动收回、并入下一版包）：
            //   只取客体代码与阶段组合（ReadCache 只读客体模式，不核口径版本、不读特化状态），各阶段代码组合已被规则程序覆盖的跳过；
            //   缺的合成抽出条目（图形补 0x30 字节零头 = NVN 头位置，常量段 1 原样给，控制段全零 = 早期深度 / 曲面模式走缺省），按缺省状态翻，并进规则程序走同一条路
            int rgAll = 0, rgHave = 0, rgDup = 0, rgVsA = 0, rgBad = 0, rgStatic = 0; List<Prog> rgAdd = new();
            if (guestDirs.Count > 0)
            {
                HashSet<string> have = rule.Concat(stageOnly).Where(p => p.Guest != null && p.Status == "ok" && !p.StageOnly).Select(p => (p.Compute ? "c" : "g") + CodeId(p.Guest)).ToHashSet();
                string[] stName = { null, "vs", "hs", "ds", "gs", "ps" };
                HashSet<string> seen = new();
                // 客体代码包（--ref-bundle，yuzu 系缓存）：代码长度口径与静态抽取不同（yuzu 带到末尾自跳转），按完整代码比永远对不上（10-27 王国之泪首跑「覆盖 0、新收 15269」）。
                //   改按规范 Fp（截到第一条 EXIT / KIL，同参考库）对静态抽出的着色器：各阶段都在静态里的跳过（组合关系交参考库、代码用静态那份），只收含静态没有的代码的程序
                HashSet<(ulong, string)> staticFp = null;
                foreach (string dir in guestDirs)
                {
                    List<RefProgram> got;
                    try { got = dir.StartsWith("bundle:") ? ReadBundle(dir[7..]) : ReadCache(dir, true); } catch (Exception e) { rgBad++; Console.Error.WriteLine($"【红】shbake --ref-guest 读不了 {dir}：{e.Message}"); continue; }
                    foreach (RefProgram r in got)
                    {
                        rgAll++;
                        if (!r.Compute && r.Stages[0].HasValue) { rgVsA++; continue; }   // 双顶点（VertexA）程序：甲段不翻这一路，计数不收
                        if (dir.StartsWith("bundle:"))
                        {
                            staticFp ??= xs.Values.Where(x => !x.Key.StartsWith("rt:")).Select(x => (CanonFp(x.Mem.Span, x.Compute), x.Stage)).ToHashSet();
                            bool inStatic = true;
                            for (int si = 0; si < r.Stages.Length && inStatic; si++)
                                if (r.Stages[si].HasValue && !staticFp.Contains((CanonFp(r.Stages[si].Value.Code, r.Compute), r.Compute ? "cs" : stName[si]))) inStatic = false;
                            if (inStatic) { rgStatic++; continue; }
                        }
                        string cid = (r.Compute ? "c" : "g") + CodeId(r.Stages);
                        if (have.Contains(cid)) { rgHave++; continue; }
                        if (!seen.Add(cid)) { rgDup++; continue; }   // 缓存里同一份代码的多个特化变体（透明测试开 / 关等）：按缺省状态只烘一个
                        Prog p = new() { Source = "ref_guest:" + dir, Compute = r.Compute, Origin = "ref_guest" };
                        for (int si = 0; si < r.Stages.Length; si++)
                        {
                            if (!r.Stages[si].HasValue) continue;
                            GuestCodeAndCbData g = r.Stages[si].Value;
                            string key = "rt:" + Sha(g.Code, 32) + ":" + Sha(g.Cb1Data, 16);
                            byte[] code = r.Compute ? g.Code : new byte[0x30].Concat(g.Code).ToArray();
                            lock (xs) xs.TryAdd(key, new XShader { Key = key, Stage = r.Compute ? "cs" : stName[si], Code = code, Ctl = new byte[0x800], C1Raw = g.Cb1Data });
                            p.Keys[si] = key;
                        }
                        p.Id = string.Join(",", p.Keys.Select(k => k ?? "-"));
                        rgAdd.Add(p);
                    }
                }
                Parallel.ForEach(rgAdd, new ParallelOptions { MaxDegreeOfParallelism = j }, p =>
                {
                    try { PhaseA(ctx, p, xs, d); }
                    catch (Exception e) { p.Status = "error_a"; p.Err = $"{e.GetType().Name}: {e.Message}".Replace('\t', ' ').Replace('\n', ' '); }
                });
                rule.AddRange(rgAdd);
                Console.Error.WriteLine($"shbake --ref-guest：{guestDirs.Count} 份缓存 {rgAll} 个程序，各阶段代码静态已有（客体代码包）{rgStatic}、已被规则覆盖 {rgHave}、缓存内同代码变体 {rgDup}、新收 {rgAdd.Count}（翻成 {rgAdd.Count(p => p.Status == "ok")}）、双顶点不收 {rgVsA}、读不了 {rgBad} 份");
            }
            // 4c) 参考库（--reflib，10-22 总指挥：参考库只存组合不存代码，代码来自玩家自己的游戏文件）：
            //   静态抽出的每支着色器按规范 Fp（客体代码截到第一条无条件 EXIT / KIL 再 sha1 取前 8 字节，与参考库同口径）建表；
            //   参考库里每个程序各阶段指纹都按阶段对上静态着色器的，合成程序（代码用静态抽出的），并进规则程序走同一条路；
            //   对不上的指纹只记数、不补代码。状态：第一版按当前翻译器缺省状态翻（特化状态 / yuzu 管线键映射由着色器线评估后再接）；
            //   各阶段代码组合已被规则程序覆盖的跳过、参考库内同代码组合（只差状态）只烘一个；双顶点（VertexA）同 ref-guest 不收
            int rlAll = 0, rlHave = 0, rlDup = 0, rlVsA = 0, rlMiss = 0, rlStage = 0, rlNoVs = 0;
            // rlRows：配上的图形程序 × 参考库状态，收尾写 reflib_states.tsv 交着色器线 refpso.py
            List<(string Id, uint Fmt, uint Cg, byte[] Raw)> rlRows = new(); HashSet<ulong> rlMissFp = new(); List<Prog> rlAdd = new();
            if (reflibs.Count > 0)
            {
                string[] colStage = { "vs", "vs", "hs", "ds", "gs", "ps", "cs" };   // 参考库 7 列：VertexA 顶点 细分控制 细分求值 几何 片元 计算
                Dictionary<(ulong, string), string> byFp = new();
                foreach (var kv in xs.OrderBy(kv => kv.Key, StringComparer.Ordinal))
                {
                    XShader x = kv.Value; if (x.Key.StartsWith("rt:")) continue;   // 只用静态抽出的（ref-guest 合成的不算）
                    byFp.TryAdd((CanonFp(x.Mem.Span, x.Compute), x.Stage), x.Key);
                }
                // 覆盖判断按 xs 键串（Id）比，不按客体代码：规则程序的客体代码截到翻译器判定的长度（Guest = Mem[..tc.Size]），这里没翻译拿不到，
                //   整段 Mem 的哈希和它对不上（着色器线 10-22 审）；代码相同但键不同（控制段不同）的由第 5 步 dup_guest 兜
                HashSet<string> have = rule.Where(p => !p.StageOnly).Select(p => p.Id).ToHashSet();
                HashSet<string> seen = new();
                foreach (string lf in reflibs)
                {
                    List<(ulong[] Cols, int State, uint Fmt, uint Cg, byte[] Raw)> lib;
                    try { lib = ReadRefLib(lf); } catch (Exception e) { Console.Error.WriteLine($"【红】shbake --reflib 读不了 {lf}：{e.Message}"); continue; }
                    foreach (var (cols, _, fmt, cg, raw) in lib)
                    {
                        rlAll++;
                        // yuzu 早期可迁移缓存（来源格式 0xFFFE0000 | 版本）一条只记一个阶段、不记阶段组合，不能当程序配；没有顶点阶段的图形行同理（拼不出合法管线）
                        if ((fmt & 0xFFFF0000u) == 0xFFFE0000u) { rlStage++; continue; }
                        if (cols[6] == 0 && cols[1] == 0) { rlNoVs++; continue; }
                        if (cols[0] != 0) { rlVsA++; continue; }
                        bool comp = cols[6] != 0; Prog p = new() { Source = "reflib:" + Path.GetFileName(lf), Compute = comp, Origin = "reflib" }; bool ok = true;
                        for (int c = comp ? 6 : 1; c < (comp ? 7 : 6); c++)
                        {
                            if (cols[c] == 0) continue;
                            if (!byFp.TryGetValue((cols[c], colStage[c]), out string key)) { ok = false; rlMissFp.Add(cols[c]); continue; }
                            p.Keys[comp ? 0 : c] = key;
                        }
                        if (!ok) { rlMiss++; continue; }
                        p.Id = string.Join(",", p.Keys.Select(k => k ?? "-"));
                        if (!comp) rlRows.Add((p.Id, fmt, cg, raw));   // 已被规则覆盖 / 库内重复的也记：每一行社区程序都有自己的状态
                        if (have.Contains(p.Id)) { rlHave++; continue; }
                        if (!seen.Add(p.Id)) { rlDup++; continue; }
                        rlAdd.Add(p);
                    }
                }
                Parallel.ForEach(rlAdd, new ParallelOptions { MaxDegreeOfParallelism = j }, p =>
                {
                    try { PhaseA(ctx, p, xs, d); }
                    catch (Exception e) { p.Status = "error_a"; p.Err = $"{e.GetType().Name}: {e.Message}".Replace('\t', ' ').Replace('\n', ' '); }
                });
                rule.AddRange(rlAdd);
                Console.Error.WriteLine($"shbake --reflib：{reflibs.Count} 份参考库 {rlAll} 个程序，已被规则覆盖 {rlHave}、库内同代码组合 {rlDup}、新配 {rlAdd.Count}（翻成 {rlAdd.Count(p => p.Status == "ok")}）、指纹对不上的程序 {rlMiss}（对不上的指纹 {rlMissFp.Count} 个）、双顶点不收 {rlVsA}、单阶段记录不收 {rlStage}、无顶点图形行不收 {rlNoVs}");
            }
            rep["reflib"] = new Dictionary<string, object> { ["files"] = reflibs.Count, ["programs"] = rlAll, ["covered_by_rule"] = rlHave, ["dup_in_lib"] = rlDup, ["added"] = rlAdd.Count, ["added_ok"] = rlAdd.Count(p => p.Status == "ok"), ["unmatched_programs"] = rlMiss, ["unmatched_fps"] = rlMissFp.Count, ["vertex_a_skipped"] = rlVsA, ["stage_only_skipped"] = rlStage, ["no_vertex_skipped"] = rlNoVs };
            rep["ref_guest"] = new Dictionary<string, object> { ["dirs"] = guestDirs.Count, ["programs"] = rgAll, ["static_code"] = rgStatic, ["covered_by_rule"] = rgHave, ["dup_in_ref"] = rgDup, ["added"] = rgAdd.Count, ["added_ok"] = rgAdd.Count(p => p.Status == "ok"), ["vertex_a_skipped"] = rgVsA, ["unreadable"] = rgBad };
            double aMs = sw.Elapsed.TotalMilliseconds;

            // 5) 已有缓存的程序原样继承；规则程序按客体代码去重，客体代码组合在已有缓存里出现过的不再另配（继承那里的特化状态）
            static string GuestId(bool compute, GuestCodeAndCbData?[] g) => (compute ? "c" : "g") + string.Concat(g.Select(s => "|" + (s.HasValue ? Sha(s.Value.Code, 32) + ":" + Sha(s.Value.Cb1Data, 16) : "-")));
            List<Prog> inherited = refsU.Select(r => new Prog { Id = GuestId(r.Compute, r.Stages), Source = "ref:" + r.From, Compute = r.Compute, Ref = r, Guest = r.Stages, Spec = r.Spec }).ToList();
            HashSet<string> refIds = inherited.Select(p => p.Id).ToHashSet();
            Dictionary<string, Prog> freshBy = new(); int aliasDup = 0, inRef = 0;
            HashSet<string> ruleIds = new();
            foreach (Prog p in rule.Where(p => p.Status == "ok"))
            {
                string gid = GuestId(p.Compute, p.Guest);
                ruleIds.Add(gid);
                // 同客体代码的规则程序：留第一个；客体代码在已有缓存里出现过 → 算继承（那边已有条目）
                if (refIds.Contains(gid)) { inRef++; p.Status = "inherited"; continue; }
                if (!freshBy.TryAdd(gid, p)) { aliasDup++; p.Status = "dup_guest"; }
            }
            // 配对规则核对：已有缓存里的每个图形程序，其客体代码组合是否被规则配出
            int refG = inherited.Count(p => !p.Compute), refGHit = inherited.Count(p => !p.Compute && ruleIds.Contains(p.Id));
            int refC = inherited.Count(p => p.Compute), refCHit = inherited.Count(p => p.Compute && ruleIds.Contains(p.Id));
            // 配对覆盖真值（--ref-cover）：旧局缓存里出现过的图形程序（按客体代码组合去重），有多少被规则配出；没配出的列前 20 个的阶段代码指纹
            // 只比各阶段客体代码（不比常量缓冲 1 数据：参照里是运行时真值，规则程序是缺省翻译）
            static string CodeId(GuestCodeAndCbData?[] g) => string.Concat(g.Select(s => "|" + (s.HasValue ? Sha(s.Value.Code, 32) : "-")));
            HashSet<string> ruleCode = rule.Where(p => !p.Compute && p.Guest != null && p.Status != "error").Select(p => CodeId(p.Guest)).ToHashSet();
            HashSet<string> coverG = new(), coverC = new(); foreach (string dir in coverDirs) foreach (RefProgram r in ReadCache(dir, true)) (r.Compute ? coverC : coverG).Add(CodeId(r.Stages));
            HashSet<string> ruleCodeC = rule.Where(p => p.Compute && p.Guest != null && p.Status != "error").Select(p => CodeId(p.Guest)).ToHashSet();
            List<string> coverMiss = coverG.Where(g => !ruleCode.Contains(g)).ToList();
            {   // 未覆盖的组合反查各阶段来源（客体代码指纹 → 抽出键 → 首个来源），便于看漏的是哪类组合
                Dictionary<string, string> codeKey = new();
                foreach (Prog q in rule.Concat(stageOnly)) if (q.Guest != null) for (int i = 0; i < q.Guest.Length && i < q.Keys.Length; i++) if (q.Guest[i].HasValue && q.Keys[i] != null) codeKey.TryAdd(Sha(q.Guest[i].Value.Code, 32), q.Keys[i]);
                Dictionary<string, string> keySrc = new(); foreach (var r in rows) keySrc.TryAdd(r.key, r.src);
                coverMiss = coverMiss.Select(g => string.Join("  ", g.Split('|', StringSplitOptions.RemoveEmptyEntries).Where(x => x != "-").Select(x => codeKey.TryGetValue(x, out string k) ? $"{k}={(keySrc.TryGetValue(k, out string sr) ? sr : "?")}" : $"{x[..12]}=未抽到"))).ToList();
            }
            List<Prog> fresh = freshBy.Values.ToList();
            rep["pairing"] = new Dictionary<string, object>
            {
                ["rule_programs_raw"] = rawPrograms, ["rule_programs_unique_keys"] = rulePrograms, ["unpaired"] = unpaired.Count, ["unpaired_examples"] = unpaired.Take(20).ToList(),
                ["rule_phaseA"] = rule.GroupBy(p => p.Status == "inherited" || p.Status == "dup_guest" ? "ok" : p.Status).ToDictionary(g => g.Key, g => g.Count()),
                ["rule_phaseA_errors"] = rule.Where(p => p.Err != null).GroupBy(p => (p.Keys[4] != null ? "gs:" : "") + (p.Err.Length > 120 ? p.Err[..120] : p.Err)).OrderByDescending(g => g.Count()).Take(10).Select(g => $"{g.Count()}×{g.Key}（例 {g.First().Source}）").ToList(),
                ["rule_unique_guest"] = ruleIds.Count, ["rule_guest_seen_in_ref"] = inRef, ["rule_guest_dup"] = aliasDup,
                ["ref_graphics_covered_by_rule"] = $"{refGHit}/{refG}", ["ref_compute_covered_by_rule"] = $"{refCHit}/{refC}",
                ["cover_graphics_by_rule"] = $"{coverG.Count - coverMiss.Count}/{coverG.Count}", ["cover_compute_by_rule"] = $"{coverC.Count(ruleCodeC.Contains)}/{coverC.Count}", ["cover_miss_examples"] = coverMiss.Take(20).ToList(),
                ["ref_not_covered"] = inherited.Where(p => !ruleIds.Contains(p.Id)).Select(p => p.Id).Take(30).ToList(),
            };

            if (Environment.GetEnvironmentVariable("S2A_SHBAKE_PAIR_ONLY") == "1")   // 只出配对统计（配对规则核对用）：不跑乙段 / 不写缓存
            {
                File.WriteAllText(Path.Combine(outRoot, "bake.json"), System.Text.Json.JsonSerializer.Serialize(rep, new System.Text.Json.JsonSerializerOptions { WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping }));
                Console.WriteLine($"shbake：只出配对统计（S2A_SHBAKE_PAIR_ONLY）→ {outRoot}/bake.json");
                Tr.Write(Path.Combine(outRoot, TrLog.FileName)); Console.WriteLine(Tr.Summary());
                return 0;
            }

            // 宽屏改写（画幅线 graphics/widen，与运行时包装层建程序调同一份 WidenShaders）+ 出 SPIR-V（按键去重）：乙段每个程序成功即做、即落盘、只留键，
            // 不把全部程序的 SPIR-V 攒在内存里（10-20 暗黑2 2.4 万个程序撞 8 GB 堆上限）。离线库键 = 改后字节，手机上才命中；
            // 各阶段的宽屏元数据（常量读法 / 片元 y / 外推 / 采样绑定）记进 widen.idx（输出根）——手机走程序二进制没有 SPIR-V，包装层按记录键查它
            ConcurrentDictionary<ulong, S2Arm.Gfx.Widen.WidenStageMeta> widx = new();
            byte[] Wd(byte[] b, ShaderStage st)
            {
                byte[] o = S2Arm.Gfx.Widen.WidenIndex.Transform(b, (int)st, st == ShaderStage.Vertex, st == ShaderStage.Fragment, out var m, allowExtrap);
                widx.TryAdd(S2Arm.Gfx.Widen.WidenIndex.Key(o), m);
                return o;
            }
            HashSet<string> spvKeys = new(); long spvBytes = 0; object spvLock = new();
            // 原画框外推的写侧几何（10-23）：能外推的程序，其顶点着色器的位置切片按改写后顶点键记进 widen_pos.bin（SpirvPosSlice）；判不出的不记（运行时按铺满、同改前）
            ConcurrentDictionary<ulong, byte[]> posx = new(); long posTried = 0, posNone = 0;
            void PutPos(byte[] vsOrig, byte[] vsOut)
            {
                Interlocked.Increment(ref posTried);
                if (S2Arm.Gfx.Widen.SpirvPosSlice.Extract(vsOrig, out _) is { } ps) posx.TryAdd(S2Arm.Gfx.Widen.WidenIndex.Key(vsOut), ps.Packed); else Interlocked.Increment(ref posNone);
            }
            // 曲面程序里的顶点着色器另出「曲面前顶点计算核」变体（gal_xc 认 <键>.vt.spv；离线索引键 = SPIR-V 键 ^ NXGAL_VT_SALT，与 gal_prog.m 同口径）
            const ulong VtSalt = 0x7465737356543031UL;
            void PutSpv(byte[] b, bool vt) { string k = SpvKey(b) + (vt ? ".vt" : ""); bool add; lock (spvLock) { add = spvKeys.Add(k); if (add) spvBytes += b.Length; } if (add) File.WriteAllBytes(Path.Combine(spvDir, k + ".spv"), b); }
            void Commit(Prog p)
            {
                if (p.Status != "ok" || p.Spirv == null) return;
                p.SpvHash = new ulong[p.Spirv.Count]; p.SpvName = new string[p.Spirv.Count]; p.SpvStage = new ShaderStage[p.Spirv.Count];
                bool tess = p.Sources.Any(x => x.Stage == ShaderStage.TessellationControl || x.Stage == ShaderStage.TessellationEvaluation);
                for (int i = 0; i < p.Spirv.Count; i++) if (p.Sources[i].Stage == ShaderStage.Fragment) p.FoInt = FoutStatic.IntWrittenTargets(p.Spirv[i]);
                var outs = new byte[p.Spirv.Count][];
                for (int i = 0; i < p.Spirv.Count; i++)
                {
                    byte[] o = Wd(p.Spirv[i], p.Sources[i].Stage); outs[i] = o;
                    bool vt = tess && p.Sources[i].Stage == ShaderStage.Vertex;
                    p.SpvStage[i] = p.Sources[i].Stage; PutSpv(o, vt); p.SpvHash[i] = BinaryPrimitives.ReadUInt64LittleEndian(SHA256.HashData(o)) ^ (vt ? VtSalt : 0); p.SpvName[i] = vt ? p.SpvHash[i].ToString("x16") : SpvKey(o);
                }
                bool fex = false; for (int i = 0; i < outs.Length; i++) if (p.Sources[i].Stage == ShaderStage.Fragment && widx.TryGetValue(S2Arm.Gfx.Widen.WidenIndex.Key(outs[i]), out var fm) && fm.Extrap) fex = true;
                if (fex) for (int i = 0; i < outs.Length; i++) if (p.Sources[i].Stage == ShaderStage.Vertex) PutPos(p.Spirv[i], outs[i]);
                p.Spirv = null;
                // Android VKPB 宿主记录要在写缓存时按 ShaderSource 重建 ShaderInfo；那份依赖落在下一步。
                if (vkProfile == null) p.Sources = null;
            }

            // 乙段（全部）：设备加载那条路
            List<Prog> all = inherited.Concat(fresh).ToList();
            sw.Restart();
            Parallel.ForEach(all, new ParallelOptions { MaxDegreeOfParallelism = j }, p =>
            {
                long t0 = Stopwatch.GetTimestamp();
                try { PhaseB(ctx, p); Commit(p); }
                catch (Exception e) { p.Status = "error_b"; p.Err = $"{e.GetType().Name}: {e.Message}".Replace('\t', ' ').Replace('\n', ' '); p.Spirv = null; p.Sources = null; }
                p.Ms += (Stopwatch.GetTimestamp() - t0) * 1000.0 / Stopwatch.Frequency;
            });
            double xlateMs = sw.Elapsed.TotalMilliseconds;

            // 变体查重（10-21 C①）：已有程序（继承 + 新配）与已加的变体按「客体代码 + 特化状态（去掉用法记录）」记一遍，补出来的变体已存在就不再出——
            //   收回的运行时缓存里已带着上一版包补过的变体，原样继承后再补一遍会写出重复条目（暗黑3 替身 1744 个程序重复写 846 条）
            HashSet<string> haveSpec = all.Where(q => q.Spec != null && q.Guest != null).Select(q => GuestId(q.Compute, q.Guest) + "|" + Sha(SpecKeyBytes(q.Spec), 32)).ToHashSet();
            bool NewSpec(Prog q, ShaderSpecializationState ns) => haveSpec.Add(GuestId(q.Compute, q.Guest) + "|" + Sha(SpecKeyBytes(ns), 32));
            // 5b) 补特化状态变体（10-19 出包线，动森首局现翻：同一程序运行时配的 a2c 抖动 / 顶点属性格式与包里不同，翻译读了这些字段就是不同的程序）：
            //    按观测补、不按猜：属性格式 = 同一顶点着色器在所有程序里观测到的取值（只看翻译读过的位置）；a2c 抖动开 = 只给观测到配过它的片元着色器；
            //    只对翻译确实读了该字段的程序补（使用记录，见 ShaderSpecializationState.S2ARecordUsage）。动森估算 +9%（a2c 两值全出要 +108%）
            static string StKey(GuestCodeAndCbData? g) => g.HasValue ? Sha(g.Value.Code, 32) : null;
            List<Prog> okG = all.Where(p => p.Status == "ok" && !p.Compute && p.Spec != null && p.Spec.S2AUsageTracked && p.Guest.Length > 5 && !(p.Source?.StartsWith("gs_fn:") ?? false)).ToList();   // 只出函数的（片元占位）不补变体
            string Proj(Prog p, uint mask) { var sb2 = new StringBuilder(); for (int i = 0; i < 32; i++) sb2.Append((mask >> i & 1) != 0 ? ((int)p.Spec.GraphicsState.AttributeTypes[i]).ToString() : "-").Append(','); return sb2.ToString(); }
            Dictionary<string, Dictionary<string, Prog>> attrObs = new();   // 顶点着色器 → 读过位置的属性取值投影 → 一个观测到它的程序（取值来源）
            HashSet<string> fsA2c = new();
            HashSet<string> haveV = new();
            foreach (Prog p in okG)
            {
                string vs = StKey(p.Guest[1]), fs = StKey(p.Guest[5]); uint m = p.Spec.S2AAttrRead; ref GpuChannelGraphicsState gs0 = ref p.Spec.GraphicsState;
                bool a2c = gs0.AlphaToCoverageEnable && gs0.AlphaToCoverageDitherEnable;
                if (vs != null) { if (!attrObs.TryGetValue(vs, out var dd)) attrObs[vs] = dd = new(); dd.TryAdd(Proj(p, m), p); }
                if (a2c && fs != null) fsA2c.Add(fs);
                haveV.Add($"{GuestId(false, p.Guest)}|{(p.Spec.S2AA2cRead ? (a2c ? 1 : 0) : -1)}|{Proj(p, m)}");
            }
            List<Prog> variants = new();
            foreach (Prog p in okG)
            {
                string vs = StKey(p.Guest[1]), fs = StKey(p.Guest[5]); uint m = p.Spec.S2AAttrRead;
                bool a2c0 = p.Spec.GraphicsState.AlphaToCoverageEnable && p.Spec.GraphicsState.AlphaToCoverageDitherEnable;
                List<bool?> a2cs = new() { p.Spec.S2AA2cRead ? a2c0 : null };
                if (p.Spec.S2AA2cRead && fs != null && fsA2c.Contains(fs)) a2cs.Add(!a2c0);
                List<Prog> srcs = vs != null && attrObs.TryGetValue(vs, out var dd2) ? dd2.Values.ToList() : new() { p };
                foreach (Prog src in srcs)
                    foreach (bool? x in a2cs)
                    {
                        string k = $"{GuestId(false, p.Guest)}|{(x == null ? -1 : (x.Value ? 1 : 0))}|{Proj(src, m)}";
                        if (!haveV.Add(k)) continue;
                        // 克隆特化状态（纹理登记 / 常量用法等全保留），只改属性格式（读过的位置取观测值）与 a2c 抖动
                        BinarySerializer rr = new(new MemoryStream(SpecBytes(p.Spec)));
                        ShaderSpecializationState ns2 = ShaderSpecializationState.Read(ref rr);
                        ref GpuChannelGraphicsState g2 = ref ns2.GraphicsState;
                        for (int i = 0; i < 32; i++) if ((m >> i & 1) != 0) g2.AttributeTypes[i] = src.Spec.GraphicsState.AttributeTypes[i];
                        if (x != null) { g2.AlphaToCoverageEnable = x.Value; g2.AlphaToCoverageDitherEnable = x.Value; }
                        if (!NewSpec(p, ns2)) continue;
                        variants.Add(new Prog { Id = p.Id + "#v" + variants.Count, Source = "variant:" + p.Source, Compute = false, Keys = p.Keys, Ref = p.Ref, Guest = p.Guest, Spec = ns2, Origin = "variant" });
                    }
            }
            // 推断出的整数类别变体（10-20，属性类别不能运行时化）：乙段翻译时 S2AAttrIntUse 判出「读出值进了整数运算」的属性位置，
            // 按推断的带符号与否改成 Sint / Uint 再出一份（不靠观测）；推断错只是多一个永不命中的条目
            int intVariants = 0;
            foreach (Prog p in okG)
            {
                uint im = p.AttrInt & p.Spec.S2AAttrRead; if (im == 0) continue;
                BinarySerializer rr = new(new MemoryStream(SpecBytes(p.Spec)));
                ShaderSpecializationState ns2 = ShaderSpecializationState.Read(ref rr);
                ref GpuChannelGraphicsState g2 = ref ns2.GraphicsState;
                for (int i = 0; i < 32; i++) if ((im >> i & 1) != 0) g2.AttributeTypes[i] = (p.AttrSint >> i & 1) != 0 ? AttributeType.Sint : AttributeType.Uint;
                bool a2c0 = p.Spec.GraphicsState.AlphaToCoverageEnable && p.Spec.GraphicsState.AlphaToCoverageDitherEnable;
                string k = $"{GuestId(false, p.Guest)}|{(p.Spec.S2AA2cRead ? (a2c0 ? 1 : 0) : -1)}|{Proj(new Prog { Spec = ns2 }, p.Spec.S2AAttrRead)}";
                if (!haveV.Add(k) || !NewSpec(p, ns2)) continue;
                variants.Add(new Prog { Id = p.Id + "#i" + variants.Count, Source = "variant_int:" + p.Source, Compute = false, Keys = p.Keys, Ref = p.Ref, Guest = p.Guest, Spec = ns2, Origin = "variant" });
                intVariants++;
            }
            // 透明测试开的变体（10-20 总指挥 C 方案）：透明测试运行时化后，一个程序只需「关 / 开」两份（比较方式与参考值走支持缓冲，只有开的那份带 discard）。
            // 给每个带片元的程序（含上面的整数属性变体）出「开」的那份；比较方式 / 参考值随便填（翻译不读，匹配也不比，见补丁 S2AAlphaRead）
            int alphaVariants = 0;
            // S2A_NO_ALPHA_VARIANTS=1：出包静态判出游戏从不设透明测试（graphics/tools/shbake/nvn_uses.py：所有模块没有调用 nvnColorStateSetAlphaTest，正对照过），「开」那份用不到
            bool alphaNeeded = Environment.GetEnvironmentVariable("S2A_NO_ALPHA_VARIANTS") != "1";
            if (TranslatorContext.S2ARuntimeState && alphaNeeded)
                foreach (Prog p in okG.Concat(variants.Where(v => v.Origin == "variant")).ToList())
                {
                    if (p.Guest.Length <= 5 || !p.Guest[5].HasValue || p.Spec.GraphicsState.AlphaTestEnable) continue;
                    BinarySerializer rr = new(new MemoryStream(SpecBytes(p.Spec)));
                    ShaderSpecializationState ns2 = ShaderSpecializationState.Read(ref rr);
                    ref GpuChannelGraphicsState g2 = ref ns2.GraphicsState;
                    g2.AlphaTestEnable = true; g2.AlphaTestCompare = CompareOp.GreaterOrEqual; g2.AlphaTestReference = 0.5f;
                    if (!NewSpec(p, ns2)) continue;
                    variants.Add(new Prog { Id = p.Id + "#a" + variants.Count, Source = "variant_alpha:" + p.Source, Compute = false, Keys = p.Keys, Ref = p.Ref, Guest = p.Guest, Spec = ns2, Origin = "variant_alpha" });
                    alphaVariants++;
                }
            sw.Restart();
            Parallel.ForEach(variants, new ParallelOptions { MaxDegreeOfParallelism = j }, p =>
            {
                try { PhaseB(ctx, p); Commit(p); }
                catch (Exception e) { p.Status = "error_b"; p.Err = $"{e.GetType().Name}: {e.Message}".Replace('\t', ' ').Replace('\n', ' '); p.Spirv = null; p.Sources = null; }
            });
            rep["variants"] = new Dictionary<string, object> { ["programs"] = okG.Count, ["added"] = variants.Count, ["ok"] = variants.Count(v => v.Status == "ok"), ["fs_with_a2c"] = fsA2c.Count, ["vs_observed"] = attrObs.Count, ["int_inferred"] = intVariants, ["alpha_test"] = alphaVariants, ["ms"] = (long)sw.Elapsed.TotalMilliseconds };
            Console.WriteLine($"shbake：补特化状态变体 {variants.Count(v => v.Status == "ok")} / {variants.Count}（a2c 抖动观测片元 {fsA2c.Count}、顶点着色器 {attrObs.Count}、推断整数属性 {intVariants}、透明测试开 {alphaVariants}），{sw.Elapsed.TotalSeconds:0.0} s");
            all = all.Concat(variants).ToList();
            // 5c) 按观测补片元输出类型变体（10-24）：能力表 NeedsFragmentOutputSpecialization 为真时，运行时按渲染目标格式定 FragmentOutputTypes 并进匹配比
            //    （SpecializationStateUpdater.SetFragmentOutputTypes：目标格式 IsInt → IsSignedInt ? Sint : Uint，否则 Float；ShaderSpecializationState.MatchesGraphics 整组 8 个比），
            //    出包缺省全浮点，画进整数目标（R32Uint 等）的程序运行时全部现翻。观测来自收集的特化管线表（S2A_SPEC_PIPES，specpipe.py）：
            //    v2 行的槽号 = Metal 颜色附件号 = 片元输出位置，像素格式是 MTLPixelFormat 数值（纯整数格式按 Metal 头文件的 Uint / Sint 分）。
            //    表里的片元函数名是运行时翻出的整数输出版的键，包里没有，所以按顶点键（及片元键）找候选程序；每个候选按观测改整组输出类型（整数目标 Uint / Sint、其余 Float）出一份，
            //    乙段翻完片元的键（宽屏改写后，与离线库 / 函数名同口径）等于观测的片元键才收（运行时那份的特化状态被逐字复现的证据），对不上的丢弃、不进库不进缓存
            int foBadLines = 0, foSame = 0; HashSet<Prog> foCand = new(); List<Prog> foVars = new(); Dictionary<(string vs, string fs, string sig), AttributeType[]> foObs = new();
            string specPipes = Environment.GetEnvironmentVariable("S2A_SPEC_PIPES");
            sw.Restart();
            if (!string.IsNullOrEmpty(specPipes) && File.Exists(specPipes))
            {
                static AttributeType FoType(int pf) => pf switch
                {
                    13 or 23 or 33 or 53 or 63 or 73 or 91 or 103 or 113 or 123 => AttributeType.Uint,   // R8 / R16 / RG8 / R32 / RG16 / RGBA8 / RGB10A2 / RG32 / RGBA16 / RGBA32 Uint
                    14 or 24 or 34 or 54 or 64 or 74 or 104 or 114 or 124 => AttributeType.Sint,           // 同上各 Sint（Metal 无 RGB10A2Sint）
                    _ => AttributeType.Float,
                };
                foreach (string line in File.ReadLines(specPipes))
                {
                    string[] f = line.Split('#')[0].Split((char[])null, StringSplitOptions.RemoveEmptyEntries);
                    if (f.Length < 9 || f[0] != "v2" || f[2] == "-" || f[7] == "0") continue;   // 没有片元 / 关光栅化（不跑片元）/ 没有颜色附件的不看
                    AttributeType[] t = new AttributeType[8]; bool anyInt = false, ok = f[1].Length >= 17 && f[2].Length >= 17;
                    foreach (string att in f.Skip(8))
                    {
                        string[] c = att.Split(':');
                        if (!ok || c.Length < 2 || !int.TryParse(c[0], out int i) || i < 0 || i > 7 || !int.TryParse(c[1], out int pf)) { ok = false; break; }
                        t[i] = FoType(pf); anyInt |= t[i] != AttributeType.Float;
                    }
                    if (!ok) { foBadLines++; continue; }
                    if (anyInt) foObs.TryAdd((f[1][1..17], f[2][1..17], string.Join(",", t.Select(x => (int)x))), t);
                }
                static string FoFn(Prog c, ShaderStage st) { if (c.SpvName == null || c.SpvStage == null) return null; int i = Array.IndexOf(c.SpvStage, st); return i < 0 ? null : c.SpvName[i]; }
                List<Prog> foBase = all.Where(p => p.Status == "ok" && !p.Compute && p.SpvName != null && p.Guest.Length > 5 && p.Guest[5].HasValue && !(p.Source?.StartsWith("gs_fn:") ?? false)).ToList();
                ILookup<string, Prog> byVs = foBase.Where(p => FoFn(p, ShaderStage.Vertex) != null).ToLookup(p => FoFn(p, ShaderStage.Vertex)), byFs = foBase.Where(p => FoFn(p, ShaderStage.Fragment) != null).ToLookup(p => FoFn(p, ShaderStage.Fragment));
                // 同一（候选程序, 输出类型组）只翻一次，收齐所有观测片元键
                Dictionary<(Prog, string), (AttributeType[] t, HashSet<string> fs)> prop = new(); List<(Prog, string)> order = new();
                foreach (var ((vs, fs, sig), t) in foObs)
                    foreach (Prog c in byVs[vs].Concat(byFs[fs]).Distinct())
                    {
                        foCand.Add(c);
                        if (!prop.TryGetValue((c, sig), out var pr)) { prop[(c, sig)] = pr = (t, new HashSet<string>()); order.Add((c, sig)); }
                        pr.fs.Add(fs);
                    }
                foreach (var key in order)
                {
                    var (t, fsSet) = prop[key]; Prog c = key.Item1;
                    BinarySerializer rr = new(new MemoryStream(SpecBytes(c.Spec)));
                    ShaderSpecializationState ns2 = ShaderSpecializationState.Read(ref rr);
                    ref GpuChannelGraphicsState g2 = ref ns2.GraphicsState;
                    for (int i = 0; i < 8; i++) g2.FragmentOutputTypes[i] = t[i];
                    if (!NewSpec(c, ns2)) { foSame++; continue; }   // 候选本身 / 已有变体就是这组类型
                    foVars.Add(new Prog { Id = c.Id + "#o" + foVars.Count, Source = "variant_fout:" + c.Source, Compute = false, Keys = c.Keys, Ref = c.Ref, Guest = c.Guest, Spec = ns2, Origin = "variant_fout", FoWant = fsSet });
                }
                Parallel.ForEach(foVars, new ParallelOptions { MaxDegreeOfParallelism = j }, p =>
                {
                    try
                    {
                        PhaseB(ctx, p);
                        int i = p.Sources.FindIndex(s => s.Stage == ShaderStage.Fragment);
                        string got = i < 0 ? null : SpvKey(S2Arm.Gfx.Widen.WidenIndex.Transform((byte[])p.Spirv[i].Clone(), (int)ShaderStage.Fragment, false, true, out _, allowExtrap));
                        if (got != null && p.FoWant.Contains(got)) Commit(p);
                        else { p.Status = "fout_mismatch"; p.Err = $"片元键 {got ?? "-"} 不是观测的 {string.Join("/", p.FoWant)}"; p.Spirv = null; p.Sources = null; }
                    }
                    catch (Exception e) { p.Status = "error_b"; p.Err = $"{e.GetType().Name}: {e.Message}".Replace('\t', ' ').Replace('\n', ' '); p.Spirv = null; p.Sources = null; }
                });
            }
            {
                List<Prog> okF = foVars.Where(v => v.Status == "ok").ToList();
                HashSet<string> gotFs = okF.Select(v => v.SpvName[Array.IndexOf(v.SpvStage, ShaderStage.Fragment)]).ToHashSet();
                int covered = foObs.Keys.Count(k => gotFs.Contains(k.fs)), mism = foVars.Count(v => v.Status == "fout_mismatch");
                List<Prog> errF = foVars.Where(v => v.Status.StartsWith("error")).ToList();
                rep["variants_fout"] = new Dictionary<string, object>
                {
                    ["table"] = specPipes ?? "", ["observed_lines"] = foObs.Count, ["bad_lines"] = foBadLines, ["matched_programs"] = foCand.Count, ["added"] = foVars.Count, ["ok"] = okF.Count,
                    ["key_mismatch_dropped"] = mism, ["errors"] = errF.Count, ["already_have"] = foSame, ["lines_covered"] = covered,
                    ["error_examples"] = errF.Take(5).Select(v => $"{v.Source}：{v.Err}").ToList(), ["ms"] = (long)sw.Elapsed.TotalMilliseconds,
                };
                Console.WriteLine($"shbake：片元输出类型变体（S2A_SPEC_PIPES{(string.IsNullOrEmpty(specPipes) ? " 未给，跳过" : "")}）整数目标观测 {foObs.Count} 行、匹配到程序 {foCand.Count}、补出 {foVars.Count}、成功 {okF.Count}（片元键对上观测；对不上丢弃 {mism}、翻译失败 {errF.Count}、已有 {foSame}）；观测行覆盖 {covered}/{foObs.Count}，{sw.Elapsed.TotalSeconds:0.0} s");
                foreach (Prog v in errF.Take(5)) Console.Error.WriteLine($"【红】shbake：片元输出类型变体翻译失败 {v.Source}：{v.Err}");
                all = all.Concat(okF).ToList();
            }
            // 5d) 静态补片元整数输出变体（10-24 总指挥：出包不试跑、玩家首遇零现编）：5c 只认运行时观测到的整数目标，新组合总要先有一局冷局撞上。
            //    片元按整数位写某个输出位置（FoutStatic：存进输出的值来自 int → float 的 OpBitcast）= 游戏要把它画进整数目标，出一份这些位置 Uint、其余照旧的变体；
            //    已是 Uint（5c 补过 / 本来就是）或同组特化已有就不出。只给 Uint：Ryujinx 运行时整数目标按格式定 Uint / Sint（SpecializationStateUpdater），Sint 目标少见、仍走 5c 观测
            {
                sw.Restart();
                List<Prog> fdVars = new(); int fdSame = 0, fdCand = 0;
                foreach (Prog c in all.Where(p => p.Status == "ok" && !p.Compute && p.FoInt != 0 && p.Guest.Length > 5 && p.Guest[5].HasValue && !(p.Source?.StartsWith("gs_fn:") ?? false)).ToList())
                {
                    fdCand++;
                    BinarySerializer rr = new(new MemoryStream(SpecBytes(c.Spec)));
                    ShaderSpecializationState ns2 = ShaderSpecializationState.Read(ref rr);
                    ref GpuChannelGraphicsState g2 = ref ns2.GraphicsState;
                    bool chg = false;
                    for (int i = 0; i < 8; i++) if ((c.FoInt >> i & 1) != 0 && g2.FragmentOutputTypes[i] == AttributeType.Float) { g2.FragmentOutputTypes[i] = AttributeType.Uint; chg = true; }
                    if (!chg || !NewSpec(c, ns2)) { fdSame++; continue; }
                    fdVars.Add(new Prog { Id = c.Id + "#d" + fdVars.Count, Source = "variant_fstatic:" + c.Source, Compute = false, Keys = c.Keys, Ref = c.Ref, Guest = c.Guest, Spec = ns2, Origin = "variant_fstatic" });
                }
                Parallel.ForEach(fdVars, new ParallelOptions { MaxDegreeOfParallelism = j }, p =>
                {
                    try { PhaseB(ctx, p); Commit(p); }
                    catch (Exception e) { p.Status = "error_b"; p.Err = $"{e.GetType().Name}: {e.Message}".Replace('\t', ' ').Replace('\n', ' '); p.Spirv = null; p.Sources = null; }
                });
                List<Prog> okD = fdVars.Where(v => v.Status == "ok").ToList(), errD = fdVars.Where(v => v.Status.StartsWith("error")).ToList();
                rep["variants_fstatic"] = new Dictionary<string, object> { ["candidates"] = fdCand, ["added"] = fdVars.Count, ["ok"] = okD.Count, ["errors"] = errD.Count, ["already_have"] = fdSame,
                    ["error_examples"] = errD.Take(5).Select(v => $"{v.Source}：{v.Err}").ToList(), ["ms"] = (long)sw.Elapsed.TotalMilliseconds };
                Console.WriteLine($"shbake：静态片元整数输出变体（5d）按整数位写的程序 {fdCand}、补出 {fdVars.Count}、成功 {okD.Count}（翻译失败 {errD.Count}、已有 {fdSame}），{sw.Elapsed.TotalSeconds:0.0} s");
                foreach (Prog v in errD.Take(5)) Console.Error.WriteLine($"【红】shbake：静态片元整数输出变体翻译失败 {v.Source}：{v.Err}");
                all = all.Concat(okD).ToList();
            }
            rep["spec_sources"] = SpecSources(d, all, TranslatorContext.S2ARuntimeState);
            var ds = (Dictionary<string, object>)((Dictionary<string, object>)rep["spec_sources"])["缺省值来源"];
            Console.WriteLine($"shbake：特化字段来源——缺省值且有程序读过的 {ds["字段数"]} 项：{string.Join("，", (List<string>)ds["字段"])}（程序 {ds["程序总数"]}，有第二代读位 {ds["有第二代读位的程序"]}）");

            // 5.9) 宽屏改写（画幅线 graphics/widen，与运行时包装层建程序调同一份 WidenShaders）：顶点 / 片元 SPIR-V 改完再出库、拼宿主二进制，离线库键 = 改后字节，手机上才命中；
            //      各阶段的宽屏元数据（常量读法 / 片元 y / 外推 / 采样绑定）记进 widen.idx（输出根）——手机走程序二进制没有 SPIR-V，包装层按记录键查它
            sw.Restart();
            Parallel.ForEach((s2aAll ? all.Concat(stageOnly) : stageOnly).Where(p => p.Status == "ok"), new ParallelOptions { MaxDegreeOfParallelism = j }, p =>
            {
                byte[] vOrig = p.ASpirv[1];
                if (p.ASpirv[1] != null) p.ASpirv[1] = Wd(p.ASpirv[1], ShaderStage.Vertex);
                if (p.ASpirv[5] != null) p.ASpirv[5] = Wd(p.ASpirv[5], ShaderStage.Fragment);
                if (vOrig != null && p.ASpirv[5] != null && widx.TryGetValue(S2Arm.Gfx.Widen.WidenIndex.Key(p.ASpirv[5]), out var fm2) && fm2.Extrap) PutPos(vOrig, p.ASpirv[1]);
            });
            S2Arm.Gfx.Widen.WidenIndex.Write(Path.Combine(outRoot, S2Arm.Gfx.Widen.WidenIndex.FileName), widx);   // 放输出根：lib/ 归 gal_xc
            S2Arm.Gfx.Widen.PosFile.Write(Path.Combine(outRoot, S2Arm.Gfx.Widen.PosFile.FileName), posx);
            Console.WriteLine($"shbake：外推写侧顶点着色器 {posx.Count} 支、{posx.Values.Sum(b => (long)b.Length) >> 10} KB（能外推程序的顶点着色器 {posTried} 次，抽不出 {posNone}）→ {S2Arm.Gfx.Widen.PosFile.FileName}");
            int wPush = widx.Values.Count(m => m.Push), wFy = widx.Values.Count(m => m.FragY > 0);
            rep["widen"] = new Dictionary<string, object> { ["stages"] = widx.Count, ["vertex_push"] = wPush, ["fragment_y"] = wFy, ["ms"] = (long)sw.Elapsed.TotalMilliseconds };
            Console.WriteLine($"shbake：宽屏改写 {widx.Count} 支阶段（顶点可外推 {wPush}、片元 y 去缩放 {wFy}），{sw.Elapsed.TotalSeconds:0.0} s → {S2Arm.Gfx.Widen.WidenIndex.FileName}");

            // 6) 出 SPIR-V（程序各阶段 + 阶段单独翻译），按键去重
            sw.Restart();
            int progSpv = spvKeys.Count;   // 程序各阶段已在乙段 Commit 时落盘
            foreach (Prog p in stageOnly.Where(q => q.Status == "ok")) foreach (byte[] b in p.ASpirv.Where(x => x != null)) PutSpv(b, false);
            int stageSpv = spvKeys.Count - progSpv;
            rep["stage_only"] = new Dictionary<string, object> { ["shaders"] = stageOnly.Count, ["status"] = stageOnly.GroupBy(q => q.Status).ToDictionary(g => g.Key, g => g.Count()), ["spv_added"] = stageSpv,
                ["errors"] = stageOnly.Where(q => q.Err != null).Take(10).Select(q => $"{q.Source} {q.Id}：{q.Err}").ToList() };   // 10-20 怪猎偶发 error_a 原文没记下、事后定不了性：失败原文进 bake.json
            foreach (Prog q in stageOnly.Where(q => q.Err != null).Take(10)) Console.Error.WriteLine($"【红】shbake：阶段单独翻译失败 {q.Source} {q.Id}：{q.Err}");
            Console.WriteLine($"shbake：阶段单独翻译 {stageOnly.Count(q => q.Status == "ok")} / {stageOnly.Count} 支（新增 SPIR-V {stageSpv} 支）");
            if (s2aAll)
            {   // 单独翻译 vs 配对翻译（同缺省状态）：同一着色器键是否同一 SPIR-V
                Dictionary<string, string> solo = new();
                foreach (Prog q in stageOnly.Where(q => q.Status == "ok")) { int i = Array.FindIndex(q.ASpirv, b => b != null); if (i >= 0) solo[q.Keys[i]] = SpvKey(q.ASpirv[i]); }
                int same = 0, diff = 0; List<string> ex = new();
                foreach (Prog q in rule.Where(q => !q.Compute && q.ASpirv[1] != null && q.ASpirv[5] != null && q.Keys[0] == null && q.Keys[2] == null && q.Keys[3] == null && q.Keys[4] == null))
                    foreach (var (k, b) in new[] { (q.Keys[1], q.ASpirv[1]), (q.Keys[5], q.ASpirv[5]) })
                        if (solo.TryGetValue(k, out string sk)) { if (sk == SpvKey(b)) same++; else { diff++; if (ex.Count < 5) ex.Add(k); } }
                Console.WriteLine($"shbake：单独翻译 vs 配对翻译 同一着色器 SPIR-V 键相同 {same}、不同 {diff}（例 {string.Join(",", ex)}）");
                rep["stage_vs_pair"] = new Dictionary<string, object> { ["same"] = same, ["diff"] = diff, ["examples"] = ex };
            }
            double spvMs = sw.Elapsed.TotalMilliseconds;

            // 7) gal_xc：SPIR-V → MSL + 离线索引（每支着色器的参数布局记录）。宿主程序二进制就是各阶段记录拼起来（nxgal_prog_binary 同格式），
            //    所以出包时不用建 Metal 程序就能写全宿主缓存：手机首启按二进制直接从离线库取函数，不重翻 Maxwell、不调 SPIRV-Cross
            sw.Restart();
            Dictionary<ulong, byte[]> recs = null; uint xcVer = 0; int xcFail = 0;
            Dictionary<(ulong, ulong), byte[]> fbrTr = null; int fbrRed = 0;
            if (xc != null)
            {
                string lib = Path.Combine(outRoot, "lib");
                // 7a) 读帧缓冲证明（gal_xc --fbr，graphics/metal/gal_fbr.m，与运行时建程序同一份证明）：程序二进制只有顶点 + 片元两段的（含转计算程序的图形段）逐对证明；
                //     按变体请求表改写，改写后的片元落成 spv/<键>.fbf.spv，下面主流程带 NXGAL_XC_FBF 翻进离线库。fbr.tsv：P 行 = 程序二进制尾段（Galp 原样接上，
                //     手机 load_binary 恢复证明）、V 行 = 变体（pso_gen.py 给（顶点, 变体片元）出基础管线）
                HashSet<Prog> fs0 = fresh.ToHashSet(); HashSet<(ulong, ulong)> pairs = new();
                foreach (Prog fp in all.Concat(rule.Where(r => !fs0.Contains(r))))
                {
                    if (fp.Status != "ok" || fp.SpvHash == null || (fp.Source != null && fp.Source.StartsWith("gs_fn:"))) continue;
                    ulong[] ks = fp.Vtg is VtgOut vo ? fp.SpvHash[vo.NCompute..] : fp.Compute ? null : fp.SpvHash;
                    if (ks != null && ks.Length == 2) pairs.Add((ks[0], ks[1]));
                }
                string fbrPairs = Path.Combine(outRoot, "fbr_pairs.tsv"), fbrOut = Path.Combine(outRoot, "fbr.tsv");
                File.WriteAllLines(fbrPairs, pairs.OrderBy(x => x.Item1).ThenBy(x => x.Item2).Select(x => $"{x.Item1:x16} {x.Item2:x16}"));
                var pfb = new ProcessStartInfo(xc) { RedirectStandardOutput = true, RedirectStandardError = true };
                foreach (string x in new[] { "--fbr", fbrPairs, spvDir, fbrOut }) pfb.ArgumentList.Add(x);
                if (fbrVars != null && File.Exists(fbrVars)) pfb.ArgumentList.Add(fbrVars);
                using (Process pr = Process.Start(pfb))
                {
                    Task<string> o1 = pr.StandardOutput.ReadToEndAsync(), o2 = pr.StandardError.ReadToEndAsync();
                    if (!pr.WaitForExit(900_000)) { pr.Kill(true); Console.Error.WriteLine("【红】shbake：gal_xc --fbr 超过 900 秒，已杀"); return 1; }
                    File.WriteAllText(Path.Combine(outRoot, "fbr.log"), o1.Result + o2.Result);
                    // 退出 1 = 有变体试译失败 / 改写不符（这些变体已不进表，其余照用）；其它非 0 = 工具坏，整张表不用
                    if (pr.ExitCode != 0) { fbrRed = 1; Console.Error.WriteLine($"【红】shbake：gal_xc --fbr 退出 {pr.ExitCode}（{outRoot}/fbr.log）"); }
                    if (pr.ExitCode is 0 or 1) Console.WriteLine("shbake：" + o1.Result.Trim());
                    if ((pr.ExitCode is 0 or 1) && File.Exists(fbrOut))
                    {
                        fbrTr = new();
                        foreach (string l in File.ReadLines(fbrOut))
                        {
                            string[] fc = l.Split('\t');
                            if (fc.Length == 4 && fc[0] == "P") fbrTr[(Convert.ToUInt64(fc[1], 16), Convert.ToUInt64(fc[2], 16))] = Convert.FromHexString(fc[3]);
                        }
                    }
                }
                rep["fbr"] = new Dictionary<string, object> { ["pairs"] = pairs.Count, ["proven"] = fbrTr?.Count ?? 0,
                    ["variants"] = File.Exists(fbrOut) ? File.ReadLines(fbrOut).Count(l => l.StartsWith("V\t")) : 0, ["vars_table"] = fbrVars ?? "" };
                var psi = new ProcessStartInfo(xc) { RedirectStandardOutput = true, RedirectStandardError = true };
                foreach (string x in new[] { spvDir, lib, plat == "macos" ? "1" : "0" }) psi.ArgumentList.Add(x);
                using (Process pr = Process.Start(psi))
                {
                    Task<string> o1 = pr.StandardOutput.ReadToEndAsync(), o2 = pr.StandardError.ReadToEndAsync();
                    if (!pr.WaitForExit(900_000)) { pr.Kill(true); Console.Error.WriteLine("【红】shbake：gal_xc 超过 900 秒，已杀"); return 1; }
                    File.WriteAllText(Path.Combine(outRoot, "xc.log"), o1.Result + o2.Result);
                    if (pr.ExitCode != 0) { Console.Error.WriteLine($"【红】shbake：gal_xc 退出 {pr.ExitCode}（{outRoot}/xc.log）"); return 1; }
                }
                string ff = Path.Combine(lib, "xc_failed.txt");
                xcFail = File.Exists(ff) ? File.ReadLines(ff).Count(l => l.Length > 0 && !l.StartsWith('#')) : 0;
                (recs, xcVer) = ReadIdx(Path.Combine(lib, "gal.idx"));
            }
            double xcMs = sw.Elapsed.TotalMilliseconds;

            // 8) 写 Ryujinx 磁盘缓存（按程序表顺序：继承的在前、新的按键排序；顺序固定 → 产物可复现）。
            //    宿主缓存按程序序号对位：给了 --xc 时拼不出宿主二进制的程序整条不写（否则后面的程序全错位），计红
            sw.Restart();
            DiskCacheHostStorage hs = new(cacheDir);
            int written = 0, hostMissing = 0, vkHostWritten = 0, vkUnsupported = 0, vkFailed = 0;
            Dictionary<string, byte[]> vkSpirv = new(StringComparer.Ordinal);
            SortedSet<string> guestKeys = new(StringComparer.Ordinal);
            using (StreamWriter pw = new(Path.Combine(outRoot, "programs.tsv"), false, new UTF8Encoding(false)))
            {
                pw.Write("idx\torigin\tstatus\tkind\tsource\tstages(阶段:键:客体长度:指纹)\tspv\tms\terr\n");
                HashSet<Prog> freshSet = fresh.ToHashSet();
                foreach (Prog p in all.Concat(rule.Where(r => !freshSet.Contains(r))))
                {
                    // 双轨直连（§12.3 覆盖率就绪）：客体代码 sha256 前 16 位 → 抽取键。运行时 Ryujinx 只看得到客体代码（抽取 .code 去头、截到翻译长度），
                    //   按这张表把见过的着色器换成键写 seen_shaders.tsv（pack/stage_direct.sh 再经 key_map 换直连键）
                    for (int i = 0; i < (p.Guest?.Length ?? 0); i++)
                        if (p.Guest[i].HasValue && i < p.Keys.Length && p.Keys[i] != null) guestKeys.Add($"{Convert.ToHexStringLower(SHA256.HashData(p.Guest[i].Value.Code))[..16]}\t{p.Keys[i]}");
                    string stages = string.Join(" ", Enumerable.Range(0, p.Guest?.Length ?? 0).Where(i => p.Guest[i].HasValue).Select(i => $"{StageName(i, p.Compute)}:{(i < p.Keys.Length ? p.Keys[i] ?? "?" : "?")}:{p.Guest[i].Value.Code.Length}:{Fp(p.Guest[i].Value.Code, p.Compute)}"));
                    string spv = "";
                    int idx = -1;
                    if (p.Status == "ok" && p.Source != null && p.Source.StartsWith("gs_fn:"))
                    {   // 规则三：片元是占位的，缓存条目永不命中，只要函数进离线库（SPIR-V 乙段已落盘）
                        p.Status = "func_only"; spv = string.Join(",", p.SpvName);
                    }
                    else if (p.Status == "ok")
                    {
                        byte[] hc;
                        if (vkProfile != null)
                        {
                            // VKPB 宿主记录：与设备 ShaderCollection.GetBinary 同一 codec / 身份。写不出的仍写 guest/shared（设备按需翻译），
                            // 但状态与 manifest 计数照实分开：unsupported = v1 明确不支持的布局，failed = 编码/元数据错（计入退出码）。
                            hc = VkpbHostBinary(ctx, p, vkProfile, vkSpirv, out string vkError, out bool vkUnsupportedLayout);
                            if (hc == null)
                            {
                                if (vkUnsupportedLayout) { vkUnsupported++; p.Status = "vkpb_unsupported"; }
                                else { vkFailed++; p.Status = "vkpb_failed"; }
                                p.Err = vkError;
                                hc = Array.Empty<byte>();
                            }
                            else vkHostWritten++;
                            hs.AddShader(ctx, new CachedShaderProgram(null, p.Spec, p.Shaders), hc);
                            idx = written++;
                        }
                        else
                        {
                            hc = recs != null ? HostBinary(ctx, p, recs, xcVer, fbrTr) : Array.Empty<byte>();
                            if (hc == null) { hostMissing++; p.Status = "host_missing"; p.Err = "离线索引里缺这个程序某一阶段的记录（gal_xc 翻译失败？）"; }
                            else
                            {
                                hs.AddShader(ctx, new CachedShaderProgram(null, p.Spec, p.Shaders), hc);
                                idx = written++;
                            }
                        }
                        spv = string.Join(",", p.SpvName);
                    }
                    pw.Write($"{idx}\t{(p.Ref != null ? "ref" : "rule")}\t{p.Status}\t{(p.Compute ? "compute" : p.Vtg != null ? $"vtg{p.Vtg.NCompute}" : "graphics")}\t{p.Source}\t{stages}\t{spv}\t{p.Ms:0.0}\t{p.Err}\n");
                }
            }
            File.WriteAllText(Path.Combine(outRoot, "guest_keys.tsv"), "# 客体代码 sha256 前 16 位\t抽取键（S2Arm 口径）\n" + string.Concat(guestKeys.Select(l => l + "\n")), new UTF8Encoding(false));
            double writeMs = sw.Elapsed.TotalMilliseconds;

            // S2：Vulkan 离线包。进记录的每支 SPIR-V 按 profile 目标环境验一遍；manifest 覆盖 profile / 翻译器 / 内容根 / 逐文件摘要，
            // 装包端按同一份格式核对后再导入。转计算 / transform feedback / 补出的几何直通阶段不在 VKPB v1：照报 🔴、不计退出码，
            // 设备按需翻译（程序正确性不受影响，只是没有离线宿主记录）。
            int vkSpirvOk = 0, vkSpirvBad = 0; List<string> vkSpirvErrors = new(); bool vkManifestFailed = false;
            if (vkProfile != null)
            {
                (vkSpirvOk, vkSpirvBad, vkSpirvErrors) = ValidateSpirv(spirvVal ?? "spirv-val", vkProfile.TargetEnv, vkSpirv, Path.Combine(outRoot, "vkpb-val"));
                foreach (string e in vkSpirvErrors) Console.Error.WriteLine($"【红】shbake：SPIR-V 校验失败 {e}");
                int xlateFailed = all.Count(p => p.Status.StartsWith("error"));
                ShaderPackCounts packCounts = new(all.Count, vkHostWritten, vkUnsupported, vkFailed + xlateFailed);
                try
                {
                    ShaderPackManifest.Create(packRoot, title.ToUpperInvariant(), contentRoot, vkProfile.Identity, vkProfile.TranslatorClosure, ShaderAssemblyMvid(), packCounts).Save(Path.Combine(packRoot, "manifest.json"));
                }
                catch (Exception e)
                {
                    vkManifestFailed = true;
                    Console.Error.WriteLine($"🔴 shbake：离线包 manifest 写不出（{packRoot}）：{e.Message}");
                }
                rep["vulkan"] = new Dictionary<string, object>
                {
                    ["profile"] = vkProfile.Identity.ProfileKey, ["translation"] = vkProfile.Identity.TranslationKey, ["target_env"] = vkProfile.TargetEnv,
                    ["vendor"] = vkProfile.VendorName, ["pack"] = packRoot, ["host_written"] = vkHostWritten,
                    ["unsupported"] = vkUnsupported, ["failed"] = vkFailed, ["spirv_checked"] = vkSpirvOk, ["spirv_bad"] = vkSpirvBad,
                    ["manifest"] = vkManifestFailed ? "failed" : "ok",
                };
                if (vkUnsupported > 0) Console.Error.WriteLine($"【红】shbake：VKPB v1 未覆盖 {vkUnsupported} 个程序（转计算 / transform feedback / 补出的几何直通阶段）：设备按需翻译，不写宿主记录");
                Console.WriteLine($"shbake：Android VKPB 宿主记录 {vkHostWritten} 个（不支持 {vkUnsupported}、编码失败 {vkFailed}），SPIR-V 校验 {vkSpirvOk} 支通过 / {vkSpirvBad} 支失败；包 → {packRoot}");
            }

            long cacheBytes = Directory.EnumerateFiles(cacheDir).Sum(f => new FileInfo(f).Length);
            rep["counts"] = new Dictionary<string, object>
            {
                ["programs_inherited"] = inherited.Count, ["rule_status"] = rule.GroupBy(p => p.Status).ToDictionary(g => g.Key, g => g.Count()), ["programs_fresh"] = fresh.Count, ["programs_total"] = all.Count, ["written"] = written,
                ["status"] = all.GroupBy(p => p.Status).ToDictionary(g => g.Key, g => g.Count()),
                ["status_by_origin"] = all.GroupBy(p => (p.Ref != null ? "ref_" : "rule_") + p.Status).ToDictionary(g => g.Key, g => g.Count()),
                ["error_examples"] = all.Where(p => p.Err != null).Take(10).Select(p => $"{p.Source} {p.Id}：{p.Err}").ToList(),
                ["spv_unique"] = spvKeys.Count, ["spv_bytes"] = spvBytes, ["cache_bytes"] = cacheBytes,
            };
            rep["wall_ms"] = new Dictionary<string, object> { ["refs"] = Math.Round(refMs), ["prep"] = Math.Round(prepMs), ["phase_a"] = Math.Round(aMs), ["phase_b"] = Math.Round(xlateMs), ["spv"] = Math.Round(spvMs), ["gal_xc"] = Math.Round(xcMs), ["write"] = Math.Round(writeMs), ["total"] = Math.Round(total.Elapsed.TotalMilliseconds), ["threads"] = j };
            // 红（计入退出码）：没配进程序（几何以外）/ 甲乙段翻译失败 / gal_xc 翻译失败 / 拼不出宿主二进制
            var red = new Dictionary<string, int>
            {
                ["no_rule"] = noRule,   // 没配进程序的顶点 / 片元走阶段单独翻译（进离线库），不算红；这里只剩其它阶段（几何 / 曲面另计）
                ["xlate"] = all.Count(p => p.Status.StartsWith("error")) + stageOnly.Count(q => q.Status.StartsWith("error")),
                ["gal_xc"] = xcFail, ["host_missing"] = hostMissing, ["fbr"] = fbrRed,
                ["vkpb_failed"] = vkFailed + vkSpirvBad + (vkManifestFailed ? 1 : 0),
            };
            rep["red"] = red;
            // 已知缺口（照报 🔴、不计入退出码）：
            //   gs_unpaired：抽到的几何着色器没进任何程序（规则 / 继承 / 静态配对都没配上），运行时首遇当场翻译 + 现编；
            //   vtg_compute：转计算程序（S2AVtg，10-21 起进缓存）没写成（翻译 / 拼复合宿主二进制失败；翻译失败同时计在 xlate 红里）；
            //   tess_unpaired：曲面细分（hs / ds）没配进程序（渲染器第 8 块）。
            // 计入退出码会让用到几何 / 曲面着色器的游戏（马车8、八方2、暗黑2、巫师3、怪猎）整款出不了新包、被迫用口径不配的旧包，更糟
            // 几何着色器的覆盖按最终结果算（配上了但甲 / 乙段翻译失败的不算覆盖）：完整程序写入 / 继承 = 覆盖；只出函数 = gs_func_only；都没有 = gs_unpaired
            int vtgOk = all.Count(p => p.Vtg != null && p.Status == "ok");
            var gsProgs = all.Concat(rule).Where(p => !p.Compute && p.Keys[4] != null).Distinct().ToList();
            HashSet<string> gsKeysAll = rows.Where(r => r.st == "gs").Select(r => r.key).ToHashSet();
            HashSet<string> gsFull = gsProgs.Where(p => p.Status is "ok" or "inherited" or "dup_guest").Select(p => p.Keys[4]).ToHashSet();
            HashSet<string> gsFnK = gsProgs.Where(p => p.Status == "func_only").Select(p => p.Keys[4]).Where(k => !gsFull.Contains(k)).ToHashSet();
            int vtgBad = gsProgs.Count(p => p.Status.StartsWith("error"));
            rep["vtg_errors"] = gsProgs.Where(p => p.Err != null).GroupBy(p => p.Err.Length > 120 ? p.Err[..120] : p.Err).OrderByDescending(g => g.Count()).Take(5).Select(g => $"{g.Count()}×{g.Key}（例 {g.First().Source}）").ToList();
            // 继承的程序（Ref）各阶段键不在 Keys 里：按客体代码对回抽出键，免得冷局记录继承来的几何程序被算成没配上
            foreach (Prog p in all.Where(p => p.Ref != null && p.Status == "ok" && p.Guest != null && p.Guest.Length > 4 && p.Guest[4].HasValue))
            {
                string c = Sha(p.Guest[4].Value.Code, 32);
                foreach (string k in gsKeysAll) if (Sha(xs[k].Mem.ToArray(), 32) == c || Sha(xs[k].Mem.Span[..Math.Min(xs[k].Mem.Length, p.Guest[4].Value.Code.Length)].ToArray(), 32) == c) { gsFull.Add(k); gsFnK.Remove(k); }
            }
            var gap = new Dictionary<string, int> { ["gs_unpaired"] = gsKeysAll.Count(k => !gsFull.Contains(k) && !gsFnK.Contains(k)), ["gs_func_only"] = gsFnK.Count, ["tess_unpaired"] = noRuleTess, ["vtg_compute"] = vtgBad, ["vkpb_unsupported"] = vkUnsupported };
            rep["known_gap"] = gap; rep["vtg_programs"] = vtgOk;
            if (gap.Values.Sum() > 0) Console.Error.WriteLine("【红】shbake：已知缺口（不计退出码）" + string.Join("，", gap.Where(kv => kv.Value > 0).Select(kv => $"{kv.Key} {kv.Value}")) + "：几何着色器没配上程序 / 转计算程序没写成，运行时首遇现翻；曲面阶段渲染器不支持（第 8 块）");
            int vtgFn = all.Count(p => p.Vtg != null && p.Status == "func_only"); rep["vtg_func_only"] = vtgFn;
            // --reflib 状态表（10-22 与画面·着色器线对齐的接口：其 refpso.py 把社区状态转成我方 v2 行，shader_pack.sh 在烘焙后、pso_gen 前调）：
            //   <输出根>/reflib_states.tsv，每个「参考库里配上的图形程序（含已被规则覆盖、库内重复的）× 我方这份程序」一行，制表符分隔：
            //   顶点函数名 s<16 位> | 片元函数名或 - | 我方这份的透明测试（关 -，开 <比较方式数值>:<参考值浮点位十六进制>）| 来源格式 u32 十六进制 | 代码生成版本 u32 十六进制 | 状态原样字节十六进制
            //   我方这份 = 该程序最终落到的那个（规则配出 ok 的本身；继承 → 已有缓存里同客体代码那个；同客体代码去重 → 留下的那个）+ 它直接的透明测试「开」变体（Id + #a<n>），
            //   由 refpso.py 按社区状态里的透明测试挑；整数属性变体（#i）不写。写在宽屏改写之后：函数名是最终 SPIR-V 的键
            if (rlRows.Count > 0)
            {
                Dictionary<string, Prog> ruleBy = new(), inhBy = new(); Dictionary<string, List<Prog>> alphaOf = new();
                foreach (Prog q in rule) if (!q.StageOnly && q.Id != null) ruleBy.TryAdd(q.Id, q);
                foreach (Prog q in inherited) if (q.Id != null) inhBy.TryAdd(q.Id, q);
                foreach (Prog v in all)
                {
                    if (v.Id == null) continue; int h = v.Id.IndexOf('#');
                    if (h > 0 && string.CompareOrdinal(v.Id, h, "#a", 0, 2) == 0 && v.Id.Length > h + 2 && v.Id.Skip(h + 2).All(char.IsDigit))
                        { if (!alphaOf.TryGetValue(v.Id[..h], out var l)) alphaOf[v.Id[..h]] = l = new(); l.Add(v); }
                }
                Prog Final(Prog rp) => rp.Status switch
                {
                    "ok" => rp,
                    "inherited" => inhBy.GetValueOrDefault(GuestId(rp.Compute, rp.Guest)),
                    "dup_guest" => freshBy.GetValueOrDefault(GuestId(rp.Compute, rp.Guest)),
                    _ => null,
                };
                static string Fn(Prog c, ShaderStage st) { if (c.SpvName == null || c.SpvStage == null) return null; int i = Array.IndexOf(c.SpvStage, st); return i < 0 ? null : "s" + c.SpvName[i]; }
                HashSet<string> lines = new(); Dictionary<string, int> miss = new();
                void Miss(string why) => miss[why] = miss.GetValueOrDefault(why) + 1;
                foreach (var (id, fmt, cg, raw) in rlRows)
                {
                    if (!ruleBy.TryGetValue(id, out Prog rp)) { Miss("规则里没有这个程序"); continue; }
                    Prog f = Final(rp); if (f == null) { Miss("程序没翻成（" + rp.Status + "）"); continue; }
                    List<Prog> copies = new() { f }; if (alphaOf.TryGetValue(f.Id, out var al)) copies.AddRange(al);
                    int before = lines.Count;
                    foreach (Prog c in copies.Where(c => c.Status == "ok"))
                    {
                        string vs = Fn(c, ShaderStage.Vertex), fs = Fn(c, ShaderStage.Fragment) ?? "-";
                        if (vs == null) continue;
                        ref GpuChannelGraphicsState gs = ref c.Spec.GraphicsState;
                        string at = gs.AlphaTestEnable ? $"{(int)gs.AlphaTestCompare}:{BitConverter.SingleToUInt32Bits(gs.AlphaTestReference):x8}" : "-";
                        lines.Add($"{vs}\t{fs}\t{at}\t{fmt:x8}\t{cg:x8}\t{Convert.ToHexString(raw).ToLowerInvariant()}");
                    }
                    if (lines.Count == before) Miss("没有可写的顶点函数名");
                }
                File.WriteAllLines(Path.Combine(outRoot, "reflib_states.tsv"), new[] { "# 顶点函数\t片元函数\t我方透明测试\t来源格式\t代码生成版本\t状态原样字节（--reflib 配上的程序 × 我方这份；接口见 ShaderBake.cs）" }.Concat(lines.OrderBy(x => x, StringComparer.Ordinal)));
                rep["reflib_states"] = new Dictionary<string, object> { ["rows"] = rlRows.Count, ["lines"] = lines.Count, ["unresolved"] = miss };
                Console.WriteLine($"shbake --reflib：状态表 {lines.Count} 行（参考库配上的图形程序 {rlRows.Count} 行；没写出的 {string.Join("，", miss.Select(kv => $"{kv.Key} {kv.Value}"))}）→ reflib_states.tsv");
            }
            Console.WriteLine($"shbake：转计算程序（顶点 / 几何当计算跑）写入 {vtgOk} 个，只出函数 {vtgFn} 个");
            rep["spec_trimmed_tex_queries"] = TrimmedTexQueries;
            File.WriteAllText(Path.Combine(outRoot, "bake.json"), System.Text.Json.JsonSerializer.Serialize(rep, new System.Text.Json.JsonSerializerOptions { WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping }));
            int nred = red.Values.Sum();
            Tr.Write(Path.Combine(outRoot, TrLog.FileName)); Console.WriteLine(Tr.Summary());
            Console.WriteLine($"shbake：继承条目贴图查询按再翻收窄 {TrimmedTexQueries} 位");
            Console.WriteLine($"shbake：程序 {all.Count}（继承 {inherited.Count} + 新配 {fresh.Count}），写入 {written}，SPIR-V {spvKeys.Count} 支 {spvBytes >> 10} KB，缓存 {cacheBytes >> 10} KB；甲段 {aMs / 1000:0.0} s + 乙段 {xlateMs / 1000:0.0} s + gal_xc {xcMs / 1000:0.0} s（{j} 线程），总 {total.Elapsed.TotalSeconds:0.0} s → {outRoot}");
            if (nred > 0) Console.Error.WriteLine($"【红】shbake：红 {nred}（" + string.Join("，", red.Where(kv => kv.Value > 0).Select(kv => $"{kv.Key} {kv.Value}")) + "），明细见 bake.json / programs.tsv");
            return nred > 0 ? 1 : 0;
        }

        // ================= S2：Android Vulkan 离线宿主记录 =================
        // 与设备 ShaderCollection.GetBinary 同一 VKPB v1 codec、同一翻译身份；ShaderInfo 按设备磁盘缓存加载路径的
        // ShaderInfoBuilder.BuildForCache 重建。不反射 VkShaderModule，也不用烘焙器的能力表冒充设备能力。
        static byte[] VkpbHostBinary(GpuContext ctx, Prog p, VulkanProfile profile, Dictionary<string, byte[]> spirv,
            out string error, out bool unsupported)
        {
            error = null;
            unsupported = false;
            if (p.Spec == null) { error = "程序没有特化状态"; return null; }
            if (p.Vtg != null) { unsupported = true; error = "转计算（S2AVtg）复合程序不在 VKPB v1"; return null; }
            if (p.Spec.TransformFeedbackDescriptors != null) { unsupported = true; error = "transform feedback 程序不在 VKPB v1"; return null; }
            if (p.GeometryPassthrough) { unsupported = true; error = "为顶点层输出补出的几何直通阶段没有缓存阶段信息，不能重建布局"; return null; }
            if (p.Shaders == null || p.Sources.Count == 0) { error = "程序没有可写的阶段"; return null; }

            ShaderInfo info;
            try
            {
                info = ShaderInfoBuilder.BuildForCache(ctx, p.Shaders, p.Spec.PipelineState, tfEnabled: false);
            }
            catch (Exception e)
            {
                error = $"ShaderInfo 重建失败：{e.GetType().Name}: {e.Message}";
                return null;
            }

            ProgramBinaryStageSpecialization[] specs = p.Sources
                .Select(_ => new ProgramBinaryStageSpecialization(Array.Empty<ProgramBinarySpecializationEntry>(), Array.Empty<byte>()))
                .ToArray();
            ProgramBinary recipe = new(profile.Identity, new ProgramBinaryOptions(false, false, false), p.Sources.ToArray(), info, specs);
            if (!ProgramBinaryCodec.TryEncode(recipe, out byte[] binary, out string encodeError))
            {
                unsupported = encodeError.StartsWith("UNSUPPORTED", StringComparison.Ordinal);
                error = encodeError;
                return null;
            }

            foreach (ShaderSource source in p.Sources)
                spirv.TryAdd(Convert.ToHexStringLower(SHA256.HashData(source.BinaryCode)), source.BinaryCode);
            return binary;
        }

        // 与 VulkanRenderer.HostProgramCacheDiscriminator 同一算法：设备宿主缓存文件名里的身份后缀。
        static string DiscriminatorOf(ProgramBinaryIdentity identity) =>
            Convert.ToHexStringLower(SHA256.HashData(Encoding.ASCII.GetBytes(
                $"{identity.Scheme}|{identity.ProfileKey}|{identity.TranslationKey}|{identity.BindingAbi}")));

        // 设备与出包按同一程序集 MVID 核对翻译器构建（manifest.translator.shaderMvid）。
        static string ShaderAssemblyMvid() => typeof(ShaderProgram).Assembly.ManifestModule.ModuleVersionId.ToString("N");

        static bool SpirvValWorks(string validator, out string error)
        {
            try
            {
                ProcessStartInfo psi = new(validator) { RedirectStandardOutput = true, RedirectStandardError = true };
                psi.ArgumentList.Add("--version");
                using Process process = Process.Start(psi);
                Task<string> stdout = process.StandardOutput.ReadToEndAsync(), stderr = process.StandardError.ReadToEndAsync();
                if (!process.WaitForExit(30_000)) { process.Kill(true); error = "spirv-val --version 超时"; return false; }
                string text = (stdout.Result + stderr.Result).Trim();
                error = process.ExitCode == 0 && text.Length > 0 ? null : $"退出 {process.ExitCode}";
                return error == null;
            }
            catch (Exception e)
            {
                error = e.Message;
                return false;
            }
        }

        static (int ok, int bad, List<string> errors) ValidateSpirv(string validator, string targetEnv,
            Dictionary<string, byte[]> spirv, string dir)
        {
            Directory.CreateDirectory(dir);
            int ok = 0, bad = 0;
            List<string> errors = new();
            foreach ((string key, byte[] bytes) in spirv.OrderBy(kv => kv.Key, StringComparer.Ordinal))
            {
                string file = Path.Combine(dir, key + ".spv");
                File.WriteAllBytes(file, bytes);
                ProcessStartInfo psi = new(validator) { RedirectStandardOutput = true, RedirectStandardError = true };
                psi.ArgumentList.Add("--target-env");
                psi.ArgumentList.Add(targetEnv);
                psi.ArgumentList.Add(file);
                try
                {
                    using Process process = Process.Start(psi);
                    Task<string> stdout = process.StandardOutput.ReadToEndAsync(), stderr = process.StandardError.ReadToEndAsync();
                    if (!process.WaitForExit(120_000)) { process.Kill(true); bad++; errors.Add($"{key}：spirv-val 超时"); continue; }
                    string text = (stdout.Result + stderr.Result).Trim();
                    if (process.ExitCode == 0) ok++;
                    else { bad++; errors.Add($"{key}：{(text.Length == 0 ? "退出 " + process.ExitCode : text.Split('\n')[0])}"); }
                }
                catch (Exception e)
                {
                    bad++;
                    errors.Add($"{key}：{e.Message}");
                }
            }

            return (ok, bad, errors);
        }

        // 离线索引（gal_prog.m off_lookup 同格式，小端）：u32 魔数 "GALI"、版本、翻译口径 GAL_XC_VERSION、平台、条数 n、填充 → 24 字节头；
        // 然后 n 条 {u64 键, u32 记录偏移, u32 记录长}；记录 = u64 键 + u32 阶段 + …（rec_write）
        static (Dictionary<ulong, byte[]>, uint) ReadIdx(string path)
        {
            byte[] b = File.ReadAllBytes(path);
            if (b.Length < 24 || BinaryPrimitives.ReadUInt32LittleEndian(b) != 0x494c4147u || BinaryPrimitives.ReadUInt32LittleEndian(b.AsSpan(4)) != 1u) throw new InvalidDataException($"{path}：不是离线索引（魔数 / 版本不符）");
            uint xv = BinaryPrimitives.ReadUInt32LittleEndian(b.AsSpan(8)), n = BinaryPrimitives.ReadUInt32LittleEndian(b.AsSpan(16));
            Dictionary<ulong, byte[]> d = new((int)n);
            for (int i = 0; i < n; i++)
            {
                ReadOnlySpan<byte> e = b.AsSpan(24 + i * 16, 16);
                ulong k = BinaryPrimitives.ReadUInt64LittleEndian(e); int off = (int)BinaryPrimitives.ReadUInt32LittleEndian(e[8..]), len = (int)BinaryPrimitives.ReadUInt32LittleEndian(e[12..]);
                byte[] r = b.AsSpan(off, len).ToArray();
                if (BinaryPrimitives.ReadUInt64LittleEndian(r) != k) throw new InvalidDataException($"{path}：第 {i} 条记录的键与索引不符");
                d[k] = r;
            }
            return (d, xv);
        }

        // 宿主程序二进制（gal_prog.m nxgal_prog_binary 同格式）：u32 "GALP"、u32 BIN_VERSION 2、u32 GAL_XC_VERSION、u32 阶段数 m、i32 frag_output_map，
        // 然后按阶段号升序 m 个 {u32 记录长, 记录}；顶点 + 片元两段且读帧缓冲证得的，再接 gal_xc --fbr 出的尾段（格式见 graphics/metal/gal_fbr.m gal_fbr_ser）。frag_output_map 与设备加载时 Ryujinx 给的同一算法（ShaderInfoBuilder.BuildForCache）。缺任一阶段记录 → null
        static byte[] HostBinary(GpuContext ctx, Prog p, Dictionary<ulong, byte[]> recs, uint xcVer, Dictionary<(ulong, ulong), byte[]> fbr = null)
        {
            if (p.Vtg is VtgOut v)
            {
                // 转计算程序：复合宿主二进制（Ryujinx S2AVtg.Pack）= 图形程序 + 顶点计算 + [几何计算] 三个后端程序二进制 + 保留布局 + 直通顶点信息
                int nc = v.NCompute;
                byte[] gb = Galp(p.SpvHash[nc..], recs, xcVer, v.GraphicsFom, fbr), vb = Galp(p.SpvHash[..1], recs, xcVer, v.ComputeFom);
                byte[] sb = v.HasGs ? Galp(p.SpvHash[1..2], recs, xcVer, v.GeometryFom) : null;
                if (gb == null || vb == null || (v.HasGs && sb == null)) return null;
                return S2AVtg.Pack(v.Tf, gb, vb, v.VRes, sb, v.GRes, v.PassthroughInfo);
            }
            int fom = ShaderInfoBuilder.BuildForCache(ctx, p.Shaders, p.Spec.PipelineState, p.Spec.TransformFeedbackDescriptors != null).FragmentOutputMap;
            return Galp(p.SpvHash, recs, xcVer, fom, fbr);
        }

        // 后端程序二进制（gal_prog.m nxgal_prog_binary 同格式）：给定各阶段 SPIR-V 键与 frag_output_map；缺记录 / 阶段重复 → null。
        // fbr：gal_xc --fbr 的证明表（（顶点键, 片元键）→ 尾段字节）；只有阶段 1 + 5 两段、表里有的才接尾段
        static byte[] Galp(ulong[] keys, Dictionary<ulong, byte[]> recs, uint xcVer, int fom, Dictionary<(ulong, ulong), byte[]> fbr = null)
        {
            List<(uint st, byte[] r)> L = new();
            foreach (ulong h in keys)
            {
                if (!recs.TryGetValue(h, out byte[] r)) return null;
                L.Add((BinaryPrimitives.ReadUInt32LittleEndian(r.AsSpan(8)), r));
            }
            if (L.Count == 0 || L.Count > 6 || L.Select(x => x.st).Distinct().Count() != L.Count) return null;
            using MemoryStream ms = new(); using BinaryWriter w = new(ms);
            w.Write(0x504c4147u); w.Write(2u); w.Write(xcVer); w.Write((uint)L.Count); w.Write(fom);
            var LS = L.OrderBy(x => x.st).ToList();
            foreach (var (_, r) in LS) { w.Write((uint)r.Length); w.Write(r); }
            if (fbr != null && LS.Count == 2 && LS[0].st == 1 && LS[1].st == 5
                && fbr.TryGetValue((BinaryPrimitives.ReadUInt64LittleEndian(LS[0].r), BinaryPrimitives.ReadUInt64LittleEndian(LS[1].r)), out byte[] tr)) w.Write(tr);
            w.Flush(); return ms.ToArray();
        }
    }
}
