using Silk.NET.Vulkan;
using System;

namespace Ryujinx.Graphics.Vulkan
{
    static class FenceHelper
    {
        private const ulong DefaultTimeout = 100000000; // 100ms

        public static bool AnySignaled(Vk api, Device device, ReadOnlySpan<Fence> fences, ulong timeout = 0)
        {
            long started = timeout > 0 ? S2AFrameTrace.Begin() : 0;
            Result result;
            try { result = api.WaitForFences(device, (uint)fences.Length, fences, false, timeout); }
            finally { S2AFrameTrace.EndFence(started); }
            result.ThrowOnError();
            return result == Result.Success;
        }

        public static bool AllSignaled(Vk api, Device device, ReadOnlySpan<Fence> fences, ulong timeout = 0)
        {
            long started = timeout > 0 ? S2AFrameTrace.Begin() : 0;
            Result result;
            try { result = api.WaitForFences(device, (uint)fences.Length, fences, true, timeout); }
            finally { S2AFrameTrace.EndFence(started); }
            result.ThrowOnError();
            return result == Result.Success;
        }

        public static void WaitAllIndefinitely(Vk api, Device device, ReadOnlySpan<Fence> fences)
        {
            Result result;
            do
            {
                long started = S2AFrameTrace.Begin();
                try { result = api.WaitForFences(device, (uint)fences.Length, fences, true, DefaultTimeout); }
                finally { S2AFrameTrace.EndFence(started); }
            }
            while (result == Result.Timeout);
            result.ThrowOnError();
        }
    }
}
