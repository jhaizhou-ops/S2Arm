namespace Ryujinx.HLE.HOS.Services.Vi.RootService.ApplicationDisplayService
{
    class AndroidSurfaceComposerClient
    {
        // NOTE: This is android::SurfaceComposerClient::getDisplayInfo.
        public static (ulong, ulong) GetDisplayInfo(ServiceCtx context, ulong displayId = 0)
        {
            // TODO: This need to be REd, it should returns the driver resolution and more.
            // S2Arm: width / height follow the host screen aspect (S2ADisplay: wider screen widens, taller screen lengthens)
            ulong height = context.Device.System.State.DockedMode ? 1080UL : 720UL;

            return (S2ADisplay.Width(height), S2ADisplay.Height(height));
        }
    }
}
