using Ryujinx.HLE.HOS.Kernel.Memory;
using Ryujinx.Horizon.Common;
using System;

namespace Ryujinx.HLE.HOS.Kernel.Common
{
    static class KernelInit
    {
        private readonly struct MemoryRegion
        {
            public ulong Address { get; }
            public ulong Size { get; }

            public ulong EndAddress => Address + Size;

            public MemoryRegion(ulong address, ulong size)
            {
                Address = address;
                Size = size;
            }
        }

        public static void InitializeResourceLimit(KResourceLimit resourceLimit, MemorySize size)
        {
            static void EnsureSuccess(Result result)
            {
                if (result != Result.Success)
                {
                    throw new InvalidOperationException($"Unexpected result \"{result}\".");
                }
            }

            ulong ramSize = KSystemControl.GetDramSize(size);

            EnsureSuccess(resourceLimit.SetLimitValue(LimitableResource.Memory, (long)ramSize));
            EnsureSuccess(resourceLimit.SetLimitValue(LimitableResource.Thread, 800));
            EnsureSuccess(resourceLimit.SetLimitValue(LimitableResource.Event, 700));
            EnsureSuccess(resourceLimit.SetLimitValue(LimitableResource.TransferMemory, 200));
            EnsureSuccess(resourceLimit.SetLimitValue(LimitableResource.Session, 900));

            if (!resourceLimit.Reserve(LimitableResource.Memory, 0) ||
                !resourceLimit.Reserve(LimitableResource.Memory, 0x60000))
            {
                throw new InvalidOperationException("Unexpected failure reserving memory on resource limit.");
            }
        }

        // S2Arm: end of the service pool. Need (Mac runs of d3 / octopath2 / witcher3 / silksong / acnh, 120 s each, all identical, nothing
        // allocated after boot): 10 ServerBase processes (Sm Bsd Fs Hid Nv Time Vi:u Vi:m Vi:s Ldn) x (2 MB heap + 1 code page + 1 stack page)
        // = 20.08 MB. A 2 MB heap needs a 2 MB-aligned block: [0x80C00000, end) holds 14 of them (4 spare, e.g. the lazy "Common" server),
        // the single pages fit below 0x80C00000. 2 MB-aligned, so the nv pool keeps the 16 KB page alignment Horizon's shared blocks need.
        // Running out is reported red (KMemoryRegionManager) instead of handing out pages past the backed DRAM.
        public const ulong S2AServicePoolEnd = DramMemoryMap.DramBase + 0x2800000;

        // S2Arm: DRAM bytes the host must back (MemoryBlock size): kernel reserve + service pool + nv pool. Applet / application pools above are unbacked
        public static ulong GetBackedDramSize()
        {
            return S2AServicePoolEnd + KSystemControl.GetMinimumNonSecureSystemPoolSize() - DramMemoryMap.DramBase;
        }

        public static KMemoryRegionManager[] GetMemoryRegions(MemorySize size, MemoryArrange arrange)
        {
            ulong poolEnd = KSystemControl.GetDramEndAddress(size);
            ulong applicationPoolSize = KSystemControl.GetApplicationPoolSize(arrange);
            ulong appletPoolSize = KSystemControl.GetAppletPoolSize(arrange);

            MemoryRegion servicePool;
            MemoryRegion nvServicesPool;
            MemoryRegion appletPool;
            MemoryRegion applicationPool;

            ulong nvServicesPoolSize = KSystemControl.GetMinimumNonSecureSystemPoolSize();

            applicationPool = new MemoryRegion(poolEnd - applicationPoolSize, applicationPoolSize);
            appletPool = new MemoryRegion(applicationPool.Address - appletPoolSize, appletPoolSize);

            // S2Arm: the service pool is sized to what the HLE service processes need, instead of "all the remaining memory"
            // (upstream gave it everything between the slab heap and the nv pool: 251 MB on 4 GiB, of which 20 MB is ever used),
            // and the nv pool follows it directly. Only the DRAM up to the nv pool end is backed (GetBackedDramSize); applet /
            // application pools stay at their Horizon addresses but are unbacked (the game runs in the host address window).
            servicePool = new MemoryRegion(DramMemoryMap.SlabHeapEnd, S2AServicePoolEnd - DramMemoryMap.SlabHeapEnd);
            nvServicesPool = new MemoryRegion(S2AServicePoolEnd, nvServicesPoolSize);

            return
            [
                GetMemoryRegion(applicationPool),
                GetMemoryRegion(appletPool),
                GetMemoryRegion(servicePool),
                GetMemoryRegion(nvServicesPool)
            ];
        }

        private static KMemoryRegionManager GetMemoryRegion(MemoryRegion region)
        {
            return new KMemoryRegionManager(region.Address, region.Size, region.EndAddress);
        }
    }
}
