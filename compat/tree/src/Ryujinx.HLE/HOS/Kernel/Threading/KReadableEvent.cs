// S2Arm: ClearIfSignaled clears the native event only after the managed precondition succeeds.
using Ryujinx.HLE.HOS.Kernel.Common;
using Ryujinx.Horizon.Common;

namespace Ryujinx.HLE.HOS.Kernel.Threading
{
    class KReadableEvent : KSynchronizationObject
    {
        private bool _signaled;

        // S2Arm: native event this object is bound to once handed to the game (0 = not bound); see S2AHooks
        public ulong S2ANativeEvent;

        public KReadableEvent(KernelContext context) : base(context)
        {
        }

        public override unsafe void Signal()
        {
            // S2Arm: forward unconditionally, the game may have cleared the native event without us seeing it
            if (S2ANativeEvent != 0)
            {
                S2AHooks.EventSignal(S2ANativeEvent);
            }

            KernelContext.CriticalSection.Enter();

            if (!_signaled)
            {
                _signaled = true;

                base.Signal();
            }

            KernelContext.CriticalSection.Leave();
        }

        public unsafe Result Clear()
        {
            if (S2ANativeEvent != 0)
            {
                S2AHooks.EventClear(S2ANativeEvent);
            }

            _signaled = false;

            return Result.Success;
        }

        public unsafe Result ClearIfSignaled()
        {
            Result result;

            KernelContext.CriticalSection.Enter();

            if (_signaled)
            {
                if (S2ANativeEvent != 0)
                {
                    S2AHooks.EventClear(S2ANativeEvent);
                }

                _signaled = false;

                result = Result.Success;
            }
            else
            {
                result = KernelResult.InvalidState;
            }

            KernelContext.CriticalSection.Leave();

            return result;
        }

        public override bool IsSignaled()
        {
            return _signaled;
        }
    }
}
