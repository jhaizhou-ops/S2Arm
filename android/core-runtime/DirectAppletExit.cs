using System;
using System.Diagnostics.CodeAnalysis;
using System.Reflection;

namespace S2A.Android.Aot
{
    // Formal Horizon applet message, not a game SDK hook. Let the game destroy
    // its Vulkan objects/allocators on its own threads before terminal freeze.
    internal static class DirectAppletExit
    {
        [DynamicDependency("get_AppletState", "Ryujinx.HLE.HOS.Horizon", "Ryujinx.HLE")]
        [DynamicDependency("get_Messages", "Ryujinx.HLE.HOS.SystemState.AppletStateMgr", "Ryujinx.HLE")]
        [DynamicDependency("Enqueue", typeof(System.Collections.Concurrent.ConcurrentQueue<>))]
        [DynamicDependency("get_MessageEvent", "Ryujinx.HLE.HOS.SystemState.AppletStateMgr", "Ryujinx.HLE")]
        [DynamicDependency(DynamicallyAccessedMemberTypes.PublicFields, "Ryujinx.HLE.HOS.Services.Am.AppletAE.AllSystemAppletProxiesService.SystemAppletProxy.AppletMessage", "Ryujinx.HLE")]
        [DynamicDependency("get_ReadableEvent", "Ryujinx.HLE.HOS.Kernel.Threading.KEvent", "Ryujinx.HLE")]
        [DynamicDependency("Signal", "Ryujinx.HLE.HOS.Kernel.Threading.KReadableEvent", "Ryujinx.HLE")]
        internal static void Request(object horizon)
        {
            ArgumentNullException.ThrowIfNull(horizon);
            object state = Get(horizon, "AppletState");
            object messages = Get(state, "Messages");
            MethodInfo enqueue = messages.GetType().GetMethod("Enqueue")
                ?? throw new MissingMethodException("Applet message enqueue");
            Type messageType = enqueue.GetParameters()[0].ParameterType;
            if (!messageType.IsEnum || !Enum.IsDefined(messageType, 4))
                throw new InvalidOperationException("Horizon applet Exit message unavailable");
            object readable = Get(Get(state, "MessageEvent"), "ReadableEvent");
            MethodInfo signal = readable.GetType().GetMethod("Signal", Type.EmptyTypes)
                ?? throw new MissingMethodException("Applet message event Signal");
            enqueue.Invoke(messages, new[] { Enum.ToObject(messageType, 4) });
            signal.Invoke(readable, null);
        }

        private static object Get(object owner, string name) =>
            owner.GetType().GetProperty(name, BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic)
                ?.GetValue(owner) ?? throw new MissingMemberException("Horizon applet " + name);
    }
}
