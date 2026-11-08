namespace Ryujinx.HLE.HOS.Services.Am.AppletAE
{
    enum AppletId
    {
        Application = 0x01,
        OverlayDisplay = 0x02,
        QLaunch = 0x03,
        Starter = 0x04,
        Auth = 0x0A,
        Cabinet = 0x0B,
        Controller = 0x0C,
        DataErase = 0x0D,
        Error = 0x0E,
        NetConnect = 0x0F,
        PlayerSelect = 0x10,
        SoftwareKeyboard = 0x11,
        MiiEdit = 0x12,
        LibAppletWeb = 0x13,
        LibAppletShop = 0x14,
        PhotoViewer = 0x15,
        Settings = 0x16,
        LibAppletOff = 0x17,
        LibAppletWhitelisted = 0x18,
        LibAppletAuth = 0x19,
        MyPage = 0x1A,
    }

    // S2Arm (11-02 Pokopia 起名卡死): Switch 2 SDKs pass library applet ids as 0x01vv00ii, where ii is the Switch 1 id
    //   (software keyboard 0x01020011, error 0x0100000E, player select 0x01000010, shop 0x01000014, MyPage 0x0100001A,
    //   controller 0x0100000C, data erase 0x0100000D). Taken as is, every one fell to the dummy applet and Pokopia
    //   recreated the keyboard every 20 ms for good (7502 times in one hand test), the player frozen in the naming dialogue.
    static class AppletIdWire
    {
        public static AppletId Read(uint raw) => (raw >> 24) == 0x01 ? (AppletId)(raw & 0xFF) : (AppletId)raw;
    }
}
