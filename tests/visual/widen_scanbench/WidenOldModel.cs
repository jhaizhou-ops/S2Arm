// 影子对照（测试用，10-21「只扫变了的」）：按旧做法「每次上传整段扫描、当场改写」算每个缓冲在 GPU 上应有的内容（旧镜像），
// 新做法实际发给 GPU 的上传记成新镜像（拷贝两边都跟着拷）；每次绘制把读到的每个 vec4（常量按读法的下标，动态下标按整段）新旧逐字节比。
// 不一致按 (缓冲, 偏移, 这段内容的版本) 去重计数：漏改 = 旧改了新没改（再按旧改写种类分出矩阵）；多改 = 新改了旧没改；值不同 = 都改了但不同。期望矩阵漏改 0。
#if WIDEN_LAZY
using S2Arm.Gfx.Widen;
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public sealed class WidenOldModel : IWidenCheck
{
    sealed class B
    {
        public byte[] Old = Array.Empty<byte>(), Raw = Array.Empty<byte>(), Known = Array.Empty<byte>(), Kind = Array.Empty<byte>(), New = Array.Empty<byte>(); public long Ver;
        public void Grow(int n)
        {
            if (n <= Old.Length) return;
            int c = Math.Max(n, Old.Length * 2);
            Array.Resize(ref Old, c); Array.Resize(ref Raw, c); Array.Resize(ref Known, c); Array.Resize(ref Kind, c); Array.Resize(ref New, c);
        }
    }
    readonly Dictionary<ulong, B> _b = new();
    readonly WidenRewriter _rw;
    byte[] _dst = new byte[1 << 16];
    readonly HashSet<(ulong, int, long)> _seen = new();
    /// <summary>比过的 vec4 读（不去重，射程）；不一致（去重）分类。</summary>
    public long Vec4s, Miss, Extra, Diff, MissMatrix;   // MissMatrix：漏改里旧改写种类是矩阵（投影 / 视图投影 / 逆投影）的
    public readonly List<string> Samples = new();

    public WidenOldModel(float aspect) { _rw = new WidenRewriter(aspect); }
    public WidenStats OldStats => _rw.Stats;

    B Get(ulong k) { if (!_b.TryGetValue(k, out B b)) _b[k] = b = new B(); return b; }

    public void Upload(ulong buffer, int offset, ReadOnlySpan<byte> data)
    {
        B b = Get(buffer); b.Grow(offset + data.Length);
        data.CopyTo(b.Raw.AsSpan(offset));
        if (_dst.Length < data.Length) _dst = new byte[data.Length * 2];
        _sink.H.Clear();
        (_rw.Rewrite(data, offset, _dst, _sink) ? (ReadOnlySpan<byte>)_dst.AsSpan(0, data.Length) : data).CopyTo(b.Old.AsSpan(offset));
        b.Kind.AsSpan(offset, data.Length).Clear();
        foreach (var (o, l, k) in _sink.H) b.Kind.AsSpan(o, l).Fill((byte)(k + 1));
        b.Known.AsSpan(offset, data.Length).Fill(1); b.Ver++;
    }
    public void Forward(ulong buffer, int offset, ReadOnlySpan<byte> sent) { B b = Get(buffer); b.Grow(offset + sent.Length); sent.CopyTo(b.New.AsSpan(offset)); }
    public void Copy(ulong src, ulong dst, int srcOffset, int dstOffset, int size)
    {
        B d = Get(dst); d.Grow(dstOffset + size); d.Ver++;
        if (!_b.TryGetValue(src, out B s)) { d.Known.AsSpan(dstOffset, size).Clear(); return; }
        int n = Math.Clamp(s.Old.Length - srcOffset, 0, size);
        Array.Copy(s.Old, srcOffset, d.Old, dstOffset, n); Array.Copy(s.Raw, srcOffset, d.Raw, dstOffset, n); Array.Copy(s.Known, srcOffset, d.Known, dstOffset, n); Array.Copy(s.Kind, srcOffset, d.Kind, dstOffset, n); Array.Copy(s.New, srcOffset, d.New, dstOffset, n);
        d.Known.AsSpan(dstOffset + n, size - n).Clear();
    }
    public void Clear(ulong buffer, int offset, int size, uint value)
    {
        B b = Get(buffer); b.Grow(offset + size); b.Ver++;
        for (int i = 0; i < size; i++) b.Old[offset + i] = b.Raw[offset + i] = b.New[offset + i] = (byte)(value >> (8 * (i & 3)));
        b.Known.AsSpan(offset, size).Fill(1); b.Kind.AsSpan(offset, size).Clear();
    }
    public void Delete(ulong buffer) => _b.Remove(buffer);

    public void Draw(ReadOnlySpan<CbufRead> reads)
    {
        foreach (ref readonly CbufRead r in reads)
        {
            if (r.Use == null || r.Use.Dynamic) { for (int o = 0; o + 16 <= r.Size; o += 16) Compare(r.Buffer, r.Offset + o); continue; }
            foreach (int ix in r.Use.Indices) { if (16 * ix + 16 > r.Size) break; Compare(r.Buffer, r.Offset + 16 * ix); }
        }
    }

    void Compare(ulong buf, int o)
    {
        if (!_b.TryGetValue(buf, out B b) || o < 0 || o + 16 > b.Old.Length || b.Known.AsSpan(o, 16).IndexOf((byte)0) >= 0) return;
        Vec4s++;
        ReadOnlySpan<byte> old = b.Old.AsSpan(o, 16), raw = b.Raw.AsSpan(o, 16), nw = b.New.AsSpan(o, 16);
        if (nw.SequenceEqual(old)) return;
        if (!_seen.Add((buf, o, b.Ver))) return;
        bool oc = !old.SequenceEqual(raw), nc = !nw.SequenceEqual(raw);
        int kind = 0; foreach (byte k in b.Kind.AsSpan(o, 16)) kind = Math.Max(kind, k);
        bool mat = kind >= 1 && kind <= 3;
        string cls;
        if (oc && !nc) { Miss++; if (mat) MissMatrix++; cls = "漏改"; }
        else if (nc && !oc) { Extra++; cls = "多改"; }
        else { Diff++; cls = "值不同"; }
        if (Samples.Count < 12)
            Samples.Add($"{cls}（旧改写种类 {(kind == 0 ? "无" : ((WidenKind)(kind - 1)).ToString())}） 缓冲 {buf} 偏移 {o}：原 {F(raw)} / 旧 {F(old)} / 新 {F(nw)}");
    }
    static string F(ReadOnlySpan<byte> b) => string.Join(" ", MemoryMarshal.Cast<byte, float>(b).ToArray());

    public string Summary() => $"影子对照：比了 {Vec4s} 次 vec4 读；不一致（按缓冲 / 偏移 / 内容版本去重）漏改矩阵 {MissMatrix}、漏改 {Miss}、多改 {Extra}、值不同 {Diff}；旧整段扫描 {_rw.Stats}";
    sealed class Sink : IWidenHitSink { public readonly List<(int, int, WidenKind)> H = new(); public void Hit(int o, int l, WidenKind k, bool c) => H.Add((o, l, k)); }
    readonly Sink _sink = new();
}
#endif
