// GAL 调用流录像：读端 + 最小回放器。把录像逐条喂给任意 IRenderer（桩渲染器 / NxRenderer / Ryujinx 自带渲染器），
// 对象 / 缓冲按录像里的稳定编号映射到目标渲染器自己建的对象。读回类调用（GetData / GetBufferData / 程序状态 …）照样调，
// 拿目标的结果和录像里的指纹比对，不一致计数（RT 内容逐次比对由渲染线的回放器在此基础上加）。
using Ryujinx.Common.Memory;
using Ryujinx.Graphics.GAL;
using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.IO;
using System.Runtime.CompilerServices;
using System.Text;

namespace RyuJudge.GalRec
{
    /// <summary>一条记录在录像文件里的位置：操作码、记录体在文件里的起点（字节）、长度、序号（从 0 起）。</summary>
    public readonly struct GalRecRecord
    {
        public readonly uint Op;
        public readonly long Offset;
        public readonly int Length;
        public readonly long Index;

        public GalRecRecord(uint op, long offset, int length, long index)
        {
            Op = op;
            Offset = offset;
            Length = length;
            Index = index;
        }

        /// <summary>旧接口兼容：<c>foreach ((uint op, int start, int len) in f.Records())</c> 配 <see cref="GalRecFile.Data"/>。录像超过 2 GB 时起点放不进 int，抛异常（改用 Payload）。</summary>
        public void Deconstruct(out uint op, out int start, out int len)
        {
            op = Op;
            start = Offset <= int.MaxValue ? (int)Offset : throw new InvalidOperationException($"记录 #{Index} 起点 {Offset} 超过 2 GB：用 GalRecFile.Payload(记录)");
            len = Length;
        }
    }

    /// <summary>
    /// 录像读端。不把整份录像读进内存：Load 只读头并扫一遍记录头建偏移索引（每条 24 字节），记录体回放时按需从文件读（定位读，不改文件指针）。
    /// 峰值内存 ≈ 索引 + 最大一条记录体，与录像大小无关（只与条数线性相关）。录像在某条记录中途截断：索引停在截断前，<see cref="Truncation"/> 说明位置。
    /// </summary>
    public sealed unsafe class GalRecFile : IDisposable
    {
        public uint Version;
        public string SignatureHash;
        public byte[] CapsBytes;
        public Capabilities Capabilities;
        public SortedDictionary<uint, string> OpNames = new();
        public string Path;
        public long FileLength;
        /// <summary>第一条记录头在文件里的起点。</summary>
        public long BodyStart;
        /// <summary>完整记录（截断那条不算）。</summary>
        public readonly List<GalRecRecord> Index = new();
        /// <summary>截断说明（null = 文件完整）：截断那条记录的序号、文件偏移、声明长度与实有字节。</summary>
        public string Truncation;
        public long TruncatedAtOffset = -1;

        Microsoft.Win32.SafeHandles.SafeFileHandle _h;
        // 记录体复用缓冲放非托管内存：放托管堆的话，一条几百 MB 的大记录会把 GC 的大对象预算一起抬高，回放期间的垃圾回收变懒、峰值成倍涨（实测 700 MB 记录 → 峰值 3.3 GB）
        byte* _buf;
        nuint _cap;
        byte[] _all;

        public static GalRecFile Load(string path)
        {
            GalRecFile f = new() { Path = path };
            f._h = File.OpenHandle(path, FileMode.Open, FileAccess.Read, FileShare.Read);
            f.FileLength = RandomAccess.GetLength(f._h);
            try
            {
                f.ReadHeader();
                f.BuildIndex();
            }
            catch
            {
                f.Dispose();
                throw;
            }

            return f;
        }

        void ReadHeader()
        {
            // 头（魔数、版本、签名哈希、能力表、操作码名表）不定长且不大：先读 64 KB，不够再翻倍，读到整个文件还不够 = 头截断
            for (long want = 1 << 16; ; want *= 2)
            {
                int n = (int)Math.Min(want, FileLength);
                byte[] b = new byte[n];
                RandomAccess.Read(_h, b, 0);
                R rr = new(b);
                try
                {
                    if (n < 12) throw new ArgumentOutOfRangeException();
                    if (rr.U64() != GalRecFormat.Magic) throw new InvalidDataException("不是 S2AGAL01 录像");
                    Version = rr.U32();
                    if (Version != GalRecFormat.Version) throw new GalRecIncompatibleException($"录像版本 {Version}，本读端只认 {GalRecFormat.Version}");
                    SignatureHash = rr.Str();
                    CapsBytes = rr.Bytes();
                    R cr = new(CapsBytes);
                    Capabilities = CapsIO.Read(ref cr);
                    uint cnt = rr.U32();
                    OpNames.Clear();
                    for (int i = 0; i < cnt; i++)
                    {
                        uint op = rr.U32();
                        OpNames[op] = rr.Str();
                    }

                    BodyStart = rr.Pos;
                    return;
                }
                catch (ArgumentOutOfRangeException)
                {
                    if (n >= FileLength) throw new InvalidDataException($"录像头截断：文件只有 {FileLength} 字节，头在第 {rr.Pos} 字节处读不下去");
                }
            }
        }

        void BuildIndex()
        {
            using FileStream fs = new(Path, FileMode.Open, FileAccess.Read, FileShare.Read, 1 << 20); // 单独开一个（用 _h 建的 FileStream 释放时会关掉 _h）
            fs.Position = BodyStart;
            Span<byte> hdr = stackalloc byte[8];
            long pos = BodyStart, idx = 0;
            while (pos < FileLength)
            {
                if (pos + 8 > FileLength)
                {
                    SetTruncated(pos, idx, $"记录 #{idx} 的记录头截断：在文件偏移 {pos}，需要 8 字节，只剩 {FileLength - pos} 字节");
                    return;
                }

                fs.ReadExactly(hdr);
                uint op = BinaryPrimitives.ReadUInt32LittleEndian(hdr);
                uint len = BinaryPrimitives.ReadUInt32LittleEndian(hdr[4..]);
                if (pos + 8 + len > FileLength)
                {
                    SetTruncated(pos, idx, $"记录 #{idx}（{Name(op)}）记录体截断：记录头在文件偏移 {pos}，声明 {len} 字节，只剩 {FileLength - pos - 8} 字节");
                    return;
                }

                if (len > int.MaxValue)
                {
                    SetTruncated(pos, idx, $"记录 #{idx}（{Name(op)}）声明长度 {len} 超过 2 GB，按损坏处理（文件偏移 {pos}）");
                    return;
                }

                Index.Add(new GalRecRecord(op, pos + 8, (int)len, idx));
                fs.Seek(len, SeekOrigin.Current);
                pos += 8 + len;
                idx++;
            }
        }

        void SetTruncated(long pos, long idx, string why)
        {
            TruncatedAtOffset = pos;
            Truncation = why + $"；前 {idx} 条完整，文件共 {FileLength} 字节";
        }

        /// <summary>逐条（只含完整记录）。</summary>
        public IEnumerable<GalRecRecord> Records() => Index;

        /// <summary>取一条记录体。返回的视图指向内部复用缓冲，只在下一次调用 Payload 之前有效（要留着就 ToArray）。</summary>
        public ReadOnlySpan<byte> Payload(in GalRecRecord r)
        {
            if (r.Length == 0) return ReadOnlySpan<byte>.Empty;
            if (_cap < (nuint)r.Length)
            {
                nuint cap = Math.Max((nuint)r.Length, Math.Max(_cap * 2, 1 << 16));
                _buf = (byte*)System.Runtime.InteropServices.NativeMemory.Realloc(_buf, cap);
                _cap = cap;
            }

            Span<byte> d = new(_buf, r.Length);
            int got = 0;
            while (got < d.Length)
            {
                int n = RandomAccess.Read(_h, d[got..], r.Offset + got);
                if (n <= 0) throw new EndOfStreamException($"记录 #{r.Index} 读到文件尾（偏移 {r.Offset + got}）：录像在 Load 之后被截短？");
                got += n;
            }

            return d;
        }

        /// <summary>
        /// 旧接口兼容：整份录像的字节（首次访问时整份读进内存）。超过 2 GB 读不了，抛异常——新代码用 <see cref="Records"/> + <see cref="Payload"/>。
        /// </summary>
        public byte[] Data
        {
            get
            {
                if (_all != null) return _all;
                if (FileLength > Array.MaxLength) throw new InvalidOperationException($"录像 {FileLength} 字节超过单个数组上限：用 Records() + Payload(记录)");
                _all = new byte[FileLength];
                RandomAccess.Read(_h, _all, 0);
                return _all;
            }
        }

        public string Name(uint op) => OpNames.TryGetValue(op, out string s) ? s : $"op 0x{op:X}";

        public void Dispose()
        {
            _h?.Dispose();
            if (_buf != null)
            {
                System.Runtime.InteropServices.NativeMemory.Free(_buf);
                _buf = null;
                _cap = 0;
            }
        }
    }

    /// <summary>录像与回放端不兼容（版本 / GAL 接口签名 / 能力表）：拒放。</summary>
    public sealed class GalRecIncompatibleException : Exception
    {
        public GalRecIncompatibleException(string m) : base(m) { }
    }

    public sealed partial class GalRecReplayer
    {
        /// <summary>
        /// 核兼容：GAL 接口签名哈希必须相同；目标渲染器的能力表必须与录制时逐字段相同（Gpu 层按能力表特化着色器 / 选转换路径，
        /// 能力表不同的录像在别的渲染器上回放没有意义）。不兼容抛 GalRecIncompatibleException。
        /// </summary>
        public void CheckCompatible(GalRecFile f)
        {
            if (f.SignatureHash != GalOps.SignatureHash)
            {
                throw new GalRecIncompatibleException($"GAL 接口签名不同：录像 {f.SignatureHash}，回放端 {GalOps.SignatureHash}");
            }

            Capabilities t = Target.GetCapabilities();
            if (!CapsIO.Bytes(t).AsSpan().SequenceEqual(f.CapsBytes))
            {
                // 例外：录像时能力更弱、目标更强，录像里按弱能力翻好的 SPIR-V 在目标上照样能执行，回放结果不受影响；反过来仍判不兼容。
                //   计算共享内存上限录像时更小（10-21 后端由 32 KB 改报 48 KB，超 Apple 上限的部分由 gal_prog.m 溢出到设备内存）；
                //   分支内屏障 / 顶点阶段写视口号录像时 false、目标 true（10-24 图形接口盘点第 2 批：false 时翻译器删屏障 / 不写视口号，SPIR-V 里本来就没有）
                var d = CapsIO.Diff(f.Capabilities, t);
                var rest = d.FindAll(x => !(x.StartsWith("MaximumComputeSharedMemorySize=", StringComparison.Ordinal)
                                            && f.Capabilities.MaximumComputeSharedMemorySize <= t.MaximumComputeSharedMemorySize)
                                          && Array.IndexOf(s_widerOk, x) < 0);
                if (rest.Count > 0) throw new GalRecIncompatibleException("能力表不同（字段=录像/目标）：" + string.Join(", ", d));
            }
        }

        // 录像 false、目标 true 时放行的能力位（上面 CheckCompatible；字段串同 CapsIO.Diff 的「名=录像/目标」）
        static readonly string[] s_widerOk = { "SupportsShaderBarrierDivergence=False/True", "SupportsViewportIndexVertexTessellation=False/True" };
        public readonly IRenderer Target;
        readonly Dictionary<uint, object> _objs = new();
        readonly Dictionary<ulong, BufferHandle> _bufs = new();
        public long Replayed, Unknown, DigestMismatches, ValueMismatches, Frames, Errors;
        public readonly Dictionary<uint, ulong> CounterResults = new();
        public readonly List<string> ErrorSamples = new();

        public GalRecReplayer(IRenderer target) => Target = target;
        static readonly bool s_lease = Environment.GetEnvironmentVariable("GALPLAY_LEASE") == "1";
        /// <summary>回放 IRenderer.CreateProgram 前改写着色器（galplay --ref 给参照端加循环上限）；空 = 原样。</summary>
        public Func<ShaderSource[], ShaderSource[]> ShaderFilter;
        /// <summary>回放每条记录前后的观察钩子（拿到的是载荷副本，不影响回放读位置）：galplay --ref 用它让参照端吃原始位顶点输入（RefRawVertexHook）；空 = 不挂</summary>
        public IReplayHook Hook;
        public interface IReplayHook { void Before(GalRecReplayer x, uint op, R rr); void After(GalRecReplayer x, uint op, R rr); }

        // ---- 编号映射 ----
        public void Put(uint id, object o) => _objs[id] = o;
        /// <summary>对象在录像里的号（诊断用，线性查找）；不在表里返回 0。</summary>
        public uint IdOf(object o) { foreach (var kv in _objs) if (ReferenceEquals(kv.Value, o)) return kv.Key; return 0; }
        /// <summary>按编号取目标对象；编号非 0 却找不到（录像里引用了没建过的对象）计 MissingRefs。</summary>
        public T Obj<T>(uint id) where T : class
        {
            if (id == 0) return null;
            if (_objs.TryGetValue(id, out object o)) return o as T;
            MissingRefs++;
            return null;
        }

        public long MissingRefs;

        public T[] Objs<T>(ref R rr) where T : class
        {
            uint n = rr.U32();
            T[] a = new T[n];
            for (int i = 0; i < n; i++) a[i] = Obj<T>(rr.U32());
            return a;
        }

        static ulong Raw(BufferHandle h) => Unsafe.As<BufferHandle, ulong>(ref h);
        public void PutBuf(ulong id, BufferHandle h) => _bufs[id] = h;
        public void DropBuf(BufferHandle recId) => _bufs.Remove(Raw(recId));
        public BufferHandle Buf(BufferHandle recId)
        {
            if (Raw(recId) == 0) return BufferHandle.Null;
            if (_bufs.TryGetValue(Raw(recId), out BufferHandle h)) return h;
            MissingRefs++;
            return BufferHandle.Null;
        }
        public BufferRange Map(BufferRange r) => new(Buf(r.Handle), r.Offset, r.Size, r.Write);

        public BufferRange[] Map(BufferRange[] a) { for (int i = 0; i < a.Length; i++) a[i] = Map(a[i]); return a; }
        public BufferAssignment[] Map(BufferAssignment[] a) { for (int i = 0; i < a.Length; i++) a[i] = new BufferAssignment(a[i].Binding, Map(a[i].Range)); return a; }
        public VertexBufferDescriptor[] Map(VertexBufferDescriptor[] a) { for (int i = 0; i < a.Length; i++) a[i] = new VertexBufferDescriptor(Map(a[i].Buffer), a[i].Stride, a[i].Divisor); return a; }

        // 结果回调可能在渲染器自己的线程上来（Vulkan 后端 CounterQueue 的消费线程）：读写都锁 CounterResults
        public EventHandler<ulong> CounterHandler(uint id) => (s, v) => { lock (CounterResults) CounterResults[id] = v; };

        public void CheckDigest(uint op, ref R rr, ReadOnlySpan<byte> got)
        {
            (uint len, ulong hash) = rr.Digest();
            Span<byte> h = stackalloc byte[20];
            System.Security.Cryptography.SHA1.HashData(got, h);
            if (len != got.Length || BinaryPrimitives.ReadUInt64LittleEndian(h) != hash) DigestMismatches++;
        }

        public void CheckValue(uint op, bool same)
        {
            if (!same) ValueMismatches++;
        }

        /// <summary>回放整份录像。</summary>
        public void ReplayAll(GalRecFile f, Action<uint, int> onRecord = null, bool skipCompatCheck = false)
        {
            if (!skipCompatCheck)
            {
                CheckCompatible(f);
            }

            int i = 0;
            foreach (GalRecRecord rec in f.Records())
            {
                uint op = rec.Op;
                onRecord?.Invoke(op, i++);
                try
                {
                    R rr = new(f.Payload(rec));
                    if (!ReplayOne(op, ref rr)) Unknown++;
                    Replayed++;
                }
                catch (Exception ex)
                {
                    Errors++;
                    if (ErrorSamples.Count < 20) ErrorSamples.Add($"#{i - 1} {f.Name(op)}: {ex.GetType().Name}: {ex.Message}");
                }
            }
        }

        public bool ReplayOne(uint op, ref R rr)
        {
            if (Hook == null) return ReplayCore(op, ref rr);
            R peek = rr;
            Hook.Before(this, op, peek);
            bool ok = ReplayCore(op, ref rr);
            Hook.After(this, op, peek);
            return ok;
        }

        bool ReplayCore(uint op, ref R rr)
        {
            if (ReplayInterface(op, ref rr)) return true;
            switch (op)
            {
                case ObjOps.CreateTextureScaled:
                {
                    TextureCreateInfo info = rr.Blit<TextureCreateInfo>(); float scale = rr.F32();
                    ITexture texture = Target.CreateTexture(info, scale); Put(rr.U32(), texture); return true;
                }
                case GalRecFormat.OpFrame: Frames++; return true;
                case GalRecFormat.OpPrologueBegin:
                case GalRecFormat.OpPrologueEnd:
                case GalRecFormat.OpNote:
                case GalRecFormat.OpStop:
                    return true;
                case GalRecFormat.OpCounterResult:
                {
                    uint id = rr.U32(); ulong v = rr.U64();
                    lock (CounterResults) if (CounterResults.TryGetValue(id, out ulong got) && got != v) ValueMismatches++;
                    return true;
                }
            }

            uint oid = rr.U32();
            switch (op)
            {
                case ObjOps.TexCopyTo1: { var d = Obj<ITexture>(rr.U32()); int a = rr.I32(), b = rr.I32(); Obj<ITexture>(oid)?.CopyTo(d, a, b); return true; }
                case ObjOps.TexCopyTo2: { var d = Obj<ITexture>(rr.U32()); int a = rr.I32(), b = rr.I32(), c = rr.I32(), e = rr.I32(); Obj<ITexture>(oid)?.CopyTo(d, a, b, c, e); return true; }
                case ObjOps.TexCopyTo3: { var d = Obj<ITexture>(rr.U32()); var s = rr.Blit<Extents2D>(); var t = rr.Blit<Extents2D>(); bool lf = rr.Bool(); Obj<ITexture>(oid)?.CopyTo(d, s, t, lf); return true; }
                case ObjOps.TexCopyToBuffer: { var r = Map(rr.Blit<BufferRange>()); int a = rr.I32(), b = rr.I32(), c = rr.I32(); Obj<ITexture>(oid)?.CopyTo(r, a, b, c); return true; }
                case ObjOps.TexCreateView: { var info = rr.Blit<TextureCreateInfo>(); int a = rr.I32(), b = rr.I32(); uint id = rr.U32(); Put(id, Obj<ITexture>(oid)?.CreateView(info, a, b)); return true; }
                case ObjOps.TexGetData: { var t = Obj<ITexture>(oid); if (t != null) { using var d = t.GetData(); CheckDigest(op, ref rr, d.Get()); } return true; }
                case ObjOps.TexGetDataLayerLevel: { int a = rr.I32(), b = rr.I32(); var t = Obj<ITexture>(oid); if (t != null) { using var d = t.GetData(a, b); CheckDigest(op, ref rr, d.Get()); } return true; }
                case ObjOps.TexSetData:
                {
                    var d = rr.Bytes(); ITexture t = Obj<ITexture>(oid);
                    // GALPLAY_LEASE=1（帧率能耗线 10-22，方案 B 对拍）：整张写入改走上传租约（租 → 拷进 → S2ASetData），与不设时同一录像比出图
                    if (t != null && s_lease && Target.S2ATryRentUpload(d.Length, out S2AUploadLease lease)) { d.CopyTo(lease.Span); t.S2ASetData(lease); return true; }
                    t?.SetData(MemoryOwner<byte>.RentCopy(d)); return true;
                }
                case ObjOps.TexSetDataLayerLevel: { var d = rr.Bytes(); int a = rr.I32(), b = rr.I32(); Obj<ITexture>(oid)?.SetData(MemoryOwner<byte>.RentCopy(d), a, b); return true; }
                case ObjOps.TexSetDataRegion: { var d = rr.Bytes(); int a = rr.I32(), b = rr.I32(); var reg = rr.Blit<Rectangle<int>>(); Obj<ITexture>(oid)?.SetData(MemoryOwner<byte>.RentCopy(d), a, b, reg); return true; }
                case ObjOps.TexSetStorage: { var r = Map(rr.Blit<BufferRange>()); Obj<ITexture>(oid)?.SetStorage(r); return true; }
                case ObjOps.TexRelease: { Obj<ITexture>(oid)?.Release(); _objs.Remove(oid); return true; }
                case ObjOps.ProgCheckLink: { bool b = rr.Bool(); var s = Obj<IProgram>(oid)?.CheckProgramLink(b); CheckValue(op, s == null || rr.I32() == (int)s); return true; }
                case ObjOps.ProgGetBinary: { var b = Obj<IProgram>(oid)?.GetBinary(); if (b != null) CheckDigest(op, ref rr, b); return true; }
                case ObjOps.ProgDispose: { Obj<IProgram>(oid)?.Dispose(); _objs.Remove(oid); return true; }
                case ObjOps.SamplerDispose: { Obj<ISampler>(oid)?.Dispose(); _objs.Remove(oid); return true; }
                case ObjOps.CounterFlush: { Obj<ICounterEvent>(oid)?.Flush(); return true; }
                case ObjOps.CounterReserve: { var c = Obj<ICounterEvent>(oid); bool b = c?.ReserveForHostAccess() ?? false; CheckValue(op, c == null || rr.Bool() == b); return true; }
                case ObjOps.CounterSetInvalid: { bool b = rr.Bool(); var c = Obj<ICounterEvent>(oid); if (c != null) c.Invalid = b; return true; }
                case ObjOps.CounterDispose: { Obj<ICounterEvent>(oid)?.Dispose(); return true; }
                case ObjOps.ArrSetSamplers: { int i = rr.I32(); Obj<ITextureArray>(oid)?.SetSamplers(i, Objs<ISampler>(ref rr)); return true; }
                case ObjOps.ArrSetTextures: { int i = rr.I32(); Obj<ITextureArray>(oid)?.SetTextures(i, Objs<ITexture>(ref rr)); return true; }
                case ObjOps.ArrSetImages: { int i = rr.I32(); Obj<IImageArray>(oid)?.SetImages(i, Objs<ITexture>(ref rr)); return true; }
                case ObjOps.ArrDispose: { (Obj<object>(oid) as IDisposable)?.Dispose(); _objs.Remove(oid); return true; }
            }

            return false;
        }
    }
}
