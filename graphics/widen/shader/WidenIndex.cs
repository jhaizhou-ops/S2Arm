// 通用宽屏 · 着色器包里的宽屏元数据（shaders/widen.idx）：手机上程序走「程序二进制」（LoadProgramBinary，见 graphics/metal/gal_prog.m），没有 SPIR-V，
// 包装层拿不到常量读法 / 片元 y 是否改过 / 顶点能否外推 / 片元采样哪些贴图。出包时（graphics/tools/shbake）对每个改后的阶段记一条，
// 运行时按程序二进制里各阶段记录开头的键（gal_spv_hash = 改后 SPIR-V 的 SHA-256 前 8 字节按小端读成 u64）查表补上——与 CreateProgram 那条路得到的完全一样。
// 格式（小端）：u32 魔数 "WIDX"、u32 版本 3、u32 条数；每条：u64 键、i32 阶段、i32 片元 y 改了几处、u8 顶点能否外推、u8 片元要按真实像素坐标画（版本 2 起；版本 1 读作 0）、
//   i32 取图缩放项数 + 每项（i32 render_scale 下标、i32 绑定号、u8 存储图像）、i32 存储图像绑定数 + 各 i32（版本 3 起）、i32 采样绑定数 + 各 i32、
//   i32 常量读法数 + 每个（i32 绑定号、u8 动态下标、i32 下标数 + 各 i32）。读法取自改写前的原 SPIR-V（同 CreateProgram 的 SpirvCbufUse.Analyze(原着色器)）。
//   版本 4 起每条末尾：u8 片元能按原画框外推（SpirvExtrap）、i32 外推采样项数 + 每项（i32 render_scale 下标、i32 绑定号）。
using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.IO;
using System.Security.Cryptography;

namespace S2Arm.Gfx.Widen
{
    public sealed class WidenStageMeta
    {
        public int Stage, FragY; public bool Push;
        /// <summary>片元要按真实像素坐标画（SpirvFetchScale 不 exact：有没经过缩放的 2D 整数取图等）；版本 2 的包里 = 片元有整数取图（那时取图缩放还不分轴，一律按真实像素）。</summary>
        public bool RealPx;
        /// <summary>取图缩放项（render_scale 下标、绑定号、存储图像），见 SpirvFetchScale。</summary>
        public (int Index, int Binding, bool Image)[] Scales = Array.Empty<(int, int, bool)>();
        /// <summary>这一阶段用到的存储图像绑定号（SPIR-V 里存储图像变量的 Binding）；null = 不知道（版本 1 / 2 的包）。程序二进制的 ShaderInfo 资源表是空的，
        /// 包装层按它认「计算派发写哪些图像」（WidenRenderer ProgImages）。</summary>
        public int[] Images;
        public int[] Sampled = Array.Empty<int>(); public CbufUse[] Uses = Array.Empty<CbufUse>();
        /// <summary>片元能按原画框外推画（SpirvExtrap 改了）；ExtrapSamples = 外推时归一化采样要写 off 的 (render_scale 下标, 绑定号)。版本 1–3 的包读作 false。</summary>
        public bool Extrap; public (int Index, int Binding)[] ExtrapSamples = Array.Empty<(int, int)>();
    }

    /// <summary>
    /// 读进来的 widen.idx：常驻的只有原文件字节和「键 → 条目起点」（都不含引用），查到时才把那一条解成 <see cref="WidenStageMeta"/>（调用方建程序时用完即弃）。
    /// 原先整份解成常驻对象图（马车8 约 16 万个对象、39 万指针槽，占全堆指针 18%），加重 gen2 标记与读盘段卡表扫描。多线程只读安全。
    /// </summary>
    public sealed class WidenIdxTable
    {
        readonly byte[] _raw; readonly uint _ver; readonly Dictionary<ulong, int> _at;
        internal WidenIdxTable(byte[] raw, uint ver, Dictionary<ulong, int> at) { _raw = raw; _ver = ver; _at = at; }

        public int Count => _at.Count;

        public bool TryGetValue(ulong key, out WidenStageMeta meta)
        {
            if (!_at.TryGetValue(key, out int at)) { meta = null; return false; }
            using var r = new BinaryReader(new MemoryStream(_raw, at, _raw.Length - at, false));
            meta = WidenIndex.ReadEntry(r, _ver);
            return true;
        }

        public WidenStageMeta this[ulong key] => TryGetValue(key, out WidenStageMeta m) ? m : throw new KeyNotFoundException();
    }

    public static class WidenIndex
    {
        public const uint Magic = 0x58444957, Version = 4;   // "WIDX"
        public const string FileName = "widen.idx";

        /// <summary>着色器键：SHA-256 前 8 字节按小端读成 u64（与 gal_prog.m gal_spv_hash、程序二进制记录开头的键同口径）。</summary>
        public static ulong Key(byte[] spv) => BinaryPrimitives.ReadUInt64LittleEndian(SHA256.HashData(spv));

        /// <summary>出包时：原 SPIR-V → 按 WidenShaders 改写，返回改后的字节与这一阶段的元数据（stage 用 Ryujinx ShaderStage 的整数值；isVertex / isFragment 由调用方按阶段给）。</summary>
        public static byte[] Transform(byte[] original, int stage, bool isVertex, bool isFragment, out WidenStageMeta meta, bool allowExtrap)
        {
            byte[] b = original; int fy = 0; bool push = false, exact = true, ex = false; (int, int, bool)[] sc = Array.Empty<(int, int, bool)>(); (int, int)[] es = Array.Empty<(int, int)>();
            if (isFragment) b = WidenShaders.Fragment(original, allowExtrap, out fy, out sc, out exact, out ex, out es);
            else if (isVertex) b = WidenShaders.Vertex(original, out push);
            meta = new WidenStageMeta { Stage = stage, FragY = fy, Push = push, RealPx = !exact, Scales = sc, Images = StorageImageBindings(original), Sampled = isFragment || isVertex ? SpirvEdgePush.SampledBindings(b) : Array.Empty<int>(), Extrap = ex, ExtrapSamples = es };
            if (SpirvCbufUse.Analyze(original) is { } u) meta.Uses = u.ToArray();
            return b;
        }

        /// <summary>存储图像变量（指向 OpTypeImage 且 Sampled = 2 的变量，含其数组）的 Binding 装饰，升序去重。</summary>
        public static int[] StorageImageBindings(byte[] spv)
        {
            if (spv == null || spv.Length < 20 || (spv.Length & 3) != 0) return Array.Empty<int>();
            ReadOnlySpan<uint> w = System.Runtime.InteropServices.MemoryMarshal.Cast<byte, uint>(spv);
            if (w[0] != 0x07230203) return Array.Empty<int>();
            var storage = new HashSet<uint>(); var ptr = new HashSet<uint>(); var bind = new Dictionary<uint, int>(); var o = new SortedSet<int>();
            for (int i = 5; i < w.Length;)
            {
                int n = (int)(w[i] >> 16), op = (int)(w[i] & 0xffff);
                if (n == 0 || i + n > w.Length) break;
                if (op == 25 && n >= 9 && w[i + 7] == 2) storage.Add(w[i + 1]);                                  // OpTypeImage … Sampled = 2
                else if ((op == 28 || op == 29) && n >= 3 && storage.Contains(w[i + 2])) storage.Add(w[i + 1]);  // OpTypeArray / OpTypeRuntimeArray 的元素
                else if (op == 32 && n == 4 && storage.Contains(w[i + 3])) ptr.Add(w[i + 1]);                     // OpTypePointer
                else if (op == 71 && n >= 4 && w[i + 2] == 33) bind[w[i + 1]] = (int)w[i + 3];                  // OpDecorate Binding
                else if (op == 59 && n >= 4 && ptr.Contains(w[i + 1]) && bind.TryGetValue(w[i + 2], out int b)) o.Add(b);   // OpVariable
                i += n;
            }
            var r = new int[o.Count]; o.CopyTo(r); return r;
        }

        public static void Write(string path, IEnumerable<KeyValuePair<ulong, WidenStageMeta>> items)
        {
            var list = new List<KeyValuePair<ulong, WidenStageMeta>>(items); list.Sort((a, b) => a.Key.CompareTo(b.Key));   // 按键排序：产物可复现
            using var w = new BinaryWriter(File.Create(path));
            w.Write(Magic); w.Write(Version); w.Write(list.Count);
            foreach (var (k, m) in list)
            {
                w.Write(k); w.Write(m.Stage); w.Write(m.FragY); w.Write((byte)(m.Push ? 1 : 0)); w.Write((byte)(m.RealPx ? 1 : 0));
                w.Write(m.Scales.Length); foreach (var (si, sb, img) in m.Scales) { w.Write(si); w.Write(sb); w.Write((byte)(img ? 1 : 0)); }
                int[] im = m.Images ?? Array.Empty<int>(); w.Write(im.Length); foreach (int b in im) w.Write(b);
                w.Write(m.Sampled.Length); foreach (int s in m.Sampled) w.Write(s);
                w.Write(m.Uses.Length);
                foreach (CbufUse u in m.Uses) { w.Write(u.Binding); w.Write((byte)(u.Dynamic ? 1 : 0)); w.Write(u.Indices.Length); foreach (int i in u.Indices) w.Write(i); }
                w.Write((byte)(m.Extrap ? 1 : 0)); w.Write(m.ExtrapSamples.Length); foreach (var (ei, eb) in m.ExtrapSamples) { w.Write(ei); w.Write(eb); }
            }
        }

        /// <summary>读表；文件不在或格式不对返回 null。旧版本照读：版本 1 没有「按真实像素」（false）、版本 1 / 2 没有取图缩放项（那时包里着色器的取图缩放不分轴，不能写）、版本 1–3 没有外推（false）。</summary>
        public static WidenIdxTable Read(string path)
        {
            if (string.IsNullOrEmpty(path) || !File.Exists(path)) return null;
            byte[] raw = File.ReadAllBytes(path);
            using var r = new BinaryReader(new MemoryStream(raw, false));
            if (r.ReadUInt32() != Magic) return null;
            uint ver = r.ReadUInt32(); if (ver < 1 || ver > Version) return null;
            int n = r.ReadInt32(); var d = new Dictionary<ulong, int>(n);
            for (int e = 0; e < n; e++)
            {
                ulong k = r.ReadUInt64(); int at = (int)r.BaseStream.Position;
                SkipEntry(r, ver);   // 只跳过、不建对象：定下一条起点，截断早抛
                d[k] = at;
            }
            return new WidenIdxTable(raw, ver, d);
        }

        /// <summary>跳过一条（布局同 <see cref="ReadEntry"/>）。</summary>
        static void SkipEntry(BinaryReader r, uint ver)
        {
            Stream st = r.BaseStream;
            void Skip(long n) { if (n < 0 || st.Position + n > st.Length) throw new EndOfStreamException(); st.Position += n; }
            Skip(9 + (ver >= 2 ? 1 : 0));
            if (ver >= 3) { Skip(9L * r.ReadInt32()); Skip(4L * r.ReadInt32()); }
            Skip(4L * r.ReadInt32());
            int uses = r.ReadInt32();
            for (int i = 0; i < uses; i++) { Skip(5); Skip(4L * r.ReadInt32()); }
            if (ver >= 4) { Skip(1); Skip(8L * r.ReadInt32()); }
        }

        internal static WidenStageMeta ReadEntry(BinaryReader r, uint ver)
        {
            var m = new WidenStageMeta { Stage = r.ReadInt32(), FragY = r.ReadInt32(), Push = r.ReadByte() != 0 };
            if (ver >= 2) m.RealPx = r.ReadByte() != 0;
            if (ver >= 3)
            {
                m.Scales = new (int, int, bool)[r.ReadInt32()]; for (int i = 0; i < m.Scales.Length; i++) m.Scales[i] = (r.ReadInt32(), r.ReadInt32(), r.ReadByte() != 0);
                m.Images = new int[r.ReadInt32()]; for (int i = 0; i < m.Images.Length; i++) m.Images[i] = r.ReadInt32();
            }
            m.Sampled = new int[r.ReadInt32()]; for (int i = 0; i < m.Sampled.Length; i++) m.Sampled[i] = r.ReadInt32();
            m.Uses = new CbufUse[r.ReadInt32()];
            for (int i = 0; i < m.Uses.Length; i++)
            {
                var u = new CbufUse { Binding = r.ReadInt32(), Dynamic = r.ReadByte() != 0 };
                int c = r.ReadInt32(); for (int j = 0; j < c; j++) u.Add(r.ReadInt32());
                m.Uses[i] = u;
            }
            if (ver >= 4) { m.Extrap = r.ReadByte() != 0; m.ExtrapSamples = new (int, int)[r.ReadInt32()]; for (int i = 0; i < m.ExtrapSamples.Length; i++) m.ExtrapSamples[i] = (r.ReadInt32(), r.ReadInt32()); }
            return m;
        }

        /// <summary>程序二进制（gal_prog.m nxgal_prog_binary：u32 "GALP"、u32 版本、u32 翻译口径、u32 阶段数 m、i32 frag_output_map，然后 m 个 {u32 记录长, 记录}，记录开头 u64 键）里各阶段的键。认不出返回 false。</summary>
        public static bool BinaryKeys(ReadOnlySpan<byte> bin, List<ulong> keys)
        {
            keys.Clear();
            if (bin.Length < 20 || BinaryPrimitives.ReadUInt32LittleEndian(bin) != 0x504c4147u) return false;
            uint m = BinaryPrimitives.ReadUInt32LittleEndian(bin[12..]); int q = 20;
            if (m == 0 || m > 6) return false;
            for (uint i = 0; i < m; i++)
            {
                if (q + 4 > bin.Length) return false;
                int L = (int)BinaryPrimitives.ReadUInt32LittleEndian(bin[q..]); q += 4;
                if (L < 8 || q + L > bin.Length) return false;
                keys.Add(BinaryPrimitives.ReadUInt64LittleEndian(bin[q..])); q += L;
            }
            return true;
        }
    }
}
