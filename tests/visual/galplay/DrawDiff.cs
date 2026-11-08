// 双后端逐绘制对拍（画面·着色器线 10-21，画面根因第 ⑤ 类：数据同步 / 渲染器偏差的总兜底）。
// galplay --ref --diff 时启用：同一录像两边同步回放，在每个「渲染通道」结束（换渲染目标、上屏之前）把刚画完的全部颜色目标 + 深度
// 两边读回逐像素比；--diff-draw a-b 时第 a..b 条记录里每次绘制之后都比（定位通道里第一处分歧的那次绘制）。
// 比法：字节全同 = 同；否则逐通道算差，单位「级」= 存储格式的最小单位（ULP）：unorm8 / sRGB 差几个码值、半精度 / R11G11B10 小浮点差几个 ULP，
//   浮点再与 8 位绝对差取小（暗部按看不看得出判）；fp32 / unorm16 折算到 10 位精度、深度折算到 16 位精度（细则见 PixDiff）；整数格式不等即 255 级。
//   任一通道差 > 容差的像素计「差异像素」；差异像素 > 0 的比对记「分歧」。
// 重同步（缺省开，--diff-nosync 关）：任一比对字节不同，就把参照那份写回我方同一贴图——下一通道从同样的输入起步，
//   每处分歧只算在引入它的那个通道 / 绘制上，不顺着采样一路传下去（差异计数 = 独立缺陷数，不是传染数）。
//   深度只在 D32Float 上写回，且只换超容差的像素（容差内几 ULP 差整张覆盖会让之后深度测 EQUAL 的通道大片过不了）；D24 只比不写回（我方 D24 内部是 float 深度，
//   读回量化成 24 位、写回不是恒等；10-23 怪猎程序 719 假分歧）。D24 两边可比自参照 D24 读回修正（Ryujinx 0166）起。
// 输出：<输出目录>/diff.tsv（每次分歧一行；--diff-all 时每次比对都写一行，带两边哈希——同后端两次回放的自比噪声用）、
//   diff_first_<k>_{ours,ref,mask}.png（前 8 次分歧的两边图与差异掩码），报告里给第一处分歧与「分歧通道 / 总通道、分歧绘制 / 总绘制」。
using Ryujinx.Common.Memory;
using Ryujinx.Graphics.GAL;
using RyuJudge.GalRec;
using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;

sealed class DrawDiff
{
    public double Tol = 1;          // 颜色容差（8 位级）：差 > Tol 的像素算差异
    public double DTol = 1;         // 深度容差（级，深度按 16 位精度折算，见 PixDiff）
    public bool Resync = true, All;
    public long FrameLo = 1, FrameHi = long.MaxValue, DrawLo = 0, DrawHi = -1;
    readonly string _out;
    readonly GalRecReplayer _a, _b;

    uint[] _rts = Array.Empty<uint>(); uint _ds;
    bool _dirty; long _passDraws, _passStart; readonly HashSet<uint> _passProgs = new();
    public long RefDepthSkip;
    public long Passes, DiffPasses, Draws, DiffDraws, Compares, Unreadable, NoResync, PassDrawsInDiff, NoiseCompares;
    public double NoiseMax;
    public string First;
    // 字节不同的比对按最大差分档（级）：≤1、≤2、≤4、≤16、≤64、>64——噪声与缺陷的分界依据
    static readonly double[] HistEdge = { 1, 2, 4, 16, 64, double.MaxValue };
    readonly long[] _hist = new long[6];
    void Hist(double mx) { for (int i = 0; i < HistEdge.Length; i++) if (mx <= HistEdge[i]) { _hist[i]++; return; } }
    readonly StringBuilder _tsv = new("记录\t帧\t类\t通道起\t程序\t槽\t贴图\t格式\t尺寸\t差异像素\t总像素\t最大差\t首个差异像素\t差异框\t我方哈希\t参照哈希\t通道绘制\t反馈环\t丢弃后导数\n");
    int _imgs;
    byte[] _ba = new byte[1 << 20], _bb = new byte[1 << 20], _bm = new byte[1 << 20];

    public DrawDiff(string outDir, GalRecReplayer ours, GalRecReplayer theirs) { _out = outDir; _a = ours; _b = theirs; }

    static bool IsDraw(uint op) => op is 0x009 or 0x00A or 0x00B or 0x00C or 0x00D or 0x00E or 0x00F;
    // 会改写当前目标的非绘制操作：清屏
    static bool IsClear(uint op) => op is 0x004 or 0x005;

    /// <summary>--diff-tex：第 rec 条记录之前把这些贴图的全部层 × 级两边读回逐字节比（上传 / 拷贝 / 压缩格式布局这类数据同步问题：
    /// 采样输入本身两边就不同时，绘制分歧不是着色器的错）。结果追加到 diff_tex.txt。</summary>
    public long TexRec = -1; public uint[] TexIds = Array.Empty<uint>();
    void CompareTextures(long rec)
    {
        var sb = new StringBuilder();
        foreach (uint id in TexIds)
        {
            ITexture ta = _a.Obj<ITexture>(id), tb = _b.Obj<ITexture>(id);
            if (ta is S2Arm.Gfx.Widen.Gal.WidenTexture w) ta = w.Inner;
            if (ta is not NxGal.NxTexture na || tb == null) { sb.Append($"记录 {rec} 贴图 {id}：取不到\n"); continue; }
            TextureCreateInfo inf = na.Info;
            int layers = inf.Target is Target.Texture2DArray or Target.Cubemap or Target.CubemapArray ? inf.GetLayers() : 1;
            for (int l = 0; l < Math.Min(layers, 6); l++)
                for (int lv = 0; lv < inf.Levels; lv++)
                {
                    int la, lb;
                    try { using (var g = na.GetData(l, lv)) la = Copy(g.Get(), ref _ba); using (var g = tb.GetData(l, lv)) lb = Copy(g.Get(), ref _bb); }
                    catch (Exception e) { sb.Append($"记录 {rec} 贴图 {id} 层 {l} 级 {lv}：读不回 {e.GetType().Name}\n"); continue; }
                    int n = Math.Min(la, lb), d = 0, first = -1;
                    for (int i = 0; i < n; i++) if (_ba[i] != _bb[i]) { d++; if (first < 0) first = i; }
                    sb.Append($"记录 {rec} 贴图 {id}（{inf.Format} {inf.Width}×{inf.Height}×{inf.Depth} {inf.Target}）层 {l} 级 {lv}：长度 我方 {la} / 参照 {lb}，不同字节 {d}{(first >= 0 ? $"（首个偏移 {first}）" : "")}\n");
                }
        }
        File.AppendAllText(Path.Combine(_out, "diff_tex.txt"), sb.ToString());
    }

    /// <summary>--diff-buf：第 rec 条记录之前把当前绑着的常量 / 存储缓冲（绑定区间）两边读回逐字节比（10-23 怪猎光照：贴图输入全同、
    /// 绘制照样分歧时，看是不是存储缓冲内容——光源列表等——两边不同）。结果追加到 diff_buf.txt。</summary>
    public long BufRec = -1;
    static ulong BufId(BufferHandle h) => System.Runtime.CompilerServices.Unsafe.As<BufferHandle, ulong>(ref h);
    readonly SortedDictionary<(int kind, int binding), BufferRange> _bufBind = new();
    void CompareBuffers(long rec)
    {
        var sb = new StringBuilder();
        foreach (var ((kind, binding), r) in _bufBind)
        {
            string kn = kind == 0 ? "常量" : "存储";
            if (r.Size <= 0) continue;
            BufferHandle ha = _a.Buf(r.Handle), hb = _b.Buf(r.Handle);
            if (ha == BufferHandle.Null || hb == BufferHandle.Null) { sb.Append($"记录 {rec} {kn} {binding}：取不到\n"); continue; }
            int la, lb;
            try
            {
                using (var g = _a.Target.GetBufferData(ha, r.Offset, r.Size)) la = Copy(g.Get(), ref _ba);
                using (var g = _b.Target.GetBufferData(hb, r.Offset, r.Size)) lb = Copy(g.Get(), ref _bb);
            }
            catch (Exception e) { sb.Append($"记录 {rec} {kn} {binding}：读不回 {e.GetType().Name}\n"); continue; }
            int n = Math.Min(la, lb), d = 0, first = -1;
            for (int i = 0; i < n; i++) if (_ba[i] != _bb[i]) { d++; if (first < 0) first = i; }
            sb.Append($"记录 {rec} {kn} {binding}（缓冲 {BufId(r.Handle)} 偏移 {r.Offset} 长 {r.Size}{(r.Write ? " 可写" : "")}）：长度 我方 {la} / 参照 {lb}，不同字节 {d}{(first >= 0 ? $"（首个偏移 {first}）" : "")}\n");
        }
        File.AppendAllText(Path.Combine(_out, "diff_buf.txt"), sb.ToString());
    }

    /// <summary>两边回放这条记录之前调：换目标 / 上屏之前把这一通道的结果比掉。</summary>
    public void Before(uint op, ReadOnlySpan<byte> pl, long rec, long frame, uint presentTex)
    {
        if (rec == TexRec) CompareTextures(rec);
        if (rec == BufRec) CompareBuffers(rec);
        if (frame < FrameLo || frame > FrameHi) return;
        if ((op == 0x029 || op == 0x201) && _dirty) ComparePass(rec, frame, "通道");
        if (op == 0x201 && presentTex != 0) CompareOne(rec, frame, "上屏", -1, presentTex, 0);
    }

    /// <summary>两边都回放完这条记录之后调。</summary>
    // 绑定状态（分歧现场 diff_state_<k>.txt 用）：采样器建法、各阶段贴图 / 采样器绑定
    readonly Dictionary<uint, SamplerCreateInfo> _smp = new();
    readonly SortedDictionary<(int, int), (uint tex, uint smp)> _bind = new();
    // 反馈环：绘制时绑定的贴图（按视图追到根贴图）就是当前颜色 / 深度附件——采样正在写的附件，两边都是未定义行为（除非中间有 TextureBarrier），
    //   分歧记「反馈环」列，定性时单列（10-20 画幅线：程序 67/76/7/13/15 无 TextureBarrier 采样当前附件，渲染器不拆通道）
    readonly Dictionary<uint, uint> _root = new();
    bool _passFb, _drawFb; long _fbDraws;
    // 「丢弃后隐式导数」：程序的 SPIR-V 里 OpKill 之后还有隐式 LOD 采样——同一 2×2 四元组里被丢弃的像素还算不算导数，Vulkan（OpKill）未定义，
    //   两后端常在 2×2 网格上出点状差（10-21 暗黑3 程序 315 / 3383：参照点状、我方干净）。分歧行「丢弃后导数」列标出，定性时单列
    readonly HashSet<uint> _killDeriv = new();
    bool _passKd, _drawKd;
    static bool KillThenImplicit(ReadOnlySpan<byte> pl)
    {
        for (int at = 0; at + 20 <= pl.Length; at += 4)
        {
            if (BinaryPrimitives.ReadUInt32LittleEndian(pl[at..]) != 0x07230203) continue;
            bool kill = false;
            for (int o = at + 20; o + 4 <= pl.Length;)
            {
                uint w = BinaryPrimitives.ReadUInt32LittleEndian(pl[o..]); int wc = (int)(w >> 16), opc = (int)(w & 0xFFFF);
                if (wc == 0 || o + 4 * wc > pl.Length) break;
                if (opc == 252) kill = true;
                else if (kill && opc is 87 or 89 or 91 or 93 or 305 or 307) return true;
                o += 4 * wc;
            }
        }
        return false;
    }
    uint Root(uint t) { for (int i = 0; i < 16 && _root.TryGetValue(t, out uint p); i++) t = p; return t; }
    bool Feedback()
    {
        if (_bind.Count == 0) return false;
        Span<uint> rr = stackalloc uint[9]; int n = 0;
        foreach (uint t in _rts) if (t != 0 && n < 8) rr[n++] = Root(t);
        if (_ds != 0) rr[n++] = Root(_ds);
        foreach (var v in _bind.Values) { if (v.tex == 0) continue; uint r = Root(v.tex); for (int i = 0; i < n; i++) if (rr[i] == r) return true; }
        return false;
    }

    public void After(uint op, ReadOnlySpan<byte> pl, long rec, long frame, uint prog)
    {
        int ssz = System.Runtime.CompilerServices.Unsafe.SizeOf<SamplerCreateInfo>();
        if (op is 0x02C or 0x031 && pl.Length >= 4)   // SetStorageBuffers / SetUniformBuffers：按绑定号记录像里的缓冲区间（--diff-buf 用）
        {
            var rr = new R(pl.ToArray());
            foreach (BufferAssignment ba in rr.Span<BufferAssignment>()) _bufBind[(op == 0x031 ? 0 : 1, ba.Binding)] = ba.Range;
        }
        if (op == 0x107 && pl.Length >= ssz + 4) _smp[BinaryPrimitives.ReadUInt32LittleEndian(pl[ssz..])] = System.Runtime.InteropServices.MemoryMarshal.Read<SamplerCreateInfo>(pl);
        if (op == 0x106 && pl.Length >= 4 && KillThenImplicit(pl)) _killDeriv.Add(BinaryPrimitives.ReadUInt32LittleEndian(pl[^4..]));
        if (op == 0x304 && pl.Length >= 8) _root[BinaryPrimitives.ReadUInt32LittleEndian(pl[^4..])] = BinaryPrimitives.ReadUInt32LittleEndian(pl);
        if (op == 0x02D && pl.Length >= 16) _bind[(BinaryPrimitives.ReadInt32LittleEndian(pl), BinaryPrimitives.ReadInt32LittleEndian(pl[4..]))] = (BinaryPrimitives.ReadUInt32LittleEndian(pl[8..]), BinaryPrimitives.ReadUInt32LittleEndian(pl[12..]));
        if (op == 0x029 && pl.Length >= 4)
        {
            uint nc = BinaryPrimitives.ReadUInt32LittleEndian(pl);
            if (pl.Length >= 8 + 4 * (int)nc)
            {
                _rts = new uint[nc];
                for (int i = 0; i < nc; i++) _rts[i] = BinaryPrimitives.ReadUInt32LittleEndian(pl[(4 + 4 * i)..]);
                _ds = BinaryPrimitives.ReadUInt32LittleEndian(pl[(4 + 4 * (int)nc)..]);
            }
            _passStart = rec + 1;
            return;
        }
        if (frame < FrameLo || frame > FrameHi) return;
        if (IsClear(op)) _dirty = true;
        if (!IsDraw(op)) return;
        Draws++; _passDraws++; _dirty = true; _passProgs.Add(prog);
        _drawFb = Feedback(); if (_drawFb) { _passFb = true; _fbDraws++; }
        _drawKd = _killDeriv.Contains(prog); _passKd |= _drawKd;
        if (rec >= DrawLo && rec <= DrawHi)
        {
            long before = DiffPasses;
            ComparePass(rec, frame, "绘制", prog);
            if (DiffPasses > before) DiffDraws++;
        }
    }

    void ComparePass(long rec, long frame, string kind, uint prog = 0)
    {
        bool any = false;
        for (int i = 0; i < _rts.Length; i++) if (_rts[i] != 0) any |= CompareOne(rec, frame, kind, i, _rts[i], prog);
        if (_ds != 0) any |= CompareOne(rec, frame, kind, 8, _ds, prog);
        Passes++;
        if (any) { DiffPasses++; if (kind == "通道") PassDrawsInDiff += _passDraws; }
        if (kind == "通道") { _passDraws = 0; _passProgs.Clear(); _dirty = false; _passFb = false; _passKd = false; }
    }

    /// <summary>比一张贴图（数组 / 立方体逐层，至多 8 层）；返回是否分歧（差异像素 > 0）。槽：0..7 颜色、8 深度、-1 上屏图。</summary>
    bool CompareOne(long rec, long frame, string kind, int slot, uint id, uint prog)
    {
        ITexture ta = _a.Obj<ITexture>(id), tb = _b.Obj<ITexture>(id);
        if (ta is S2Arm.Gfx.Widen.Gal.WidenTexture w) ta = w.Inner;
        if (ta is not NxGal.NxTexture na || tb == null) { Unreadable++; return false; }
        int layers = na.Info.Target is Target.Texture2DArray or Target.Cubemap or Target.CubemapArray or Target.Texture2DMultisampleArray ? Math.Min(na.Info.GetLayers(), 8) : 1;
        bool any = false;
        for (int l = 0; l < layers; l++) any |= CompareLayer(rec, frame, kind, slot, id, prog, na, tb, l);
        return any;
    }

    bool CompareLayer(long rec, long frame, string kind, int slot, uint id, uint prog, NxGal.NxTexture na, ITexture tb, int layer)
    {
        TextureCreateInfo inf = na.Info;
        // 参照 D24S8：MoltenVK 没有 D24S8，Ryujinx Vulkan 换成 D32FloatS8Uint、只拷深度面。10-23 起转换改成逐像素紧排（Ryujinx 0166，galplay --selftest-ref-d24
        //   往返单测），读回 = d24 << 8、模板 0：深度比、模板不比（模板取我方），可写回。其余 D24 系布局仍不比
        if (inf.Format is Format.S8UintD24Unorm or Format.X8UintD24Unorm) { RefDepthSkip++; return false; }
        int la, lb;
        try
        {
            using (var g = na.GetData(layer, 0)) la = Copy(g.Get(), ref _ba);
            using (var g = tb.GetData(layer, 0)) lb = Copy(g.Get(), ref _bb);
        }
        catch (Exception) { Unreadable++; return false; }
        Compares++;
        int stride = inf.GetMipStride(0), need = inf.Height * stride;
        // 参照（Ryujinx Vulkan）按层读回时缓冲按整张（全部层）大小给、只有开头一层有效（PersistentFlushBuffer.GetTextureData(…, layer, level) 只拷一片）：截到一层比
        if (lb > la && la == need) lb = la;
        // 参照深度模板只拷深度平面（TextureView.CopyFromOrToBuffer：DepthBit|StencilBit 改成只 DepthBit）：D32FloatS8Uint 读回 = 每像素 4 字节紧排的深度，模板没拷。
        //   换成我方布局（每像素 {float 深度, u32 模板}）：深度取参照、模板取我方（模板不比）——10-21 丝之歌下半张「差」即布局错位
        if (inf.Format == Format.D32FloatS8Uint && la == need && lb >= inf.Width * inf.Height * 4)
        {
            if (_bb.Length < la) Array.Resize(ref _bb, la);
            var tmp = new byte[inf.Width * inf.Height * 4]; Array.Copy(_bb, tmp, tmp.Length);
            for (int y = 0; y < inf.Height; y++)
                for (int x = 0; x < inf.Width; x++)
                {
                    int o = y * stride + x * 8;
                    Array.Copy(tmp, (y * inf.Width + x) * 4, _bb, o, 4);
                    Array.Copy(_ba, o + 4, _bb, o + 4, 4);
                }
            lb = la;
        }
        if (inf.Format == Format.D24UnormS8Uint && la == need && lb >= need)
        {
            for (int y = 0; y < inf.Height; y++) for (int x = 0; x < inf.Width; x++) { int o = y * stride + x * 4; _bb[o] = _ba[o]; }
            lb = la;
        }
        ReadOnlySpan<byte> a = _ba.AsSpan(0, la), b = _bb.AsSpan(0, lb);
        bool same = la == lb && a.SequenceEqual(b);
        string progs = kind == "通道" ? string.Join(",", _passProgs.Take(6)) + (_passProgs.Count > 6 ? $",…共{_passProgs.Count}" : "") : prog.ToString();
        string sl = (slot == 8 ? "D" : slot < 0 ? "P" : slot.ToString()) + (layer > 0 ? $"/层{layer}" : "");
        if (same)
        {
            if (All) Row(rec, frame, kind, progs, sl, id, inf, 0, inf.Width * inf.Height, 0, "", "", Hash(a), Hash(b));
            return false;
        }
        bool depth = IsDs(inf.Format);
        double tol = depth ? DTol : Tol;
        long n = 0; double mx = 0; int fx = -1, fy = -1, x0 = int.MaxValue, y0 = int.MaxValue, x1 = -1, y1 = -1;
        byte[] mask = null;
        bool lenBad = la != lb || la < need;
        if (lenBad) { n = inf.Width * inf.Height; mx = 255; }
        else
        {
            if (_imgs < 8) mask = new byte[inf.Width * inf.Height];
            // 深度重同步只换超容差的像素（10-23 着色器线：整张写回参照深度时，容差内的几 ULP 差让之后深度测 EQUAL 的着色通道大片过不了——
            //   怪猎程序 719「光照分歧」就是这样造出来的假象，--diff-nosync 下只差 5 像素）：拿我方这份做底，只把真分歧像素换成参照的
            if (depth && Resync) { if (_bm.Length < la) Array.Resize(ref _bm, la); a.CopyTo(_bm); }
            Span<double> ca = stackalloc double[4], cb = stackalloc double[4];
            int bpp = Bpp(inf.Format);
            for (int y = 0; y < inf.Height; y++)
            {
                int ro = y * stride;
                if (a.Slice(ro, inf.Width * bpp).SequenceEqual(b.Slice(ro, inf.Width * bpp))) continue;
                for (int x = 0; x < inf.Width; x++)
                {
                    int o = ro + x * bpp;
                    if (a.Slice(o, bpp).SequenceEqual(b.Slice(o, bpp))) continue;
                    double d = PixDiff(inf.Format, a.Slice(o, bpp), b.Slice(o, bpp), ca, cb);
                    if (d > mx) mx = d;
                    if (d <= tol) continue;
                    n++;
                    if (depth && Resync) b.Slice(o, bpp).CopyTo(_bm.AsSpan(o));
                    if (fx < 0) { fx = x; fy = y; }
                    x0 = Math.Min(x0, x); y0 = Math.Min(y0, y); x1 = Math.Max(x1, x); y1 = Math.Max(y1, y);
                    if (mask != null) mask[y * inf.Width + x] = 1;
                }
            }
        }
        // 重同步：参照那份写回我方（字节布局相同才写）
        if (Resync && !lenBad && !depth)
            na.SetData(MemoryOwner<byte>.RentCopy(b), layer, 0);
        // D24 只比不写回：我方 D24 内部是 float 深度，读回量化成 24 位、写回不是恒等，连写回我方自己那份都会让之后深度 EQUAL 的通道过不了（10-23 怪猎 719）。
        //   D32Float 往返无损，只换真分歧像素写回
        else if (Resync && !lenBad && inf.Format == Format.D32Float) { if (n > 0) na.SetData(MemoryOwner<byte>.RentCopy(_bm.AsSpan(0, la)), layer, 0); }
        else if (Resync && !lenBad && depth && n > 0) NoResync++;
        else if (Resync) NoResync++;
        if (n == 0) { NoiseCompares++; NoiseMax = Math.Max(NoiseMax, mx); }
        Hist(mx);
        if (n == 0 && !All) return false;
        string lens = lenBad ? $"读回长度 我方 {la} / 参照 {lb}（应 ≥ {need}；{inf.Target} 采样 {inf.Samples} 层 {inf.Depth} 级 {inf.Levels}）" : null;
        Row(rec, frame, kind, progs, sl, id, inf, n, inf.Width * inf.Height, mx, lens ?? (fx < 0 ? "" : $"{fx},{fy}"), fx < 0 ? "" : $"{x0},{y0}-{x1},{y1}", Hash(a), Hash(b));
        if (n == 0) return false;
        string where = (slot == 8 ? "深度" : slot < 0 ? "上屏图" : $"颜色 {slot}") + (layer > 0 ? $" 第 {layer} 层" : "");
        First ??= $"第一处分歧：记录 {rec}（帧 {frame}，{kind}{(kind == "通道" ? $"起于记录 {_passStart}、本通道绘制 {_passDraws} 次" : "")}{((kind == "通道" ? _passFb : _drawFb) ? "，有反馈环（采样当前附件）" : "")}{((kind == "通道" ? _passKd : _drawKd) ? "，有丢弃后隐式导数的程序" : "")}），程序 {progs}，{where} 贴图 {id}（{inf.Format} {inf.Width}×{inf.Height}），差异像素 {n}/{inf.Width * inf.Height}，最大差 {mx:F1} 级，" + (lens ?? $"首个差异像素 ({fx},{fy})，差异框 [{x0},{y0}]-[{x1},{y1}]");
        if (mask != null && _imgs < 8)
        {
            Preview(Path.Combine(_out, $"diff_first_{_imgs}_ours.png"), inf, a, stride);
            Preview(Path.Combine(_out, $"diff_first_{_imgs}_ref.png"), inf, b, stride);
            var m = new byte[inf.Width * inf.Height * 4];
            for (int i = 0; i < mask.Length; i++) { m[i * 4] = mask[i] != 0 ? (byte)255 : (byte)0; m[i * 4 + 3] = 255; }
            Png.Write(Path.Combine(_out, $"diff_first_{_imgs}_mask.png"), m, inf.Width, inf.Height, inf.Width * 4, Format.R8G8B8A8Unorm);
            File.WriteAllText(Path.Combine(_out, $"diff_state_{_imgs}.txt"), State());
            File.AppendAllText(Path.Combine(_out, "diff_first.txt"), $"{_imgs}\t记录 {rec}\t帧 {frame}\t{kind}\t程序 {progs}\t{where}\t贴图 {id}\t{inf.Format} {inf.Width}x{inf.Height}\t差异像素 {n}\t最大差 {mx:F1}\n");
            _imgs++;
        }
        return true;
    }

    /// <summary>分歧现场：当前各阶段贴图 / 采样器绑定（贴图按我方建法、采样器按录像里的建法）。只在逐次绘制比时准确对应这一次绘制；通道比时是通道末尾的绑定。</summary>
    string State()
    {
        var sb = new StringBuilder("阶段\t绑定\t贴图\t格式\t尺寸\t目标\t级数\t分量重排\t采样器\t缩小\t放大\t寻址 U/V/W\t比较\t边框色\tLOD 下 / 上 / 偏移\t各向异性\n");
        foreach (var kv in _bind)
        {
            (uint t, uint sm) = kv.Value;
            ITexture tx = _a.Obj<ITexture>(t); if (tx is S2Arm.Gfx.Widen.Gal.WidenTexture w) tx = w.Inner;
            sb.Append((Ryujinx.Graphics.Shader.ShaderStage)kv.Key.Item1).Append('\t').Append(kv.Key.Item2).Append('\t').Append(t).Append('\t');
            if (tx is NxGal.NxTexture nt) { var i = nt.Info; sb.Append(i.Format).Append('\t').Append(i.Width).Append('x').Append(i.Height).Append('x').Append(i.Depth).Append('\t').Append(i.Target).Append('\t').Append(i.Levels).Append('\t').Append($"{i.SwizzleR}{i.SwizzleG}{i.SwizzleB}{i.SwizzleA}"); }
            else sb.Append("?\t?\t?\t?\t?");
            sb.Append('\t').Append(sm);
            if (_smp.TryGetValue(sm, out SamplerCreateInfo c))
                sb.Append('\t').Append(c.MinFilter).Append('\t').Append(c.MagFilter).Append('\t').Append($"{c.AddressU}/{c.AddressV}/{c.AddressP}").Append('\t').Append(c.CompareMode == CompareMode.None ? "无" : c.CompareOp.ToString())
                  .Append('\t').Append($"{c.BorderColor.Red},{c.BorderColor.Green},{c.BorderColor.Blue},{c.BorderColor.Alpha}").Append('\t').Append($"{c.MinLod}/{c.MaxLod}/{c.MipLodBias}").Append('\t').Append(c.MaxAnisotropy);
            sb.Append('\n');
        }
        return sb.ToString();
    }

    void Row(long rec, long frame, string kind, string progs, string slot, uint id, TextureCreateInfo inf, long n, long tot, double mx, string first, string box, string ha, string hb)
        => _tsv.Append(rec).Append('\t').Append(frame).Append('\t').Append(kind).Append('\t').Append(kind == "通道" ? _passStart : rec).Append('\t').Append(progs).Append('\t')
            .Append(slot).Append('\t').Append(id).Append('\t').Append(inf.Format).Append('\t').Append(inf.Width).Append('x').Append(inf.Height).Append('\t')
            .Append(n).Append('\t').Append(tot).Append('\t').Append(mx.ToString("F2")).Append('\t').Append(first).Append('\t').Append(box).Append('\t').Append(ha).Append('\t').Append(hb).Append('\t').Append(kind == "通道" ? _passDraws : 1).Append('\t').Append((kind == "通道" ? _passFb : _drawFb) ? "是" : "").Append('\t').Append((kind == "通道" ? _passKd : _drawKd) ? "是" : "").Append('\n');

    public string Report()
    {
        File.WriteAllText(Path.Combine(_out, "diff.tsv"), _tsv.ToString());
        return $"逐绘制对拍（容差 颜色 {Tol} 级 / 深度 {DTol} 级，级 = 存储格式 ULP，重同步{(Resync ? "开" : "关")}{(DrawHi >= DrawLo ? $"，第 {DrawLo}..{DrawHi} 条记录逐次绘制比" : "")}）：比对 {Compares} 次（字节不同但在容差内 {NoiseCompares} 次、其最大差 {NoiseMax:F2} 级）、读不回 {Unreadable}、不能写回 {NoResync}、D24 深度不比（参照读回不准）{RefDepthSkip}；" +
               $"分歧 {DiffPasses}/{Passes}（通道或绘制），分歧通道内绘制 {PassDrawsInDiff}、逐次比的分歧绘制 {DiffDraws}，总绘制 {Draws}（其中绑着当前附件的反馈环绘制 {_fbDraws}）\n" +
               $"字节不同的比对按最大差分档：≤1 级 {_hist[0]}、≤2 {_hist[1]}、≤4 {_hist[2]}、≤16 {_hist[3]}、≤64 {_hist[4]}、>64 {_hist[5]}\n" + (First ?? "无分歧") + "\n";
    }

    static int Copy(ReadOnlySpan<byte> s, ref byte[] buf)
    {
        if (buf.Length < s.Length) buf = new byte[Math.Max(s.Length, buf.Length * 2)];
        s.CopyTo(buf);
        return s.Length;
    }

    static string Hash(ReadOnlySpan<byte> d)
    {
        Span<byte> h = stackalloc byte[32];
        System.Security.Cryptography.SHA256.HashData(d, h);
        return Convert.ToHexString(h[..8]).ToLowerInvariant();
    }

    static bool IsDs(Format f) => f is Format.D16Unorm or Format.D24UnormS8Uint or Format.S8UintD24Unorm or Format.X8UintD24Unorm or Format.D32Float or Format.D32FloatS8Uint or Format.S8Uint;

    public static int Bpp(Format f) => f switch
    {
        Format.R8Unorm or Format.R8Snorm or Format.R8Uint or Format.R8Sint or Format.S8Uint => 1,
        Format.R8G8Unorm or Format.R8G8Snorm or Format.R8G8Uint or Format.R8G8Sint or Format.R16Float or Format.R16Unorm or Format.R16Snorm or Format.R16Uint or Format.R16Sint or Format.D16Unorm
            or Format.B5G6R5Unorm or Format.B5G5R5A1Unorm or Format.R5G6B5Unorm or Format.R5G5B5A1Unorm or Format.A1B5G5R5Unorm or Format.R4G4B4A4Unorm => 2,
        Format.R16G16B16A16Float or Format.R16G16B16A16Unorm or Format.R16G16B16A16Snorm or Format.R16G16B16A16Uint or Format.R16G16B16A16Sint or Format.R32G32Float or Format.R32G32Uint or Format.R32G32Sint
            or Format.D32FloatS8Uint => 8,
        Format.R32G32B32A32Float or Format.R32G32B32A32Uint or Format.R32G32B32A32Sint => 16,
        Format.R32G32B32Float or Format.R32G32B32Uint or Format.R32G32B32Sint => 12,
        _ => 4,
    };

    /// <summary>一个像素两边逐通道差的最大值，单位「级」= 存储格式的最小单位（ULP）：unorm8 / sRGB / snorm8 差几个码值，unorm10 同理；
    /// 半精度 / R11G11B10 小浮点按编码整数距离（同号时单调 = ULP 距离）与 8 位绝对差取小（见 Vis）；fp32 与 unorm16 折算到 10 位尾数 / 10 位精度（fp32 ULP 距离 ÷ 2^13、unorm16 ÷ 64），
    /// 深度 D32F 折算到 16 位尾数（÷ 2^7）、D24 折算到 16 位（÷ 256）、D16 直接码值；整数格式与模板不等即 255 级；一边 NaN / Inf 另一边不是 = 255 级。</summary>
    static double PixDiff(Format f, ReadOnlySpan<byte> a, ReadOnlySpan<byte> b, Span<double> ca, Span<double> cb)
    {
        double m = 0;
        switch (f)
        {
            case Format.R8G8B8A8Unorm or Format.R8G8B8A8Srgb or Format.B8G8R8A8Unorm or Format.B8G8R8A8Srgb or Format.R8Unorm or Format.R8G8Unorm:
                for (int i = 0; i < a.Length; i++) m = Math.Max(m, Math.Abs(a[i] - b[i])); return m;
            case Format.R8Snorm or Format.R8G8Snorm or Format.R8G8B8A8Snorm:
                for (int i = 0; i < a.Length; i++) m = Math.Max(m, Math.Abs(Math.Max(-127, (int)(sbyte)a[i]) - Math.Max(-127, (int)(sbyte)b[i]))); return m;
            case Format.R10G10B10A2Unorm:
            {
                uint x = BinaryPrimitives.ReadUInt32LittleEndian(a), y = BinaryPrimitives.ReadUInt32LittleEndian(b);
                for (int sh = 0; sh < 30; sh += 10) m = Math.Max(m, Math.Abs((int)(x >> sh & 1023) - (int)(y >> sh & 1023)));
                return Math.Max(m, Math.Abs((int)(x >> 30) - (int)(y >> 30)));
            }
            case Format.R16Unorm or Format.R16G16Unorm or Format.R16G16B16A16Unorm:
                for (int i = 0; i < a.Length; i += 2) m = Math.Max(m, Math.Abs(BinaryPrimitives.ReadUInt16LittleEndian(a[i..]) - BinaryPrimitives.ReadUInt16LittleEndian(b[i..])) / 64.0); return m;
            case Format.R16Float or Format.R16G16Float or Format.R16G16B16A16Float:
                for (int i = 0; i < a.Length; i += 2)
                {
                    ushort x = BinaryPrimitives.ReadUInt16LittleEndian(a[i..]), y = BinaryPrimitives.ReadUInt16LittleEndian(b[i..]);
                    m = Math.Max(m, Vis(FUlp(x, y, 15, 10), (double)BitConverter.UInt16BitsToHalf(x), (double)BitConverter.UInt16BitsToHalf(y)));
                }
                return m;
            case Format.R32Float or Format.R32G32Float or Format.R32G32B32Float or Format.R32G32B32A32Float:
                for (int i = 0; i < a.Length; i += 4)
                {
                    uint x = BinaryPrimitives.ReadUInt32LittleEndian(a[i..]), y = BinaryPrimitives.ReadUInt32LittleEndian(b[i..]);
                    m = Math.Max(m, Vis(FUlp(x, y, 31, 23) / 8192.0, BitConverter.UInt32BitsToSingle(x), BitConverter.UInt32BitsToSingle(y)));
                }
                return m;
            case Format.R11G11B10Float:
            {
                uint x = BinaryPrimitives.ReadUInt32LittleEndian(a), y = BinaryPrimitives.ReadUInt32LittleEndian(b);
                m = Math.Max(Vis(UUlp(x & 0x7FF, y & 0x7FF, 6), Uf(x & 0x7FF, 6), Uf(y & 0x7FF, 6)), Vis(UUlp(x >> 11 & 0x7FF, y >> 11 & 0x7FF, 6), Uf(x >> 11 & 0x7FF, 6), Uf(y >> 11 & 0x7FF, 6)));
                return Math.Max(m, Vis(UUlp(x >> 22, y >> 22, 5), Uf(x >> 22, 5), Uf(y >> 22, 5)));
            }
            case Format.D32Float: return FUlp(BinaryPrimitives.ReadUInt32LittleEndian(a), BinaryPrimitives.ReadUInt32LittleEndian(b), 31, 23) / 128.0;
            case Format.D32FloatS8Uint: return a[4] != b[4] ? 255 : FUlp(BinaryPrimitives.ReadUInt32LittleEndian(a), BinaryPrimitives.ReadUInt32LittleEndian(b), 31, 23) / 128.0;
            case Format.D16Unorm: return Math.Abs(BinaryPrimitives.ReadUInt16LittleEndian(a) - BinaryPrimitives.ReadUInt16LittleEndian(b));
            case Format.D24UnormS8Uint:
            {
                uint x = BinaryPrimitives.ReadUInt32LittleEndian(a), y = BinaryPrimitives.ReadUInt32LittleEndian(b);
                return (x & 0xFF) != (y & 0xFF) ? 255 : Math.Abs((long)(x >> 8) - (y >> 8)) / 256.0;
            }
            case Format.S8UintD24Unorm or Format.X8UintD24Unorm:
            {
                uint x = BinaryPrimitives.ReadUInt32LittleEndian(a), y = BinaryPrimitives.ReadUInt32LittleEndian(b);
                return f == Format.S8UintD24Unorm && (x >> 24) != (y >> 24) ? 255 : Math.Abs((long)(x & 0xFFFFFF) - (y & 0xFFFFFF)) / 256.0;
            }
            default: return a.SequenceEqual(b) ? 0 : 255;
        }
    }

    /// <summary>浮点颜色的「看得见的差」：ULP 距离与 8 位绝对差（|a−b| × 255）取小——大值处按存储精度（相对差）判，接近 0 的暗部按 8 位能不能看出来判
    /// （只用 ULP 时 1e-4 对 2e-4 也是几十个 ULP，10-21 动森岛 R11G11B10 场景目标实测：同一处分歧按 ULP 72 级、按看得见的差 8 级）。NaN / Inf 不夹。</summary>
    static double Vis(double ulp, double x, double y) => ulp >= 1e9 ? ulp : Math.Min(ulp, Math.Abs(x - y) * 255);

    /// <summary>有符号 IEEE 浮点（总位 sb+1、尾数 mb 位）编码距离：映射成单调整数后相减 = ULP 距离；NaN 对 NaN 算 0，一边 NaN / Inf 算 255 级以上。</summary>
    static double FUlp(uint x, uint y, int sb, int mb)
    {
        uint em = (1u << sb) - 1, ex = em & ~((1u << mb) - 1);
        bool nx = (x & em) > ex, ny = (y & em) > ex;
        if (nx || ny) return nx && ny ? 0 : 1e9;
        bool ix = (x & em) == ex, iy = (y & em) == ex;
        if (ix || iy) return x == y ? 0 : 1e9;
        long ox = (x >> sb) != 0 ? -(long)(x & em) : (long)(x & em), oy = (y >> sb) != 0 ? -(long)(y & em) : (long)(y & em);
        return Math.Abs(ox - oy);
    }

    /// <summary>无符号小浮点（5 位指数 + mb 位尾数）编码距离。</summary>
    static double UUlp(uint x, uint y, int mb)
    {
        uint ex = 31u << mb;
        bool nx = x > ex, ny = y > ex;
        if (nx || ny) return nx && ny ? 0 : 1e9;
        return Math.Abs((long)x - y);
    }

    enum Kind { Norm, Float, Depth, Int }

    static int Decode(Format f, ReadOnlySpan<byte> p, Span<double> c, out Kind k)
    {
        k = Kind.Norm;
        switch (f)
        {
            case Format.R8G8B8A8Unorm or Format.R8G8B8A8Srgb or Format.B8G8R8A8Unorm or Format.B8G8R8A8Srgb:
                for (int i = 0; i < 4; i++) c[i] = p[i] / 255.0; return 4;
            case Format.R8Unorm: c[0] = p[0] / 255.0; return 1;
            case Format.R8G8Unorm: c[0] = p[0] / 255.0; c[1] = p[1] / 255.0; return 2;
            case Format.R8Snorm or Format.R8G8Snorm or Format.R8G8B8A8Snorm:
            {
                int n = f == Format.R8Snorm ? 1 : f == Format.R8G8Snorm ? 2 : 4;
                for (int i = 0; i < n; i++) c[i] = Math.Max(-1, (sbyte)p[i] / 127.0) / 2; return n;
            }
            case Format.R10G10B10A2Unorm:
            {
                uint v = BinaryPrimitives.ReadUInt32LittleEndian(p);
                c[0] = (v & 1023) / 1023.0; c[1] = (v >> 10 & 1023) / 1023.0; c[2] = (v >> 20 & 1023) / 1023.0; c[3] = (v >> 30) / 3.0; return 4;
            }
            case Format.R16Unorm or Format.R16G16Unorm or Format.R16G16B16A16Unorm:
            {
                int n = f == Format.R16Unorm ? 1 : f == Format.R16G16Unorm ? 2 : 4;
                for (int i = 0; i < n; i++) c[i] = BinaryPrimitives.ReadUInt16LittleEndian(p[(2 * i)..]) / 65535.0; return n;
            }
            case Format.R16Float or Format.R16G16Float or Format.R16G16B16A16Float:
            {
                k = Kind.Float; int n = f == Format.R16Float ? 1 : f == Format.R16G16Float ? 2 : 4;
                for (int i = 0; i < n; i++) c[i] = (double)BitConverter.UInt16BitsToHalf(BinaryPrimitives.ReadUInt16LittleEndian(p[(2 * i)..])); return n;
            }
            case Format.R32Float or Format.R32G32Float or Format.R32G32B32Float or Format.R32G32B32A32Float:
            {
                k = Kind.Float; int n = p.Length / 4;
                for (int i = 0; i < n; i++) c[i] = BinaryPrimitives.ReadSingleLittleEndian(p[(4 * i)..]); return n;
            }
            case Format.R11G11B10Float:
            {
                k = Kind.Float; uint v = BinaryPrimitives.ReadUInt32LittleEndian(p);
                c[0] = Uf(v & 0x7FF, 6); c[1] = Uf(v >> 11 & 0x7FF, 6); c[2] = Uf(v >> 22 & 0x3FF, 5); return 3;
            }
            case Format.D32Float: k = Kind.Depth; c[0] = BinaryPrimitives.ReadSingleLittleEndian(p); return 1;
            case Format.D16Unorm: k = Kind.Depth; c[0] = BinaryPrimitives.ReadUInt16LittleEndian(p) / 65535.0; return 1;
            case Format.D24UnormS8Uint: k = Kind.Depth; { uint v = BinaryPrimitives.ReadUInt32LittleEndian(p); c[0] = (v >> 8) / 16777215.0; c[1] = (v & 0xFF) / 65535.0 * 256; } return 2;
            case Format.S8UintD24Unorm or Format.X8UintD24Unorm: k = Kind.Depth; { uint v = BinaryPrimitives.ReadUInt32LittleEndian(p); c[0] = (v & 0xFFFFFF) / 16777215.0; c[1] = (v >> 24) / 65535.0 * 256; } return 2;
            case Format.D32FloatS8Uint: k = Kind.Depth; c[0] = BinaryPrimitives.ReadSingleLittleEndian(p); c[1] = p[4] / 65535.0 * 256; return 2;
            default:
            {
                // 整数格式与其余：按字节不等即差
                k = Kind.Int; int n = Math.Min(p.Length, 4);
                for (int i = 0; i < n; i++) c[i] = p[i]; return n;
            }
        }
    }

    /// <summary>无符号小浮点（R11G11B10：5 位指数 + 6/5 位尾数）。</summary>
    static double Uf(uint v, int mb)
    {
        uint e = v >> mb, m = v & ((1u << mb) - 1);
        if (e == 31) return m == 0 ? double.PositiveInfinity : double.NaN;
        return e == 0 ? m / (double)(1 << mb) * Math.Pow(2, -14) : (1 + m / (double)(1 << mb)) * Math.Pow(2, (int)e - 15);
    }

    /// <summary>任意可解码格式出 RGBA8 预览图（浮点夹到 [0,1]；深度按 [min,max] 拉开）。</summary>
    static void Preview(string path, TextureCreateInfo inf, ReadOnlySpan<byte> d, int stride)
    {
        int bpp = Bpp(inf.Format), w = inf.Width, h = inf.Height;
        var o = new byte[w * h * 4]; Span<double> c = stackalloc double[4];
        double lo = double.MaxValue, hi = double.MinValue;
        bool depth = IsDs(inf.Format);
        if (depth)
            for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) { Decode(inf.Format, d.Slice(y * stride + x * bpp, bpp), c, out _); lo = Math.Min(lo, c[0]); hi = Math.Max(hi, c[0]); }
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++)
            {
                int n = Decode(inf.Format, d.Slice(y * stride + x * bpp, bpp), c, out Kind k);
                int q = (y * w + x) * 4;
                if (depth) { byte g = (byte)(hi > lo ? (c[0] - lo) / (hi - lo) * 255 : 0); o[q] = o[q + 1] = o[q + 2] = g; }
                else for (int i = 0; i < 3; i++) o[q + i] = (byte)Math.Clamp((i < n ? c[i] : n == 1 ? c[0] : 0) * 255, 0, 255);
                if (inf.Format is Format.B8G8R8A8Unorm or Format.B8G8R8A8Srgb) (o[q], o[q + 2]) = (o[q + 2], o[q]);
                o[q + 3] = 255;
            }
        Png.Write(path, o, w, h, w * 4, Format.R8G8B8A8Unorm);
    }
}
