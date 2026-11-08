using System;

namespace Ryujinx.Graphics.Gpu.Shader.DiskCache
{
    // S2Arm: the shader disk cache must never make the game wait for a batch recompile at boot. Upstream, when the cache
    // was written by another translator version (or a program's host code is missing), every affected program is
    // re-translated and re-compiled from guest code before the first frame (desktop shows a progress screen; 9000+
    // programs take minutes). Here such programs are dropped instead (the whole stale cache is deleted) and are
    // compiled on demand / taken from the offline library; each drop is reported red and counted.
    public static class S2AShaderCacheGuard
    {
        private static int _discarded;

        public static uint TranslatorVersion => DiskCacheHostStorage.CodeGenVersion;

        public static bool HasCurrentCode(string directory, out uint version)
        {
            version = DiskCacheHostStorage.S2AReadCodeGenVersion(directory);
            return version == TranslatorVersion;
        }

        /// <summary>
        /// Programs whose cached host binary was missing when the runtime state matched them, so they had to be compiled on demand
        /// (health table / tests). Stale specialization variants that the runtime never selects are not counted (10-27, #551).
        /// </summary>
        public static int Discarded => _discarded;

        /// <summary>
        /// S2A：着色器包种入磁盘缓存的程序数（graphics/loop/ShaderPack 装包时按包里 shared.toc 设）。缓存里序号小于它的条目是包内的（出包烘焙），
        /// 之后的是运行时追加的；首次命中核对不符时据此报「包内」或「缓存」特化不符。没有包 = 0
        /// </summary>
        public static int PackPrograms;

        /// <summary>
        /// S2A：提前热程序表路径（包里 shaders/pso_warm.tsv，出包 psowarm.py 写；graphics/loop/ShaderPack 确认缓存是本包种的之后设）。
        /// 每行「程序号\t首用帧\t函数名串」，按首用帧升序。磁盘缓存载完后后台线程按表把这些程序先交底层渲染器载入一次再放掉：
        /// 渲染器程序一建成就按管线首用表后台预取管线（graphics/metal/gal_state.m），换场景那帧不再在渲染线程上开片 / 取管线。没有表 = null
        /// </summary>
        public static string WarmList;

        /// <summary>
        /// S2A（#1411 / #1546 复审口径）：离线包种入后要不要报「读到 0 支」红。
        /// 种入 > 0 且装载索引 0 支时，唯一不报的结局是 StaleVersion——版本不符整批作废在装载时已按两边版本号 /
        /// 能力身份单独报红，再报「没读到」是误报。其余结局照报：Missing（文件缺失）与 null（装载没走到定结局处，
        /// 如 magic / FormatVersion 损坏抛异常被装载器接住）都算「读出问题」。
        /// </summary>
        internal static bool ShouldReportPackZero(int packPrograms, int loadedPrograms, ParallelDiskCacheLoader.S2ALoadOutcome? outcome)
            => packPrograms > 0 && loadedPrograms == 0 && outcome != ParallelDiskCacheLoader.S2ALoadOutcome.StaleVersion;

        public static void ResetSession()
        {
            _discarded = 0;
            PackPrograms = 0;
            WarmList = null;
        }

        internal static void Report(int count, string reason)
        {
            System.Threading.Interlocked.Add(ref _discarded, count);
            Console.Error.WriteLine($"[gal] 【红】着色器磁盘缓存作废 {count} 支（{reason}）：不在开局重编，改走离线库 + 按需");
        }
    }
}
