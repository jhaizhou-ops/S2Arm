// 短缓存重复描述符单测（#1364：歧路旅人 II 选人画面 AutoDeleteCache.AddShortCache 重复键 ArgumentException）。
// 被测：compat/tree/src/Ryujinx.Graphics.Gpu/Image/AutoDeleteCache.cs 的短缓存查找表。
// 复现：同一 TextureDescriptor 在查找表里还活着时再次 AddShortCache（另一张纹理，或同一纹理未先移除旧条目），
//   修前 _shortCacheLookup.Add 抛 ArgumentException，整会话失败；修后按原语义先移除旧条目再加入，引用计数不漂。
// 全部用真 GpuContext / PhysicalMemory / Texture / AutoDeleteCache；渲染器是 DispatchProxy 桩（不建任何宿主资源）。
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Gpu;
using Ryujinx.Graphics.Gpu.Image;
using Ryujinx.Graphics.Gpu.Memory;
using Ryujinx.Graphics.Texture;
using Ryujinx.Memory.Range;
using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;

public class StubProxy : DispatchProxy
{
    protected override object Invoke(MethodInfo m, object[] a)
    {
        Type t = m.ReturnType;
        if (t == typeof(void)) return null;
        if (t.IsInterface) return Create(t, typeof(StubProxy));
        return t.IsValueType ? Activator.CreateInstance(t) : null;
    }
}

static class Program
{
    static int _pass;
    static int _fail;

    static void Check(string name, bool ok, string detail = "")
    {
        if (ok) _pass++; else _fail++;
        Console.WriteLine($"{(ok ? "✓" : "✗")} {name}{(detail.Length > 0 ? "：" + detail : "")}");
    }

    static Texture NewTexture(GpuContext ctx, PhysicalMemory phys, ulong address)
    {
        TextureInfo info = new(
            address,
            64,
            64,
            1,
            1,
            1,
            1,
            0,
            false,
            1,
            1,
            1,
            Target.TextureBuffer,
            FormatInfo.Default);

        return new Texture(ctx, phys, info, new SizeInfo(0x1000), new MultiRange(address, 0x1000), TextureScaleMode.Eligible);
    }

    static int Main()
    {
        var ctx = new GpuContext((IRenderer)DispatchProxy.Create(typeof(IRenderer), typeof(StubProxy)), new Ryujinx.Common.Configuration.DirtyHacks(Array.Empty<ulong>()));
        var phys = new PhysicalMemory(ctx, null);

        TextureDescriptor d = default;
        d.Word0 = 0x12345678;
        d.Word1 = 0x00100000;
        d.Word7 = 0x00000001;

        // ① 另一张纹理带着同一描述符再次进入短缓存（本轮崩溃现场：描述符在 64 代窗口内被复用）
        {
            var cache = new AutoDeleteCache();
            var t1 = NewTexture(ctx, phys, 0x100000);
            var t2 = NewTexture(ctx, phys, 0x100000);
            t1.IncrementReferenceCount(); // 基线 1：模拟 AutoDeleteCache 之外所有者（池 / 使用方）持有的引用
            t2.IncrementReferenceCount();

            bool threw = false;
            try
            {
                cache.AddShortCache(t1, ref d);
                cache.ProcessShortCache();
                cache.ProcessShortCache();
                cache.ProcessShortCache();
                cache.AddShortCache(t2, ref d); // 修前：ArgumentException（同一描述符已在查找表）
            }
            catch (ArgumentException e)
            {
                threw = true;
                Console.WriteLine($"  插入异常：{e.GetType().Name}: {e.Message}");
            }

            Check("① 同描述符另一张纹理二次 AddShortCache 不抛", !threw);
            if (!threw)
            {
                Check("① 旧条目纹理引用计数回到基线 1", t1.S2ARefCount == 1, $"t1={t1.S2ARefCount}");
                Check("① 新条目纹理引用计数 = 基线 + 短缓存 1", t2.S2ARefCount == 2, $"t2={t2.S2ARefCount}");
                Check("① 查找表命中新条目（返回新纹理）", ReferenceEquals(cache.FindShortCache(d), t2));
                cache.RemoveShortCache(t2);
                Check("① 移除短缓存后新纹理引用计数回基线", t2.S2ARefCount == 1, $"t2={t2.S2ARefCount}");
            }
        }

        // ② 同一张纹理带着同一描述符再次进入（旧条目未先移除）
        {
            var cache = new AutoDeleteCache();
            var t = NewTexture(ctx, phys, 0x200000);
            t.IncrementReferenceCount();

            bool threw = false;
            try
            {
                cache.AddShortCache(t, ref d);
                cache.AddShortCache(t, ref d);
            }
            catch (ArgumentException e)
            {
                threw = true;
                Console.WriteLine($"  插入异常：{e.GetType().Name}: {e.Message}");
            }

            Check("② 同一纹理同描述符二次 AddShortCache 不抛", !threw);
            if (!threw)
            {
                Check("② 只保留一个短缓存引用（基线 + 1）", t.S2ARefCount == 2, $"ref={t.S2ARefCount}");
                Check("② 查找表仍命中该纹理", ReferenceEquals(cache.FindShortCache(d), t));
                cache.RemoveShortCache(t);
                Check("② 移除后引用计数回基线", t.S2ARefCount == 1, $"ref={t.S2ARefCount}");
                Check("② 移除后查找表为空", cache.FindShortCache(d) == null);
            }
        }

        // ③ 不同描述符互不影响（防止修复把别的描述符条目误删）
        {
            var cache = new AutoDeleteCache();
            var t1 = NewTexture(ctx, phys, 0x300000);
            var t2 = NewTexture(ctx, phys, 0x400000);
            t1.IncrementReferenceCount();
            t2.IncrementReferenceCount();

            TextureDescriptor d2 = d;
            d2.Word1 = 0x00400000;

            cache.AddShortCache(t1, ref d);
            cache.AddShortCache(t2, ref d2);
            Check("③ 两个描述符各自命中", ReferenceEquals(cache.FindShortCache(d), t1) && ReferenceEquals(cache.FindShortCache(d2), t2));
            Check("③ 两张纹理引用计数都正确", t1.S2ARefCount == 2 && t2.S2ARefCount == 2, $"t1={t1.S2ARefCount} t2={t2.S2ARefCount}");
        }

        // ④ 失效旧条目还在代集合里：它到期时不能误删同描述符的新查找项
        {
            var cache = new AutoDeleteCache();
            var stale = NewTexture(ctx, phys, 0x500000);
            var fresh = NewTexture(ctx, phys, 0x500000);
            stale.IncrementReferenceCount();
            fresh.IncrementReferenceCount();

            cache.AddShortCache(stale, ref d);
            cache.ProcessShortCache(); // 让新旧条目落在不同代，旧条目先到期
            stale.RemoveFromPools(false); // 失效序号 +1：FindShortCache 判定旧条目失效并只移出查找表，条目仍留代集合
            bool staleMiss = cache.FindShortCache(d) == null;
            cache.AddShortCache(fresh, ref d);
            Check("④ 失效旧条目被移出查找表、新条目接上", staleMiss && ReferenceEquals(cache.FindShortCache(d), fresh));

            bool kept = true;
            int ticks = 0;
            while (stale.S2ARefCount > 1 && ticks < 300)
            {
                cache.ProcessShortCache();
                ticks++;
                if (!ReferenceEquals(cache.FindShortCache(d), fresh))
                {
                    kept = false;
                    break;
                }
            }
            Check("④ 旧条目到期不误删新查找项", kept && stale.S2ARefCount == 1, $"ticks={ticks} stale={stale.S2ARefCount}");
            Check("④ 新条目仍命中", ReferenceEquals(cache.FindShortCache(d), fresh));
        }

        // ⑤ 同一纹理只被短缓存持有（ref=1）时同描述符二次 AddShortCache：
        //    不能先把它减到 0（RemoveTextureFromCache / Dispose）再加回来变成悬挂纹理。
        {
            var cache = new AutoDeleteCache();
            var t = NewTexture(ctx, phys, 0x600000);
            cache.AddShortCache(t, ref d); // 唯一持有者就是短缓存，ref=1

            var textures = (MultiRangeList<Texture>)typeof(TextureCache)
                .GetField("_textures", BindingFlags.Instance | BindingFlags.NonPublic)
                .GetValue(phys.TextureCache);
            textures.Add(t); // 模拟纹理本来就在贴图缓存里（真实路径由 FindOrCreateTexture 加入）

            var views = (List<Texture>)typeof(Texture)
                .GetField("_views", BindingFlags.Instance | BindingFlags.NonPublic)
                .GetValue(t);
            views.Add(t); // 引用归零时不触发 Dispose；本用例只核贴图缓存成员与引用计数

            bool threw = false;
            try
            {
                cache.AddShortCache(t, ref d);
            }
            catch (Exception e)
            {
                threw = true;
                Console.WriteLine($"  复入异常：{e.GetType().Name}: {e.Message}");
            }

            Check("⑤ 只被短缓存持有的纹理同描述符二次 AddShortCache 不抛", !threw);
            if (!threw)
            {
                Check("⑤ 纹理仍在贴图缓存（未被 RemoveTextureFromCache）", textures.Any(x => ReferenceEquals(x, t)));
                Check("⑤ 引用计数仍为 1（只有短缓存一份）", t.S2ARefCount == 1, $"ref={t.S2ARefCount}");
                Check("⑤ 查找表仍命中该纹理", ReferenceEquals(cache.FindShortCache(d), t));
                cache.RemoveShortCache(t);
                Check("⑤ 移除短缓存后引用计数归零", t.S2ARefCount == 0, $"ref={t.S2ARefCount}");
            }
        }

        Console.WriteLine($"gpu_shortcache：{_pass} 项通过、{_fail} 项失败");
        return _fail == 0 ? 0 : 1;
    }
}
