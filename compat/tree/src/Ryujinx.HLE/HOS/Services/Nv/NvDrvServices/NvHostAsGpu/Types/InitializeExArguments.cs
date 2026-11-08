using System.Runtime.InteropServices;

namespace Ryujinx.HLE.HOS.Services.Nv.NvDrvServices.NvHostAsGpu.Types
{
    [StructLayout(LayoutKind.Sequential)]
    struct InitializeExArguments
    {
        public uint Flags;
        public int AsFd;
        public uint BigPageSize;
        public uint Reserved;
        // S2Arm: nvservices AllocAsEx names (yuzu IoctlAllocAsEx): the guest's GPU address space bounds, all 0 = defaults
        public ulong VaRangeStart;
        public ulong VaRangeEnd;
        public ulong VaRangeSplit;
    }
}
