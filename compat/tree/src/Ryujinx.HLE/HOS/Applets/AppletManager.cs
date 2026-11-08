using Ryujinx.Common.Logging;
using Ryujinx.HLE.HOS.Applets.Browser;
using Ryujinx.HLE.HOS.Applets.Cabinet;
using Ryujinx.HLE.HOS.Applets.Dummy;
using Ryujinx.HLE.HOS.Applets.Error;
using Ryujinx.HLE.HOS.Applets.MiiEdit;
using Ryujinx.HLE.HOS.Services.Am.AppletAE;

namespace Ryujinx.HLE.HOS.Applets
{
    static class AppletManager
    {
        public static IApplet Create(AppletId applet, Horizon system)
        {
            switch (applet)
            {
                case AppletId.Controller:
                    return new ControllerApplet(system);
                case AppletId.Error:
                    return new ErrorApplet(system);
                case AppletId.PlayerSelect:
                    return new PlayerSelectApplet(system);
                case AppletId.SoftwareKeyboard:
                    return new SoftwareKeyboardApplet(system);
                case AppletId.LibAppletWeb:
                case AppletId.LibAppletShop:
                case AppletId.LibAppletOff:
                // S2Arm (11-03 Zumba 分享截图 Break): 0x18 is the share / login / lobby web applet (switchbrew: ShareApplet and LoginApplet are 0x18; libnx webShareCreate / webLobbyCreate use
                //   AppletId_LibraryAppletLoginShare = 0x18 with WebShimKind Share / Lobby). nn::web::ShowSharePage joins it and reads exactly 0x2000
                //   bytes of output (CommonApi::JoinAndFinishLibraryApplet aborts on any other size); the dummy applet pushed 8, so the game Broke.
                //   The browser applet answers by shim kind like hardware: Share at version >= 0x30000 gets the 0x2000-byte TLV reply with only
                //   ExitReason (SharePostResult is left out; the SDK then reports its own fallback 1), Login / Lobby get WebCommonReturnValue.
                case AppletId.LibAppletWhitelisted:
                    return new BrowserApplet();
                case AppletId.MiiEdit:
                    return new MiiEditApplet(system);
                case AppletId.Cabinet:
                    return new CabinetApplet(system);
            }

            Logger.Warning?.Print(LogClass.Application, $"Applet {applet} not implemented!");
            return new DummyApplet(system);
        }
    }
}
