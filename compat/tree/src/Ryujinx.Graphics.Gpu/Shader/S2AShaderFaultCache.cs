using System;
using System.Collections.Generic;

namespace Ryujinx.Graphics.Gpu.Shader
{
    /// <summary>
    /// S2A（#723 P1）：取码失败负缓存对外部世界（MemoryManager）的提问面。
    /// 运行时由 S2AFaultHostOf 实现，单测用假实现——本文件不引用 Ryujinx 其它类型，可以单文件编译测试（照 tests/multirange 的写法）。
    /// </summary>
    internal interface IS2AFaultHost
    {
        /// <summary>映射代数号（MemoryManager.S2AMapGen）：变了说明页表改过，页的物理地址可能变了。</summary>
        int MapGen { get; }

        /// <summary>页对齐 GPU VA → 物理地址；未映射返回 ulong.MaxValue。</summary>
        ulong TranslatePage(ulong page);

        /// <summary>给这一页的物理内存武装写跟踪，并记下解码器在这页读过的字节区间 [lo, hi) 的内容（之后任何写都会让 Dirty 为真）。未映射返回 null。</summary>
        IS2AFaultWatch Arm(ulong page, int lo, int hi);
    }

    /// <summary>S2A：一页的写跟踪 + 解码器读过的字节区间的内容快照。Arm 时 Reprotect 一次清掉新建即有的脏位并武装。</summary>
    internal interface IS2AFaultWatch : IDisposable
    {
        /// <summary>自上次武装起页被写过。</summary>
        bool Dirty { get; }

        /// <summary>页被写过时调：先重新武装（清脏），再比读过区间的内容——与武装时相同返回 true（条目仍有效），变了返回 false。</summary>
        bool Rearm();
    }

    /// <summary>
    /// S2A：图形着色器负缓存的键——六个阶段的 GPU 地址。
    /// 不直接用 ShaderAddresses，是为了让本文件可以单文件编译（单测不引整个 Gpu 工程）。
    /// </summary>
    internal readonly struct S2AFaultKey : IEquatable<S2AFaultKey>
    {
        private readonly ulong _v0, _v1, _v2, _v3, _v4, _v5;

        public S2AFaultKey(ulong v0, ulong v1, ulong v2, ulong v3, ulong v4, ulong v5)
        {
            _v0 = v0; _v1 = v1; _v2 = v2; _v3 = v3; _v4 = v4; _v5 = v5;
        }

        public bool Equals(S2AFaultKey other) =>
            _v0 == other._v0 && _v1 == other._v1 && _v2 == other._v2 &&
            _v3 == other._v3 && _v4 == other._v4 && _v5 == other._v5;

        public override bool Equals(object obj) => obj is S2AFaultKey other && Equals(other);

        public override int GetHashCode() => HashCode.Combine(_v0, _v1, _v2, _v3, _v4, _v5);
    }

    /// <summary>S2A：一页里解码器读过的字节区间 [Lo, Hi)。</summary>
    internal readonly struct S2AFaultPage
    {
        public readonly ulong Page;
        public readonly int Lo, Hi;

        public S2AFaultPage(ulong page, int lo, int hi)
        {
            Page = page; Lo = lo; Hi = hi;
        }
    }

    /// <summary>
    /// S2A：一次解码碰过的页与每页读过的字节区间。GpuAccessor.GetCode 每取一段调 Note（未映射那页也记），
    /// 解码失败时由 ShaderCache 取走，交给负缓存的 Arm 序列。区间只用来比内容：别的数据与本页共页、它那部分被改写不算本条目失效。
    /// </summary>
    internal sealed class S2AFaultProbe
    {
        public const int PageSize = 0x1000;

        private readonly Dictionary<ulong, (int lo, int hi)> _ranges = new();
        private readonly List<ulong> _order = new();

        /// <summary>整页。</summary>
        public void Note(ulong page) => Note(page, PageSize);

        /// <summary>[address, address + size) 覆盖的每一页记下读到的区间（同页多次取并成一段）。</summary>
        public void Note(ulong address, int size)
        {
            ulong end = address + (ulong)size;
            for (ulong page = address & ~(ulong)(PageSize - 1); page < end; page += PageSize)
            {
                int lo = (int)(Math.Max(address, page) - page);
                int hi = (int)(Math.Min(end, page + PageSize) - page);
                if (_ranges.TryGetValue(page, out (int lo, int hi) r)) _ranges[page] = (Math.Min(r.lo, lo), Math.Max(r.hi, hi));
                else { _ranges[page] = (lo, hi); _order.Add(page); }
            }
        }

        /// <summary>取走（取走即空，随后可以接着用于下一轮解码）。</summary>
        public S2AFaultPage[] Take()
        {
            S2AFaultPage[] pages = new S2AFaultPage[_order.Count];
            for (int i = 0; i < pages.Length; i++)
            {
                (int lo, int hi) = _ranges[_order[i]];
                pages[i] = new S2AFaultPage(_order[i], lo, hi);
            }
            _ranges.Clear();
            _order.Clear();
            return pages;
        }

        public static ulong[] PagesOf(S2AFaultPage[] pages)
        {
            ulong[] v = new ulong[pages.Length];
            for (int i = 0; i < v.Length; i++) v[i] = pages[i].Page;
            return v;
        }
    }

    /// <summary>
    /// S2A（#723 P1）：着色器取码失败的负缓存。同一地址再派发时直接交出上次的报错，不再解码。
    ///
    /// 失效三条件（任一成立即重试）：
    ///   ① 任一页被写过（写跟踪句柄 Dirty）且解码器读过的字节内容变了——精确到实际碰过的每一页，游戏只改第 N 页也认得出；
    ///      写了但读过的内容没变（同值重写、共页的别处被改）只重新武装、不失效（10-28 冷缓存实测这类占页脏失效的 53%）；
    ///   ② 映射代数号变了且逐页重翻译后物理地址与记录时不同（页被挪走）；
    ///   ③ 条目被淘汰（上限 4096，按最旧淘汰，句柄随之 Dispose）。
    /// 映射代数号变了但每页物理地址没变 → 不失效（别的 VA 改了映射，与这段代码无关）。
    ///
    /// 报红去重仍由两个调用方各自的集合（上限 64 组）负责，与此处无关。
    /// </summary>
    internal sealed class S2AShaderFaultCache : IDisposable
    {
        /// <summary>负缓存条目上限（报红仍限 64 组）。</summary>
        public const int Capacity = 4096;

        private sealed class Entry
        {
            public ulong[] Pages;    // 页对齐 GPU VA（含未映射页）
            public ulong[] Pas;      // 记录时各页的物理地址（未映射为 ulong.MaxValue）
            public IS2AFaultWatch[] Watches;
            public int Gen;
            public string Message;
            public long Seq;
        }

        private readonly Dictionary<ulong, Entry> _compute = new();
        private readonly Dictionary<S2AFaultKey, Entry> _graphics = new();
        private readonly object _lock = new();
        private long _seq;

        public void Dispose()
        {
            lock (_lock)
            {
                foreach (Entry entry in _compute.Values) DisposeAll(entry);
                foreach (Entry entry in _graphics.Values) DisposeAll(entry);
                _compute.Clear(); _graphics.Clear();
            }
        }

        /// <summary>计算着色器：命中（仍然有效）返回要抛的消息，否则 null。</summary>
        public string Check(ulong gpuVa, IS2AFaultHost host)
        {
            lock (_lock)
            {
                if (!_compute.TryGetValue(gpuVa, out Entry e)) return null;
                if (Valid(e, host)) return e.Message;
                _compute.Remove(gpuVa);   // 失效即摘：Rearm 已消费了脏位，留着会在下一次 Check 被当成有效
                DisposeAll(e);
                return null;
            }
        }

        /// <summary>图形着色器：同上。</summary>
        public string Check(S2AFaultKey key, IS2AFaultHost host)
        {
            lock (_lock)
            {
                if (!_graphics.TryGetValue(key, out Entry e)) return null;
                if (Valid(e, host)) return e.Message;
                _graphics.Remove(key);   // 失效即摘（同上）
                DisposeAll(e);
                return null;
            }
        }

        /// <summary>失败时记入（同键已有的旧条目连同其句柄一起作废）。</summary>
        public void Record(ulong gpuVa, IS2AFaultHost host, ulong[] pages, IS2AFaultWatch[] watches, string message)
        {
            lock (_lock)
            {
                if (_compute.Remove(gpuVa, out Entry old)) DisposeAll(old);
                if (RefuseIfDirty(watches)) return;
                EvictIfFull(_compute);
                _compute[gpuVa] = Make(host, pages, watches, message);
            }
        }

        /// <summary>失败时记入（图形）。</summary>
        public void Record(S2AFaultKey key, IS2AFaultHost host, ulong[] pages, IS2AFaultWatch[] watches, string message)
        {
            lock (_lock)
            {
                if (_graphics.Remove(key, out Entry old)) DisposeAll(old);
                if (RefuseIfDirty(watches)) return;
                EvictIfFull(_graphics);
                _graphics[key] = Make(host, pages, watches, message);
            }
        }

        /// <summary>解码成功：同一键的旧失败条目作废（游戏换了代码，这段现在解得开了）。</summary>
        public void Forget(ulong gpuVa)
        {
            lock (_lock)
            {
                if (_compute.Remove(gpuVa, out Entry e)) DisposeAll(e);
            }
        }

        /// <summary>解码成功：同上（图形）。</summary>
        public void Forget(S2AFaultKey key)
        {
            lock (_lock)
            {
                if (_graphics.Remove(key, out Entry e)) DisposeAll(e);
            }
        }

        /// <summary>条目数（单测用）。</summary>
        public int CountOf(ulong gpuVa) { lock (_lock) { return _compute.Count; } }
        public int CountOfGraphics() { lock (_lock) { return _graphics.Count; } }

        private bool Valid(Entry e, IS2AFaultHost host)
        {
            foreach (IS2AFaultWatch w in e.Watches)
            {
                if (w.Dirty && !w.Rearm()) return false;   // ① 页被写过且读过的内容变了（没变：Rearm 已重新武装）
            }

            int gen = host.MapGen;
            if (e.Gen == gen) return true;   // ② 代数号没变 ⇒ 翻译结果不变

            for (int i = 0; i < e.Pages.Length; i++)
            {
                if (host.TranslatePage(e.Pages[i]) != e.Pas[i]) return false;
            }

            e.Gen = gen;   // 页一个没挪：记下新代数号，免得之后每次命中都重翻一遍
            return true;
        }

        private Entry Make(IS2AFaultHost host, ulong[] pages, IS2AFaultWatch[] watches, string message)
        {
            ulong[] pas = new ulong[pages.Length];
            for (int i = 0; i < pages.Length; i++) pas[i] = host.TranslatePage(pages[i]);

            return new Entry
            {
                Pages = pages,
                Pas = pas,
                Watches = watches,
                Gen = host.MapGen,
                Message = message,
                Seq = ++_seq,
            };
        }

        private static void EvictIfFull<TKey>(Dictionary<TKey, Entry> map)
        {
            if (map.Count < Capacity) return;

            TKey oldest = default;
            long min = long.MaxValue;
            bool found = false;

            foreach (KeyValuePair<TKey, Entry> kv in map)
            {
                if (kv.Value.Seq < min)
                {
                    min = kv.Value.Seq;
                    oldest = kv.Key;
                    found = true;
                }
            }

            if (found && map.Remove(oldest, out Entry e)) DisposeAll(e);
        }

        private static void DisposeAll(Entry e)
        {
            foreach (IS2AFaultWatch w in e.Watches) w.Dispose();
        }

        /// <summary>武装到确认之间有页被写过：确认那次看到的内容未必是武装时记下的，不记（句柄释放，下次派发重来）。</summary>
        private static bool RefuseIfDirty(IS2AFaultWatch[] watches)
        {
            foreach (IS2AFaultWatch w in watches)
            {
                if (!w.Dirty) continue;
                foreach (IS2AFaultWatch x in watches) x.Dispose();
                return true;
            }
            return false;
        }
    }
}
