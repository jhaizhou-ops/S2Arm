using System;
using System.Diagnostics;
using System.Threading;

namespace Ryujinx.Graphics.GAL.Multithreading
{
    static class ThreadedHelpers
    {
        public static void SpinUntilNonNull<T>(ref T obj) where T : class
        {
            Span<SpinWait> spinWait = stackalloc SpinWait[1];

            while (obj == null)
            {
                spinWait[0].SpinOnce(-1);
            }
        }

        /// <summary>
        /// S2A：等渲染线程把对象建好。宿主自起线程且设了上限（ThreadedRenderer.S2AConfigureBounds）时有界：约每 50 ms 查一次失败闩与渲染线程有没有前进，
        /// 渲染线程卡住按失败处理（抛异常）；没设上限同原版
        /// </summary>
        public static void SpinUntilNonNull<T>(ref T obj, ThreadedRenderer renderer, string what) where T : class
        {
            if (!renderer.S2ABounded)
            {
                SpinUntilNonNull(ref obj);

                return;
            }

            Span<SpinWait> spinWait = stackalloc SpinWait[1];
            ThreadedRenderer.S2AStallWatch watch = renderer.S2AWatch();
            long slice = Stopwatch.Frequency / 20;
            long next = Stopwatch.GetTimestamp() + slice;

            while (obj == null)
            {
                spinWait[0].SpinOnce(-1);

                if (Stopwatch.GetTimestamp() >= next)
                {
                    renderer.S2ACheckStall(ref watch, what);
                    next = Stopwatch.GetTimestamp() + slice;
                }
            }
        }

        public static void SpinUntilExchange(ref int target, int value, int comparand)
        {
            Span<SpinWait> spinWait = stackalloc SpinWait[1];

            while (Interlocked.CompareExchange(ref target, value, comparand) != comparand)
            {
                spinWait[0].SpinOnce(-1);
            }
        }
    }
}
