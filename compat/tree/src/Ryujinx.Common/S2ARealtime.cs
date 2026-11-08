using System;
using System.Runtime.InteropServices;

namespace Ryujinx.Common
{
    /// <summary>
    /// S2Arm: real-time (time-constraint) scheduling for the calling thread on Apple platforms.
    /// </summary>
    /// <remarks>
    /// The audio renderer must hand a 5 ms period to the device every 5 ms. Its threads were plain .NET threads (QoS default) while the
    /// game threads run user-interactive, so under load they were not scheduled for tens of ms at a time: 10-22 acnh on Mac, the loop
    /// was 27–34 ms late at each catch-up (thread handoff and preempted renders, not the work itself: render ≤ 3 ms), the processor
    /// dropped up to 946 periods per 10 s and the device played that much silence (crackle on iPhone too). CoreAudio's own IO threads
    /// use this policy; a thread that overruns its computation budget is demoted by the kernel, so a bug cannot starve the system.
    /// Cost (10-24 direct-mode acnh on iPhone): Apple schedules time-constraint threads on performance cores only, so the 0.13-core
    /// renderer loop sat 100% on P-cores for ~0.12 W. S2A_AUDIO_SCHED=utility instead gives the thread QoS utility (efficiency cores,
    /// not real-time) for an A/B against underruns: the device keeps ≥ 70 ms in flight, so a 5 ms period only has to be met on average.
    /// </remarks>
    public static partial class S2ARealtime
    {
        private const int ThreadTimeConstraintPolicy = 2;
        private const uint ThreadTimeConstraintPolicyCount = 4;

        [StructLayout(LayoutKind.Sequential)]
        private struct TimeConstraintPolicy
        {
            public uint Period;
            public uint Computation;
            public uint Constraint;
            public int Preemptible;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct MachTimebaseInfo
        {
            public uint Numer;
            public uint Denom;
        }

        [LibraryImport("libc")]
        private static partial uint mach_thread_self();

        [LibraryImport("libc")]
        private static partial int mach_port_deallocate(uint task, uint name);

        [LibraryImport("libc")]
        private static partial int thread_policy_set(uint thread, int flavor, ref TimeConstraintPolicy policy, uint count);

        [LibraryImport("libc")]
        private static partial int mach_timebase_info(out MachTimebaseInfo info);

        [LibraryImport("libc")]
        private static partial uint task_self_trap();

        [LibraryImport("libc")]
        private static partial int pthread_set_qos_class_self_np(uint qosClass, int relativePriority);

        private const uint QosClassUtility = 0x11;
        private const uint QosClassUserInteractive = 0x21;

        // S2A_AUDIO_SCHED=utility / interactive：不设实时调度，只给该档 QoS（10-25 Air 马车8 直连：utility 每 10 秒断供 25–30 次、渲染丢 285 周期，不可用）
        private static readonly string Sched = Environment.GetEnvironmentVariable("S2A_AUDIO_SCHED");

        /// <summary>
        /// Make the calling thread real-time: every <paramref name="periodNs"/> it needs up to <paramref name="computationNs"/> of CPU,
        /// done within <paramref name="constraintNs"/>. Returns the kernel result (0 = applied); does nothing off Apple platforms.
        /// </summary>
        public static int Promote(string who, long periodNs, long computationNs, long constraintNs)
        {
            if (!OperatingSystem.IsMacOS() && !OperatingSystem.IsIOS())
            {
                return -1;
            }

            if (Sched == "utility" || Sched == "interactive")
            {
                int qrc = pthread_set_qos_class_self_np(Sched == "utility" ? QosClassUtility : QosClassUserInteractive, 0);

                Console.Error.WriteLine($"[S2A 声音] {who}：QoS {Sched}{(qrc == 0 ? "已设" : $"没设上（rc {qrc}）")}（不设实时调度，S2A_AUDIO_SCHED={Sched}）");

                return qrc;
            }

            mach_timebase_info(out MachTimebaseInfo tb);

            uint Ticks(long ns) => (uint)(ns * tb.Denom / tb.Numer);

            TimeConstraintPolicy p = new()
            {
                Period = Ticks(periodNs),
                Computation = Ticks(computationNs),
                Constraint = Ticks(constraintNs),
                Preemptible = 1,
            };

            uint self = mach_thread_self();
            int rc = thread_policy_set(self, ThreadTimeConstraintPolicy, ref p, ThreadTimeConstraintPolicyCount);
            mach_port_deallocate(task_self_trap(), self);

            Console.Error.WriteLine($"[S2A 声音] {who}：实时调度{(rc == 0 ? "已设" : $"没设上（rc {rc}）")}（周期 {periodNs / 1e6:F1} ms、计算 {computationNs / 1e6:F1} ms、期限 {constraintNs / 1e6:F1} ms）");

            return rc;
        }
    }
}
