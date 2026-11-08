using Silk.NET.Vulkan;
using System;
using System.Threading;

namespace Ryujinx.Graphics.Vulkan
{
    /// <summary>
    /// S2A（#1360 候选 3）：建管线失败 / 程序未链接时，绘制或派发会被静默跳过。
    /// 这里只做计数与首例报红，不改变任何渲染行为；计数进 [vkpb] 管线创建汇总行。
    /// </summary>
    internal static class S2APipelineDiagnostics
    {
        private const int MaxExamples = 8;

        private static long _createFailures;
        private static long _unlinkedSkips;
        private static long _unlinkedGraphics;
        private static long _unlinkedCompute;
        private static long _feedbackHazardHits;
        private static long _feedbackColorHits;
        private static long _feedbackDepthHits;
        private static long _depthPassSplits;
        private static long _cacheImportBytes;
        private static string _cacheImportError = "未尝试";

        // 修⑦：texel 影子开销计数——建影子数 / 回写 flush 次数与段数 / 回写触发的 EndRenderPass 数。
        // 始终计数（Interlocked 便宜），汇总进 [vkpb] 行；S2A_TEXEL_DIAG=1 时每次回写打一行。
        private static long _texelShadows;
        private static long _texelWritebackFlushes;
        private static long _texelWritebackEntries;
        private static long _texelEndRenderPasses;

        internal static readonly bool TexelDiag = Environment.GetEnvironmentVariable("S2A_TEXEL_DIAG") == "1";

        /// <summary>S2A：驱动管线缓存导入结果（字节数 / null = 命中，非 null = 未命中原因），进 [vkpb] 汇总行。</summary>
        public static void ReportCacheImport(long bytes, string error)
        {
            Interlocked.Exchange(ref _cacheImportBytes, bytes);
            Volatile.Write(ref _cacheImportError, error);
        }

        public static void ReportCreateFailure(Result result, string pipelineKey, string shaderHashes)
        {
            long n = Interlocked.Increment(ref _createFailures);

            if (n <= MaxExamples)
            {
                Console.Error.WriteLine(
                    $"[vkpb] 【红】建图形管线失败 #{n}：VkResult={result}、管线 key={pipelineKey}、shader={shaderHashes}");
            }
            else if ((n & (n - 1)) == 0)
            {
                Console.Error.WriteLine(
                    $"[vkpb] 【红】建图形管线失败累计 {n} 次（前 {MaxExamples} 例已逐行列出，之后只计数）");
            }
        }

        public static void ReportUnlinkedSkip(PipelineBindPoint bindPoint, string where, string pipelineKey, string shaderHashes)
        {
            long n = Interlocked.Increment(ref _unlinkedSkips);

            if (bindPoint == PipelineBindPoint.Compute)
            {
                Interlocked.Increment(ref _unlinkedCompute);
            }
            else
            {
                Interlocked.Increment(ref _unlinkedGraphics);
            }

            if (n <= MaxExamples)
            {
                Console.Error.WriteLine(
                    $"[vkpb] 【红】程序未链接跳过 #{n}：{where}（{bindPoint}）、管线 key={pipelineKey}、shader={shaderHashes}");
            }
            else if ((n & (n - 1)) == 0)
            {
                Console.Error.WriteLine(
                    $"[vkpb] 【红】程序未链接跳过累计 {n} 次（前 {MaxExamples} 例已逐行列出，之后只计数）");
            }
        }

        public static void ReportFeedbackLoopHazards(
            FeedbackLoopAspects aspects, System.Collections.Generic.List<TextureView> hazards, string shaderHashes)
        {
            long n = Interlocked.Increment(ref _feedbackHazardHits);

            if ((aspects & FeedbackLoopAspects.Color) != 0)
            {
                Interlocked.Increment(ref _feedbackColorHits);
            }

            if ((aspects & FeedbackLoopAspects.Depth) != 0)
            {
                Interlocked.Increment(ref _feedbackDepthHits);
            }

            if (n <= MaxExamples)
            {
                TextureView first = hazards[0];
                Console.Error.WriteLine(
                    $"[vkpb] 【红】采样当前附件（feedback loop）#{n}：aspects={aspects}、hazard={hazards.Count}、" +
                    $"首例 {first.Info.Format}/{first.VkFormat} {first.Width}x{first.Height} " +
                    $"mode={first.Info.DepthStencilMode}、shader={shaderHashes}");
            }
            else if ((n & (n - 1)) == 0)
            {
                Console.Error.WriteLine(
                    $"[vkpb] 【红】采样当前附件（feedback loop）累计 {n} 次（前 {MaxExamples} 例已逐行列出，之后只计数）");
            }
        }

        public static void ReportDepthPassSplit(int hazards, TextureView first, string shaderHashes)
        {
            long n = Interlocked.Increment(ref _depthPassSplits);

            if (n <= MaxExamples)
            {
                Console.Error.WriteLine(
                    $"[vkpb] 深度反馈环拆通道 #{n}：hazard={hazards}、{first.Info.Format}/{first.VkFormat} " +
                    $"{first.Width}x{first.Height} mode={first.Info.DepthStencilMode}、shader={shaderHashes}");
            }
            else if ((n & (n - 1)) == 0)
            {
                Console.Error.WriteLine($"[vkpb] 深度反馈环拆通道累计 {n} 次");
            }
        }

        /// <summary>修⑦：新建一个未对齐 texel 影子。</summary>
        public static void ReportAlignedTexelShadow()
        {
            Interlocked.Increment(ref _texelShadows);
        }

        /// <summary>修⑦：影子填充 / 回写前被迫 EndRenderPass（代价所在）。</summary>
        public static void ReportAlignedTexelEndRenderPass()
        {
            Interlocked.Increment(ref _texelEndRenderPasses);
        }

        /// <summary>修⑦：一次 texel 写回落账（entries = 本次拷回段数）。</summary>
        public static void ReportAlignedTexelWriteback(int entries)
        {
            long flushes = Interlocked.Increment(ref _texelWritebackFlushes);
            long totalEntries = Interlocked.Add(ref _texelWritebackEntries, entries);

            if (TexelDiag)
            {
                Console.Error.WriteLine(
                    $"[vktex] 回写 {entries} 段（累计 flush {flushes} 次 / {totalEntries} 段、" +
                    $"影子 {Interlocked.Read(ref _texelShadows)} 建、EndRenderPass {Interlocked.Read(ref _texelEndRenderPasses)} 次）");
            }
        }

        public static string Summary()
        {
            long create = Interlocked.Read(ref _createFailures);
            long skips = Interlocked.Read(ref _unlinkedSkips);
            long graphics = Interlocked.Read(ref _unlinkedGraphics);
            long compute = Interlocked.Read(ref _unlinkedCompute);
            long feedback = Interlocked.Read(ref _feedbackHazardHits);
            long feedbackColor = Interlocked.Read(ref _feedbackColorHits);
            long feedbackDepth = Interlocked.Read(ref _feedbackDepthHits);
            long depthSplits = Interlocked.Read(ref _depthPassSplits);
            long cacheBytes = Interlocked.Read(ref _cacheImportBytes);
            string cacheError = Volatile.Read(ref _cacheImportError);
            string cache = cacheError == null ? $"驱动缓存导入 {cacheBytes} 字节（命中）"
                : $"驱动缓存导入 {cacheBytes} 字节（未命中：{cacheError}）";

            return $"建管线失败 {create}、未链接跳过 {skips}（图形 {graphics} / 计算 {compute}）、" +
                   $"反馈环采样附件 {feedback}（颜色 {feedbackColor} / 深度 {feedbackDepth}）、" +
                   $"深度反馈环拆通道 {depthSplits}、{cache}、" +
                   $"texel 影子 {Interlocked.Read(ref _texelShadows)} 建、" +
                   $"回写 {Interlocked.Read(ref _texelWritebackFlushes)} 次 {Interlocked.Read(ref _texelWritebackEntries)} 段、" +
                   $"回写触 EndRenderPass {Interlocked.Read(ref _texelEndRenderPasses)} 次";
        }
    }
}
