using Ryujinx.Graphics.Gpu;
using Ryujinx.HLE.HOS.Services.Nv.NvDrvServices.NvHostCtrl;
using System;
using System.Runtime.InteropServices;

namespace Ryujinx.HLE.HOS.Services.Nv.Types
{
    [StructLayout(LayoutKind.Sequential, Size = 0x8)]
    internal struct NvFence
    {
        public const uint InvalidSyncPointId = uint.MaxValue;

        public uint Id;
        public uint Value;

        public readonly bool IsValid()
        {
            return Id != InvalidSyncPointId;
        }

        public void UpdateValue(NvHostSyncpt hostSyncpt)
        {
            Value = hostSyncpt.ReadSyncpointValue(Id);
        }

        public void Increment(GpuContext gpuContext)
        {
            Value = gpuContext.Synchronization.IncrementSyncpoint(Id);
        }

        public readonly bool Wait(GpuContext gpuContext, TimeSpan timeout)
        {
            if (IsValid())
            {
                // S2Arm: already reached (same comparison as Syncpoint.RegisterCallback) -> no wait. WaitOnSyncpoint creates a
                // ManualResetEvent and a closure (~192 B) before finding that out; the compositor waits on every presented frame
                if (gpuContext.Synchronization.GetSyncpointValue(Id) >= Value)
                {
                    return false;
                }

                return gpuContext.Synchronization.WaitOnSyncpoint(Id, Value, timeout);
            }

            return false;
        }
    }
}
