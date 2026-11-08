using Ryujinx.Common.Logging;
using Ryujinx.HLE.HOS.Kernel.Threading;
using Ryujinx.HLE.HOS.Services.Nv.NvDrvServices.NvHostCtrlGpu.Types;
using Ryujinx.Horizon.Common;
using Ryujinx.Memory;
using System;
using System.Diagnostics;

namespace Ryujinx.HLE.HOS.Services.Nv.NvDrvServices.NvHostCtrlGpu
{
    class NvHostCtrlGpuDeviceFile : NvDeviceFile
    {
        // S2Arm: ioctl delegates cached per instance (a method group converted per call allocates every ioctl)
        private IoctlProcessor<ZcullGetCtxSizeArguments> _s2aZcullGetCtxSize1;
        private IoctlProcessor<ZcullGetInfoArguments> _s2aZcullGetInfo1;
        private IoctlProcessor<ZbcSetTableArguments> _s2aZbcSetTable1;
        private IoctlProcessor<GetCharacteristicsArguments> _s2aGetCharacteristics1;
        private IoctlProcessor<GetTpcMasksArguments> _s2aGetTpcMasks1;
        private IoctlProcessor<NumVsmsArguments> _s2aNumVsms1;
        private IoctlProcessor<VsmsMappingArguments> _s2aVsmsMapping1;
        private IoctlProcessor<GetActiveSlotMaskArguments> _s2aGetActiveSlotMask1;
        private IoctlProcessor<GetGpuTimeArguments> _s2aGetGpuTime1;
        private IoctlProcessorInline<GetCharacteristicsArguments, GpuCharacteristics> _s2aGetCharacteristics2;
        private IoctlProcessorInline<GetTpcMasksArguments, int> _s2aGetTpcMasks2;

        private static readonly Stopwatch _pTimer = new();
        private static readonly double _ticksToNs = (1.0 / Stopwatch.Frequency) * 1_000_000_000;

        private readonly KEvent _errorEvent;
        private readonly KEvent _unknownEvent;

        public NvHostCtrlGpuDeviceFile(ServiceCtx context, IVirtualMemoryManager memory, ulong owner) : base(context, owner)
        {
            _errorEvent = new KEvent(context.Device.System.KernelContext);
            _unknownEvent = new KEvent(context.Device.System.KernelContext);
        }

        static NvHostCtrlGpuDeviceFile()
        {
            _pTimer.Start();
        }

        public override NvInternalResult Ioctl(NvIoctl command, Span<byte> arguments)
        {
            NvInternalResult result = NvInternalResult.NotImplemented;

            if (command.Type == NvIoctl.NvGpuMagic)
            {
                switch (command.Number)
                {
                    case 0x01:
                        result = CallIoctlMethod<ZcullGetCtxSizeArguments>(_s2aZcullGetCtxSize1 ??= ZcullGetCtxSize, arguments);
                        break;
                    case 0x02:
                        result = CallIoctlMethod<ZcullGetInfoArguments>(_s2aZcullGetInfo1 ??= ZcullGetInfo, arguments);
                        break;
                    case 0x03:
                        result = CallIoctlMethod<ZbcSetTableArguments>(_s2aZbcSetTable1 ??= ZbcSetTable, arguments);
                        break;
                    case 0x05:
                        result = CallIoctlMethod<GetCharacteristicsArguments>(_s2aGetCharacteristics1 ??= GetCharacteristics, arguments);
                        break;
                    case 0x06:
                        result = CallIoctlMethod<GetTpcMasksArguments>(_s2aGetTpcMasks1 ??= GetTpcMasks, arguments);
                        break;
                    case 0x12:
                        result = CallIoctlMethod<NumVsmsArguments>(_s2aNumVsms1 ??= NumVsms, arguments);
                        break;
                    case 0x13:
                        result = CallIoctlMethod<VsmsMappingArguments>(_s2aVsmsMapping1 ??= VsmsMapping, arguments);
                        break;
                    case 0x14:
                        result = CallIoctlMethod<GetActiveSlotMaskArguments>(_s2aGetActiveSlotMask1 ??= GetActiveSlotMask, arguments);
                        break;
                    case 0x1c:
                        result = CallIoctlMethod<GetGpuTimeArguments>(_s2aGetGpuTime1 ??= GetGpuTime, arguments);
                        break;
                }
            }

            return result;
        }

        public override NvInternalResult Ioctl3(NvIoctl command, Span<byte> arguments, Span<byte> inlineOutBuffer)
        {
            NvInternalResult result = NvInternalResult.NotImplemented;

            if (command.Type == NvIoctl.NvGpuMagic)
            {
                switch (command.Number)
                {
                    case 0x05:
                        result = CallIoctlMethod<GetCharacteristicsArguments, GpuCharacteristics>(_s2aGetCharacteristics2 ??= GetCharacteristics, arguments, inlineOutBuffer);
                        break;
                    case 0x06:
                        result = CallIoctlMethod<GetTpcMasksArguments, int>(_s2aGetTpcMasks2 ??= GetTpcMasks, arguments, inlineOutBuffer);
                        break;
                    case 0x12:
                        result = CallIoctlMethod<NumVsmsArguments>(_s2aNumVsms1 ??= NumVsms, arguments);
                        break;
                    case 0x13:
                        result = CallIoctlMethod<VsmsMappingArguments, byte>(_s2aVsmsMappingInline ??= VsmsMappingInline, arguments, inlineOutBuffer);
                        break;
                }
            }

            return result;
        }

        // S2Arm: the game's NVN driver pre-fills the inline buffer of the Ioctl3 form with a 0xc0c0 sentinel and fails device
        // creation if it is not overwritten. Upstream only fills the argument block; on desktop the kernel copies the server's
        // (zero) pointer buffer back over it, which in-thread direct dispatch does not do. Reproduce that result: all zero
        // (the reference Ryujinx IPC record shows exactly this).
        private IoctlProcessorInlineSpan<VsmsMappingArguments, byte> _s2aVsmsMappingInline;

        private NvInternalResult VsmsMappingInline(ref VsmsMappingArguments arguments, Span<byte> inlineData)
        {
            NvInternalResult result = VsmsMapping(ref arguments);

            inlineData.Clear();

            return result;
        }

        public override NvInternalResult QueryEvent(out int eventHandle, uint eventId)
        {
            // TODO: accurately represent and implement those events.
            KEvent targetEvent = null;

            switch (eventId)
            {
                case 0x1:
                    targetEvent = _errorEvent;
                    break;
                case 0x2:
                    targetEvent = _unknownEvent;
                    break;
            }

            if (targetEvent != null)
            {
                if (Context.Process.HandleTable.GenerateHandle(targetEvent.ReadableEvent, out eventHandle) != Result.Success)
                {
                    throw new InvalidOperationException("Out of handles!");
                }
            }
            else
            {
                eventHandle = 0;

                return NvInternalResult.InvalidInput;
            }

            return NvInternalResult.Success;
        }

        public override void Close() { }

        private NvInternalResult ZcullGetCtxSize(ref ZcullGetCtxSizeArguments arguments)
        {
            arguments.Size = 1;

            return NvInternalResult.Success;
        }

        private NvInternalResult ZcullGetInfo(ref ZcullGetInfoArguments arguments)
        {
#pragma warning disable IDE0055 // Disable formatting
            arguments.WidthAlignPixels           = 0x20;
            arguments.HeightAlignPixels          = 0x20;
            arguments.PixelSquaresByAliquots     = 0x400;
            arguments.AliquotTotal               = 0x800;
            arguments.RegionByteMultiplier       = 0x20;
            arguments.RegionHeaderSize           = 0x20;
            arguments.SubregionHeaderSize        = 0xc0;
            arguments.SubregionWidthAlignPixels  = 0x20;
            arguments.SubregionHeightAlignPixels = 0x40;
            arguments.SubregionCount             = 0x10;
#pragma warning restore IDE0055

            return NvInternalResult.Success;
        }

        private NvInternalResult ZbcSetTable(ref ZbcSetTableArguments arguments)
        {
            Logger.Stub?.PrintStub(LogClass.ServiceNv);

            return NvInternalResult.Success;
        }

        private NvInternalResult GetCharacteristics(ref GetCharacteristicsArguments arguments)
        {
            return GetCharacteristics(ref arguments, ref arguments.Characteristics);
        }

        private NvInternalResult GetCharacteristics(ref GetCharacteristicsArguments arguments, ref GpuCharacteristics characteristics)
        {
            arguments.Header.BufferSize = 0xa0;

#pragma warning disable IDE0055 // Disable formatting
            characteristics.Arch                   = 0x120;
            characteristics.Impl                   = 0xb;
            characteristics.Rev                    = 0xa1;
            characteristics.NumGpc                 = 0x1;
            characteristics.L2CacheSize            = 0x40000;
            characteristics.OnBoardVideoMemorySize = 0x0;
            characteristics.NumTpcPerGpc           = 0x2;
            characteristics.BusType                = 0x20;
            characteristics.BigPageSize            = 0x20000;
            characteristics.CompressionPageSize    = 0x20000;
            characteristics.PdeCoverageBitCount    = 0x1b;
            characteristics.AvailableBigPageSizes  = 0x30000;
            characteristics.GpcMask                = 0x1;
            characteristics.SmArchSmVersion        = 0x503;
            characteristics.SmArchSpaVersion       = 0x503;
            characteristics.SmArchWarpCount        = 0x80;
            characteristics.GpuVaBitCount          = 0x28;
            characteristics.Reserved               = 0x0;
            characteristics.Flags                  = 0x55;
            characteristics.TwodClass              = 0x902d;
            characteristics.ThreedClass            = 0xb197;
            characteristics.ComputeClass           = 0xb1c0;
            characteristics.GpfifoClass            = 0xb06f;
            characteristics.InlineToMemoryClass    = 0xa140;
            characteristics.DmaCopyClass           = 0xb0b5;
            characteristics.MaxFbpsCount           = 0x1;
            characteristics.FbpEnMask              = 0x0;
            characteristics.MaxLtcPerFbp           = 0x2;
            characteristics.MaxLtsPerLtc           = 0x1;
            characteristics.MaxTexPerTpc           = 0x0;
            characteristics.MaxGpcCount            = 0x1;
            characteristics.RopL2EnMask0           = 0x21d70;
            characteristics.RopL2EnMask1           = 0x0;
            characteristics.ChipName               = 0x6230326d67;
            characteristics.GrCompbitStoreBaseHw   = 0x0;
#pragma warning restore IDE0055

            arguments.Characteristics = characteristics;

            return NvInternalResult.Success;
        }

        private NvInternalResult GetTpcMasks(ref GetTpcMasksArguments arguments)
        {
            return GetTpcMasks(ref arguments, ref arguments.TpcMask);
        }

        private NvInternalResult GetTpcMasks(ref GetTpcMasksArguments arguments, ref int tpcMask)
        {
            if (arguments.MaskBufferSize != 0)
            {
                tpcMask = 3;
                arguments.TpcMask = tpcMask;
            }

            return NvInternalResult.Success;
        }

        private NvInternalResult NumVsms(ref NumVsmsArguments arguments)
        {
            Logger.Stub?.PrintStub(LogClass.ServiceNv);

            arguments.NumVsms = 2;

            return NvInternalResult.Success;
        }

        private NvInternalResult VsmsMapping(ref VsmsMappingArguments arguments)
        {
            Logger.Stub?.PrintStub(LogClass.ServiceNv);

            arguments.Sm0GpcIndex = 0;
            arguments.Sm0TpcIndex = 0;
            arguments.Sm1GpcIndex = 0;
            arguments.Sm1TpcIndex = 1;

            return NvInternalResult.Success;
        }

        private NvInternalResult GetActiveSlotMask(ref GetActiveSlotMaskArguments arguments)
        {
            Logger.Stub?.PrintStub(LogClass.ServiceNv);

            arguments.Slot = 0x07;
            arguments.Mask = 0x01;

            return NvInternalResult.Success;
        }

        private NvInternalResult GetGpuTime(ref GetGpuTimeArguments arguments)
        {
            arguments.Timestamp = GetPTimerNanoSeconds();

            return NvInternalResult.Success;
        }

        private static ulong GetPTimerNanoSeconds()
        {
            double ticks = _pTimer.ElapsedTicks;

            return (ulong)(ticks * _ticksToNs) & 0xff_ffff_ffff_ffff;
        }
    }
}
