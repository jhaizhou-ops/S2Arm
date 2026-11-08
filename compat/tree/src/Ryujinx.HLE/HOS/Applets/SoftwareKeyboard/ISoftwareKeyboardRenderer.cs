// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using Ryujinx.HLE.UI;
using Ryujinx.Memory;

namespace Ryujinx.HLE.HOS.Applets.SoftwareKeyboard
{
    internal interface ISoftwareKeyboardRenderer
    {
        void CreateSurface(RenderingSurfaceInfo surfaceInfo);
        void DrawMutableElements(SoftwareKeyboardUIState state);
        void CopyImageToBuffer();
        bool WriteBufferToMemory(IVirtualMemoryManager destination, ulong position);
    }
}
