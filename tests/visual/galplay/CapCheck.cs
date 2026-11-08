// galplay --capcheck <帧>：拷屏贴回一致性量具（画幅线 10-21，宽屏第二层 lytsz / capsz 闭环判据）。
// 界面拷屏控件 = 先把屏幕（或它的拷贝）画进一张拷屏贴图 C（拷屏），之后再把 C 画回屏幕目标 T（贴回）。不缩放的拷屏是原样搬运：贴回改动的像素应等于拷屏那一刻 T 同位置的像素。
// 拷屏区域与贴回位置对不上（塞尔达ポーチ页按「画布宽 / 2」定中心、拷的是 [0,1280) 贴到 [142,1422)）时，改动像素与原位不符。
// 认法（只看录像调用流，不按游戏）：该帧里一次绘制的颜色目标 0 = C、绑定的贴图里有 T 或 T 本帧 CopyTo 出的拷贝 → 拷屏，读回此刻的 T 记为 C 的源快照；
//   之后一次绘制颜色目标 0 = T、绑定的贴图里有 C → 贴回，读回贴回前后的 T：改动像素（任一通道差 > 2/255）里，与源快照同位置差 > 8/255 的算「不符」。
// 判定：贴回改动 ≥ 100 像素且不符占改动 > 1% → 红。只判原样拷屏：C 与目标同尺寸，或改动区域有一边与 C 同长（±2 像素）、另一边不超过 C；缩小拷屏做模糊底等贴回本就不是原样，只记不判。
// 正对照（--capcheck-selftest）：同一判定函数对合成画面——恒等贴回 0 不符（绿）、整体右移 142 列贴回大量不符（红），任一不成立退出 5。
using NxGal;
using Ryujinx.Graphics.GAL;
using S2Arm.Gfx.Widen.Gal;
using System;
using System.Buffers.Binary;
using System.Collections.Generic;
using System.Text;

sealed class CapCheck
{
    readonly long _frame;
    readonly Func<uint, NxTexture> _tex;
    readonly Dictionary<long, uint> _bound = new();      // (阶段 << 32 | 绑定号) → 贴图号
    readonly Dictionary<uint, uint> _copyOf = new();     // 本帧 CopyTo 目标 → 源（链式归到最初的源）
    readonly Dictionary<uint, uint> _view = new();       // 视图 → 被视的贴图（链式归到最底层）
    uint Root(uint t) { if (_view.TryGetValue(t, out uint v)) t = v; return _copyOf.TryGetValue(t, out uint c) ? (_view.TryGetValue(c, out uint cv) ? cv : c) : t; }
    readonly Dictionary<uint, (uint t, byte[] snap)> _src = new();   // 拷屏贴图 C → (源目标 T, 拷屏时刻 T 的快照)
    (uint t, uint c, byte[] snap, byte[] before, long rec, uint prog)? _pend;
    public readonly StringBuilder Log = new();
    public int Pastes, Red, Skipped, Judged;

    static readonly bool s_dbg = Environment.GetEnvironmentVariable("CAPCHECK_DEBUG") == "1";
    public CapCheck(long frame, Func<uint, NxTexture> tex) { _frame = frame; _tex = tex; }

    static bool IsDraw(uint op) => op is 0x009 or 0x00A or 0x00B or 0x00C or 0x00D or 0x00E;

    byte[] Read(uint id, out TextureCreateInfo inf)
    {
        NxTexture t = _tex(id); inf = default;
        if (t == null) return null;
        inf = t.Info;
        using var g = t.GetData(0, 0); return g.Get().ToArray();
    }

    /// <summary>每条记录回放前调（frame = 本条所在上屏序号，rt0 = 当前颜色目标 0）。</summary>
    public void Before(uint op, ReadOnlySpan<byte> pl, long frame, uint rt0, long rec, uint prog)
    {
        if (op == 0x304 && pl.Length >= 76) { uint vs = BinaryPrimitives.ReadUInt32LittleEndian(pl), vd = BinaryPrimitives.ReadUInt32LittleEndian(pl[72..]); _view[vd] = _view.TryGetValue(vs, out uint v0) ? v0 : vs; }   // 视图（任何帧建的）：同一份内容
        if (frame != _frame) return;
        if (op == 0x02D && pl.Length >= 12) { _bound[(long)BinaryPrimitives.ReadInt32LittleEndian(pl) << 32 | (uint)BinaryPrimitives.ReadInt32LittleEndian(pl[4..])] = BinaryPrimitives.ReadUInt32LittleEndian(pl[8..]); return; }
        if (op is 0x300 or 0x301 or 0x302 && pl.Length >= 8)
        {
            uint s = BinaryPrimitives.ReadUInt32LittleEndian(pl), d = BinaryPrimitives.ReadUInt32LittleEndian(pl[4..]);
            _copyOf[d] = _copyOf.TryGetValue(s, out uint s0) ? s0 : s; return;
        }
        if (s_dbg && (IsDraw(op) || op is 0x300 or 0x301 or 0x302 or 0x304)) Log.AppendLine($"[调试] #{rec} 操作 {op:x3} 目标 {rt0} 程序 {prog} 绑定 {string.Join(",", _bound.Values)}{(op >= 0x300 && pl.Length >= 8 ? $" 源 {BinaryPrimitives.ReadUInt32LittleEndian(pl)} 目 {BinaryPrimitives.ReadUInt32LittleEndian(pl[4..])}" : "")}");
        if (!IsDraw(op) || rt0 == 0) return;
        uint rtRoot = Root(rt0);
        foreach (uint b in _bound.Values)
            if (b != 0 && _src.TryGetValue(Root(b), out var s) && s.t == rtRoot)
            {
                byte[] before = Read(rt0, out _);
                if (before != null) _pend = (rt0, b, s.snap, before, rec, prog);
                return;
            }
        foreach (uint b in _bound.Values)
        {
            if (b == 0) continue;
            uint root = Root(b);
            if (root == rtRoot) continue;
            NxTexture rt = _tex(rt0), src = _tex(root);
            if (rt == null || src == null || src.Info.Width < 256) continue;   // 源要像屏幕（≥ 256 宽），小贴图绑定不算拷屏
            byte[] snap = Read(root, out _);
            if (snap != null) _src[rtRoot] = (root, snap);
            return;
        }
    }

    /// <summary>每条记录回放后调。</summary>
    public void After(uint op, long frame)
    {
        if (frame != _frame || !IsDraw(op) || _pend is not { } p) return;
        _pend = null;
        byte[] after = Read(p.t, out TextureCreateInfo inf);
        NxTexture c = _tex(p.c);
        if (after == null) return;
        Pastes++;
        var (chg, bad, x0, x1, y0, y1) = Judge(p.before, after, p.snap, inf.Width, inf.Height, inf.GetMipStride(0), inf.Format);
        // 原样拷屏才判：拷屏贴图与目标同尺寸（整屏），或与改动区域同尺寸（±2 像素：局部区域原样拷，塞尔达画布外滑入控件 50×200）；缩小拷屏做模糊底的贴回本就不是原样，只记不判
        bool whole = c != null && c.Info.Width == inf.Width && c.Info.Height == inf.Height;
        // 局部原样拷屏：改动区域有一边与拷屏贴图同长（±2 像素）、另一边不超过它（贴回里与屏幕本来相同的行 / 列不算改动）；改动 0 = 贴回与屏幕原样一致，也算判过（绿）
        int bw = x1 - x0 + 1, bh = y1 - y0 + 1;
        bool region = c != null && (chg == 0 || (Math.Abs(c.Info.Width - bw) <= 2 && bh <= c.Info.Height + 2) || (Math.Abs(c.Info.Height - bh) <= 2 && bw <= c.Info.Width + 2));
        if (chg < 0 || !(whole || region))
        {
            Skipped++;
            Log.AppendLine($"贴回 #{p.rec} 程序 {p.prog}：目标 {p.t}（{inf.Width}×{inf.Height} {inf.Format}）← 拷屏贴图 {p.c}（{c?.Info.Width}×{c?.Info.Height}）：改动区域 {(chg > 0 ? $"{x1 - x0 + 1}×{y1 - y0 + 1}" : chg < 0 ? "格式不认识" : "无")}，不是原样拷屏，只记不判");
            return;
        }
        bool red = chg >= 100 && bad > chg / 100;
        if (red) Red++;
        Judged++;
        Log.AppendLine($"贴回 #{p.rec} 程序 {p.prog}：目标 {p.t}（{inf.Width}×{inf.Height} {inf.Format}）← 拷屏贴图 {p.c}（{c.Info.Width}×{c.Info.Height}，{(whole ? "整屏" : "局部")}）：改动 {chg} 像素（列 {x0}–{x1}、行 {y0}–{y1}），与拷屏时原位不符 {bad}（{(chg > 0 ? 100.0 * bad / chg : 0):F2}%）→ {(red ? "红" : "绿")}");
    }

    /// <summary>判定函数（正对照与实测同用）：返回（改动像素数、其中与源快照原位不符数、改动列范围）。格式不认识时全返回 −1。</summary>
    public static (int chg, int bad, int x0, int x1, int y0, int y1) Judge(byte[] before, byte[] after, byte[] snap, int w, int h, int stride, Format f)
    {
        if (f is not (Format.R10G10B10A2Unorm or Format.R8G8B8A8Unorm or Format.R8G8B8A8Srgb or Format.B8G8R8A8Unorm or Format.B8G8R8A8Srgb)) return (-1, -1, -1, -1, -1, -1);
        bool ten = f == Format.R10G10B10A2Unorm; int chg = 0, bad = 0, x0 = int.MaxValue, x1 = -1, y0 = int.MaxValue, y1 = -1;
        Span<float> a = stackalloc float[3], b = stackalloc float[3], s = stackalloc float[3];
        for (int y = 0; y < h; y++)
            for (int x = 0; x < w; x++)
            {
                int o = y * stride + x * 4;
                Rgb(before, o, ten, a); Rgb(after, o, ten, b); Rgb(snap, o, ten, s);
                if (MaxDiff(a, b) <= 2f / 255) continue;
                chg++; if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y;
                if (MaxDiff(b, s) > 8f / 255) bad++;
            }
        return (chg, bad, chg > 0 ? x0 : -1, x1, chg > 0 ? y0 : -1, y1);
    }

    static void Rgb(byte[] d, int o, bool ten, Span<float> c)
    {
        uint v = BinaryPrimitives.ReadUInt32LittleEndian(d.AsSpan(o));
        if (ten) { c[0] = (v & 0x3ff) / 1023f; c[1] = ((v >> 10) & 0x3ff) / 1023f; c[2] = ((v >> 20) & 0x3ff) / 1023f; }
        else { c[0] = (v & 0xff) / 255f; c[1] = ((v >> 8) & 0xff) / 255f; c[2] = ((v >> 16) & 0xff) / 255f; }
    }
    static float MaxDiff(Span<float> a, Span<float> b) => MathF.Max(MathF.Abs(a[0] - b[0]), MathF.Max(MathF.Abs(a[1] - b[1]), MathF.Abs(a[2] - b[2])));

    public string Summary() => $"拷屏贴回检查（--capcheck 帧 {_frame}）：贴回 {Pastes} 次，判 {Judged}（不是原样拷屏只记不判 {Skipped}），红 {Red}\n" + Log;

    /// <summary>正对照：1564×720 合成画面（每列颜色不同的渐变 + 中间一个「人物」色块），拷屏快照 = 画面；贴回前把屏幕压暗（模拟拷屏后画的遮罩），
    /// 恒等贴回 = 把快照原样写回 [142,1422)；位移贴回 = 写回快照的 [0,1280) 到 [142,1422)。期望：恒等 不符 0、绿；位移 不符占比 > 1%、红。</summary>
    public static int SelfTest(StringBuilder log)
    {
        const int W = 1564, H = 720, S = W * 4; byte[] scr = new byte[S * H];
        for (int y = 0; y < H; y++) for (int x = 0; x < W; x++)
            {
                uint r = (uint)(x * 255 / W), g = (uint)(y * 255 / H), b = (uint)((x * 7 + y * 3) & 0xff);
                if (x >= 1290 && x < 1500 && y >= 120 && y < 640) { r = 240; g = 170; b = 100; }   // 人物色块
                BinaryPrimitives.WriteUInt32LittleEndian(scr.AsSpan(y * S + x * 4), r | g << 8 | b << 16 | 0xffu << 24);
            }
        byte[] dim = (byte[])scr.Clone();
        for (int i = 0; i < dim.Length; i += 4) { dim[i] /= 4; dim[i + 1] /= 4; dim[i + 2] /= 4; }
        byte[] ident = (byte[])dim.Clone(), shift = (byte[])dim.Clone();
        for (int y = 0; y < H; y++)
        {
            Array.Copy(scr, y * S + 142 * 4, ident, y * S + 142 * 4, 1280 * 4);
            Array.Copy(scr, y * S, shift, y * S + 142 * 4, 1280 * 4);
        }
        var (c1, b1, _, _, _, _) = Judge(dim, ident, scr, W, H, S, Format.R8G8B8A8Unorm);
        var (c2, b2, _, _, _, _) = Judge(dim, shift, scr, W, H, S, Format.R8G8B8A8Unorm);
        bool ok1 = c1 >= 100 && b1 == 0, ok2 = c2 >= 100 && b2 > c2 / 100;
        log.AppendLine($"正对照：恒等贴回 改动 {c1}、不符 {b1} → {(ok1 ? "绿（对）" : "不对")}；位移 142 列贴回 改动 {c2}、不符 {b2}（{100.0 * b2 / Math.Max(1, c2):F1}%）→ {(ok2 ? "红（对）" : "不对")}");
        return ok1 && ok2 ? 0 : 5;
    }
}
