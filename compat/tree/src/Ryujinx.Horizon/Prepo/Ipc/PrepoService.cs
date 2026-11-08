using MsgPack;
using MsgPack.Serialization;
using Ryujinx.Common.Logging;
using Ryujinx.Common.Utilities;
using Ryujinx.Horizon.Common;
using Ryujinx.Horizon.Prepo.Types;
using Ryujinx.Horizon.Sdk.Account;
using Ryujinx.Horizon.Sdk.Arp;
using Ryujinx.Horizon.Sdk.Prepo;
using Ryujinx.Horizon.Sdk.Sf;
using Ryujinx.Horizon.Sdk.Sf.Hipc;
using System;
using System.Text;
using ApplicationId = Ryujinx.Horizon.Sdk.Ncm.ApplicationId;

namespace Ryujinx.Horizon.Prepo.Ipc
{
    partial class PrepoService : IPrepoService
    {
        private readonly ArpApi _arp;
        private readonly PrepoServicePermissionLevel _permissionLevel;
        private ulong _systemSessionId;

        private bool _immediateTransmissionEnabled;
        private bool _userAgreementCheckEnabled = true;

        public PrepoService(ArpApi arp, PrepoServicePermissionLevel permissionLevel)
        {
            _arp = arp;
            _permissionLevel = permissionLevel;
        }

        [CmifCommand(10100)] // 1.0.0-5.1.0
        [CmifCommand(10102)] // 6.0.0-9.2.0
        [CmifCommand(10104)] // 10.0.0+
        public Result SaveReportOld([Buffer(HipcBufferFlags.In | HipcBufferFlags.Pointer)] ReadOnlySpan<byte> gameRoomBuffer, [Buffer(HipcBufferFlags.In | HipcBufferFlags.MapAlias)] ReadOnlySpan<byte> reportBuffer, [ClientProcessId] ulong pid)
        {
            if ((_permissionLevel & PrepoServicePermissionLevel.User) == 0)
            {
                return PrepoResult.PermissionDenied;
            }

            ProcessPlayReport(PlayReportKind.Normal, gameRoomBuffer, reportBuffer, pid, Uid.Null);

            return Result.Success;
        }

        [CmifCommand(10106)] // 21.0.0+
        public Result SaveReport([Buffer(HipcBufferFlags.In | HipcBufferFlags.Pointer)] ReadOnlySpan<byte> gameRoomBuffer, [Buffer(HipcBufferFlags.In | HipcBufferFlags.MapAlias)] ReadOnlySpan<byte> reportBuffer, [ClientProcessId] ulong pid, bool optInCheckEnabled)
        {
            if ((_permissionLevel & PrepoServicePermissionLevel.User) == 0)
            {
                return PrepoResult.PermissionDenied;
            }

            ProcessPlayReport(PlayReportKind.Normal, gameRoomBuffer, reportBuffer, pid, Uid.Null);

            return Result.Success;
        }

        [CmifCommand(10101)] // 1.0.0-5.1.0
        [CmifCommand(10103)] // 6.0.0-9.2.0
        [CmifCommand(10105)] // 10.0.0+
        public Result SaveReportWithUserOld(Uid userId, [Buffer(HipcBufferFlags.In | HipcBufferFlags.Pointer)] ReadOnlySpan<byte> gameRoomBuffer, [Buffer(HipcBufferFlags.In | HipcBufferFlags.MapAlias)] ReadOnlySpan<byte> reportBuffer, [ClientProcessId] ulong pid)
        {
            if ((_permissionLevel & PrepoServicePermissionLevel.User) == 0)
            {
                return PrepoResult.PermissionDenied;
            }

            ProcessPlayReport(PlayReportKind.Normal, gameRoomBuffer, reportBuffer, pid, userId, true);

            return Result.Success;
        }

        [CmifCommand(10107)] // 21.0.0+
        public Result SaveReportWithUser(Uid userId, [Buffer(HipcBufferFlags.In | HipcBufferFlags.Pointer)] ReadOnlySpan<byte> gameRoomBuffer, [Buffer(HipcBufferFlags.In | HipcBufferFlags.MapAlias)] ReadOnlySpan<byte> reportBuffer, [ClientProcessId] ulong pid, bool optInCheckEnabled)
        {
            if ((_permissionLevel & PrepoServicePermissionLevel.User) == 0)
            {
                return PrepoResult.PermissionDenied;
            }

            ProcessPlayReport(PlayReportKind.Normal, gameRoomBuffer, reportBuffer, pid, userId, true);

            return Result.Success;
        }

        [CmifCommand(10200)]
        public Result RequestImmediateTransmission()
        {
            _immediateTransmissionEnabled = true;

            // It signals an event of nn::prepo::detail::service::core::TransmissionStatusManager that requests the transmission of the report.
            // Since we don't use reports, it's fine to do nothing.

            return Result.Success;
        }

        [CmifCommand(10300)]
        public Result GetTransmissionStatus(out int status)
        {
            status = 0;

            if (_immediateTransmissionEnabled && _userAgreementCheckEnabled)
            {
                status = 1;
            }

            return Result.Success;
        }

        [CmifCommand(10400)] // 9.0.0+
        public Result GetSystemSessionId(out ulong systemSessionId)
        {
            systemSessionId = default;

            if ((_permissionLevel & PrepoServicePermissionLevel.User) == 0)
            {
                return PrepoResult.PermissionDenied;
            }

            if (_systemSessionId == 0)
            {
                _systemSessionId = (ulong)Random.Shared.NextInt64();
            }

            systemSessionId = _systemSessionId;

            return Result.Success;
        }

        // S2Arm：Switch 2 nn::prepo::PlayReport::Send(Uid) 的发送命令（时之笛 0400486024DEC000 玩法转场发）。线上格式取自时之笛 sdk 代理 0x5aba60 / 发送助手 0x5ac640：
        //   域消息；pid；X 缓冲 = 事件名（含结尾 NUL）；复制句柄 1 个 = 报告缓冲建成的传输内存（PlayReportImpl::Send 0x5aadc0 以权限「无」建，IPC 一返回就销毁，所以报告要在本命令里同步收完）；
        //   数据 u8 @0 = 是否做同意检查、u32 @4 = 报告缓冲容量（传输内存长）、u32 @8 = 报告长、Uid @0x10、u64 @0x20 = pid 占位；回出对象 IAsyncContext。
        //   本机离线、报告不上传：照存报告（10107）收下并记一行，回已完成、结果成功的异步上下文
        [CmifCommand(10500)] // Switch 2
        public Result SendReportWithUser(
            out IAsyncContext asyncContext,
            bool optInCheckEnabled,
            uint transferMemorySize,
            uint reportSize,
            Uid userId,
            [Buffer(HipcBufferFlags.In | HipcBufferFlags.Pointer)] ReadOnlySpan<byte> eventIdBuffer,
            [CopyHandle] int transferMemoryHandle,
            [ClientProcessId] ulong pid)
        {
            asyncContext = null;

            try
            {
                if ((_permissionLevel & PrepoServicePermissionLevel.User) == 0)
                {
                    return PrepoResult.PermissionDenied;
                }

                if (reportSize > transferMemorySize)
                {
                    throw new NotImplementedException($"prepo:u 10500：报告长 0x{reportSize:X} 超过传输内存长 0x{transferMemorySize:X}（sdk 不会这样发，真机回什么不知道）");
                }

                ulong address = HorizonStatic.Syscall.GetTransferMemoryAddress(transferMemoryHandle);

                if (address == 0)
                {
                    throw new NotImplementedException($"prepo:u 10500：句柄 0x{transferMemoryHandle:X} 不是传输内存（真机回什么不知道）");
                }

                Result result = ProcessPlayReport(PlayReportKind.Normal, eventIdBuffer, HorizonStatic.AddressSpace.GetSpan(address, (int)reportSize), pid, userId, true);

                if (result.IsFailure)
                {
                    return result;
                }

                asyncContext = new AsyncContext(Result.Success);

                return Result.Success;
            }
            finally
            {
                HorizonStatic.Syscall.CloseHandle(transferMemoryHandle);
            }
        }

        [CmifCommand(20100)]
        public Result SaveSystemReport([Buffer(HipcBufferFlags.In | HipcBufferFlags.Pointer)] ReadOnlySpan<byte> gameRoomBuffer, ApplicationId applicationId, [Buffer(HipcBufferFlags.In | HipcBufferFlags.MapAlias)] ReadOnlySpan<byte> reportBuffer)
        {
            if ((_permissionLevel & PrepoServicePermissionLevel.System) != 0)
            {
                return PrepoResult.PermissionDenied;
            }

            return ProcessPlayReport(PlayReportKind.System, gameRoomBuffer, reportBuffer, 0, Uid.Null, false, applicationId);
        }

        [CmifCommand(20101)]
        public Result SaveSystemReportWithUser(Uid userId, [Buffer(HipcBufferFlags.In | HipcBufferFlags.Pointer)] ReadOnlySpan<byte> gameRoomBuffer, ApplicationId applicationId, [Buffer(HipcBufferFlags.In | HipcBufferFlags.MapAlias)] ReadOnlySpan<byte> reportBuffer)
        {
            if ((_permissionLevel & PrepoServicePermissionLevel.System) != 0)
            {
                return PrepoResult.PermissionDenied;
            }

            return ProcessPlayReport(PlayReportKind.System, gameRoomBuffer, reportBuffer, 0, userId, true, applicationId);
        }

        [CmifCommand(40100)] // 2.0.0+
        public Result IsUserAgreementCheckEnabled(out bool enabled)
        {
            enabled = false;

            if (_permissionLevel is PrepoServicePermissionLevel.User or PrepoServicePermissionLevel.System)
            {
                enabled = _userAgreementCheckEnabled;

                // If "enabled" is false, it sets some internal fields to 0.
                // Then, it mounts "prepo-sys:/is_user_agreement_check_enabled.bin" and returns the contained bool.
                // We can return the private bool instead, we don't care about the agreement since we don't send reports.

                return Result.Success;
            }

            return PrepoResult.PermissionDenied;
        }

        [CmifCommand(40101)] // 2.0.0+
        public Result SetUserAgreementCheckEnabled(bool enabled)
        {
            if (_permissionLevel is PrepoServicePermissionLevel.User or PrepoServicePermissionLevel.System)
            {
                _userAgreementCheckEnabled = enabled;

                // If "enabled" is false, it sets some internal fields to 0.
                // Then, it mounts "prepo-sys:/is_user_agreement_check_enabled.bin" and stores the "enabled" value.
                // We can store in the private bool instead, we don't care about the agreement since we don't send reports.

                return Result.Success;
            }

            return PrepoResult.PermissionDenied;
        }

        private const int MaxParsedReportSize = 64 * 1024;

        private Result ProcessPlayReport(PlayReportKind playReportKind, ReadOnlySpan<byte> gameRoomBuffer, ReadOnlySpan<byte> reportBuffer, ulong pid, Uid userId, bool withUserId = false, ApplicationId applicationId = default)
        {
            if (withUserId)
            {
                if (userId.IsNull)
                {
                    return PrepoResult.InvalidArgument;
                }
            }

            if (gameRoomBuffer.Length > 31)
            {
                return PrepoResult.InvalidArgument;
            }

            string gameRoom = Encoding.UTF8.GetString(gameRoomBuffer).TrimEnd();

            if (gameRoom == string.Empty)
            {
                return PrepoResult.InvalidState;
            }

            if (reportBuffer.Length == 0)
            {
                return PrepoResult.InvalidBufferSize;
            }

            // S2Arm: play reports are only logged here; parsing one materializes a managed copy and an object tree as large as the report.
            // Above a fixed cap log the size only (iPhone low address space is scarce; nothing is uploaded either way)
            if (reportBuffer.Length > MaxParsedReportSize)
            {
                Logger.Info?.Print(LogClass.ServicePrepo, $"PlayReport {playReportKind} in room {gameRoom}: {reportBuffer.Length} bytes (not parsed, over {MaxParsedReportSize})");

                return Result.Success;
            }

            // S2Arm: 没人订阅 PlayReport 事件时（S2Arm 全仓没有订阅者，报告也不上传）不解析、不排版、不起线程，只记一行长度（帧率能耗线 10-24）。
            //   原先每份报告解成 MessagePack 对象树、整份排成缩进 JSON（字节数组每字节 6 字符）、经四五次整串拷贝写日志：
            //   真机马车8 读盘段第 412–420 帧一批报告产 69 MB 字符串，夹着一次 28 ms gen1；服务层单测 32 KB 报告整进程分配 2524 KB。返回码不变（pid 照旧经 arp 核）
            if (!HorizonStatic.HasPlayReportHandlers)
            {
                if (_arp.GetApplicationInstanceId(out _, pid).IsFailure)
                {
                    return PrepoResult.InvalidPid;
                }

                Logger.Info?.Print(LogClass.ServicePrepo, $"PlayReport {playReportKind} in room {gameRoom}: {reportBuffer.Length} bytes (not parsed: no subscriber)");

                return Result.Success;
            }

            StringBuilder builder = new();
            MessagePackObject deserializedReport = MessagePackSerializer.UnpackMessagePackObject(reportBuffer.ToArray());

            PlayReport playReport = new()
            {
                Kind = playReportKind,
                Room = gameRoom,
                ReportData = deserializedReport
            };

            builder.AppendLine();
            builder.AppendLine("PlayReport log:");
            builder.AppendLine($" Kind: {playReportKind}");

            // NOTE: Reports are stored internally and an event is signaled to transmit them.

            if (pid != 0)
            {
                builder.AppendLine($" Pid: {pid}");
                playReport.Pid = pid;
            }
            else
            {
                builder.AppendLine($" ApplicationId: {applicationId}");
                playReport.AppId = applicationId;
            }

            Result result = _arp.GetApplicationInstanceId(out ulong applicationInstanceId, pid);
            if (result.IsFailure)
            {
                return PrepoResult.InvalidPid;
            }

            _arp.GetApplicationLaunchProperty(out ApplicationLaunchProperty applicationLaunchProperty, applicationInstanceId).AbortOnFailure();

            playReport.Version = applicationLaunchProperty.Version;

            builder.AppendLine($" ApplicationVersion: {applicationLaunchProperty.Version}");

            if (!userId.IsNull)
            {
                builder.AppendLine($" UserId: {userId}");
                playReport.UserId = userId;
            }

            builder.AppendLine($" Room: {gameRoom}");
            builder.AppendLine($" Report: {MessagePackObjectFormatter.Format(deserializedReport)}");

            HorizonStatic.HandlePlayReport(playReport);

            Logger.Info?.Print(LogClass.ServicePrepo, builder.ToString());

            return Result.Success;
        }
    }
}
