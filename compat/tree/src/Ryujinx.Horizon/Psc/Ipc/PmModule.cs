using Ryujinx.Horizon.Common;
using Ryujinx.Horizon.Sdk.OsTypes;
using Ryujinx.Horizon.Sdk.Psc;
using Ryujinx.Horizon.Sdk.Sf;
using Ryujinx.Horizon.Sdk.Sf.Hipc;
using System;
using System.Collections.Generic;
using System.Threading;

namespace Ryujinx.Horizon.Psc.Ipc
{
    // psc 模块（S2Arm 最小实现，缺口扫描族 1）：Initialize 交出一个事件；宿主进后台 / 睡眠时 PscHost.Request 往所有已初始化的模块排一条
    //   休眠请求、回来时排一条唤醒请求并点亮事件；GetRequest 回队首（没有请求时回 FullAwake），Acknowledge / AcknowledgeEx(队首状态) 出队，队里还有就再点亮。
    //   不阻塞宿主：游戏不确认也照常进后台 / 回来（iOS 后台本来整体冻结，回来后游戏依次读到休眠、唤醒）
    partial class PmModule : IPmModule, IDisposable
    {
        // 队列空时 GetRequest 报的状态；确认这个状态成功、不出队（审计 #1534 P1-76：读到什么就能确认什么）
        private const PmState IdleState = PmState.FullAwake;

        private static readonly Lock _registryLock = new();
        private static readonly List<PmModule> _modules = [];

        private readonly Lock _lock = new();
        private readonly Queue<PmState> _requests = new();
        private SystemEventType _event;
        private bool _initialized;

        [CmifCommand(0)]
        public Result Initialize([CopyHandle] out int eventHandle, uint moduleId, [Buffer(HipcBufferFlags.In | HipcBufferFlags.MapAlias)] ReadOnlySpan<uint> dependencies)
        {
            lock (_lock)
            {
                if (!_initialized)
                {
                    Os.CreateSystemEvent(out _event, EventClearMode.AutoClear, interProcess: true).AbortOnFailure();
                    _initialized = true;
                    lock (_registryLock) _modules.Add(this);
                }

                eventHandle = Os.GetReadableHandleOfSystemEvent(ref _event);
            }

            return Result.Success;
        }

        [CmifCommand(1)]
        public Result GetRequest(out PmState state, out uint flags)
        {
            lock (_lock)
            {
                state = _requests.Count > 0 ? _requests.Peek() : IdleState;
                flags = 0;
            }

            return Result.Success;
        }

        [CmifCommand(2)]
        public Result Acknowledge()
        {
            return Dequeue(null);
        }

        [CmifCommand(3)]
        public Result Finalize()
        {
            Dispose();

            return Result.Success;
        }

        [CmifCommand(4)] // 5.1.0+
        public Result AcknowledgeEx(PmState state)
        {
            return Dequeue(state);
        }

        // 确认 = 出队首（审计 P2-38）：没初始化回 psc NotInitialized；带状态确认与队首不符回失败且不出队。
        //   队列空时（审计 #1534 P1-76）：GetRequest 回 IdleState 且成功，确认它（不带状态或带 IdleState）成功、不出队；确认别的状态回失败。
        //   主机对失败一支的真实失败码未公开（switchbrew / Atmosphère 只登记了 psc 2 / 3），用通用 InvalidState
        private Result Dequeue(PmState? state)
        {
            lock (_lock)
            {
                if (!_initialized)
                {
                    return PscResult.NotInitialized;
                }

                if (_requests.Count == 0)
                {
                    return !state.HasValue || state.Value == IdleState ? Result.Success : KernelResult.InvalidState;
                }

                if (state.HasValue && _requests.Peek() != state.Value)
                {
                    return KernelResult.InvalidState;
                }

                _requests.Dequeue();

                if (_requests.Count > 0)
                {
                    Os.SignalSystemEvent(ref _event);
                }
            }

            return Result.Success;
        }

        // 宿主侧（S2A.Services Lifecycle）：休眠 = SleepReady，唤醒 = FullAwake
        internal static void RequestAll(PmState state)
        {
            lock (_registryLock)
            {
                foreach (PmModule module in _modules)
                {
                    module.Request(state);
                }
            }
        }

        private void Request(PmState state)
        {
            lock (_lock)
            {
                if (!_initialized)
                {
                    return;
                }

                _requests.Enqueue(state);
                Os.SignalSystemEvent(ref _event);
            }
        }

        public void Dispose()
        {
            lock (_registryLock) _modules.Remove(this);

            lock (_lock)
            {
                if (_initialized)
                {
                    _initialized = false;
                    _requests.Clear();
                    Os.DestroySystemEvent(ref _event);
                }
            }
        }
    }
}
