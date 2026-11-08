// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using Ryujinx.HLE.UI;
using System;

namespace Ryujinx.HLE.HOS.Applets.SoftwareKeyboard
{
    internal static class SoftwareKeyboardRendererFactory
    {
        public static ISoftwareKeyboardRenderer Create(IHostUITheme theme)
        {
#if S2A_ANDROID_HOST
            // AndroidHostUi already rejects theme/input requests. Preserve that explicit
            // unsupported boundary; never confirm text or pretend a renderer produced pixels.
            throw new NotSupportedException("Android host UI is not connected: inline keyboard renderer");
#elif S2A_APPLE_HOST
            // Apple hosts give no UI theme, so the inline keyboard is headless and never builds a renderer.
            throw new NotSupportedException("Apple host has no inline keyboard renderer");
#else
            return new SoftwareKeyboardRendererBase(theme);
#endif
        }
    }
}
