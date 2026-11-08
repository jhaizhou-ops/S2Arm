using Ryujinx.Horizon.Sdk.Sf.Hipc;
using System;

namespace Ryujinx.Horizon
{
    // S2Arm: hooks for in-thread direct dispatch of Horizon services (services/S2A.Services sets them; when unset,
    // behaviour is upstream's). The game's requests are processed on the game thread through the service's own
    // ServerManager (ProcessRequest), instead of the service thread's receive loop.
    static unsafe class S2AHorizonHooks
    {
        // IPC buffer descriptor addresses are 39-bit: restore bit 39 for a buffer in the part of the alias region above 2^39 (macOS;
        // same native function as Ryujinx.HLE S2AHooks.IpcAddr39). Null = as decoded.
        public static delegate* unmanaged<ulong, ulong> IpcAddr39;
        public static ulong FixIpcAddr(ulong a) => IpcAddr39 == null ? a : IpcAddr39(a);

        // Android 的显式进程收局 owner；未设置时音频服务仍由上游 Shutdown 释放。
        public static Action<IDisposable> AudioCreated;

        // A server port was registered with a manager (sm RegisterService / ManageNamedPort succeeded)
        public static Action<ServerManagerBase, Server> PortRegistered;

        // A session was registered (after accept / CreateSession, and after each processed request); when set, the session
        // is not linked to the manager's wait list (the service thread's loop never serves it)
        public static Action<ServerManagerBase, ServerSession> SessionRegistered;
    }
}
