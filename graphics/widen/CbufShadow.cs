// 通用宽屏 · 常量缓冲影子（画幅线，10-21「只扫变了的」）：常量改写在上传时做，但只扫内容真变了的部分。
// 影子只给「绑过常量缓冲的区间」留（按 4 KB 页，绑定时建页），上传时逐 16 字节（一粒）比影子：没变的粒不扫，已有命中原样保留；
// 没影子的部分（顶点 / 索引 / 只当存储用的数据）照旧整段扫。
//
// 每个缓冲（Buf）：
//   Pages  4 KB 一页：上传字节、每粒「已知」位（影子里是这粒最近一次上传的内容）、每粒「镜头脏」位（CameraTrack 用：起点在这粒的 64 字节窗口自上次判过后被写过）、
//          每粒「边缘」位（这粒在某次上传的头 / 尾 48 字节里：跨那次上传边界的窗口没整个判过，下次上传整个盖住时要重判）；
//   Hits   当前有效的改写区间（按 Lo 升序、互不重叠），原值 / 改写值 / 是否暂时写回了原值。
// 稳态零分配：页按「最近一次被绑」老化，KeepFrames 帧没再绑的回收进池子（内容作废，等于没影子：再上传整段扫），删了的缓冲连页带命中表回收复用；
// 10-22 暗黑2：常量绑定在大缓冲里一路往后挪、缓冲不停新建 / 删除，旧做法页只建不收（30 帧 211 页、影子 37 MB 还在涨）、每个新缓冲新建一份，编码线程每帧约 40 KB 分配。
using System;
using System.Collections.Generic;
using System.Numerics;
using System.Runtime.InteropServices;
using System.Runtime.Intrinsics;

namespace S2Arm.Gfx.Widen
{
    public sealed class CbufShadow
    {
        internal const int PageBits = 12, PageSize = 1 << PageBits, GranPerPage = PageSize / 16;

        // Restored：GPU 上暂时写回了原值（非放宽目标 / 原比例页读过），回到放宽目标再写改写值
        internal struct Hit { public int Lo, Len; public WidenKind Kind; public bool Restored; public Bytes64 Orig, New; }

        // 一页的「粒」位图（每粒 16 字节，一页 256 粒 = 4 个 ulong），内联在 Page 里，不单独分配
        [System.Runtime.CompilerServices.InlineArray(GranPerPage / 64)] internal struct Bits { ulong _e; }

        // 影子页：4 KB 数据放非托管内存（NativeMemory，页只回池不释放；10-26 巫师3 场景切换宽屏绑定每帧托管分配 33–278 KB，
        //   88% 是 Cover 在页池长到新峰值时 new Page 的 4 KB 数组 + 三张位图），位图内联——一页的托管对象从约 4.4 KB 降到约 150 字节。
        //   CbufShadow 每局一个、页池随它活到收局；单测里建很多个 CbufShadow，页数据随进程退出回收
        internal sealed unsafe class Page
        {
            internal readonly byte* Ptr = (byte*)NativeMemory.AllocZeroed(PageSize);
            internal Span<byte> Data => new(Ptr, PageSize);
            internal Bits Known, Dc, Edge;
            internal Buf Owner; internal int Index, Live;   // 属于哪个缓冲的第几页、在存活表里的下标
            internal long Bound;                             // 最近一次被绑时的帧号
        }

        /// <summary>页多少帧没再被绑就回收（30 帧游戏约 4 秒）。主镜头 / 场景常量每帧都绑，不会被收。</summary>
        public const int KeepFrames = 120;

        public sealed class Buf
        {
            internal ulong Key;
            internal Page[] Pages = Array.Empty<Page>();
            internal List<Hit> Hits = new();   // 不是 readonly：缓冲迁移时整张命中表从源交给目标（见 CopyHits）
            internal bool Deleted;
            internal long Version;   // 有内容变了 / 影子作废就换新值（镜头跟踪的读法缓存按它判失效）
            // 上一次 ScanUpload 判完时的范围、内容版本、相机签名版本（WidenFrame.ScanUpload 同段未变跳过用；ScanLo = −1 没扫过）
            internal int ScanLo = -1, ScanEnd; internal long ScanVer, ScanCam;
            internal Buf(ulong key) { Key = key; }
            public long Ver => Version;
            public bool IsDeleted => Deleted;
            public int HitCount => Hits.Count;

            internal Page P(int pi) => (uint)pi < (uint)Pages.Length ? Pages[pi] : null;
            internal Page PageAt(int byteOff) => byteOff < 0 ? null : P(byteOff >> PageBits);

            /// <summary>命中表里第一个末端 &gt; lo 的下标（命中按 Lo 升序、互不重叠，末端同样升序）。</summary>
            internal int FirstHitEndingAfter(int lo)
            {
                Span<Hit> hs = CollectionsMarshal.AsSpan(Hits);
                int a = 0, b = hs.Length;
                while (a < b) { int m = (a + b) >> 1; if (hs[m].Lo + hs[m].Len > lo) b = m; else a = m + 1; }
                return a;
            }
            // 最近几次上传的末尾 48 字节（环形 8 条，按缓冲建一次、零分配）：没绑过常量的区间没有影子页，矩阵被分两次传时靠它判跨界窗口（WidenFrame.ScanStraddle）
            internal const int TailN = 8, TailB = 48;
            internal readonly byte[] TailData = new byte[TailN * TailB];
            internal readonly int[] TailEnd = new int[TailN];
            internal readonly byte[] TailLen = new byte[TailN];
            internal int TailNext;
            internal void NoteTail(int end, ReadOnlySpan<byte> data)
            {
                int n = Math.Min(TailB, data.Length);
                for (int i = 0; i < TailN; i++) if (TailLen[i] > 0 && TailEnd[i] == end) { Put(i, end, data[^n..]); return; }
                Put(TailNext, end, data[^n..]); TailNext = (TailNext + 1) % TailN;
            }
            internal void Put(int i, int end, ReadOnlySpan<byte> d) { d.CopyTo(TailData.AsSpan(i * TailB + TailB - d.Length)); TailEnd[i] = end; TailLen[i] = (byte)d.Length; }
            /// <summary>有一次上传正好在 end 结束、末尾至少留了 len 字节：拷出 [end−len, end)。</summary>
            internal bool ReadTail(int end, int len, Span<byte> dst)
            {
                for (int i = 0; i < TailN; i++)
                    if (TailLen[i] >= len && TailEnd[i] == end) { TailData.AsSpan(i * TailB + TailB - len, len).CopyTo(dst); return true; }
                return false;
            }
            internal void DropTails(int lo, int hi)
            {
                for (int i = 0; i < TailN; i++) if (TailLen[i] > 0 && TailEnd[i] - TailLen[i] < hi && TailEnd[i] > lo) TailLen[i] = 0;
                for (int i = 0; i < TailN; i++) if (HeadLen[i] > 0 && HeadStart[i] < hi && HeadStart[i] + HeadLen[i] > lo) HeadLen[i] = 0;
            }
            // 最近几次上传的开头 48 字节（同末尾环）：游戏倒序分块上传时（10-22 暗黑2：先传 [1331200, …) 再传 [1327104, 1331200)），
            // 矩阵窗口起点在后传的那块里、终点落进先传的那块开头，靠它判
            internal readonly byte[] HeadData = new byte[TailN * TailB];
            internal readonly int[] HeadStart = new int[TailN];
            internal readonly byte[] HeadLen = new byte[TailN];
            internal int HeadNext;
            internal void NoteHead(int start, ReadOnlySpan<byte> data)
            {
                int n = Math.Min(TailB, data.Length), k = -1;
                for (int i = 0; i < TailN; i++) if (HeadLen[i] > 0 && HeadStart[i] == start) { k = i; break; }
                if (k < 0) { k = HeadNext; HeadNext = (HeadNext + 1) % TailN; }
                data[..n].CopyTo(HeadData.AsSpan(k * TailB)); HeadStart[k] = start; HeadLen[k] = (byte)n;
            }
            /// <summary>有一次上传正好从 start 开始、开头至少留了 len 字节：拷出 [start, start+len)。</summary>
            internal bool ReadHead(int start, int len, Span<byte> dst)
            {
                for (int i = 0; i < TailN; i++)
                    if (HeadLen[i] >= len && HeadStart[i] == start) { HeadData.AsSpan(i * TailB, len).CopyTo(dst); return true; }
                return false;
            }
            /// <summary>[off, off+len)（16 字节对齐）每一粒都在影子里已知时拷出字节。</summary>
            internal bool ReadKnown(int off, int len, Span<byte> dst)
            {
                for (int g = off; g < off + len; g += 16)
                {
                    Page p = PageAt(g); int gi = (g & (PageSize - 1)) >> 4;
                    if (p == null || (p.Known[gi >> 6] >> (gi & 63) & 1) == 0) return false;
                    p.Data.Slice(g & (PageSize - 1), 16).CopyTo(dst[(g - off)..]);
                }
                return true;
            }
            internal bool OverlapsHit(int lo, int hi)
            {
                int i = FirstHitEndingAfter(lo);
                return i < Hits.Count && Hits[i].Lo < hi;
            }
            /// <summary>同 OverlapsHit，给按 lo 单调不减连续查询的扫描循环用：k 是上次查到的「第一个末端 &gt; lo」下标，往前挪即可（摊下来 O(1)）；
            /// k &lt; 0 时二分定位。命中表改过（插入 / 删除）后调用方把 k 置 −1（10-26 八方2 真机：扫描循环里每个候选重新二分占游戏渲染线程 3.8%）。</summary>
            internal bool OverlapsHitFrom(ref int k, int lo, int hi)
            {
                Span<Hit> hs = CollectionsMarshal.AsSpan(Hits);
                if (k < 0) k = FirstHitEndingAfter(lo);
                else while (k < hs.Length && hs[k].Lo + hs[k].Len <= lo) k++;
                return k < hs.Length && hs[k].Lo < hi;
            }
            internal void InsertHit(in Hit h) => Hits.Insert(FirstHitEndingAfter(h.Lo), h);
            /// <summary>一批新命中一次插入（WidenFrame.ScanAll 用，S2A_WIDEN_HIT_BATCH=1）：结果与逐条 InsertHit 完全相同的条件——
            /// 这批按起点升序且互不重叠，且插入点 i 之后的旧命中都在这批最后一条起点之后结束（命中表按起点升序、互不重叠，结束位置也单调）。
            /// 逐条插入时第 k 条落在 i + k；整段 InsertRange 只搬一次尾部（10-23 巫师3：逐条插入搬尾占进程忙时 1.7%，命中结构 144 字节）。
            /// 条件不满足就退回逐条插入。</summary>
            internal void InsertHits(List<Hit> add)
            {
                if (add.Count == 0) return;
                Span<Hit> a = CollectionsMarshal.AsSpan(add);
                bool ok = true;
                for (int k = 1; k < a.Length && ok; k++) ok = a[k].Lo >= a[k - 1].Lo + a[k - 1].Len;
                int i = FirstHitEndingAfter(a[0].Lo);
                if (ok && i < Hits.Count) { Hit nx = Hits[i]; ok = nx.Lo + nx.Len > a[^1].Lo; }
                if (ok) { Hits.InsertRange(i, add); return; }
                foreach (ref readonly Hit h in a) InsertHit(h);
            }
            /// <summary>丢掉与 [lo, hi) 相交的命中。</summary>
            internal void DropHits(int lo, int hi)
            {
                int i = FirstHitEndingAfter(lo), j = i;
                while (j < Hits.Count && Hits[j].Lo < hi) j++;
                if (j > i) Hits.RemoveRange(i, j - i);
            }

            /// <summary>[off, off+dst.Length) 涉及的粒都在影子里且已知时拷出（CPU 递来的原值；宽屏几何判定读常量用，不等 GPU）。</summary>
            public bool ReadKnown(int off, Span<byte> dst)
            {
                for (int pos = off, end = off + dst.Length; pos < end;)
                {
                    Page p = PageAt(pos); int gi = (pos & (PageSize - 1)) >> 4;
                    if (p == null || (p.Known[gi >> 6] >> (gi & 63) & 1) == 0) return false;
                    int ge = Math.Min(end, (pos & ~15) + 16);
                    p.Data.Slice(pos & (PageSize - 1), ge - pos).CopyTo(dst[(pos - off)..]);
                    pos = ge;
                }
                return true;
            }
            /// <summary>[off, off+64) 整个在影子里且已知时取出 16 个浮点（镜头跟踪用）。</summary>
            internal bool ReadWindow(int off, Span<float> m)
            {
                Span<byte> d = MemoryMarshal.AsBytes(m[..16]);
                for (int k = 0; k < 4; k++)
                {
                    int g = off + k * 16;
                    Page p = PageAt(g);
                    int gi = (g & (PageSize - 1)) >> 4;
                    if (p == null || (p.Known[gi >> 6] >> (gi & 63) & 1) == 0) return false;
                    p.Data.Slice(g & (PageSize - 1), 16).CopyTo(d[(k * 16)..]);
                }
                return true;
            }
            internal bool DcGet(int off) { Page p = PageAt(off); int gi = (off & (PageSize - 1)) >> 4; return p != null && (p.Dc[gi >> 6] >> (gi & 63) & 1) != 0; }
            internal void DcClear(int off) { Page p = PageAt(off); int gi = (off & (PageSize - 1)) >> 4; if (p != null) p.Dc[gi >> 6] &= ~(1UL << (gi & 63)); }
            void DcSet(int granule)
            {
                if (granule < 0) return;
                Page p = P(granule >> (PageBits - 4));
                int gi = granule & (GranPerPage - 1);
                if (p != null) p.Dc[gi >> 6] |= 1UL << (gi & 63);
            }
            /// <summary>粒 g 变了：起点在 g−3..g 的 64 字节窗口镜头脏。</summary>
            internal void DcChanged(int g) { for (int k = g - 3; k <= g; k++) DcSet(k); }
            /// <summary>粒 [g0, g1)（缓冲内粒号，可跨页、g0 可为负）镜头脏位置 1：等于对其中每一粒变了的粒调 DcChanged（调用方传 g0 = 首个变了的粒 − 3）。</summary>
            internal void DcRange(int g0, int g1)
            {
                if (g0 < 0) g0 = 0;
                while (g0 < g1)
                {
                    int pi = g0 >> (PageBits - 4), e = Math.Min(g1, (pi + 1) << (PageBits - 4));
                    if (P(pi) is Page p) SetBits(p.Dc, g0 & (GranPerPage - 1), (e - 1 & (GranPerPage - 1)) + 1);
                    g0 = e;
                }
            }
        }

        readonly Dictionary<ulong, Buf> _bufs = new();
        readonly List<Page> _live = new();
        readonly Stack<Page> _freePages = new();
        /// <summary>缓冲拷贝里整页从源挂到目标的页数（不建新页，见 CopyShadow）。</summary>
        public long PagesMoved;
        /// <summary>缓冲迁移时整张命中表交给目标的次数（见 CopyHits）。</summary>
        public long HitListsMoved;
        readonly Stack<Buf> _freeBufs = new();
        long _frame;
        const int CacheBits = 8;
        readonly ulong[] _ck = new ulong[1 << CacheBits]; readonly Buf[] _cv = new Buf[1 << CacheBits];
        static int CI(ulong k) => (int)((k * 0x9E3779B97F4A7C15UL) >> (64 - CacheBits));
        static long s_ver;
        internal static long NextVer() => ++s_ver;

        /// <summary>影子总字节 / 峰值（页数 × 4 KB）。</summary>
        public long Bytes { get; private set; }
        public long PeakBytes { get; private set; }
        /// <summary>上传到没有影子的区间（没绑过常量）的字节：这些照旧整段扫。</summary>
        public long NoPageBytes;
        public int Count => _bufs.Count;

        public Buf TryGet(ulong key)
        {
            int i = CI(key);
            if (_ck[i] == key && _cv[i] != null) return _cv[i];
            if (!_bufs.TryGetValue(key, out Buf b)) return null;
            _ck[i] = key; _cv[i] = b;
            return b;
        }
        public Buf Get(ulong key)
        {
            Buf b = TryGet(key);
            if (b != null) return b;
            if (_freeBufs.Count > 0) { b = _freeBufs.Pop(); b.Key = key; b.Deleted = false; b.Version = NextVer(); }
            else b = new Buf(key);
            _bufs[key] = b;
            int i = CI(key); _ck[i] = key; _cv[i] = b;
            return b;
        }

        /// <summary>[offset, offset+size) 被绑成常量缓冲：给覆盖到的页建影子（内容未知，下次上传整段扫一次、记进影子）。</summary>
        public void Cover(ulong key, int offset, int size)
        {
            if (size <= 0 || offset < 0) return;
            Buf b = Get(key);
            int p0 = offset >> PageBits, p1 = (offset + size - 1) >> PageBits;
            if (b.Pages.Length <= p1) Array.Resize(ref b.Pages, Math.Max(p1 + 1, b.Pages.Length * 2));
            for (int p = p0; p <= p1; p++)
            {
                Page pg = b.Pages[p];
                if (pg != null) { pg.Bound = _frame; continue; }
                pg = _freePages.Count > 0 ? _freePages.Pop() : new Page();
                pg.Owner = b; pg.Index = p; pg.Bound = _frame; pg.Live = _live.Count; _live.Add(pg);
                b.Pages[p] = pg;
                Bytes += PageSize; if (Bytes > PeakBytes) PeakBytes = Bytes;
            }
        }

        /// <summary>页回收进池子：位图清零（内容作废），移出存活表。调用方负责把缓冲里那一格置空。</summary>
        void FreePage(Page pg)
        {
            pg.Known = default; pg.Dc = default; pg.Edge = default;
            Page last = _live[^1]; _live[pg.Live] = last; last.Live = pg.Live; _live.RemoveAt(_live.Count - 1);
            pg.Owner = null; _freePages.Push(pg);
            Bytes -= PageSize;
        }

        /// <summary>一帧结束（上屏）：KeepFrames 帧没再被绑的页回收（之后上传到那里等于没影子、整段扫；命中表不动）。</summary>
        public void EndFrame()
        {
            _frame++;
            long cut = _frame - KeepFrames;
            for (int i = _live.Count - 1; i >= 0; i--)
            {
                Page pg = _live[i];
                if (pg.Bound >= cut) continue;
                Buf b = pg.Owner; b.Pages[pg.Index] = null; b.Version = NextVer();
                FreePage(pg);
            }
        }

        /// <summary>CPU 上传：有影子的页逐粒比，内容变了的（或原来未知的）粒拷进影子、标已知；没影子的部分整段算变了。
        /// 变了的字节区间（按粒取整、截在上传之内）按升序写进 changed；返回是否有变。</summary>
        public bool Write(ulong key, int offset, ReadOnlySpan<byte> data, List<(int Lo, int Hi)> changed, out Buf buf)
        {
            changed.Clear();
            Buf b = buf = Get(key);
            int end = offset + data.Length;
            int runLo = -1, runHi = -1;
            void Add(int lo, int hi)
            {
                if (runHi >= lo) { runHi = Math.Max(runHi, hi); return; }
                if (runLo >= 0) changed.Add((runLo, runHi));
                runLo = lo; runHi = hi;
            }
            for (int pos = offset; pos < end;)
            {
                int pe = Math.Min(end, ((pos >> PageBits) + 1) << PageBits);
                Page pg = b.PageAt(pos);
                if (pg == null) { NoPageBytes += pe - pos; Add(pos, pe); pos = pe; continue; }
                Span<byte> sh = pg.Data;
                int pb = pos & ~(PageSize - 1), gLast = (pe - 1 - pb) >> 4;
                while (pos < pe)
                {
                    int g = (pos - pb) >> 4, gs = pb + (g << 4);
                    if (pos == gs && gs + 16 <= pe && (pg.Known[g >> 6] >> (g & 63) & 1) != 0)
                    {
                        // 连着的已知整粒（按位找到哪，截到这页这次上传里的最后一个整粒）：向量化找第一个不同的字节
                        int ke = Math.Min(pb + (KnownRunEnd(pg.Known, g) << 4), pb + ((pe - pb) >> 4 << 4));
                        int n = data[(pos - offset)..(ke - offset)].CommonPrefixLength(sh[(pos - pb)..(ke - pb)]);
                        if (pos + n >= ke) { pos = ke; continue; }
                        pos += n;
                        g = (pos - pb) >> 4; gs = pb + (g << 4);
                    }
                    // 从粒 g 起变了（或未知 / 半粒）的一段：直到下一个已知、整粒、内容没变的粒。整段一次拷进影子、按位段置已知 / 镜头脏（10-23 巫师3：
                    // 逐粒拷 + 置位 + 记区间，每次上传几十 KB 未知粒，50 帧 97 ms；比对本身只占零头）
                    int j = g + 1;
                    while (j <= gLast)
                    {
                        int js = pb + (j << 4);
                        if ((pg.Known[j >> 6] >> (j & 63) & 1) == 0) { j = Math.Min(KnownRunStart(pg.Known, j), gLast + 1); continue; }
                        if (js + 16 <= pe && data.Slice(js - offset, 16).SequenceEqual(sh.Slice(js - pb, 16))) break;
                        j++;
                    }
                    int lo = Math.Max(gs, offset), hi = Math.Min(pe, pb + (j << 4));
                    data[(lo - offset)..(hi - offset)].CopyTo(sh[(lo - pb)..]);
                    // 已知位：整个落在这次上传里的粒置位；半粒（上传头 / 尾截断的）只拷了一部分，原来已知的仍已知、未知的仍未知
                    int k0 = (lo - pb + 15) >> 4, k1 = (hi - pb) >> 4;
                    if (k1 > k0) SetBits(pg.Known, k0, k1);
                    b.DcRange((gs >> 4) - 3, (pb >> 4) + j);
                    Add(lo, hi);
                    pos = hi;
                }
            }
            if (runLo >= 0) changed.Add((runLo, runHi));
            if (changed.Count > 0) b.Version = NextVer();
            return changed.Count > 0;
        }

        /// <summary>同 Write，但调用方保证 [offset, end) 里 ranges（相对 offset 的升序区间）以外的字节与上一次交给这块影子的逐字节相同（直连宽屏胶水按影子续拼的更新段给出）：
        /// 只比这些区间，省掉整段比对（11-02 怪猎真机：每笔每槽整段比 5 KB，每帧 20 MB）。结果与 Write 逐项相同的前提——整段 16 字节对齐、覆盖到的页都在、每粒都已知
        /// （Write 把未知粒 / 半粒算变了，那些这里看不到）——不满足就返回 false、什么都不动，调用方改走 Write。各区间外扩到整粒、相接的并成一段后逐段调 Write：
        /// Write 的判法是逐粒的（变了的一段只延到下一个已知且没变的粒），段与段之间至少隔一个没变的已知粒，逐段调与整段调得到同一组变了的区间</summary>
        public bool WriteRanges(ulong key, int offset, ReadOnlySpan<byte> data, ReadOnlySpan<(int Lo, int Hi)> ranges, List<(int Lo, int Hi)> changed, out Buf buf)
        {
            buf = null;
            int end = offset + data.Length;
            if (((offset | end) & 15) != 0 || data.Length == 0) return false;
            Buf b = Get(key);
            for (int pos = offset; pos < end;)
            {
                int pe = Math.Min(end, ((pos >> PageBits) + 1) << PageBits);
                Page pg = b.PageAt(pos);
                if (pg == null) return false;
                int pb = pos & ~(PageSize - 1), g0 = (pos - pb) >> 4, g1 = (pe - pb) >> 4;
                if (KnownRunEnd(pg.Known, g0) < g1 || (pg.Known[g0 >> 6] >> (g0 & 63) & 1) == 0) return false;
                pos = pe;
            }
            changed.Clear(); buf = b;
            _rangeTmp.Clear();
            int curLo = -1, curHi = -1;
            foreach (var (rl, rh) in ranges)
            {
                int lo = Math.Max(offset, (offset + rl) & ~15), hi = Math.Min(end, (offset + rh + 15) & ~15);
                if (hi <= lo) continue;
                if (curHi >= lo) { curHi = Math.Max(curHi, hi); continue; }
                if (curLo >= 0) _rangeTmp.Add((curLo, curHi));
                curLo = lo; curHi = hi;
            }
            if (curLo >= 0) _rangeTmp.Add((curLo, curHi));
            RangeBytes = 0;
            foreach (var (lo, hi) in _rangeTmp)
            {
                RangeBytes += hi - lo;
                Write(key, lo, data[(lo - offset)..(hi - offset)], _rangeChg, out _);
                foreach (var c in _rangeChg)
                    if (changed.Count > 0 && changed[^1].Hi >= c.Lo) changed[^1] = (changed[^1].Lo, Math.Max(changed[^1].Hi, c.Hi)); else changed.Add(c);
            }
            return true;
        }
        readonly List<(int Lo, int Hi)> _rangeTmp = new(), _rangeChg = new();
        /// <summary>上一次 WriteRanges 实际比的字节数（各区间外扩到整粒、合并后的总长）</summary>
        public int RangeBytes;

        /// <summary>[offset, end) 里带「边缘」位的粒（内容没变也要重判：之前跨上传边界的窗口这次可能整个落在上传里），按升序合并成区间写进 runs（截在上传之内）。
        /// 10-21 暗黑2：游戏按 4 KB 一块传常量，矩阵跨两块时两次都判不了；之后整段 8 KB 上传、内容没变，只扫变了的就一直不改它（整段扫描会改）。</summary>
        public static void EdgeRuns(Buf b, int offset, int end, List<(int Lo, int Hi)> runs)
        {
            runs.Clear();
            for (int g = offset & ~15; g < end; g += 16)
            {
                Page p = b.PageAt(g);
                if (p == null) { g = ((g >> PageBits) + 1 << PageBits) - 16; continue; }
                int gi = (g & (PageSize - 1)) >> 4;
                if (p.Edge[gi >> 6] == 0) { g = (g & ~(64 * 16 - 1)) + 63 * 16; continue; }
                if ((p.Edge[gi >> 6] >> (gi & 63) & 1) == 0) continue;
                int lo = Math.Max(g, offset), hi = Math.Min(g + 16, end);
                if (runs.Count > 0 && runs[^1].Hi >= lo) runs[^1] = (runs[^1].Lo, hi); else runs.Add((lo, hi));
            }
        }

        /// <summary>这次上传判完：上传里的粒清「边缘」位，再给头 / 尾 48 字节的粒置位（跨这次上传边界的窗口、浮点对没判过）。</summary>
        public static void MarkEdges(Buf b, int offset, int end)
        {
            for (int g = offset & ~15; g < end;)
            {
                int pe = ((g >> PageBits) + 1) << PageBits;
                Page p = b.PageAt(g);
                if (p != null)
                {
                    // 按 64 位一字清 [g, min(end, 页末)) 的位
                    int a = (g & (PageSize - 1)) >> 4, z = ((Math.Min(end, pe) - 1) & (PageSize - 1)) >> 4;
                    for (int w = a >> 6; w <= z >> 6; w++)
                    {
                        int lo = Math.Max(a, w << 6) & 63, hi = Math.Min(z, (w << 6) + 63) & 63;
                        p.Edge[w] &= ~((~0UL >> (63 - hi)) & (~0UL << lo));
                    }
                }
                g = pe;
            }
            // 只在边界外侧那粒已知（之前传过、跨界窗口以后可能被一次上传整个盖住）时置位；外侧未知的，等它上传时由那次在它的边界上置位
            if ((offset & 15) != 0 || IsKnown(b, offset - 16))
                for (int g = offset & ~15; g < Math.Min(end, offset + 48); g += 16) SetEdge(b, g);
            if ((end & 15) != 0 || IsKnown(b, end))
                for (int g = Math.Max(offset & ~15, (end - 48) & ~15); g < end; g += 16) SetEdge(b, g);
        }
        static bool IsKnown(Buf b, int g)
        {
            Page p = b.PageAt(g);
            int gi = (g & (PageSize - 1)) >> 4;
            return p != null && (p.Known[gi >> 6] >> (gi & 63) & 1) != 0;
        }
        static void SetEdge(Buf b, int g)
        {
            Page p = b.PageAt(g);
            int gi = (g & (PageSize - 1)) >> 4;
            if (p != null) p.Edge[gi >> 6] |= 1UL << (gi & 63);
        }

        /// <summary>页内从粒 g 起连续已知粒的末端（粒号，≤ GranPerPage）。</summary>
        /// <summary>从粒 g 起第一个已知粒（没有 = GranPerPage）。</summary>
        static int KnownRunStart(ReadOnlySpan<ulong> k, int g)
        {
            while (g < GranPerPage)
            {
                ulong m = k[g >> 6] & (~0UL << (g & 63));
                if (m != 0) return ((g >> 6) << 6) + BitOperations.TrailingZeroCount(m);
                g = ((g >> 6) + 1) << 6;
            }
            return GranPerPage;
        }
        /// <summary>位图 [a, b) 置 1。</summary>
        internal static void SetBits(Span<ulong> k, int a, int b)
        {
            while (a < b)
            {
                int w = a >> 6, e = Math.Min(b, (w + 1) << 6);
                ulong m = (e - a == 64 ? ~0UL : ((1UL << (e - a)) - 1)) << (a & 63);
                k[w] |= m; a = e;
            }
        }
        static int KnownRunEnd(ReadOnlySpan<ulong> k, int g)
        {
            while (g < GranPerPage)
            {
                ulong m = ~k[g >> 6] & (~0UL << (g & 63));
                if (m != 0) return Math.Min(GranPerPage, ((g >> 6) << 6) + BitOperations.TrailingZeroCount(m));
                g = ((g >> 6) + 1) << 6;
            }
            return GranPerPage;
        }

        /// <summary>GPU 往 [offset, offset+size) 写了别的内容（缓冲间拷贝、清缓冲）：那段命中丢掉、影子作废（下次上传整段重扫）。</summary>
        public void Overwritten(ulong key, int offset, int size)
        {
            Buf b = TryGet(key);
            if (b == null || size <= 0) return;
            b.DropHits(offset, offset + size); b.DropTails(offset, offset + size);
            for (int g = offset & ~15; g < offset + size; g += 16)
            {
                Page p = b.PageAt(g);
                if (p == null) { g = ((g >> PageBits) + 1 << PageBits) - 16; continue; }
                int gi = (g & (PageSize - 1)) >> 4;
                p.Known[gi >> 6] &= ~(1UL << (gi & 63));
                b.DcChanged(g >> 4);
            }
            b.Version = NextVer();
        }

        /// <summary>GPU 上缓冲拷贝 [srcOffset, +size) → [dstOffset, +size)：目标区间按覆写作废（影子未知、旧命中丢掉），再把源里整个落在拷贝区间内的命中平移搬过去——
        /// 拷过去的就是源在 GPU 上的那份内容（改写值，或暂时写回的原值：Restored 照抄）。以前只作废不搬：Ryujinx 缓冲迁移 / 合并时用拷贝搬常量，
        /// 搬过去的改写值没了命中记录，读它的绘制当成「没读到改写矩阵」按 ScaleK 画、也不再写回 / 补回，只在发生拷贝的那几帧（10-22 暗黑2 人物界面云层 / 手中火焰、营地火炬 / 叹号隔帧横向抖）。
        /// 跨拷贝边界、只拷了一截的命中不搬（目标里那一截字节当未知）。返回搬过去的、Restored 的命中个数（调用方登记待补回）。</summary>
        public int CopyHits(ulong src, ulong dst, int srcOffset, int dstOffset, int size, List<(ulong Buf, int Lo)> restored)
        {
            Buf s = TryGet(src);
            bool self = s != null && src == dst;
            // 源里整个落在拷贝区间内的命中（命中按 Lo 升序、互不重叠 → 是连续一段 [i0, i1)）。源 / 目标不同时直接从源表搬、不经临时表
            //   （10-23 M4 暗黑2：临时表 _copy 与目标表每逢命中数创新高就按倍数长，一次拷贝 10–65 万字节）；同一缓冲内拷贝要先抄出来（覆写目标会删掉源命中）
            int i0 = 0, i1 = 0;
            if (s != null && size > 0)
            {
                Span<Hit> hs = CollectionsMarshal.AsSpan(s.Hits);
                i0 = s.FirstHitEndingAfter(srcOffset);
                if (i0 < hs.Length && hs[i0].Lo < srcOffset) i0++;   // 跨拷贝起点、只拷了一截的不搬
                i1 = i0;
                while (i1 < hs.Length && hs[i1].Lo + hs[i1].Len <= srcOffset + size) i1++;
                if (self) { _copy.Clear(); for (int k = i0; k < i1; k++) _copy.Add(hs[k]); }
            }
            Overwritten(dst, dstOffset, size);
            if (s != null && size > 0)
            {
                Buf dt = null;
                for (int i = 0; i < Buf.TailN; i++)
                {
                    int e = s.TailEnd[i], l = s.TailLen[i];
                    if (l == 0 || e - l < srcOffset || e > srcOffset + size) continue;
                    (dt ??= Get(dst)).NoteTail(e - srcOffset + dstOffset, s.TailData.AsSpan(i * Buf.TailB + Buf.TailB - l, l));
                }
                for (int i = 0; i < Buf.TailN; i++)
                {
                    int st = s.HeadStart[i], l = s.HeadLen[i];
                    if (l == 0 || st < srcOffset || st + l > srcOffset + size) continue;
                    (dt ??= Get(dst)).NoteHead(st - srcOffset + dstOffset, s.HeadData.AsSpan(i * Buf.TailB, l));
                }
            }
            // 影子内容也跟着搬：源上已知的粒（16 字节对齐、源 / 目标同余）把字节与已知 / 边缘位拷到目标。只搬命中不搬影子时，之后对目标的部分上传
            // 当成整段都变了、丢掉跨上传起点的命中，而上传起点前那几粒影子未知、那个窗口也重判不了（10-22 暗黑2：缓冲迁移 895 → 1796 后从 c[16] 起上传，
            // c[13..16] 的投影命中丢了、GPU 上仍是改写值，第 10 帧云层 / 手光按 ScaleK 画）
            if (s != null && size > 0 && ((srcOffset ^ dstOffset) & 15) == 0 && s.Pages.Length > 0 && Get(dst) is { } dsh && !ReferenceEquals(dsh, s)) CopyShadow(s, dsh, srcOffset, dstOffset, size);
            int n = self ? _copy.Count : i1 - i0;
            if (n == 0) return 0;
            Buf d = Get(dst); int nr = 0, shift = dstOffset - srcOffset;
            // 缓冲迁移（Ryujinx 把旧缓冲 0 → 0 整段拷进新缓冲、随后删掉旧的；10-23 M4 暗黑2 大帧：602–1600 个命中逐个插进新缓冲的空表、表按倍数长）：
            //   源的命中全在拷贝区间里、偏移不变、目标没有命中 → 整张命中表交给目标（目标的空表换给源，旧缓冲迁移后不再被绑 / 上传）
            if (!self && shift == 0 && srcOffset == 0 && d.Hits.Count == 0 && n == s.Hits.Count)
            {
                (s.Hits, d.Hits) = (d.Hits, s.Hits);
                s.Version = NextVer(); HitListsMoved++;
            }
            else
            {
                // 目标区间已被覆写清空：搬来的一段整体插在同一处（升序不变），再原地改偏移
                int at = d.FirstHitEndingAfter(dstOffset);
                ReadOnlySpan<Hit> part = self ? CollectionsMarshal.AsSpan(_copy) : CollectionsMarshal.AsSpan(s.Hits)[i0..i1];
                d.Hits.InsertRange(at, part);
                Span<Hit> ins = CollectionsMarshal.AsSpan(d.Hits).Slice(at, n);
                for (int k = 0; k < n; k++) ins[k].Lo += shift;
            }
            {
                Span<Hit> dh = CollectionsMarshal.AsSpan(d.Hits);
                int a = d.FirstHitEndingAfter(dstOffset);
                for (int k = a; k < dh.Length && dh[k].Lo < dstOffset + size; k++) if (dh[k].Restored) { restored?.Add((dst, dh[k].Lo)); nr++; }
            }
            d.Version = NextVer();
            return nr;
        }
        readonly List<Hit> _copy = new();

        void CopyShadow(Buf s, Buf d, int so, int dof, int size)
        {
            // 整页搬（10-23 M4 暗黑2 大帧分配：Ryujinx 缓冲迁移 0 → 0 整段拷，目标页逐页 new Page，一次 30–65 万字节、池子空——
            //   迁移时源缓冲还没删，页要等它删了才回池）：源 / 目标页内同余、源页整页落在拷贝区间里、目标那页还没影子 → 把源页直接挂到目标，不建新页。
            //   影子只是已知内容的缓存：源之后若再有上传，那页当未知整段重扫（迁移源随后就删）；命中表不动（命中在 Hits 里，不在页上）
            if (((so - dof) & (PageSize - 1)) == 0)
            {
                int p0 = (so + PageSize - 1) >> PageBits, p1 = (so + size) >> PageBits;   // 源里整页落在 [so, so+size) 的页 [p0, p1)
                for (int sp = p0; sp < p1 && sp < s.Pages.Length; sp++)
                {
                    Page pg = s.Pages[sp];
                    if (pg == null) continue;
                    int dp = (sp << PageBits) - so + dof >> PageBits;
                    if (d.P(dp) != null) continue;
                    if (d.Pages.Length <= dp) Array.Resize(ref d.Pages, Math.Max(dp + 1, d.Pages.Length * 2));
                    s.Pages[sp] = null; d.Pages[dp] = pg; pg.Owner = d; pg.Index = dp; pg.Bound = _frame;
                    PagesMoved++;
                }
                s.Version = NextVer();
            }
            for (int g = (16 - (so & 15)) & 15; g + 16 <= size; g += 16)
            {
                int sg = so + g, dg = dof + g;
                Page sp = s.PageAt(sg);
                if (sp == null) { g += (PageSize - (sg & (PageSize - 1))) - 16; continue; }   // 源这页没影子：跳到源下一页
                int si = (sg & (PageSize - 1)) >> 4, di = (dg & (PageSize - 1)) >> 4;
                if ((sp.Known[si >> 6] >> (si & 63) & 1) == 0) continue;
                Page dp = d.PageAt(dg);
                if (dp == null) { Cover(d.Key, dg & ~(PageSize - 1), PageSize); dp = d.PageAt(dg); }   // 源上有影子的粒：目标那页跟着建（迁移出来的新缓冲还没绑过）
                sp.Data.Slice(sg & (PageSize - 1), 16).CopyTo(dp.Data.Slice(dg & (PageSize - 1), 16));
                dp.Known[di >> 6] |= 1UL << (di & 63);
                if ((sp.Edge[si >> 6] >> (si & 63) & 1) != 0) dp.Edge[di >> 6] |= 1UL << (di & 63); else dp.Edge[di >> 6] &= ~(1UL << (di & 63));
            }
        }

        /// <summary>相机签名表变了：全部影子作废（下次上传整段重扫，之前在没变的数据里判过没中的系数对按新签名重判）。九款整局只变 1–6 次。</summary>
        public void InvalidateAll()
        {
            foreach (Buf b in _bufs.Values)
            {
                foreach (Page p in b.Pages) if (p != null) p.Known = default;
                b.Version = NextVer();
            }
        }

        public void Delete(ulong key)
        {
            if (!_bufs.Remove(key, out Buf b)) return;
            b.Deleted = true;
            foreach (Page p in b.Pages) if (p != null) FreePage(p);
            Array.Clear(b.Pages); b.Hits.Clear(); Array.Clear(b.TailLen); Array.Clear(b.HeadLen);
            int i = CI(key); if (_ck[i] == key) { _ck[i] = 0; _cv[i] = null; }
            _freeBufs.Push(b);
        }
    }
}
