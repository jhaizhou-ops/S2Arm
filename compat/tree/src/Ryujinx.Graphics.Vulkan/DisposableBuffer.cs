using Silk.NET.Vulkan;
using System;
using Buffer = Silk.NET.Vulkan.Buffer;

namespace Ryujinx.Graphics.Vulkan
{
    readonly struct DisposableBuffer : IDisposable
    {
        private readonly Vk _api;
        private readonly Device _device;

        public Buffer Value { get; }

        // S2A：后备分配大小（字节），描述符 range 按 VK_WHOLE_SIZE 解析真实上界与 VUID-00332 钳制用
        public int Size { get; }

        public DisposableBuffer(Vk api, Device device, Buffer buffer, int size)
        {
            _api = api;
            _device = device;
            Value = buffer;
            Size = size;
        }

        public void Dispose()
        {
            _api.DestroyBuffer(_device, Value, Span<AllocationCallbacks>.Empty);
        }
    }
}
