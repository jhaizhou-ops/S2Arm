using Microsoft.IO;
using Ryujinx.Common.Logging;
using Ryujinx.Common.Memory;
using Ryujinx.HLE.HOS.Services.Am.AppletAE;
using Ryujinx.HLE.HOS.Services.Hid;
using Ryujinx.HLE.HOS.Services.Hid.Types;
using System;
using System.IO;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using static Ryujinx.HLE.HOS.Services.Hid.HidServer.HidUtils;

namespace Ryujinx.HLE.HOS.Applets
{
    internal class ControllerApplet : IApplet
    {
        private readonly Horizon _system;

        private AppletSession _normalSession;

        // S2Arm：上一次手柄设置的请求与应答（每次拉起都新建小程序实例，故放静态；按 Horizon 实例区分，同进程重启不串）
        private static Horizon s_lastSystem;
        private static byte[] s_lastPrivate = [];
        private static byte[] s_lastArg = [];
        private static PlayerIndex s_lastPrimary = PlayerIndex.Unknown;

        public event EventHandler AppletStateChanged;

        public ControllerApplet(Horizon system)
        {
            _system = system;
        }

        public ResultCode Start(AppletSession normalSession, AppletSession interactiveSession)
        {
            _normalSession = normalSession;

            byte[] launchParams = _normalSession.Pop();
            byte[] controllerSupportArgPrivate = _normalSession.Pop();
            ControllerSupportArgPrivate privateArg = IApplet.ReadStruct<ControllerSupportArgPrivate>(controllerSupportArgPrivate);

            Logger.Stub?.PrintStub(LogClass.ServiceHid, $"ControllerApplet ArgPriv {privateArg.PrivateSize} {privateArg.ArgSize} {privateArg.Mode} " +
                        $"HoldType:{(NpadJoyHoldType)privateArg.NpadJoyHoldType} StyleSets:{(ControllerType)privateArg.NpadStyleSet}");

            if (privateArg.Mode != ControllerSupportMode.ShowControllerSupport)
            {
                _normalSession.Push(BuildResponse()); // Dummy response for other modes
                AppletStateChanged?.Invoke(this, null);

                // S2Arm：其余模式（腕带说明 / 手柄固件更新等）结束时同样把焦点还给游戏，同本文件 ShowControllerSupport 与其余小程序。
                //   真机小程序结束游戏会收到回到焦点的消息；Let's Get Fit 7 分钟处 ShowControllerStrapGuide 后等这条，原先不发 → 卡在「安全区」页、任何键都没反应
                _system.ReturnFocus();

                return ResultCode.Success;
            }

            byte[] controllerSupportArg = _normalSession.Pop();

            ControllerSupportArgHeader argHeader;

            if (privateArg.ArgSize == Marshal.SizeOf<ControllerSupportArgV7>())
            {
                ControllerSupportArgV7 arg = IApplet.ReadStruct<ControllerSupportArgV7>(controllerSupportArg);
                argHeader = arg.Header;

                Logger.Stub?.PrintStub(LogClass.ServiceHid, $"ControllerSupportArg Version 7 EnableExplainText={arg.EnableExplainText != 0}");
                // Read enable text here?
            }
            else if (privateArg.ArgSize == Marshal.SizeOf<ControllerSupportArgVPre7>())
            {
                ControllerSupportArgVPre7 arg = IApplet.ReadStruct<ControllerSupportArgVPre7>(controllerSupportArg);
                argHeader = arg.Header;

                Logger.Stub?.PrintStub(LogClass.ServiceHid, $"ControllerSupportArg Version Pre-7 EnableExplainText={arg.EnableExplainText != 0}");
                // Read enable text here?
            }
            else
            {
                Logger.Stub?.PrintStub(LogClass.ServiceHid, "ControllerSupportArg Version Unknown");

                argHeader = IApplet.ReadStruct<ControllerSupportArgHeader>(controllerSupportArg); // Read just the header
            }

            int playerMin = argHeader.PlayerCountMin;
            int playerMax = argHeader.PlayerCountMax;
            bool singleMode = argHeader.EnableSingleMode != 0;

            Logger.Stub?.PrintStub(LogClass.ServiceHid, $"ControllerApplet Arg {playerMin} {playerMax} {argHeader.EnableTakeOverConnection} {argHeader.EnableSingleMode} LeftJustify={argHeader.EnableLeftJustify} PermitJoyDual={argHeader.EnablePermitJoyDual}");

            if (singleMode)
            {
                // Applications can set an arbitrary player range even with SingleMode, so clamp it
                playerMin = playerMax = 1;
            }

            // S2Arm：游戏紧接着用同样参数再拉起手柄设置 = 上次答的掌机格游戏不收（11-05 超级舞动 瓦力欧制造：样式 Handheld + JoyconPair，
            //   答掌机格后每帧重开、整局 14949 次）。真机上玩家这时照游戏提示拆下 Joy-Con、在小程序里改接法；这里同样把掌机格从本次可接受样式里去掉，
            //   交宿主改接游戏收的非掌机样式（如双 Joy-Con 接 Player1）。参数不同或上次不是掌机格就照原样
            ControllerType acceptedStyles = (ControllerType)privateArg.NpadStyleSet;
            bool sameRequest = ReferenceEquals(s_lastSystem, _system) && controllerSupportArgPrivate.AsSpan().SequenceEqual(s_lastPrivate) && controllerSupportArg.AsSpan().SequenceEqual(s_lastArg);
            if (sameRequest && s_lastPrimary == PlayerIndex.Handheld && (acceptedStyles & ~ControllerType.Handheld) != 0)
            {
                acceptedStyles &= ~ControllerType.Handheld;
                Logger.Info?.Print(LogClass.ServiceHid, $"ControllerApplet: same request re-launched after a Handheld answer, offering {acceptedStyles} instead");
            }

            int configuredCount;
            PlayerIndex primaryIndex;
            while (!_system.Device.Hid.Npads.Validate(playerMin, playerMax, acceptedStyles, out configuredCount, out primaryIndex))
            {
                ControllerAppletUIArgs uiArgs = new()
                {
                    PlayerCountMin = playerMin,
                    PlayerCountMax = playerMax,
                    SupportedStyles = acceptedStyles,
                    SupportedPlayers = _system.Device.Hid.Npads.GetSupportedPlayers(),
                    IsDocked = _system.State.DockedMode,
                };

                if (!_system.Device.UIHandler.DisplayMessageDialog(uiArgs))
                {
                    break;
                }
            }

            ControllerSupportResultInfo result = new()
            {
                PlayerCount = (sbyte)configuredCount,
                SelectedId = (uint)GetNpadIdTypeFromIndex(primaryIndex),
            };

            Logger.Stub?.PrintStub(LogClass.ServiceHid, $"ControllerApplet ReturnResult {result.PlayerCount} {result.SelectedId}");

            (s_lastSystem, s_lastPrivate, s_lastArg, s_lastPrimary) = (_system, controllerSupportArgPrivate, controllerSupportArg, primaryIndex);

            _normalSession.Push(BuildResponse(result));
            AppletStateChanged?.Invoke(this, null);

            _system.ReturnFocus();

            return ResultCode.Success;
        }

        private static byte[] BuildResponse(ControllerSupportResultInfo result)
        {
            using RecyclableMemoryStream stream = MemoryStreamManager.Shared.GetStream();
            using BinaryWriter writer = new(stream);

            writer.Write(MemoryMarshal.AsBytes(MemoryMarshal.CreateReadOnlySpan(ref result, Unsafe.SizeOf<ControllerSupportResultInfo>())));

            return stream.ToArray();
        }

        private static byte[] BuildResponse()
        {
            using RecyclableMemoryStream stream = MemoryStreamManager.Shared.GetStream();
            using BinaryWriter writer = new(stream);

            writer.Write((ulong)ResultCode.Success);

            return stream.ToArray();
        }
    }
}
