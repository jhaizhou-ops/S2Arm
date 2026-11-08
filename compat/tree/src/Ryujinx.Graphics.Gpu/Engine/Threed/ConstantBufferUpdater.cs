using Ryujinx.Graphics.Gpu.Memory;
using Ryujinx.Memory.Range;
using System;
using System.Runtime.InteropServices;

namespace Ryujinx.Graphics.Gpu.Engine.Threed
{
    /// <summary>
    /// Constant buffer updater.
    /// </summary>
    class ConstantBufferUpdater
    {
        private const int UniformDataCacheSize = 512;

        private readonly GpuChannel _channel;
        private readonly DeviceStateWithShadow<ThreedClassState> _state;

        // State associated with direct uniform buffer updates.
        // This state is used to attempt to batch together consecutive updates.
        private ulong _ubFollowUpAddress = 0;
        private ulong _ubByteCount = 0;
        private int _ubIndex = 0;
        private readonly int[] _ubData = new int[UniformDataCacheSize];

        /// <summary>
        /// Creates a new instance of the constant buffer updater.
        /// </summary>
        /// <param name="channel">GPU channel</param>
        /// <param name="state">Channel state</param>
        public ConstantBufferUpdater(GpuChannel channel, DeviceStateWithShadow<ThreedClassState> state)
        {
            _channel = channel;
            _state = state;
        }

        /// <summary>
        /// Binds a uniform buffer for the vertex shader stage.
        /// </summary>
        /// <param name="argument">Method call argument</param>
        public void BindVertex(int argument)
        {
            Bind(argument, ShaderType.Vertex);
        }

        /// <summary>
        /// Binds a uniform buffer for the tessellation control shader stage.
        /// </summary>
        /// <param name="argument">Method call argument</param>
        public void BindTessControl(int argument)
        {
            Bind(argument, ShaderType.TessellationControl);
        }

        /// <summary>
        /// Binds a uniform buffer for the tessellation evaluation shader stage.
        /// </summary>
        /// <param name="argument">Method call argument</param>
        public void BindTessEvaluation(int argument)
        {
            Bind(argument, ShaderType.TessellationEvaluation);
        }

        /// <summary>
        /// Binds a uniform buffer for the geometry shader stage.
        /// </summary>
        /// <param name="argument">Method call argument</param>
        public void BindGeometry(int argument)
        {
            Bind(argument, ShaderType.Geometry);
        }

        /// <summary>
        /// Binds a uniform buffer for the fragment shader stage.
        /// </summary>
        /// <param name="argument">Method call argument</param>
        public void BindFragment(int argument)
        {
            Bind(argument, ShaderType.Fragment);
        }

        /// <summary>
        /// Binds a uniform buffer for the specified shader stage.
        /// </summary>
        /// <param name="argument">Method call argument</param>
        /// <param name="type">Shader stage that will access the uniform buffer</param>
        private void Bind(int argument, ShaderType type)
        {
            bool enable = (argument & 1) != 0;

            int index = (argument >> 4) & 0x1f;

            FlushUboDirty();

            if (enable)
            {
                UniformBufferState uniformBuffer = _state.State.UniformBufferState;

                ulong address = uniformBuffer.Address.Pack();

                _channel.BufferManager.SetGraphicsUniformBuffer((int)type, index, address, (uint)uniformBuffer.Size);
            }
            else
            {
                _channel.BufferManager.SetGraphicsUniformBuffer((int)type, index, 0, 0);
            }
        }

        /// <summary>
        /// Flushes any queued UBO updates.
        /// </summary>
        public void FlushUboDirty()
        {
            if (_ubFollowUpAddress != 0)
            {
                MemoryManager memoryManager = _channel.MemoryManager;

                Span<byte> data = MemoryMarshal.Cast<int, byte>(_ubData.AsSpan(0, (int)(_ubByteCount / 4)));

                ulong gpuVa = _ubFollowUpAddress - _ubByteCount;
                MultiRange range = memoryManager.GetPhysicalRegions(gpuVa, _ubByteCount);

                if (range.Count == 1)
                {
                    // S2A（审计 #876 F-ubo-count1-stale）：用刷新这一刻的翻译，不用开批时缓存的物理地址——中间这块 GPU 地址被改映射 / 卸掉时，
                    //   旧地址已不属于它（写进别人的页）；卸掉时还会对没有映射的地址标脏，BufferCache 取不到缓冲直接空引用崩。未映射不写
                    ulong pa = range.GetSubRange(0).Address;

                    if (pa != MemoryManager.PteUnmapped && memoryManager.Physical.WriteWithRedundancyCheck(pa, data))
                    {
                        memoryManager.Physical.BufferCache.ForceDirty(memoryManager, gpuVa, _ubByteCount);
                    }
                }
                else
                {
                    // S2A（原生层 10-28，银河2 压段根修的同类排查）：上游从首个 GPU 地址翻译一次就线性写满整批（最多 2 KB），
                    // 整批跨进另一个映射的页时，后半截写进第一段之后的游戏内存（我们的物理地址就是游戏真实内存）。按真实分段逐段写
                    int offset = 0;

                    for (int i = 0; i < range.Count; i++)
                    {
                        MemoryRange subRange = range.GetSubRange(i);

                        if (subRange.Address != MemoryManager.PteUnmapped &&
                            memoryManager.Physical.WriteWithRedundancyCheck(subRange.Address, data.Slice(offset, (int)subRange.Size)))
                        {
                            memoryManager.Physical.BufferCache.ForceDirty(memoryManager, gpuVa + (ulong)offset, subRange.Size);
                        }

                        offset += (int)subRange.Size;
                    }
                }

                _ubFollowUpAddress = 0;
                _ubIndex = 0;
            }
        }

        /// <summary>
        /// Updates the uniform buffer data with inline data.
        /// </summary>
        /// <param name="argument">New uniform buffer data word</param>
        public void Update(int argument)
        {
            UniformBufferState uniformBuffer = _state.State.UniformBufferState;

            ulong address = uniformBuffer.Address.Pack() + (uint)uniformBuffer.Offset;

            if (_ubFollowUpAddress != address || _ubIndex == _ubData.Length)
            {
                FlushUboDirty();

                _ubByteCount = 0;
            }

            _ubData[_ubIndex++] = argument;

            _ubFollowUpAddress = address + 4;
            _ubByteCount += 4;

            _state.State.UniformBufferState.Offset += 4;
        }

        /// <summary>
        /// Updates the uniform buffer data with inline data.
        /// </summary>
        /// <param name="data">Data to be written to the uniform buffer</param>
        public void Update(ReadOnlySpan<int> data)
        {
            UniformBufferState uniformBuffer = _state.State.UniformBufferState;

            ulong address = uniformBuffer.Address.Pack() + (uint)uniformBuffer.Offset;

            ulong size = (ulong)data.Length * 4;

            if (_ubFollowUpAddress != address || _ubIndex + data.Length > _ubData.Length)
            {
                FlushUboDirty();

                _ubByteCount = 0;
            }

            data.CopyTo(_ubData.AsSpan(_ubIndex));
            _ubIndex += data.Length;

            _ubFollowUpAddress = address + size;
            _ubByteCount += size;

            _state.State.UniformBufferState.Offset += data.Length * 4;
        }
    }
}
