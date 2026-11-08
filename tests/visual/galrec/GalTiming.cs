// 渲染器调用耗时：录像 / 防护层每个 IRenderer / IPipeline / IWindow 调用转发给渲染器时计墙钟（单调时钟）。
// 嵌套调用（渲染器回调里又调渲染器）只计最外层；加载着色器缓存的工作线程也会调，按线程计深度、原子累加。
using System.Diagnostics;
using System.Threading;

namespace RyuJudge.GalRec
{
    public static class GalTiming
    {
        public static long RendererTicks;   // 全部渲染器调用（含下面两项）
        public static long FlushTicks;      // 其中等渲染器完成的：GetBufferData、WaitSync
        public static long ProgramTicks;    // 其中后端建程序：CreateProgram、LoadProgramBinary
        public static long Calls;

        [System.ThreadStatic] static int _depth;

        /// <summary>为假时不计时。缺省假（S2A_TIMING=1 才开）：10-19 测试机1 实测每次渲染器调用取两次时间戳占 GPU 线程 14.1%（mach_absolute_time 12.1% 自身），frames.tsv 的 renderer_us / flush_wait_us / prog_create_us 关时记 0。</summary>
        public static bool Enabled = true;

        /// <summary>本线程不计时（多线程渲染后端的渲染线程：GPU 线程那层已计过「等渲染器」的时间，渲染线程再计会重复）。</summary>
        [System.ThreadStatic] public static bool SuppressThisThread;

        // 关计时（缺省）时不碰线程静态变量：AOT 下每次 [ThreadStatic] 访问都要取线程静态区（10-19 真机渲染线程上与锁合计约 4%）
        public static long Begin() => !Enabled ? -2 : _depth++ == 0 && !SuppressThisThread ? Stopwatch.GetTimestamp() : -1;

        /// <param name="kind">0 普通，1 等完成，2 建程序</param>
        public static void End(long t0, int kind)
        {
            if (t0 == -2)
            {
                return;
            }

            _depth--;
            if (t0 < 0) return;
            long d = Stopwatch.GetTimestamp() - t0;
            Interlocked.Add(ref RendererTicks, d);
            Interlocked.Increment(ref Calls);
            if (kind == 1) Interlocked.Add(ref FlushTicks, d);
            else if (kind == 2) Interlocked.Add(ref ProgramTicks, d);
        }
    }
}
