using Ryujinx.Common.Logging;
using Ryujinx.Graphics.Gpu;
using Ryujinx.Graphics.Gpu.Synchronization;
using Ryujinx.HLE.HOS.Kernel;
using Ryujinx.HLE.HOS.Kernel.Threading;
using Ryujinx.HLE.HOS.Services.Nv.Types;
using Ryujinx.Horizon.Common;
using System;
using System.Threading;

namespace Ryujinx.HLE.HOS.Services.Nv.NvDrvServices.NvHostCtrl
{
    class NvHostEvent
    {
        public NvFence Fence;
        public NvHostEventState State;
        public KEvent Event;
        public int EventHandle;

        private readonly uint _eventId;
#pragma warning disable IDE0052 // Remove unread private member
        private readonly NvHostSyncpt _syncpointManager;
#pragma warning restore IDE0052
        private SyncpointWaiterHandle _waiterInformation;

        private NvFence _previousFailingFence;
        private uint _failingCount;

        public readonly Lock Lock = new();

        /// <summary>
        /// Max failing count until waiting on CPU.
        /// FIXME: This seems enough for most of the cases, reduce if needed.
        /// </summary>
        private const uint FailingCountMax = 2;

        public NvHostEvent(NvHostSyncpt syncpointManager, uint eventId, Horizon system)
        {
            Fence.Id = 0;

            State = NvHostEventState.Available;

            Event = new KEvent(system.KernelContext);

            if (KernelStatic.GetCurrentProcess().HandleTable.GenerateHandle(Event.ReadableEvent, out EventHandle) != Result.Success)
            {
                throw new InvalidOperationException("Out of handles!");
            }

            _eventId = eventId;

            _syncpointManager = syncpointManager;

            ResetFailingState();
        }

        private void ResetFailingState()
        {
            _previousFailingFence.Id = NvFence.InvalidSyncPointId;
            _previousFailingFence.Value = 0;
            _failingCount = 0;
        }

        private void Signal()
        {
            lock (Lock)
            {
                NvHostEventState oldState = State;

                State = NvHostEventState.Signaling;

                if (oldState == NvHostEventState.Waiting)
                {
                    Event.WritableEvent.Signal();
                }

                State = NvHostEventState.Signaled;
            }
        }

        private Action<SyncpointWaiterHandle> _gpuSignaled;

        private void GpuSignaled(SyncpointWaiterHandle waiterInformation)
        {
            lock (Lock)
            {
                // If the signal does not match our current waiter,
                // then it is from a past fence and we should just ignore it.
                if (waiterInformation != null && waiterInformation != _waiterInformation)
                {
                    return;
                }

                ResetFailingState();
                Ryujinx.Graphics.Gpu.S2AGameSync.Observe(Fence.Id, Fence.Value);   // S2A：游戏等的同步点到值（之后唤醒游戏）

                Signal();
            }
        }

        public void Cancel(GpuContext gpuContext)
        {
            lock (Lock)
            {
                NvHostEventState oldState = State;

                State = NvHostEventState.Cancelling;

                if (oldState == NvHostEventState.Waiting && _waiterInformation != null)
                {
                    gpuContext.Synchronization.UnregisterCallback(Fence.Id, _waiterInformation);
                    _waiterInformation = null;

                    if (_previousFailingFence.Id == Fence.Id && _previousFailingFence.Value == Fence.Value)
                    {
                        _failingCount++;
                    }
                    else
                    {
                        _failingCount = 1;

                        _previousFailingFence = Fence;
                    }
                }

                State = NvHostEventState.Cancelled;

                Event.WritableEvent.Clear();
            }
        }

        public bool Wait(GpuContext gpuContext, NvFence fence)
        {
            lock (Lock)
            {
                Fence = fence;

                // Repeated guest cancellations may need a bounded CPU wait while the GPU is busy.
                // A timeout is still pending, so it must arm the event instead of reporting completion.
                if (_failingCount >= FailingCountMax)
                {
                    Logger.Warning?.Print(LogClass.ServiceNv, "GPU processing thread is too slow, waiting on CPU...");

                    if (!Fence.Wait(gpuContext, TimeSpan.FromSeconds(1)))
                    {
                        ResetFailingState();

                        return false;
                    }
                }

                // The event may have been signaled for a previous fence.
                Event.WritableEvent.Clear();
                State = NvHostEventState.Waiting;

                // S2Arm: reuse the delegate for the pending fence callback.
                _waiterInformation = gpuContext.Synchronization.RegisterCallbackOnSyncpoint(Fence.Id, Fence.Value, _gpuSignaled ??= GpuSignaled);

                return true;
            }
        }

        public string DumpState(GpuContext gpuContext)
        {
            string res = $"\nNvHostEvent {_eventId}:\n";
            res += $"\tState: {State}\n";

            if (State == NvHostEventState.Waiting)
            {
                res += "\tFence:\n";
                res += $"\t\tId            : {Fence.Id}\n";
                res += $"\t\tThreshold     : {Fence.Value}\n";
                res += $"\t\tCurrent Value : {gpuContext.Synchronization.GetSyncpointValue(Fence.Id)}\n";
                res += $"\t\tWaiter Valid  : {_waiterInformation != null}\n";
            }

            return res;
        }

        public void CloseEvent(ServiceCtx context)
        {
            if (EventHandle != 0)
            {
                context.Process.HandleTable.CloseHandle(EventHandle);
                EventHandle = 0;
            }
        }
    }
}
