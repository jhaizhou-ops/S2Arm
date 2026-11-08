using Ryujinx.Common.Logging;
using Ryujinx.Cpu;
using Ryujinx.HLE.HOS.Ipc;
using Ryujinx.HLE.HOS.Kernel.Threading;
using Ryujinx.HLE.HOS.Services.Time.TimeZone;
using Ryujinx.HLE.Utilities;
using Ryujinx.Memory;
using System;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Text;

namespace Ryujinx.HLE.HOS.Services.Time.StaticService
{
    class ITimeZoneServiceForGlue : IpcService
    {
        private readonly TimeZoneContentManager _timeZoneContentManager;
        private readonly ITimeZoneServiceForPsc _inner;
        private readonly bool _writePermission;

        public ITimeZoneServiceForGlue(TimeZoneContentManager timeZoneContentManager, bool writePermission)
        {
            _timeZoneContentManager = timeZoneContentManager;
            _writePermission = writePermission;
            _inner = new ITimeZoneServiceForPsc(timeZoneContentManager.Manager, writePermission);
        }

        [CommandCmif(0)]
        // GetDeviceLocationName() -> nn::time::LocationName
        public ResultCode GetDeviceLocationName(ServiceCtx context)
        {
            return _inner.GetDeviceLocationName(context);
        }

        [CommandCmif(1)]
        // SetDeviceLocationName(nn::time::LocationName)
        public ResultCode SetDeviceLocationName(ServiceCtx context)
        {
            if (!_writePermission)
            {
                return ResultCode.PermissionDenied;
            }

            string locationName = StringUtils.ReadInlinedAsciiString(context.RequestData, 0x24);

            ResultCode result = _timeZoneContentManager.SetDeviceLocationName(locationName);

            if (result == ResultCode.Success)
            {
                _locationNameOperationEvent?.ReadableEvent.Signal();
            }

            return result;
        }

        [CommandCmif(2)]
        // GetTotalLocationNameCount() -> u32
        public ResultCode GetTotalLocationNameCount(ServiceCtx context)
        {
            return _inner.GetTotalLocationNameCount(context);
        }

        [CommandCmif(3)]
        // LoadLocationNameList(u32 index) -> (u32 outCount, buffer<nn::time::LocationName, 6>)
        public ResultCode LoadLocationNameList(ServiceCtx context)
        {
            uint index = context.RequestData.ReadUInt32();
            ulong bufferPosition = context.Request.ReceiveBuff[0].Position;
            ulong bufferSize = context.Request.ReceiveBuff[0].Size;

            ResultCode errorCode = _timeZoneContentManager.LoadLocationNameList(index, out string[] locationNameArray, (uint)bufferSize / 0x24);

            if (errorCode == 0)
            {
                uint offset = 0;

                foreach (string locationName in locationNameArray)
                {
                    int padding = 0x24 - locationName.Length;

                    if (padding < 0)
                    {
                        return ResultCode.LocationNameTooLong;
                    }

                    context.Memory.Write(bufferPosition + offset, Encoding.ASCII.GetBytes(locationName));
                    MemoryHelper.FillWithZeros(context.Memory, bufferPosition + offset + (ulong)locationName.Length, padding);

                    offset += 0x24;
                }

                context.ResponseData.Write((uint)locationNameArray.Length);
            }

            return errorCode;
        }

        [CommandCmif(4)]
        // LoadTimeZoneRule(nn::time::LocationName locationName) -> buffer<nn::time::TimeZoneRule, 0x16>
        public ResultCode LoadTimeZoneRule(ServiceCtx context)
        {
            ulong bufferPosition = context.Request.ReceiveBuff[0].Position;
            ulong bufferSize = context.Request.ReceiveBuff[0].Size;

            if (bufferSize != 0x4000)
            {
                // TODO: find error code here
                Logger.Error?.Print(LogClass.ServiceTime, $"TimeZoneRule buffer size is 0x{bufferSize:x} (expected 0x4000)");

                throw new InvalidOperationException();
            }

            string locationName = StringUtils.ReadInlinedAsciiString(context.RequestData, 0x24);

            using WritableRegion region = context.Memory.GetWritableRegion(bufferPosition, Unsafe.SizeOf<TimeZoneRule>());

            ref TimeZoneRule rules = ref MemoryMarshal.Cast<byte, TimeZoneRule>(region.Memory.Span)[0];

            return _timeZoneContentManager.LoadTimeZoneRule(ref rules, locationName);
        }

        // S2Arm：glue 的 5 / 6 / 7 / 8 / 20（9.0.0+，4 款 Switch 2 游戏 sdk 的 ITimeZoneService 代理表含 0–8、20、100、101、201、202）。
        //   事实取自 Eden-NS2（GPL，代码自写）glue/time/time_zone.cpp：5 / 6 转给 psc 的实现；7 先查写权限、再回未实现；8 回未实现；
        //   20 交出「设备时区变更」事件（本会话 SetDeviceLocationName 成功时触发）
        [CommandCmif(5)] // 2.0.0+
        // GetTimeZoneRuleVersion() -> nn::time::TimeZoneRuleVersion
        public ResultCode GetTimeZoneRuleVersion(ServiceCtx context)
        {
            return _inner.GetTimeZoneRuleVersion(context);
        }

        [CommandCmif(6)] // 5.0.0+
        // GetDeviceLocationNameAndUpdatedTime() -> (nn::time::LocationName, nn::time::SteadyClockTimePoint)
        public ResultCode GetDeviceLocationNameAndUpdatedTime(ServiceCtx context)
        {
            return _inner.GetDeviceLocationNameAndUpdatedTime(context);
        }

        [CommandCmif(7)] // 9.0.0+
        // SetDeviceLocationNameWithTimeZoneRule(nn::time::LocationName, buffer<nn::time::TimeZoneBinary, 0x21>)
        public ResultCode SetDeviceLocationNameWithTimeZoneRule(ServiceCtx context)
        {
            return _writePermission ? ResultCode.NotImplemented : ResultCode.PermissionDenied;
        }

        [CommandCmif(8)] // 9.0.0+
        // ParseTimeZoneBinary(buffer<nn::time::TimeZoneBinary, 0x21>) -> buffer<nn::time::TimeZoneRule, 0x16>
        public ResultCode ParseTimeZoneBinary(ServiceCtx context)
        {
            return ResultCode.NotImplemented;
        }

        private KEvent _locationNameOperationEvent;
        private int _locationNameOperationEventHandle;

        [CommandCmif(20)] // 9.0.0+
        // GetDeviceLocationNameOperationEventReadableHandle() -> handle<copy>
        public ResultCode GetDeviceLocationNameOperationEventReadableHandle(ServiceCtx context)
        {
            _locationNameOperationEvent ??= new KEvent(context.Device.System.KernelContext);

            if (_locationNameOperationEventHandle == 0 &&
                context.Process.HandleTable.GenerateHandle(_locationNameOperationEvent.ReadableEvent, out _locationNameOperationEventHandle) != Ryujinx.Horizon.Common.Result.Success)
            {
                throw new InvalidOperationException("Out of handles!");
            }

            context.Response.HandleDesc = IpcHandleDesc.MakeCopy(_locationNameOperationEventHandle);

            return ResultCode.Success;
        }

        [CommandCmif(100)]
        // ToCalendarTime(nn::time::PosixTime time, buffer<nn::time::TimeZoneRule, 0x15> rules) -> (nn::time::CalendarTime, nn::time::sf::CalendarAdditionalInfo)
        public ResultCode ToCalendarTime(ServiceCtx context)
        {
            return _inner.ToCalendarTime(context);
        }

        [CommandCmif(101)]
        // ToCalendarTimeWithMyRule(nn::time::PosixTime) -> (nn::time::CalendarTime, nn::time::sf::CalendarAdditionalInfo)
        public ResultCode ToCalendarTimeWithMyRule(ServiceCtx context)
        {
            return _inner.ToCalendarTimeWithMyRule(context);
        }

        [CommandCmif(201)]
        // ToPosixTime(nn::time::CalendarTime calendarTime, buffer<nn::time::TimeZoneRule, 0x15> rules) -> (u32 outCount, buffer<nn::time::PosixTime, 0xa>)
        public ResultCode ToPosixTime(ServiceCtx context)
        {
            return _inner.ToPosixTime(context);
        }

        [CommandCmif(202)]
        // ToPosixTimeWithMyRule(nn::time::CalendarTime calendarTime) -> (u32 outCount, buffer<nn::time::PosixTime, 0xa>)
        public ResultCode ToPosixTimeWithMyRule(ServiceCtx context)
        {
            return _inner.ToPosixTimeWithMyRule(context);
        }
    }
}
