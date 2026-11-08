// ITexture / ISampler / ITextureArray / IImageArray（第 3 块）。
using Ryujinx.Common.Memory;
using Ryujinx.Graphics.GAL;
using System;
using System.Runtime.InteropServices;

namespace NxGal
{
    static unsafe partial class N
    {
        [DllImport(Lib)] public static extern uint nxgal_tex_create(NTexInfo* info);
        [DllImport(Lib)] public static extern uint nxgal_tex_view(uint parent, NTexInfo* info, int firstLayer, int firstLevel);
        [DllImport(Lib)] public static extern void nxgal_tex_release(uint tex);
        [DllImport(Lib)] public static extern ulong nxgal_tex_get_data(uint tex, int layer, int level, void* outp, ulong outLen);
        [DllImport(Lib)] public static extern void nxgal_tex_set_data(uint tex, int layer, int level, NRect* region, void* data, ulong len);
        [DllImport(Lib)] public static extern void nxgal_tex_set_data_lease(uint tex, int layer, int level, NRect* region, uint lease, ulong len);
        [DllImport(Lib)] public static extern void nxgal_tex_copy(uint src, uint dst, int firstLayer, int firstLevel);
        [DllImport(Lib)] public static extern void nxgal_tex_copy_slice(uint src, uint dst, int srcLayer, int dstLayer, int srcLevel, int dstLevel);
        [DllImport(Lib)] public static extern void nxgal_tex_copy_region(uint src, uint dst, NRect* srcRect, NRect* dstRect, int linear);
        [DllImport(Lib)] public static extern void nxgal_tex_copy_to_buffer(uint src, NBufRange* dst, int layer, int level, int stride);
        [DllImport(Lib)] public static extern void nxgal_tex_set_storage(uint tex, NBufRange* buf);
        [DllImport(Lib)] public static extern uint nxgal_sampler_create(NSamplerInfo* info);
        [DllImport(Lib)] public static extern void nxgal_sampler_release(uint smp);
        [DllImport(Lib)] public static extern uint nxgal_tarr_create(int size, int isBuffer, int isImage);
        [DllImport(Lib)] public static extern void nxgal_tarr_set_textures(uint arr, int index, uint* tex, int n);
        [DllImport(Lib)] public static extern void nxgal_tarr_set_samplers(uint arr, int index, uint* smp, int n);
        [DllImport(Lib)] public static extern void nxgal_tarr_release(uint arr);
    }

    public sealed unsafe class NxTexture : ITexture
    {
        public readonly uint Id;
        public readonly TextureCreateInfo Info;
        public int Width => Info.Width;
        public int Height => Info.Height;
        NxTexture(uint id, TextureCreateInfo info) { Id = id; Info = info; }

        internal static NxTexture Create(NxRenderer r, TextureCreateInfo info) { NTexInfo n = Conv.TexInfo(info); return new NxTexture(N.nxgal_tex_create(&n), info); }
        public ITexture CreateView(TextureCreateInfo info, int firstLayer, int firstLevel) { NTexInfo n = Conv.TexInfo(info); return new NxTexture(N.nxgal_tex_view(Id, &n, firstLayer, firstLevel), info); }

        public void CopyTo(ITexture destination, int firstLayer, int firstLevel) => N.nxgal_tex_copy(Id, ((NxTexture)destination).Id, firstLayer, firstLevel);
        public void CopyTo(ITexture destination, int srcLayer, int dstLayer, int srcLevel, int dstLevel) => N.nxgal_tex_copy_slice(Id, ((NxTexture)destination).Id, srcLayer, dstLayer, srcLevel, dstLevel);
        public void CopyTo(ITexture destination, Extents2D srcRegion, Extents2D dstRegion, bool linearFilter)
        {
            NRect s = new() { X = srcRegion.X1, Y = srcRegion.Y1, W = srcRegion.X2 - srcRegion.X1, H = srcRegion.Y2 - srcRegion.Y1 };
            NRect d = new() { X = dstRegion.X1, Y = dstRegion.Y1, W = dstRegion.X2 - dstRegion.X1, H = dstRegion.Y2 - dstRegion.Y1 };
            N.nxgal_tex_copy_region(Id, ((NxTexture)destination).Id, &s, &d, linearFilter ? 1 : 0);
        }
        public void CopyTo(BufferRange range, int layer, int level, int stride) { NBufRange r = Conv.Range(range); N.nxgal_tex_copy_to_buffer(Id, &r, layer, level, stride); }

        PinnedSpan<byte> Get(int layer, int level)
        {
            ulong size = N.nxgal_tex_get_data(Id, layer, level, null, 0);
            if (NxGetDataStat.On) NxGetDataStat.Note(true, $"{Info.Width}x{Info.Height}x{Info.Depth} {Info.Format} {Info.Target} lv{level}", (long)size);
            // 返回的 PinnedSpan 只存指针：块必须活到它 Dispose 才回池（10-18 动森帐篷录像对拍 AccessViolation 即托管数组被提前回收）
            PinnedSpan<byte> r = NxPinPool.Rent((int)size, out byte* p);   // 读回缓冲来自原生块池：不分配托管内存（回写路径每帧调，旧版每次新数组 → 测试机2 每帧 14.5 MB）
            N.nxgal_tex_get_data(Id, layer, level, p, size);
            return r;
        }
        public PinnedSpan<byte> GetData() => Get(-1, -1);
        public PinnedSpan<byte> GetData(int layer, int level) => Get(layer, level);

        void Set(MemoryOwner<byte> data, int layer, int level, NRect* region)
        {
            using (data) { Span<byte> s = data.Span; fixed (byte* p = s) N.nxgal_tex_set_data(Id, layer, level, region, p, (ulong)s.Length); }
        }
        public void SetData(MemoryOwner<byte> data) => Set(data, -1, -1, null);
        public void S2ASetData(S2AUploadLease lease) => N.nxgal_tex_set_data_lease(Id, -1, -1, null, lease.Id, (ulong)lease.Size);
        public void SetData(MemoryOwner<byte> data, int layer, int level) => Set(data, layer, level, null);
        public void SetData(MemoryOwner<byte> data, int layer, int level, Rectangle<int> region) { NRect r = new() { X = region.X, Y = region.Y, W = region.Width, H = region.Height }; Set(data, layer, level, &r); }
        public void SetStorage(BufferRange buffer) { NBufRange r = Conv.Range(buffer); N.nxgal_tex_set_storage(Id, &r); }
        public void Release() => N.nxgal_tex_release(Id);
    }

    public sealed unsafe class NxSampler : ISampler
    {
        public readonly uint Id;
        public NxSampler(SamplerCreateInfo i)
        {
            NSamplerInfo n = new()
            {
                MinFilter = (int)i.MinFilter, MagFilter = (int)i.MagFilter, SeamlessCube = i.SeamlessCubemap ? 1 : 0,
                AddrU = (int)i.AddressU, AddrV = (int)i.AddressV, AddrP = (int)i.AddressP, CompareMode = (int)i.CompareMode, CompareOp = (int)i.CompareOp,
                MinLod = i.MinLod, MaxLod = i.MaxLod, LodBias = i.MipLodBias, MaxAniso = i.MaxAnisotropy,
            };
            n.Border[0] = i.BorderColor.Red; n.Border[1] = i.BorderColor.Green; n.Border[2] = i.BorderColor.Blue; n.Border[3] = i.BorderColor.Alpha;
            Id = N.nxgal_sampler_create(&n);
        }
        public void Dispose() => N.nxgal_sampler_release(Id);
    }

    public sealed unsafe class NxTextureArray : ITextureArray, IImageArray
    {
        public readonly uint Id;
        public NxTextureArray(int size, bool isBuffer, bool isImage) => Id = N.nxgal_tarr_create(size, isBuffer ? 1 : 0, isImage ? 1 : 0);
        public void SetTextures(int index, ITexture[] textures)
        {
            uint* t = stackalloc uint[textures.Length];
            for (int i = 0; i < textures.Length; i++) t[i] = textures[i] is NxTexture x ? x.Id : 0;
            N.nxgal_tarr_set_textures(Id, index, t, textures.Length);
        }
        public void SetImages(int index, ITexture[] images) => SetTextures(index, images);
        public void SetSamplers(int index, ISampler[] samplers)
        {
            uint* s = stackalloc uint[samplers.Length];
            for (int i = 0; i < samplers.Length; i++) s[i] = samplers[i] is NxSampler x ? x.Id : 0;
            N.nxgal_tarr_set_samplers(Id, index, s, samplers.Length);
        }
        public void Dispose() => N.nxgal_tarr_release(Id);
    }
}

namespace NxGal
{
    // 诊断（S2A_GETDATA_STAT=1，缺省关）：读回（GetData）按资源计次与字节，每 2 秒打前 6——查谁每帧被回读（10-20 写跟踪 A 方案回读成本）
    static class NxGetDataStat
    {
        // S2A_GETDATA_BT=1（帧率能耗线 10-23，马车8 渲染线程每帧几十次读贴图）：键附调用方托管栈前 5 层（Ryujinx / NxGal 帧），按次数排，查谁在读、为什么读
        public static readonly bool Bt = System.Environment.GetEnvironmentVariable("S2A_GETDATA_BT") == "1";
        public static readonly bool On = Bt || System.Environment.GetEnvironmentVariable("S2A_GETDATA_STAT") == "1";
        static string Caller()
        {
            var st = new System.Diagnostics.StackTrace(2, false); var sb = new System.Text.StringBuilder(); int k = 0;
            for (int i = 0; i < st.FrameCount && k < 5; i++)
            {
                var m = st.GetFrame(i)?.GetMethod(); string t = m?.DeclaringType?.FullName ?? "?";
                if (t.StartsWith("NxGal.NxGetDataStat")) continue;
                sb.Append(k == 0 ? "" : " ← ").Append(m?.DeclaringType?.Name).Append('.').Append(m?.Name); k++;
            }
            return sb.ToString();
        }
        static readonly System.Collections.Generic.Dictionary<string, (long n, long bytes, bool tex)> _m = new();
        static long _last, _n, _bytes;
        public static void Note(bool tex, string key, long bytes)
        {
            if (!On) return;
            if (Bt) key = $"{key}［{(System.Threading.Thread.CurrentThread.Name ?? "?")}］〔{Ryujinx.Graphics.GAL.S2AReadTag.Current ?? "其他"}〕{Caller()}";
            lock (_m)
            {
                _m.TryGetValue(key, out var v); _m[key] = (v.n + 1, v.bytes + bytes, tex); _n++; _bytes += bytes;
                long now = System.Environment.TickCount64; if (now - _last < 2000) return; _last = now;
                var top = new System.Collections.Generic.List<System.Collections.Generic.KeyValuePair<string, (long n, long bytes, bool tex)>>(_m);
                if (Bt) top.Sort((x, y) => y.Value.n.CompareTo(x.Value.n)); else top.Sort((x, y) => y.Value.bytes.CompareTo(x.Value.bytes));
                // 总数在前（前 6 只是按字节排的头部，判据数次数要看总数）
                var sb = new System.Text.StringBuilder($"[gal] 读回累计共 {_n} 次 {_bytes >> 10} KB；前 6：");
                for (int i = 0; i < top.Count && i < (Bt ? 10 : 6); i++) sb.Append($" {(top[i].Value.tex ? "贴图" : "")}{top[i].Key} ×{top[i].Value.n} {top[i].Value.bytes >> 20} MB；");
                System.Console.Error.WriteLine(sb.ToString());
            }
        }
    }
}

namespace NxGal
{
    // 读回用的原生内存块池（贴图 / 缓冲 GetData）：按 2 的幂分级，块用 NativeMemory 分配、永不释放；每块一个缓存好的归还动作，
    // 稳态一次读回零托管分配（PinnedSpan 的 Dispose 调归还动作，块回到本级的栈）。数组栈 + 锁：ConcurrentStack 每次压栈都要分配节点
    static unsafe class NxPinPool
    {
        sealed class Level { public nint[] Free = new nint[16]; public int N; }
        static readonly Level[] _lv = new Level[32];
        static readonly System.Collections.Generic.Dictionary<nint, System.Action> _ret = new();
        static readonly object _mu = new();
        public static PinnedSpan<byte> Rent(int size, out byte* p)
        {
            int k = size <= 4096 ? 12 : 32 - System.Numerics.BitOperations.LeadingZeroCount((uint)(size - 1));
            nint b; System.Action ret;
            lock (_mu)
            {
                Level l = _lv[k] ??= new Level();
                if (l.N > 0) b = l.Free[--l.N];
                else
                {
                    b = (nint)System.Runtime.InteropServices.NativeMemory.Alloc((nuint)1 << k);
                    nint bb = b; int kk = k;
                    _ret[b] = () => { lock (_mu) { Level q = _lv[kk]; if (q.N == q.Free.Length) System.Array.Resize(ref q.Free, q.N * 2); q.Free[q.N++] = bb; } };
                }
                ret = _ret[b];
            }
            p = (byte*)b;
            return new PinnedSpan<byte>((void*)b, size, ret);
        }
    }
}
