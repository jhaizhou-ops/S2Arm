using System;
using System.Collections.Concurrent;

namespace Ryujinx.Graphics.GAL
{
    /// <summary>
    /// S2A（画幅线 10-24，GC gen1 晋升定因）：贴图数组绑定更新不再每次新建大数组。缺省开（10-24 总指挥批：测试机2 同局交替两局，GPU 线程分配 −62%、每帧分配 3742→3271 / 3063→2026 B、帧时不退）；S2A_TEXARR_REUSE=0 关。
    /// 塞尔达 iPhone 可操作阶段一个 GC 间隔 8.2 MB 分配里，TextureManager.CommitGraphicsBindings 占 3.2 MB、ITexture[] 2.1 MB 居首：
    /// 贴图池一改，TextureBindingsArrayCache 整条重建贴图数组条目，每次 new ISampler[数组长度] + ITexture[数组长度]；
    /// 双线程渲染 ThreadedTextureArray 再 ToArray() 复制一份进命令队列，渲染线程执行时 Select(...).ToArray() 又一份；宽屏包装层 Unwrap 再一份。
    /// 队列里那份活到渲染线程消费，赶上 gen0 就被晋升。
    /// 开关打开后：Gpu 层条目复用自己的数组；入队那份从这里的精确长度池取（下游按 .Length 取个数，不能给更长的），渲染线程原地换成底层对象、用完清空归还。
    /// </summary>
    public static class S2ATexArrReuse
    {
        // 开关：缺省开；S2A_TEXARR_REUSE=0 一直关、=1 一直开；没给且设了 S2A_ALT（同局交替，原生层 runtime/src/alt.c）时按相位开——开段开、关段 / MARK 前关。
        //   切换跨在入队与执行之间也安全：入队时开（池里取）、执行时关 → 那份照旧路径用完交给 GC；入队时关（ToArray 私有副本）、执行时开 → 原地改私有副本再归还
        static readonly string s_env = Environment.GetEnvironmentVariable("S2A_TEXARR_REUSE");
        static bool s_alt = !string.IsNullOrEmpty(Environment.GetEnvironmentVariable("S2A_ALT"));
        [System.Runtime.InteropServices.DllImport("s2a_native")] static extern int s2a_alt_phase();
        public static bool On
        {
            get
            {
                if (s_env == "0") return false;
                if (s_env == "1" || !s_alt) return true;
                try { return s2a_alt_phase() == 1; }
                catch (Exception) { s_alt = false; return true; }   // 回放器 / 单测等不在宿主里跑的进程：没有原生层、不交替，按缺省开
            }
        }

        // 图像数组也复用（帧率能耗线 10-24，缺省关：底层改动真机达标再翻）：S2A_IMGARR_REUSE=1 随 On；没给且设了 S2A_ALT 时按同局交替相位（开段开）；=0 一直关。
        //   原先图像数组整条每次新建三份：Gpu 层条目 new ITexture[]（双线程按引用入队，不能复用）、渲染线程 Select(...).ToArray()、宽屏 Unwrap 无暂存。
        //   打开后与贴图数组同法：入队那份是私有副本（池里取），Gpu 层条目就能复用自己的数组；执行时原地换底层对象再归还
        static readonly string s_imgEnv = Environment.GetEnvironmentVariable("S2A_IMGARR_REUSE");
        public static bool ImgOn => s_imgEnv == "1" ? On : s_imgEnv != "0" && On && AltOnPhase();
        // 双线程入队要不要给私有副本：开着要；交替时关段也要（ToArray）——相位可能在 Gpu 层取数组和入队之间翻，按引用入队的若是条目复用的数组会被下一次重建改掉。
        //   不交替又关着时照上游按引用入队，缺省路径不多一份
        public static bool ImgCopy => ImgOn || (s_alt && s_imgEnv != "0");
        static bool AltOnPhase()   // 同局交替的开段（与贴图数组的 S2A_TEXARR_REUSE 无关：给了 =1 也照相位交替图像数组）
        {
            if (!s_alt) return false;
            try { return s2a_alt_phase() == 1; }
            catch (Exception) { s_alt = false; return false; }
        }

        // 诊断（S2A_ALLOC_TRACE=1 时渲染循环 20 秒行打出累计）：ITexture[] / ISampler[] 各新建点的字节数（数组头 24 + 8 × 长度）
        //   0 池未命中 1 宽屏 Unwrap 2 双线程入队 ToArray（关时） 3 渲染线程 Select.ToArray（关时） 4 Gpu 条目复用路径新建（新条目 / 长度变） 5 Gpu 条目关时新建
        public static readonly long[] Diag = new long[6];
        public static void DiagAdd(int k, int n) => System.Threading.Interlocked.Add(ref Diag[k], 24 + 8L * n);

        /// <summary>双线程入队用的私有副本：<paramref name="on"/> 时池里取（执行完由命令归还），否则 ToArray。</summary>
        public static T[] Copy<T>(T[] a, bool on) where T : class
        {
            if (!on) { DiagAdd(2, a.Length); return (T[])a.Clone(); }
            T[] c = Rent<T>(a.Length);
            Array.Copy(a, c, a.Length);
            return c;
        }

        static class Pool<T> where T : class
        {
            // 长度 → 空闲数组。生产者是 GPU 模拟线程、消费者是渲染线程；每种长度留着的个数 = 队列里同时在途的最大份数，稳态不再分配
            internal static readonly ConcurrentDictionary<int, ConcurrentBag<T[]>> Free = new();
        }

        /// <summary>取一个长度恰为 n 的数组（内容为空）。</summary>
        public static T[] Rent<T>(int n) where T : class
        {
            if (n == 0) return Array.Empty<T>();
            if (Pool<T>.Free.TryGetValue(n, out var bag) && bag.TryTake(out var a)) return a;
            DiagAdd(0, n);
            return new T[n];
        }

        /// <summary>清空并归还 Rent 取的数组。</summary>
        public static void Return<T>(T[] a) where T : class
        {
            if (a == null || a.Length == 0) return;
            Array.Clear(a);
            Pool<T>.Free.GetOrAdd(a.Length, static _ => new ConcurrentBag<T[]>()).Add(a);
        }
    }
}
