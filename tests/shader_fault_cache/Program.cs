// #723 P1 着色器取码失败负缓存单测。期望值全部手算（不跑被测实现推期望）；退出码 = 失败项数。
//
// 覆盖的是 S2AShaderFaultCache 的判定（Check / Record / Forget / 失效三条件 / 淘汰），
// 外加一段「照 ShaderCache 的调用序列写的镜像」验证第二次派发不再调解码器。
// 注意：镜像不是 ShaderCache 本体（那要 GpuContext），真实接线由真机 / 列车的解码次数读数验证，见 result.md。
using System;
using System.Collections.Generic;
using Ryujinx.Graphics.Gpu.Shader;

static class T
{
    static int total, fails;

    static void Check(string name, object want, object got)
    {
        total++;
        bool ok = Equals(want, got);
        if (!ok) fails++;
        Console.WriteLine($"{(ok ? "过" : "✖")}  {name}：期望 {want} → 真结果 {got}");
    }

    sealed class FakeWatch : IS2AFaultWatch
    {
        public bool Dirty = true;   // 与真句柄一致：Ryujinx RegionHandle 新建即脏（RegionHandle.cs「Dirty = mapped」），要靠 Arm 清掉
        public int Disposed;
        public ulong Content;       // 这页被读区间的内容（用一个数代表）
        public ulong Armed;         // 武装时记下的内容
        public bool IsDirty => Dirty;
        bool IS2AFaultWatch.Dirty => Dirty;
        public bool Rearm() { Dirty = false; return Content == Armed; }   // 镜像 S2AFaultWatchOf.Rearm：先重新武装再比内容
        public void Dispose() => Disposed++;
    }

    sealed class FakeHost : IS2AFaultHost
    {
        public int Gen;
        public readonly Dictionary<ulong, ulong> Pa = new();
        public readonly Dictionary<ulong, FakeWatch> Watches = new();
        public int MapGen => Gen;

        public ulong TranslatePage(ulong page) => Pa.TryGetValue(page, out ulong v) ? v : ulong.MaxValue;

        public IS2AFaultWatch Arm(ulong page, int lo, int hi)
        {
            // 未映射页不武装（与 S2AFaultHostOf 同规则）
            if (TranslatePage(page) == ulong.MaxValue) return null;
            if (!Watches.TryGetValue(page, out FakeWatch w)) Watches[page] = w = new FakeWatch();
            w.Dirty = false;   // 镜像 S2AFaultHostOf.Arm 的 handle.Reprotect()：清掉新建即有的脏位、武装，之后一写才脏
            w.Armed = w.Content;   // 记下读过区间的内容
            return w;
        }

        public void Map(ulong page, ulong pa) { Pa[page] = pa; Gen++; }
    }

    // 照 ShaderCache 计算路径的调用序列写的镜像：先查负缓存，再解码；失败则武装页、确认解码一次，碰的页都在范围内就记入
    static string DecodeThroughCache(S2AShaderFaultCache cache, FakeHost host, ulong va, Action<S2AFaultProbe, int> decode, ref int decodes)
    {
        string fault = cache.Check(va, host);
        if (fault != null) return fault;

        S2AFaultProbe probe = new();
        try
        {
            decode(probe, ++decodes);
            cache.Forget(va);
            return null;
        }
        catch (InvalidOperationException e)
        {
            S2AFaultPage[] pages = probe.Take();
            var watches = new List<IS2AFaultWatch>();
            foreach (S2AFaultPage p in pages) { var w = host.Arm(p.Page, p.Lo, p.Hi); if (w != null) watches.Add(w); }

            S2AFaultProbe probe2 = new();
            try
            {
                decode(probe2, ++decodes);
                cache.Forget(va);
                return null;
            }
            catch (InvalidOperationException e2)
            {
                if (Covers(probe2.Take(), pages)) cache.Record(va, host, S2AFaultProbe.PagesOf(pages), watches.ToArray(), e.Message);
                return e2.Message;
            }
        }
    }

    static bool Covers(S2AFaultPage[] pages, S2AFaultPage[] armed)
    {
        var set = new HashSet<ulong>(S2AFaultProbe.PagesOf(armed));
        foreach (S2AFaultPage p in pages) if (!set.Contains(p.Page)) return false;
        return true;
    }

    const ulong Va = 0x8ec1d8_0000UL;
    const ulong P0 = Va, P1 = Va + 0x1000, P2 = Va + 0x2000, P3 = Va + 0x3000;
    const string Msg = "S2A: shader code fetch exceeded 256 pages (at GPU VA 0x8EC1D80000)";

    static int Main()
    {
        // ---------- ① 同一地址失败两次，第二次不调解码器（任务要求的核心行为） ----------
        {
            var host = new FakeHost { Gen = 1 };
            host.Pa[P0] = 0x10_0000; host.Pa[P1] = 0x10_1000; host.Pa[P2] = 0x10_2000;
            var cache = new S2AShaderFaultCache();
            int decodes = 0;
            Action<S2AFaultProbe, int> boom = (probe, _) => { probe.Note(P0); probe.Note(P1); probe.Note(P2); probe.Note(P3); throw new InvalidOperationException(Msg); };

            string f1 = DecodeThroughCache(cache, host, Va, boom, ref decodes);
            Check("① 第一次失败：交出解码器消息", Msg, f1);
            Check("① 第一次失败：解码器跑了 2 次（原始 + 确认）", 2, decodes);

            string f2 = DecodeThroughCache(cache, host, Va, boom, ref decodes);
            Check("① 第二次派发：直接抛上次的消息", Msg, f2);
            Check("① 第二次派发：解码器一次都没跑（仍 2）", 2, decodes);
        }

        // ---------- ② 游戏改了第 N 页（N = 3，不是首页）→ 条目作废、重新解码 ----------
        {
            var host = new FakeHost { Gen = 1 };
            host.Pa[P0] = 0x10_0000; host.Pa[P1] = 0x10_1000; host.Pa[P2] = 0x10_2000; host.Pa[P3] = 0x10_3000;
            var cache = new S2AShaderFaultCache();
            int decodes = 0;
            Action<S2AFaultProbe, int> boom = (probe, _) => { probe.Note(P0); probe.Note(P1); probe.Note(P2); probe.Note(P3); throw new InvalidOperationException(Msg); };
            DecodeThroughCache(cache, host, Va, boom, ref decodes);

            host.Watches[P3].Dirty = true; host.Watches[P3].Content = 1;   // 只写第 3 页，且读过的内容变了
            Check("② 只写第 3 页 → 失效（不是只比首页）", null, cache.Check(Va, host));

            DecodeThroughCache(cache, host, Va, boom, ref decodes);
            Check("② 失效后重试：解码器又跑了 2 次（共 4）", 4, decodes);
        }

        // ---------- ③ 映射代数号变了但物理地址没变 → 仍然命中 ----------
        {
            var host = new FakeHost { Gen = 1 };
            host.Pa[P0] = 0x10_0000;
            var cache = new S2AShaderFaultCache();
            cache.Record(Va, host, new[] { P0 }, Array.Empty<IS2AFaultWatch>(), Msg);
            host.Gen = 7;   // 别的 VA 改了映射
            Check("③ 代数号变、物理地址不变 → 不失效", Msg, cache.Check(Va, host));
        }

        // ---------- ④ 映射代数号变了且某页被挪走 → 失效 ----------
        {
            var host = new FakeHost { Gen = 1 };
            host.Pa[P0] = 0x10_0000; host.Pa[P1] = 0x10_1000;
            var cache = new S2AShaderFaultCache();
            cache.Record(Va, host, new[] { P0, P1 }, Array.Empty<IS2AFaultWatch>(), Msg);
            host.Map(P1, 0x20_0000);   // 第 1 页挪走
            Check("④ 代数号变 + 一页物理地址变 → 失效", null, cache.Check(Va, host));
        }

        // ---------- ⑤ 未映射页：被映射上（代数号变、物理地址从 MaxValue 变成实际值）→ 失效 ----------
        {
            var host = new FakeHost { Gen = 1 };
            host.Pa[P0] = 0x10_0000;   // P1 未映射
            var cache = new S2AShaderFaultCache();
            cache.Record(Va, host, new[] { P0, P1 }, Array.Empty<IS2AFaultWatch>(), Msg);
            host.Map(P1, 0x30_0000);
            Check("⑤ 未映射页后来被映射上 → 失效（合法新代码会重试）", null, cache.Check(Va, host));
        }

        // ---------- ⑥ 解码成功 → Forget → 再失败会重试 ----------
        {
            var host = new FakeHost { Gen = 1 };
            host.Pa[P0] = 0x10_0000;
            var cache = new S2AShaderFaultCache();
            cache.Record(Va, host, new[] { P0 }, Array.Empty<IS2AFaultWatch>(), Msg);
            cache.Forget(Va);
            Check("⑥ Forget 后不再命中", null, cache.Check(Va, host));
        }

        // ---------- ⑦ 上限 4096：满了按最旧淘汰，被淘汰条目的句柄 Dispose、不再命中 ----------
        {
            var host = new FakeHost { Gen = 1 };
            var cache = new S2AShaderFaultCache();
            var firstWatch = new FakeWatch { Dirty = false };   // 已武装（Arm 过）的句柄
            host.Pa[P0] = 0x10_0000;
            cache.Record(1, host, new[] { P0 }, new IS2AFaultWatch[] { firstWatch }, Msg);
            for (ulong k = 2; k <= (ulong)S2AShaderFaultCache.Capacity; k++) cache.Record(k, host, new[] { P0 }, Array.Empty<IS2AFaultWatch>(), Msg);
            Check("⑦ 条数 = 上限", S2AShaderFaultCache.Capacity, cache.CountOf(1));
            Check("⑦ 最旧那条仍在（还没超）", Msg, cache.Check(1, host));

            cache.Record((ulong)S2AShaderFaultCache.Capacity + 1, host, new[] { P0 }, Array.Empty<IS2AFaultWatch>(), Msg);
            Check("⑦ 再插一条：最旧被淘汰", null, cache.Check(1, host));
            Check("⑦ 被淘汰条目的句柄被 Dispose 一次", 1, firstWatch.Disposed);
            Check("⑦ 淘汰后条数仍是上限", S2AShaderFaultCache.Capacity, cache.CountOf((ulong)S2AShaderFaultCache.Capacity + 1));
            Check("⑦ 新条目在", Msg, cache.Check((ulong)S2AShaderFaultCache.Capacity + 1, host));
        }

        // ---------- ⑧ 图形键：不同地址组不互相命中（计算 / 图形、图形 / 图形都分开） ----------
        {
            var host = new FakeHost { Gen = 1 };
            host.Pa[P0] = 0x10_0000;
            var cache = new S2AShaderFaultCache();
            var k1 = new S2AFaultKey(1, 2, 3, 4, 5, 6);
            var k2 = new S2AFaultKey(1, 2, 3, 4, 5, 7);
            cache.Record(k1, host, new[] { P0 }, Array.Empty<IS2AFaultWatch>(), Msg);
            Check("⑧ 图形：同键命中", Msg, cache.Check(k1, host));
            Check("⑧ 图形：差一个阶段的键不命中", null, cache.Check(k2, host));
            Check("⑧ 计算表不被图形键污染", null, cache.Check(Va, host));
        }

        // ---------- ⑨ 同键重记：旧条目的句柄被释放，不泄漏 ----------
        {
            var host = new FakeHost { Gen = 1 };
            host.Pa[P0] = 0x10_0000;
            var cache = new S2AShaderFaultCache();
            var w1 = new FakeWatch { Dirty = false };   // 已武装的句柄
            cache.Record(Va, host, new[] { P0 }, new IS2AFaultWatch[] { w1 }, Msg);
            cache.Record(Va, host, new[] { P0 }, Array.Empty<IS2AFaultWatch>(), Msg + "（第二次）");
            Check("⑨ 同键重记：旧句柄释放一次", 1, w1.Disposed);
            Check("⑨ 同键重记：消息取新的", Msg + "（第二次）", cache.Check(Va, host));
        }

        // ---------- ⑩ 句柄新建即脏（镜像真 RegionHandle）：Arm 必须清掉；之后不写，第二次 Check 必须命中 ----------
        //   10-28 冷缓存真局抓到的缺陷：S2AFaultHostOf.Arm 没 Reprotect，条目一记进去就按「页被写过」作废，命中恒 0。
        {
            var host = new FakeHost { Gen = 1 };
            host.Pa[P0] = 0x10_0000; host.Pa[P1] = 0x10_1000;
            var cache = new S2AShaderFaultCache();
            var watches = new List<IS2AFaultWatch> { host.Arm(P0, 0, 0x1000), host.Arm(P1, 0, 0x1000) };
            Check("⑩ 新建句柄初值为脏（镜像真句柄）", true, new FakeWatch().IsDirty);
            Check("⑩ Arm 后句柄不脏", false, host.Watches[P0].IsDirty);
            cache.Record(Va, host, new[] { P0, P1 }, watches.ToArray(), Msg);
            Check("⑩ Arm 后不写：第一次 Check 命中", Msg, cache.Check(Va, host));
            Check("⑩ Arm 后不写：第二次 Check 仍命中", Msg, cache.Check(Va, host));
        }

        // ---------- ⑪ 页被写了但读过的内容没变（同值重写 / 共页别处被改）→ 重新武装、仍命中 ----------
        //   10-28 冷缓存实测：页脏失效里 53% 内容与武装时完全相同，这一类不该重解。
        {
            var host = new FakeHost { Gen = 1 };
            host.Pa[P0] = 0x10_0000; host.Pa[P1] = 0x10_1000;
            var cache = new S2AShaderFaultCache();
            int decodes = 0;
            Action<S2AFaultProbe, int> boom = (probe, _) => { probe.Note(P0); probe.Note(P1); throw new InvalidOperationException(Msg); };
            DecodeThroughCache(cache, host, Va, boom, ref decodes);
            host.Watches[P1].Dirty = true;   // 写了第 1 页，内容没变
            Check("⑪ 写了但内容没变 → 仍命中", Msg, cache.Check(Va, host));
            Check("⑪ 命中时已重新武装（句柄不脏）", false, host.Watches[P1].IsDirty);
            Check("⑪ 再派发不解码（仍 2）", 2, DecodeThroughCache(cache, host, Va, boom, ref decodes) == Msg ? decodes : -1);
        }

        // ---------- ⑫ 页被写且读过的内容变了 → 失效、重解、按新内容重记 ----------
        {
            var host = new FakeHost { Gen = 1 };
            host.Pa[P0] = 0x10_0000; host.Pa[P1] = 0x10_1000;
            var cache = new S2AShaderFaultCache();
            int decodes = 0;
            Action<S2AFaultProbe, int> boom = (probe, _) => { probe.Note(P0); probe.Note(P1); throw new InvalidOperationException(Msg); };
            DecodeThroughCache(cache, host, Va, boom, ref decodes);
            host.Watches[P1].Dirty = true; host.Watches[P1].Content = 7;
            Check("⑫ 写了且内容变 → 失效", null, cache.Check(Va, host));
            DecodeThroughCache(cache, host, Va, boom, ref decodes);
            Check("⑫ 失效后重试：解码器又跑 2 次（共 4）", 4, decodes);
            Check("⑫ 重记后按新内容命中", Msg, cache.Check(Va, host));
        }

        // ---------- ⑬ Record 时句柄已脏（武装到确认之间有写）→ 不记、句柄释放 ----------
        {
            var host = new FakeHost { Gen = 1 };
            host.Pa[P0] = 0x10_0000;
            var cache = new S2AShaderFaultCache();
            var w = (FakeWatch)host.Arm(P0, 0, 0x1000);
            w.Dirty = true;
            cache.Record(Va, host, new[] { P0 }, new IS2AFaultWatch[] { w }, Msg);
            Check("⑬ 记入时已脏 → 不记（Check 为空）", null, cache.Check(Va, host));
            Check("⑬ 句柄释放一次", 1, w.Disposed);
            Check("⑬ 条数 0", 0, cache.CountOf(Va));
        }

        // ---------- ⑭ 探针：按 GetCode 的 address / size 记读过的区间，同页并段、跨页拆开 ----------
        {
            var probe = new S2AFaultProbe();
            probe.Note(P0 + 0x40, 0x100);     // P0 [0x40, 0x140)
            probe.Note(P0 + 0x800, 0x1000);   // P0 [0x800, 0x1000) + P1 [0, 0x800)
            probe.Note(P0 + 0x20, 0x10);      // P0 并成 [0x20, 0x1000)
            S2AFaultPage[] pages = probe.Take();
            Check("⑭ 两页", 2, pages.Length);
            Check("⑭ 首页区间 lo", 0x20, pages[0].Lo);
            Check("⑭ 首页区间 hi", 0x1000, pages[0].Hi);
            Check("⑭ 第二页是 P1", P1, pages[1].Page);
            Check("⑭ 第二页区间", (0, 0x800), (pages[1].Lo, pages[1].Hi));
            Check("⑭ 取走即空", 0, probe.Take().Length);
        }

        Console.WriteLine($"负缓存单测：{total} 项，失败 {fails} 项");
        return fails;
    }
}
