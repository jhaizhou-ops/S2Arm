// F4.4：managed owner 控制循环。native 的 provider.poll 是“仅 owner”的控制片入口；本类就是它的
// 实际调用者——在 direct 会话 Active 期间持续调用，把需求编译在途/执行包挂起时的窗口与 Stop
// 事件推进到 native owner，而不是让 draw 自己等编译时没有任何控制轮询。
//
// 约束：
//   * 单实例、单线程；重复 Start 在旧循环退出前明确拒绝（返回 Stopped/Argument），不能并行两个 owner；
//   * 关闭有界：Stop(budget) 只等预算内退出，退出不了如实返回 false，不 Join 到天荒地老；
//     调用方在 false 时不得继续 Destroy native context（线程可能还在里面）；
//   * poll 的 PENDING 是正常状态，不是失败；负码按失败记录一次并通知调用方；
//   * 会话返回 STOPPED 是正常终点（Stop 已收尾），不当错误打印。
using System;
using System.Threading;

namespace S2A.Android.Aot
{
    public sealed class DirectOwnerLoop
    {
        public const uint SliceMs = 10;
        // 与 native 收尾预算对齐：compile worker 有界 Stop 为 1 s、外壳 detach 期限 1 s；
        // owner 循环正常在收到 STOPPED 后立刻退出，这个预算只约束“poll 卡在驱动调用”的病态路径。
        public const int DefaultStopBudgetMs = 1000;

        private Thread _thread;
        private DirectSession _session;
        private Action<int, string> _onFailure;
        private volatile bool _exitRequested;
        private volatile bool _running;
        private long _exitDeadlineTicks;
        private long _slices, _pendingSlices;

        /// <summary>已执行的控制片数。</summary>
        public long Slices => Interlocked.Read(ref _slices);
        /// <summary>返回 PENDING 的控制片数（需求编译在途或执行包挂起）。</summary>
        public long PendingSlices => Interlocked.Read(ref _pendingSlices);
        /// <summary>失败码（0 = 无失败；STOPPED 不算失败）。</summary>
        public int LastError { get; private set; }
        public string LastFailure { get; private set; } = string.Empty;
        public string StopReason { get; private set; } = string.Empty;
        /// <summary>循环是否因 Stop 预算耗尽而退出（此时可能没有完全停止）。</summary>
        public bool TimedOut { get; private set; }
        public bool Running => _running;

        /// <summary>启动 owner 循环；会话必须已经 Activate。失败返回负码，不创建半套线程。</summary>
        public int Start(DirectSession session, Action<int, string> onFailure = null)
        {
            if (session == null) return DirectAbi.Argument;
            if (!session.Activated) return DirectAbi.Argument;
            if (_running || (_thread != null && _thread.IsAlive)) return DirectAbi.Stopped;
            _session = session;
            _onFailure = onFailure;
            _exitRequested = false;
            _exitDeadlineTicks = 0;
            LastError = 0;
            LastFailure = string.Empty;
            StopReason = string.Empty;
            TimedOut = false;
            Interlocked.Exchange(ref _slices, 0);
            Interlocked.Exchange(ref _pendingSlices, 0);
            _running = true;
            try
            {
                _thread = new Thread(Run) { IsBackground = true, Name = "s2a-direct-owner" };
                _thread.Start();
            }
            catch (Exception error)
            {
                _running = false;
                _thread = null;
                LastError = DirectAbi.Internal;
                LastFailure = "owner loop thread creation failed: " + error.Message;
                Console.Error.WriteLine("[s2a] direct owner loop: " + LastFailure);
                return DirectAbi.Internal;
            }
            return DirectAbi.Ok;
        }

        /// <summary>
        /// 请求退出并记录预算：循环继续 poll 到会话 STOPPED 或预算耗尽。只发请求，不等待。
        /// </summary>
        public void RequestExit(int budgetMs = DefaultStopBudgetMs)
        {
            if (budgetMs < 0) budgetMs = 0;
            Interlocked.Exchange(ref _exitDeadlineTicks, Environment.TickCount64 + budgetMs);
            _exitRequested = true;
        }

        /// <summary>
        /// 有界关闭：最多等 budgetMs。返回 true = 线程确实已退出，可以安全 Destroy native context；
        /// false = 仍在 poll（例如驱动调用卡住），调用方必须保留上下文、跳过 Destroy 并如实报错。
        /// </summary>
        public bool Stop(int budgetMs = DefaultStopBudgetMs)
        {
            RequestExit(budgetMs);
            Thread thread = _thread;
            if (thread == null) return true;
            if (!thread.IsAlive)
            {
                _thread = null;
                _running = false;
                return true;
            }
            if (!thread.Join(budgetMs < 0 ? 0 : budgetMs))
            {
                Console.Error.WriteLine(
                    "[s2a] direct owner loop: still running after " + budgetMs + " ms; native context must be retained");
                return false;
            }
            _thread = null;
            _running = false;
            return true;
        }

        private void Run()
        {
            int failure = 0;
            string reason = "stopped";
            try
            {
                for (;;)
                {
                    if (_exitRequested)
                    {
                        long deadline = Interlocked.Read(ref _exitDeadlineTicks);
                        if (deadline != 0 && Environment.TickCount64 >= deadline)
                        {
                            TimedOut = true;
                            reason = "stop budget exhausted";
                            break;
                        }
                    }
                    int rc = _session.Poll(SliceMs);
                    Interlocked.Increment(ref _slices);
                    if (rc == DirectAbi.Pending)
                    {
                        Interlocked.Increment(ref _pendingSlices);
                        continue;
                    }
                    if (rc == DirectAbi.Ok) continue;
                    if (rc == DirectAbi.Stopped)
                    {
                        reason = "session stopped";
                        break;
                    }
                    failure = rc;
                    LastError = rc;
                    LastFailure = "owner poll failed (" + rc + ")";
                    reason = "poll failure";
                    Console.Error.WriteLine("[s2a] direct owner loop: " + LastFailure);
                    try { _onFailure?.Invoke(rc, LastFailure); }
                    catch (Exception error)
                    {
                        // 失败回调自己抛出不能吞掉首个根因，也不能让异常跨线程终止进程。
                        Console.Error.WriteLine("[s2a] direct owner loop: failure handler threw: " + error);
                    }
                    break;
                }
            }
            catch (Exception error)
            {
                failure = DirectAbi.Internal;
                LastError = failure;
                LastFailure = "owner loop exception: " + error.Message;
                reason = "exception";
                Console.Error.WriteLine("[s2a] direct owner loop: " + LastFailure);
            }
            finally
            {
                StopReason = reason;
                _running = false;
                Console.Error.WriteLine(
                    $"[s2a] direct owner loop exited: slices={Slices} pending={PendingSlices} failure={failure} reason={reason}");
            }
        }
    }
}
