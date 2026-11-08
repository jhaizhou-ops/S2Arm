using Ryujinx.Common.Logging;
using Ryujinx.Graphics.Gpu.Memory;
using Ryujinx.HLE.HOS.Services.Nv.NvDrvServices.NvHostAsGpu.Types;
using Ryujinx.HLE.HOS.Services.Nv.NvDrvServices.NvHostChannel;
using Ryujinx.HLE.HOS.Services.Nv.NvDrvServices.NvMap;
using Ryujinx.Memory;
using System;
using System.Diagnostics;
using System.Runtime.CompilerServices;

namespace Ryujinx.HLE.HOS.Services.Nv.NvDrvServices.NvHostAsGpu
{
    class NvHostAsGpuDeviceFile : NvDeviceFile
    {
        // S2Arm: ioctl delegates cached per instance (a method group converted per call allocates every ioctl)
        private IoctlProcessor<BindChannelArguments> _s2aBindChannel1;
        private IoctlProcessor<AllocSpaceArguments> _s2aAllocSpace1;
        private IoctlProcessor<FreeSpaceArguments> _s2aFreeSpace1;
        private IoctlProcessor<UnmapBufferArguments> _s2aUnmapBuffer1;
        private IoctlProcessor<MapBufferExArguments> _s2aMapBufferEx1;
        private IoctlProcessor<GetVaRegionsArguments> _s2aGetVaRegions1;
        private IoctlProcessorInlineSpan<GetVaRegionsArguments, VaRegion> _s2aGetVaRegions3;
        private IoctlProcessor<InitializeExArguments> _s2aInitializeEx1;
        private IoctlProcessorSpan<RemapArguments> _s2aRemap1;

        private const uint SmallPageSize = 0x1000;
        private const uint BigPageSize = 0x10000;

        private const ulong SmallRegionLimit = 0x400000000UL; // 16 GiB
        private const ulong DefaultUserSize = 1UL << 37;

        internal readonly struct VmRegion
        {
            public ulong Start { get; }
            public ulong Limit { get; }

            public VmRegion(ulong start, ulong limit)
            {
                Start = start;
                Limit = limit;
            }
        }

        // S2Arm: the regions GetVaRegions reports start as these defaults and follow the guest's InitializeEx (nvservices AllocAsEx):
        //   a guest that sizes its own GPU address space (10-29 脑锻炼 010062200D392000 links CUDA, wants a far larger range) read the
        //   fixed 12 GiB small / 112 GiB big regions back and crashed on a null right after, direct and generic mode alike
        private VmRegion[] _vmRegions =
        [
            new((ulong)BigPageSize << 16, SmallRegionLimit),
            new(SmallRegionLimit, DefaultUserSize)
        ];

        private readonly uint[] _regionPageSizes = [SmallPageSize, BigPageSize];
        private bool _initializedEx;

        // nvservices AllocAsEx bounds (yuzu nvhost_as_gpu VM): big pages 64 / 128 KiB; a big page size alone moves the start to
        // big << 10 with the 16 GiB split and 128 GiB end; explicit ranges replace all three. The GPU memory manager and the
        // allocator cover 40 bits, so a range past 1 TiB cannot be honoured.
        private const uint SupportedBigPageSizes = 0x30000;
        private const int VaStartShift = 10;
        private const ulong DefaultVaSplit = 1UL << 34;
        private const ulong DefaultVaRange = 1UL << 37;
        private const ulong GpuVaLimit = 1UL << 40;

        internal static NvInternalResult S2AAddressSpace(in InitializeExArguments arguments, out VmRegion small, out VmRegion big, out uint bigPageSize)
        {
            small = new((ulong)BigPageSize << 16, SmallRegionLimit);
            big = new(SmallRegionLimit, DefaultUserSize);
            bigPageSize = BigPageSize;

            ulong start = small.Start, split = SmallRegionLimit, end = DefaultUserSize;

            if (arguments.BigPageSize != 0)
            {
                if (!ulong.IsPow2(arguments.BigPageSize) || (arguments.BigPageSize & SupportedBigPageSizes) == 0)
                {
                    return NvInternalResult.InvalidInput;
                }

                bigPageSize = arguments.BigPageSize;
                start = (ulong)arguments.BigPageSize << VaStartShift;
                split = DefaultVaSplit;
                end = DefaultVaRange;
            }

            if (arguments.VaRangeStart != 0)
            {
                start = arguments.VaRangeStart;
                split = arguments.VaRangeSplit;
                end = arguments.VaRangeEnd;
            }

            if (start >= split || split > end || end > GpuVaLimit || start % SmallPageSize != 0 || split % bigPageSize != 0 || end % bigPageSize != 0)
            {
                return NvInternalResult.InvalidInput;
            }

            small = new(start, split);
            big = new(split, end);

            return NvInternalResult.Success;
        }

        private readonly AddressSpaceContext _asContext;
        private readonly NvMemoryAllocator _memoryAllocator;

        public NvHostAsGpuDeviceFile(ServiceCtx context, IVirtualMemoryManager memory, ulong owner) : base(context, owner)
        {
            _asContext = new AddressSpaceContext(context.Device.Gpu.CreateMemoryManager(owner, context.Device.Configuration.MemoryConfiguration.DramSize));
            _memoryAllocator = new NvMemoryAllocator();
        }

        public override NvInternalResult Ioctl(NvIoctl command, Span<byte> arguments)
        {
            NvInternalResult result = NvInternalResult.NotImplemented;

            if (command.Type == NvIoctl.NvGpuAsMagic)
            {
                switch (command.Number)
                {
                    case 0x01:
                        result = CallIoctlMethod<BindChannelArguments>(_s2aBindChannel1 ??= BindChannel, arguments);
                        break;
                    case 0x02:
                        result = CallIoctlMethod<AllocSpaceArguments>(_s2aAllocSpace1 ??= AllocSpace, arguments);
                        break;
                    case 0x03:
                        result = CallIoctlMethod<FreeSpaceArguments>(_s2aFreeSpace1 ??= FreeSpace, arguments);
                        break;
                    case 0x05:
                        result = CallIoctlMethod<UnmapBufferArguments>(_s2aUnmapBuffer1 ??= UnmapBuffer, arguments);
                        break;
                    case 0x06:
                        result = CallIoctlMethod<MapBufferExArguments>(_s2aMapBufferEx1 ??= MapBufferEx, arguments);
                        break;
                    case 0x08:
                        result = CallIoctlMethod<GetVaRegionsArguments>(_s2aGetVaRegions1 ??= GetVaRegions, arguments);
                        break;
                    case 0x09:
                        result = CallIoctlMethod<InitializeExArguments>(_s2aInitializeEx1 ??= InitializeEx, arguments);
                        break;
                    case 0x14:
                        result = CallIoctlMethod<RemapArguments>(_s2aRemap1 ??= Remap, arguments);
                        break;
                }
            }

            return result;
        }

        public override NvInternalResult Ioctl3(NvIoctl command, Span<byte> arguments, Span<byte> inlineOutBuffer)
        {
            NvInternalResult result = NvInternalResult.NotImplemented;

            if (command.Type == NvIoctl.NvGpuAsMagic)
            {
                switch (command.Number)
                {
                    case 0x08:
                        // S2Arm: Ioctl3 GetVaRegions hands the regions back in the inline output buffer (Switch nvservices; yuzu GetVARegions3).
                        // Upstream assumed that buffer is empty and left it untouched: an SDK reading the regions from it (10-26 census
                        // Brain Training via NvRmGpuAddressSpaceGetInfo) got two all-zero regions, failed to build its GPU VA allocators,
                        // and crashed in its own cleanup
                        result = CallIoctlMethod<GetVaRegionsArguments, VaRegion>(_s2aGetVaRegions3 ??= GetVaRegions3, arguments, inlineOutBuffer);
                        break;
                }
            }

            return result;
        }

        private NvInternalResult BindChannel(ref BindChannelArguments arguments)
        {
            NvHostChannelDeviceFile channelDeviceFile = INvDrvServices.DeviceFileIdRegistry.GetData<NvHostChannelDeviceFile>(arguments.Fd);
            if (channelDeviceFile == null)
            {
                // TODO: Return invalid Fd error.
            }

            channelDeviceFile.Channel.BindMemory(_asContext.Gmm);

            return NvInternalResult.Success;
        }

        private NvInternalResult AllocSpace(ref AllocSpaceArguments arguments)
        {
            ulong size = (ulong)arguments.Pages * (ulong)arguments.PageSize;

            NvInternalResult result = NvInternalResult.Success;

            lock (_asContext)
            {
                // Note: When the fixed offset flag is not set,
                // the Offset field holds the alignment size instead.
                if ((arguments.Flags & AddressSpaceFlags.FixedOffset) != 0)
                {
                    bool regionInUse = _memoryAllocator.IsRegionInUse(arguments.Offset, size, out ulong freeAddressStartPosition);
                    ulong address;

                    if (!regionInUse)
                    {
                        _memoryAllocator.AllocateRange(arguments.Offset, size, freeAddressStartPosition);
                        address = freeAddressStartPosition;
                    }
                    else
                    {
                        address = NvMemoryAllocator.PteUnmapped;
                    }

                    arguments.Offset = address;
                }
                else
                {
                    ulong address = _memoryAllocator.GetFreeAddress(size, out ulong freeAddressStartPosition, arguments.Offset);
                    if (address != NvMemoryAllocator.PteUnmapped)
                    {
                        _memoryAllocator.AllocateRange(address, size, freeAddressStartPosition);
                    }

                    arguments.Offset = address;
                }

                if (arguments.Offset == NvMemoryAllocator.PteUnmapped)
                {
                    arguments.Offset = 0;

                    Logger.Warning?.Print(LogClass.ServiceNv, $"Failed to allocate size {size:x16}!");

                    result = NvInternalResult.OutOfMemory;
                }
                else
                {
                    _asContext.AddReservation(arguments.Offset, size);
                }
            }

            return result;
        }

        private NvInternalResult FreeSpace(ref FreeSpaceArguments arguments)
        {
            ulong size = (ulong)arguments.Pages * (ulong)arguments.PageSize;

            NvInternalResult result = NvInternalResult.Success;

            lock (_asContext)
            {
                if (_asContext.RemoveReservation(arguments.Offset))
                {
                    _memoryAllocator.DeallocateRange(arguments.Offset, size);
                    _asContext.Gmm.Unmap(arguments.Offset, size);
                }
                else
                {
                    Logger.Warning?.Print(LogClass.ServiceNv,
                        $"Failed to free offset 0x{arguments.Offset:x16} size 0x{size:x16}!");

                    result = NvInternalResult.InvalidInput;
                }
            }

            return result;
        }

        private NvInternalResult UnmapBuffer(ref UnmapBufferArguments arguments)
        {
            lock (_asContext)
            {
                if (_asContext.RemoveMap(arguments.Offset, out ulong size))
                {
                    if (size != 0)
                    {
                        _memoryAllocator.DeallocateRange(arguments.Offset, size);
                        _asContext.Gmm.Unmap(arguments.Offset, size);
                    }
                }
                else
                {
                    Logger.Warning?.Print(LogClass.ServiceNv, $"Invalid buffer offset {arguments.Offset:x16}!");
                }
            }

            return NvInternalResult.Success;
        }

        private NvInternalResult MapBufferEx(ref MapBufferExArguments arguments)
        {
            const string MapErrorMsg = "Failed to map fixed buffer with offset 0x{0:x16}, size 0x{1:x16} and alignment 0x{2:x16}!";

            ulong physicalAddress;

            if ((arguments.Flags & AddressSpaceFlags.RemapSubRange) != 0)
            {
                lock (_asContext)
                {
                    if (_asContext.TryGetMapPhysicalAddress(arguments.Offset, out physicalAddress))
                    {
                        ulong virtualAddress = arguments.Offset + arguments.BufferOffset;

                        physicalAddress += arguments.BufferOffset;
                        _asContext.Gmm.Map(physicalAddress, virtualAddress, arguments.MappingSize, (PteKind)arguments.Kind);

                        return NvInternalResult.Success;
                    }
                    else
                    {
                        Logger.Warning?.Print(LogClass.ServiceNv, $"Address 0x{arguments.Offset:x16} not mapped!");

                        return NvInternalResult.InvalidInput;
                    }
                }
            }

            NvMapHandle map = NvMapDeviceFile.GetMapFromHandle(Owner, arguments.NvMapHandle);

            if (map == null)
            {
                Logger.Warning?.Print(LogClass.ServiceNv, $"Invalid NvMap handle 0x{arguments.NvMapHandle:x8}!");

                return NvInternalResult.InvalidInput;
            }

            ulong pageSize = (ulong)arguments.PageSize;

            if (pageSize == 0)
            {
                pageSize = (ulong)map.Align;
            }

            physicalAddress = map.Address + arguments.BufferOffset;

            ulong size = arguments.MappingSize;

            if (size == 0)
            {
                size = map.Size;
            }

            NvInternalResult result = NvInternalResult.Success;

            lock (_asContext)
            {
                // Note: When the fixed offset flag is not set,
                // the Offset field holds the alignment size instead.
                bool virtualAddressAllocated = (arguments.Flags & AddressSpaceFlags.FixedOffset) == 0;

                if (!virtualAddressAllocated)
                {
                    if (_asContext.ValidateFixedBuffer(arguments.Offset, size, pageSize))
                    {
                        _asContext.Gmm.Map(physicalAddress, arguments.Offset, size, (PteKind)arguments.Kind);
                    }
                    else
                    {
                        string message = string.Format(MapErrorMsg, arguments.Offset, size, pageSize);

                        Logger.Warning?.Print(LogClass.ServiceNv, message);

                        result = NvInternalResult.InvalidInput;
                    }
                }
                else
                {
                    ulong va = _memoryAllocator.GetFreeAddress(size, out ulong freeAddressStartPosition, pageSize);
                    if (va != NvMemoryAllocator.PteUnmapped)
                    {
                        _memoryAllocator.AllocateRange(va, size, freeAddressStartPosition);
                    }

                    _asContext.Gmm.Map(physicalAddress, va, size, (PteKind)arguments.Kind);
                    arguments.Offset = va;
                }

                if (arguments.Offset == NvMemoryAllocator.PteUnmapped)
                {
                    arguments.Offset = 0;

                    Logger.Warning?.Print(LogClass.ServiceNv, $"Failed to map size 0x{size:x16}!");

                    result = NvInternalResult.InvalidInput;
                }
                else
                {
                    _asContext.AddMap(arguments.Offset, size, physicalAddress, virtualAddressAllocated);
                }
            }

            return result;
        }

        private NvInternalResult GetVaRegions(ref GetVaRegionsArguments arguments)
        {
            int vaRegionStructSize = Unsafe.SizeOf<VaRegion>();

            Debug.Assert(vaRegionStructSize == 0x18);
            Debug.Assert(_regionPageSizes.Length == 2);

            uint writeEntries = (uint)(arguments.BufferSize / vaRegionStructSize);
            if (writeEntries > _regionPageSizes.Length)
            {
                writeEntries = (uint)_regionPageSizes.Length;
            }

            Span<VaRegion> regionsSpan = arguments.Regions.AsSpan();

            for (uint i = 0; i < writeEntries; i++)
            {
                ref VaRegion region = ref regionsSpan[(int)i];

                VmRegion vmRegion = _vmRegions[i];
                uint pageSize = _regionPageSizes[i];

                region.PageSize = pageSize;
                region.Offset = vmRegion.Start;
                region.Pages = (vmRegion.Limit - vmRegion.Start) / pageSize;
                region.Padding = 0;
            }

            arguments.BufferSize = (uint)(_regionPageSizes.Length * vaRegionStructSize);

            return NvInternalResult.Success;
        }

        private NvInternalResult GetVaRegions3(ref GetVaRegionsArguments arguments, Span<VaRegion> inlineRegions)
        {
            // Same count GetVaRegions writes: what the caller's buffer size holds, at most the two regions
            int count = Math.Min(Math.Min(inlineRegions.Length, (int)(arguments.BufferSize / (uint)Unsafe.SizeOf<VaRegion>())), _regionPageSizes.Length);
            NvInternalResult result = GetVaRegions(ref arguments);

            Span<VaRegion> regions = arguments.Regions.AsSpan();

            regions[..count].CopyTo(inlineRegions);

            return result;
        }

        private NvInternalResult InitializeEx(ref InitializeExArguments arguments)
        {
            // S2Arm: nvservices AllocAsEx — once per address space (InvalidState after), bounds validated, then GetVaRegions reports them
            lock (_asContext)
            {
                if (_initializedEx)
                {
                    return NvInternalResult.InvalidState;
                }

                NvInternalResult result = S2AAddressSpace(arguments, out VmRegion small, out VmRegion big, out uint bigPageSize);

                Logger.Info?.Print(LogClass.ServiceNv, $"InitializeEx: big page 0x{arguments.BigPageSize:x}, range 0x{arguments.VaRangeStart:x} / 0x{arguments.VaRangeSplit:x} / 0x{arguments.VaRangeEnd:x} → {result}" +
                    (result == NvInternalResult.Success ? $", regions 0x{small.Start:x}-0x{small.Limit:x} (4 KiB) 0x{big.Start:x}-0x{big.Limit:x} (0x{bigPageSize:x})" : ""));

                if (result != NvInternalResult.Success)
                {
                    return result;
                }

                _vmRegions = [small, big];
                _regionPageSizes[1] = bigPageSize;
                _initializedEx = true;
            }

            return NvInternalResult.Success;
        }

        private NvInternalResult Remap(Span<RemapArguments> arguments)
        {
            MemoryManager gmm = _asContext.Gmm;

            for (int index = 0; index < arguments.Length; index++)
            {
                ref RemapArguments argument = ref arguments[index];
                ulong gpuVa = (ulong)argument.GpuOffset << 16;
                ulong size = (ulong)argument.Pages << 16;
                int nvmapHandle = argument.NvMapHandle;

                if (nvmapHandle == 0)
                {
                    gmm.Unmap(gpuVa, size);
                }
                else
                {
                    ulong mapOffs = (ulong)argument.MapOffset << 16;
                    PteKind kind = (PteKind)argument.Kind;

                    NvMapHandle map = NvMapDeviceFile.GetMapFromHandle(Owner, nvmapHandle);

                    if (map == null)
                    {
                        Logger.Warning?.Print(LogClass.ServiceNv, $"Invalid NvMap handle 0x{nvmapHandle:x8}!");

                        return NvInternalResult.InvalidInput;
                    }

                    gmm.Map(mapOffs + map.Address, gpuVa, size, kind);
                }
            }

            return NvInternalResult.Success;
        }

        public override void Close() { }
    }
}
