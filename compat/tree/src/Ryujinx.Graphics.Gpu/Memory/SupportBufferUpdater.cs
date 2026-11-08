using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Shader;
using System;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

namespace Ryujinx.Graphics.Gpu.Memory
{
    /// <summary>
    /// Support buffer data updater.
    /// </summary>
    class SupportBufferUpdater : BufferUpdater
    {
        private SupportBuffer _data;

        /// <summary>
        /// Creates a new instance of the support buffer updater.
        /// </summary>
        /// <param name="renderer">Renderer that the support buffer will be used with</param>
        public SupportBufferUpdater(IRenderer renderer) : base(renderer)
        {
            Vector4<float> defaultScale = new() { X = 1f, Y = 0f, Z = 0f, W = 0f };
            _data.RenderScale.AsSpan().Fill(defaultScale);
            _data.RenderScaleY.AsSpan().Fill(defaultScale);
            DirtyRenderScale(0, SupportBuffer.RenderScaleMaxCount);
        }

        /// <summary>
        /// Marks the fragment render scale count as being modified.
        /// </summary>
        private void DirtyFragmentRenderScaleCount()
        {
            MarkDirty(SupportBuffer.FragmentRenderScaleCountOffset, sizeof(int));
        }

        /// <summary>
        /// Marks data of a given type as being modified.
        /// </summary>
        /// <typeparam name="T">Type of the data</typeparam>
        /// <param name="baseOffset">Base offset of the data in bytes</param>
        /// <param name="offset">Index of the data, in elements</param>
        /// <param name="count">Number of elements</param>
        private void DirtyGenericField<T>(int baseOffset, int offset, int count) where T : unmanaged
        {
            int elemSize = Unsafe.SizeOf<T>();

            MarkDirty(baseOffset + offset * elemSize, count * elemSize);
        }

        /// <summary>
        /// Marks render scales as being modified.
        /// </summary>
        /// <param name="offset">Index of the first scale that was modified</param>
        /// <param name="count">Number of modified scales</param>
        private void DirtyRenderScale(int offset, int count)
        {
            DirtyGenericField<Vector4<float>>(SupportBuffer.GraphicsRenderScaleOffset, offset, count);
            DirtyGenericField<Vector4<float>>(SupportBuffer.RenderScaleYOffset, offset, count);
        }

        /// <summary>
        /// Marks render target BGRA format state as modified.
        /// </summary>
        /// <param name="offset">Index of the first render target that had its BGRA format modified</param>
        /// <param name="count">Number of render targets</param>
        private void DirtyFragmentIsBgra(int offset, int count)
        {
            DirtyGenericField<Vector4<int>>(SupportBuffer.FragmentIsBgraOffset, offset, count);
        }

        /// <summary>
        /// Updates the inverse viewport vector.
        /// </summary>
        /// <param name="data">Inverse viewport vector</param>
        private void UpdateViewportInverse(Vector4<float> data)
        {
            _data.ViewportInverse = data;

            MarkDirty(SupportBuffer.ViewportInverseOffset, SupportBuffer.FieldSize);
        }

        /// <summary>
        /// Updates the viewport size vector.
        /// </summary>
        /// <param name="data">Viewport size vector</param>
        private void UpdateViewportSize(Vector4<float> data)
        {
            _data.ViewportSize = data;

            MarkDirty(SupportBuffer.ViewportSizeOffset, SupportBuffer.FieldSize);
        }

        /// <summary>
        /// Sets the scale of all output render targets (they should all have the same scale).
        /// </summary>
        /// <param name="scale">Scale value</param>
        public void SetRenderTargetScale(float scale)
        {
            _data.RenderScale[0].X = scale;
            _data.RenderScaleY[0].X = scale;
            DirtyRenderScale(0, 1); // Just the first element.
        }

        /// <summary>
        /// Updates the render scales for shader input textures or images.
        /// </summary>
        /// <param name="index">Index of the scale</param>
        /// <param name="scale">Scale value</param>
        public void UpdateRenderScale(int index, float scale)
        {
            Span<Vector4<float>> renderScaleSpan = _data.RenderScale.AsSpan();
            
            if (renderScaleSpan[1 + index].X != scale)
            {
                renderScaleSpan[1 + index].X = scale;
                _data.RenderScaleY[1 + index].X = scale;
                DirtyRenderScale(1 + index, 1);
            }
        }

        /// <summary>
        /// Updates the render scales for shader input textures or images.
        /// </summary>
        /// <param name="totalCount">Total number of scales across all stages</param>
        /// <param name="fragmentCount">Total number of scales on the fragment shader stage</param>
        public void UpdateRenderScaleFragmentCount(int totalCount, int fragmentCount)
        {
            // Only update fragment count if there are scales after it for the vertex stage.
            if (fragmentCount != totalCount && fragmentCount != _data.FragmentRenderScaleCount.X)
            {
                _data.FragmentRenderScaleCount.X = fragmentCount;
                DirtyFragmentRenderScaleCount();
            }
        }

        /// <summary>
        /// Sets whether the format of a given render target is a BGRA format.
        /// </summary>
        /// <param name="index">Render target index</param>
        /// <param name="isBgra">True if the format is BGRA< false otherwise</param>
        public void SetRenderTargetIsBgra(int index, bool isBgra)
        {
            Span<Vector4<int>> fragmentIsBgraSpan = _data.FragmentIsBgra.AsSpan();
            
            bool isBgraChanged = fragmentIsBgraSpan[index].X != 0 != isBgra;

            if (isBgraChanged)
            {
                fragmentIsBgraSpan[index].X = isBgra ? 1 : 0;
                DirtyFragmentIsBgra(index, 1);
            }
        }

        /// <summary>
        /// Sets whether a viewport has transform disabled.
        /// </summary>
        /// <param name="viewportWidth">Value used as viewport width</param>
        /// <param name="viewportHeight">Value used as viewport height</param>
        /// <param name="scale">Render target scale</param>
        /// <param name="disableTransform">True if transform is disabled, false otherwise</param>
        public void SetViewportTransformDisable(float viewportWidth, float viewportHeight, float scale, bool disableTransform)
        {
            float disableTransformF = disableTransform ? 1.0f : 0.0f;
            if (_data.ViewportInverse.W != disableTransformF || disableTransform)
            {
                UpdateViewportInverse(new Vector4<float>
                {
                    X = scale * 2f / viewportWidth,
                    Y = scale * 2f / viewportHeight,
                    Z = 1,
                    W = disableTransformF,
                });
            }
        }

        /// <summary>
        /// Sets the viewport size, used to invert the fragment coordinates Y value.
        /// </summary>
        /// <param name="viewportWidth">Value used as viewport width</param>
        /// <param name="viewportHeight">Value used as viewport height</param>
        public void SetS2ADepthMode(bool minusOneToOne)   // S2A：DepthMode 运行时化（SupportBuffer.S2AFlags 位 0），翻译器按它选顶点出口 z 变换
        {
            int v = (_data.S2AFlags.X & ~SupportBuffer.S2AFlagDepthMinusOneToOne) | (minusOneToOne ? SupportBuffer.S2AFlagDepthMinusOneToOne : 0);
            if (v != _data.S2AFlags.X)
            {
                _data.S2AFlags.X = v;
                MarkDirty(SupportBuffer.S2AFlagsOffset, SupportBuffer.FieldSize);
            }
        }

        /// <summary>S2A：点大小运行时化（SupportBuffer.S2APoint.X，浮点位），顶点着色器开头按它写 gl_PointSize</summary>
        public void SetS2APointSize(float size)
        {
            int v = BitConverter.SingleToInt32Bits(size);
            if (v != _data.S2APoint.X)
            {
                _data.S2APoint.X = v;
                MarkDirty(SupportBuffer.S2APointOffset, sizeof(int));
            }
        }

        public void SetS2ACbDrawParameters(bool builtin)   // S2A：绘制参数来源运行时化（SupportBuffer.S2AFlags 位 1）
        {
            int v = (_data.S2AFlags.X & ~SupportBuffer.S2AFlagCbDrawParameters) | (builtin ? SupportBuffer.S2AFlagCbDrawParameters : 0);
            if (v != _data.S2AFlags.X)
            {
                _data.S2AFlags.X = v;
                MarkDirty(SupportBuffer.S2AFlagsOffset, SupportBuffer.FieldSize);
            }
        }

        public void SetS2ATexUnnormalized(int binding, bool unnormalized)   // S2A：贴图坐标归一化运行时化（SupportBuffer.S2AFlags Y/Z/W 位图）
        {
            int pos = SupportBuffer.S2ATexUnnormBit(binding);
            if (pos < 0) return;
            ref int lane = ref (pos < 32 ? ref _data.S2AFlags.Y : ref (pos < 64 ? ref _data.S2AFlags.Z : ref _data.S2AFlags.W));
            int m = 1 << (pos & 31), v = unnormalized ? lane | m : lane & ~m;
            if (v != lane)
            {
                lane = v;
                MarkDirty(SupportBuffer.S2AFlagsOffset, SupportBuffer.FieldSize);
            }
        }

        public void SetS2AAlphaTest(bool enable, float reference, CompareOp op)   // S2A：透明测试运行时化（SupportBuffer.FragmentAlphaTest：X 比较方式、Y 参考值）
        {
            int code = !enable ? 8 : op switch   // AlphaTestOp：Never 1 … Always 8（同 GpuChannelGraphicsState.CreateShaderGraphicsState）
            {
                CompareOp.Never or CompareOp.NeverGl => 1, CompareOp.Less or CompareOp.LessGl => 2, CompareOp.Equal or CompareOp.EqualGl => 3,
                CompareOp.LessOrEqual or CompareOp.LessOrEqualGl => 4, CompareOp.Greater or CompareOp.GreaterGl => 5, CompareOp.NotEqual or CompareOp.NotEqualGl => 6,
                CompareOp.GreaterOrEqual or CompareOp.GreaterOrEqualGl => 7, _ => 8,
            };
            int rb = BitConverter.SingleToInt32Bits(reference);
            if (_data.FragmentAlphaTest.X != code || _data.FragmentAlphaTest.Y != rb)
            {
                _data.FragmentAlphaTest.X = code; _data.FragmentAlphaTest.Y = rb;
                MarkDirty(SupportBuffer.FragmentAlphaTestOffset, SupportBuffer.FieldSize);
            }
        }

        public void SetViewportSize(float viewportWidth, float viewportHeight)
        {
            if (_data.ViewportSize.X != viewportWidth || _data.ViewportSize.Y != viewportHeight)
            {
                UpdateViewportSize(new Vector4<float>
                {
                    X = viewportWidth,
                    Y = viewportHeight,
                    Z = 1,
                    W = 0
                });
            }
        }

        /// <summary>
        /// Sets offset for the misaligned portion of a transform feedback buffer, and the buffer size, for transform feedback emulation.
        /// </summary>
        /// <param name="bufferIndex">Index of the transform feedback buffer</param>
        /// <param name="offset">Misaligned offset of the buffer</param>
        public void SetTfeOffset(int bufferIndex, int offset)
        {
            ref int currentOffset = ref GetElementRef(ref _data.TfeOffset, bufferIndex);

            if (currentOffset != offset)
            {
                currentOffset = offset;
                MarkDirty(SupportBuffer.TfeOffsetOffset + bufferIndex * sizeof(int), sizeof(int));
            }
        }

        /// <summary>
        /// Sets the vertex count used for transform feedback emulation with instanced draws.
        /// </summary>
        /// <param name="vertexCount">Vertex count of the instanced draw</param>
        public void SetTfeVertexCount(int vertexCount)
        {
            if (_data.TfeVertexCount.X != vertexCount)
            {
                _data.TfeVertexCount.X = vertexCount;
                MarkDirty(SupportBuffer.TfeVertexCountOffset, sizeof(int));
            }
        }

        /// <summary>
        /// Submits all pending buffer updates to the GPU.
        /// </summary>
        public void Commit()
        {
            Commit(MemoryMarshal.Cast<SupportBuffer, byte>(MemoryMarshal.CreateSpan(ref _data, 1)), SupportBuffer.Binding);
        }
    }
}
