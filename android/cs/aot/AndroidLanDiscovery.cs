// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using System;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using S2A.Services;

namespace S2A.Android.Aot;

internal static unsafe class AndroidLanDiscovery
{
    [DllImport("s2a_native")]
    private static extern LanDiscoveryV1* s2a_android_lan_provider(delegate* unmanaged<byte*, void> setServer);

    [ModuleInitializer]
    internal static void Register() => Native.RegisterLanDiscovery(s2a_android_lan_provider(&SetServer));
    [UnmanagedCallersOnly]
    private static void SetServer(byte* ipv4)
    {
        try { Host.SetLdnServer(ipv4 == null ? null : Marshal.PtrToStringUTF8((nint)ipv4)); }
        catch (Exception) { /* Never unwind managed exceptions through JNI/native callbacks. */ }
    }
}
