using Ryujinx.Common;
using Silk.NET.Vulkan;
using System;

namespace Ryujinx.Graphics.Vulkan
{
    static class ResultExtensions
    {
        extension(Result result)
        {
            public bool IsError => result < Result.Success;

            public void ThrowOnError()
            {
                // Only negative result codes are errors.
                if (result.IsError)
                {
                    if (result == Result.ErrorDeviceLost)
                    {
                        // 诊断失败不能取代原始 DeviceLost。
                        try { S2AGsDiag.DumpLost(); }
                        catch (Exception) { }
                    }

                    throw new VulkanException(result);
                }
            }
        }
    }

    class VulkanException : Exception
    {
        public VulkanException()
        {
        }

        public VulkanException(Result result) : base($"Unexpected API error \"{result}\".")
        {
        }

        public VulkanException(string message) : base(message)
        {
        }

        public VulkanException(string message, Exception innerException) : base(message, innerException)
        {
        }
    }
}
