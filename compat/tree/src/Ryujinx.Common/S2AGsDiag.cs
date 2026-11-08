using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Text;
using System.Threading;

namespace Ryujinx.Common
{
    /// <summary>
    /// S2A（#1456，owner 批准）：几何补齐 / 原子访存 DeviceLost 的单点诊断。
    /// 记三类事实，好把「GS 补齐路径」与「描述符漏填」两种嫌疑分开：
    /// ① 宿主追加的直通几何来自哪个追加点（ShaderCache / 磁盘缓存加载器 / 转计算 Vtg）；
    /// ② 遮挡查询是否在飞（SamplesPassed 复位未报告的个数）；
    /// ③ 每次宿主提交里可作原子访存目标的客体 VA（SSBO + 可写镜像，记原值不对齐——漏填的 0x0 要看得见）。
    ///
    /// 门序与原生 s2a_debug_entries_open() 同口径：先查门再读条目，生产包不读不写。
    /// 「门」的判定只有原生一份（编译期 S2A_ANDROID_DEBUG_ENV + 系统属性两道，
    /// android/native/debug_gate.h）；原生层在封门时把结果注成
    /// S2A_DEBUG_ENTRIES=1 env（debug_environment.h seal），本类只读这份结果，
    /// 门开才读 S2A_GS_DIAG。玩家包编译期门就关、标记与 env 都不会有。
    /// </summary>
    public static class S2AGsDiag
    {
        /// <summary>单次提交最多记的原子面条数；溢出只记个数（诊断不拖慢提交）。</summary>
        private const int MaxEntriesPerSubmit = 32;

        /// <summary>崩前回放保留的最近提交行数——「崩前最后几次提交里 atomic 地址有没有 0」就靠这环答。</summary>
        private const int RecentSubmitsKept = 8;

        // 宿主测试可换：门判定与输出口；s_envProbes 让测试断言「门关时连 env 都没读」。
        internal static Func<bool> s_gateOpen = DefaultGateOpen;
        internal static Action<string> s_emit = line => Console.Error.WriteLine(line);
        internal static int s_envProbes;

        private static int _on = -1;   // -1 未查，0 关，1 开

        /// <summary>诊断是否打开：先过门，门开才读 S2A_GS_DIAG；查过一次就冻住（env 注入只在冷启动）。</summary>
        public static bool On => _on == 1 || (_on == -1 && Probe());

        private static bool Probe()
        {
            if (!s_gateOpen())
            {
                Volatile.Write(ref _on, 0);
                return false;
            }

            Interlocked.Increment(ref s_envProbes);
            int value = Environment.GetEnvironmentVariable("S2A_GS_DIAG") == "1" ? 1 : 0;
            Volatile.Write(ref _on, value);
            return value == 1;
        }

        private static bool DefaultGateOpen()
        {
            // 门的判定只有原生一份：s2a_debug_entries_open()（编译期 S2A_ANDROID_DEBUG_ENV + 系统属性
            // 两道，android/native/debug_gate.h）——原生层在封门时把门开的结果注成
            // S2A_DEBUG_ENTRIES=1 env（debug_environment.h seal，registerHost / create 前必跑）。
            // 这里只读这份结果、不自写属性判定：玩家包编译期门就关、标记不会出现；
            // 非安卓没有原生门与生产包通道，开发者自己设这个标记 = 自己授权。
            return Environment.GetEnvironmentVariable("S2A_DEBUG_ENTRIES") == "1";
        }

        private static readonly ConcurrentDictionary<string, int> _appendSites = new();
        private static int _occInFlight;
        private static readonly object _pendingLock = new();
        private static readonly List<(string Kind, ulong Va, ulong Size)> _pending = new(MaxEntriesPerSubmit);
        private static int _pendingDropped;
        private static ulong _submitSeq;
        private static readonly Queue<string> _recent = new(RecentSubmitsKept);   // _pendingLock 内读写

        /// <summary>① 直通几何追加点：ShaderCache 编译 / 磁盘缓存加载器 / 转计算 Vtg 各在追加处打一处。</summary>
        public static void NotePassthrough(string site)
        {
            if (!On)
            {
                return;
            }

            int count = _appendSites.AddOrUpdate(site, 1, static (_, c) => c + 1);
            s_emit($"[gpu] 【诊】宿主追加直通几何：来源={site} 该点累计={count} 遮挡查询在飞={OccText()}");
        }

        /// <summary>② 遮挡查询打开（SamplesPassed 复位）。</summary>
        public static void OccBegin()
        {
            if (On)
            {
                Interlocked.Increment(ref _occInFlight);
            }
        }

        /// <summary>② 遮挡查询关闭（SamplesPassed 报告）；报告可能比复位多，钳位不为负。</summary>
        public static void OccEnd()
        {
            if (!On)
            {
                return;
            }

            int value;
            do
            {
                value = Volatile.Read(ref _occInFlight);
                if (value <= 0)
                {
                    return;
                }
            }
            while (Interlocked.CompareExchange(ref _occInFlight, value - 1, value) != value);
        }

        /// <summary>③ 原子面登记：SSBO 与可写镜像绑定时记客体 VA（传进来的原值，不做对齐——漏填的 0x0 要看得见）。
        /// kind 是调用点字面量、stage 为着色器阶段号（无阶段传 -1）——字符串在门内才拼，关着零分配。</summary>
        public static void NoteAtomic(string kind, int stage, ulong va, ulong size)
        {
            if (!On)
            {
                return;
            }

            string label = stage < 0 ? kind : $"{kind}-s{stage}";

            lock (_pendingLock)
            {
                if (_pending.Count < MaxEntriesPerSubmit)
                {
                    _pending.Add((label, va, size));
                }
                else
                {
                    _pendingDropped++;
                }
            }
        }

        /// <summary>
        /// 宿主提交点（CommandBufferPool.Return）：把上次提交以来登记的原子面落成一行。
        /// 绑定在 GPU 线程、提交在渲染线程，「上次提交以来的绑定≈这次提交的」是近似口径；
        /// 同步写 stderr——崩的是这块 GPU，排队的行可能随进程一起没，落盘才算数。
        /// </summary>
        public static void Submit(int commandBufferIndex)
        {
            if (!On)
            {
                return;
            }

            List<(string Kind, ulong Va, ulong Size)> entries;
            int dropped;

            lock (_pendingLock)
            {
                entries = new List<(string Kind, ulong Va, ulong Size)>(_pending);
                dropped = _pendingDropped;
                _pending.Clear();
                _pendingDropped = 0;
            }

            ulong seq = Interlocked.Increment(ref _submitSeq);
            StringBuilder sb = new(256);
            sb.Append("[gpu] 【诊】提交 cb#").Append(commandBufferIndex)
              .Append(" 序").Append(seq)
              .Append(" 原子面=").Append(entries.Count);

            if (dropped != 0)
            {
                sb.Append("(+").Append(dropped).Append("溢出)");
            }

            foreach ((string kind, ulong va, ulong size) in entries)
            {
                sb.Append(' ').Append(kind).Append(":0x").Append(va.ToString("X"))
                  .Append("+0x").Append(size.ToString("X"));
            }

            sb.Append(" 遮挡查询在飞=").Append(OccText())
              .Append(" 直通几何追加=").Append(SitesText());

            string line = sb.ToString();
            lock (_pendingLock)
            {
                if (_recent.Count == RecentSubmitsKept)
                {
                    _recent.Dequeue();
                }

                _recent.Enqueue(line);
            }

            s_emit(line);
        }

        /// <summary>
        /// 崩前回放：宿主报 ErrorDeviceLost 时（VulkanException ThrowOnError 钩）把最近
        /// RecentSubmitsKept 次提交行原样重打一遍——stderr 行已按提交时序落过，但崩溃现场
        /// 滚屏 / 捞日志时「崩前最后几次提交的 atomic 地址有没有 0」要能一眼答上来。
        /// 门没开过（含门关时记不了行）就一行头都不打。
        /// </summary>
        public static void DumpLost()
        {
            if (!On)
            {
                return;
            }

            string[] replay;
            lock (_pendingLock)
            {
                replay = _recent.ToArray();
            }

            s_emit($"[gpu] 【诊】崩前回放：最近 {replay.Length} 次提交");
            foreach (string line in replay)
            {
                s_emit(line);
            }
        }

        private static string OccText()
        {
            int value = Volatile.Read(ref _occInFlight);
            return value > 0 ? $"开×{value}" : "关";
        }

        private static string SitesText()
        {
            if (_appendSites.IsEmpty)
            {
                return "无";
            }

            StringBuilder sb = new(64);
            foreach (KeyValuePair<string, int> kv in _appendSites)
            {
                if (sb.Length != 0)
                {
                    sb.Append(',');
                }

                sb.Append(kv.Key).Append('×').Append(kv.Value);
            }

            return sb.ToString();
        }

        /// <summary>宿主测试专用：全部状态与钩子复位到出厂；测试各自先调一次再装自己的门 / 输出。</summary>
        internal static void S2ATestReset()
        {
            s_gateOpen = DefaultGateOpen;
            s_emit = line => Console.Error.WriteLine(line);
            s_envProbes = 0;
            Volatile.Write(ref _on, -1);
            Interlocked.Exchange(ref _occInFlight, 0);
            _appendSites.Clear();
            Volatile.Write(ref _submitSeq, 0UL);

            lock (_pendingLock)
            {
                _pending.Clear();
                _pendingDropped = 0;
                _recent.Clear();
            }
        }
    }
}
