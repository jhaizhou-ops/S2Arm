namespace Ryujinx.HLE.HOS.Applets.Browser
{
    public enum WebExitReason : uint
    {
        ExitButton,
        BackButton,
        Requested,
        LastUrl,
        // S2Arm (11-04 BioShock Remastered 条款页死循环): 4 = the page closed its own window (yuzu-lineage WebExitReason::WindowClosed). Ryujinx upstream lacks it
        WindowClosed,
        ErrorDialog = 7,
    }
}
