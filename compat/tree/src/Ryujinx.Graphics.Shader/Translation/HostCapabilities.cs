namespace Ryujinx.Graphics.Shader.Translation
{
    class HostCapabilities
    {
        public readonly bool ReducedPrecision;
        public readonly bool SupportsFragmentShaderInterlock;
        public readonly bool SupportsFragmentShaderOrderingIntel;
        public readonly bool SupportsGeometryShaderPassthrough;
        public readonly bool SupportsShaderBallot;
        public readonly bool SupportsShaderBarrierDivergence;
        public readonly bool SupportsShaderFloat64;
        public readonly bool SupportsShaderNonUniformIndexing;
        public readonly bool SupportsTextureShadowLod;
        public readonly bool SupportsViewportMask;
        public readonly bool SupportsSpirv15;
        public readonly bool SpirvLayerExt;
        public readonly bool SpirvLayerNv;
        public readonly bool LayerOutput;
        public readonly bool ViewportOutput;

        public HostCapabilities(
            bool reducedPrecision,
            bool supportsFragmentShaderInterlock,
            bool supportsFragmentShaderOrderingIntel,
            bool supportsGeometryShaderPassthrough,
            bool supportsShaderBallot,
            bool supportsShaderBarrierDivergence,
            bool supportsShaderFloat64,
            bool supportsShaderNonUniformIndexing,
            bool supportsTextureShadowLod,
            bool supportsViewportMask,
            bool supportsSpirv15,
            bool spirvLayerExt,
            bool spirvLayerNv,
            bool layerOutput,
            bool viewportOutput)
        {
            ReducedPrecision = reducedPrecision;
            SupportsFragmentShaderInterlock = supportsFragmentShaderInterlock;
            SupportsFragmentShaderOrderingIntel = supportsFragmentShaderOrderingIntel;
            SupportsGeometryShaderPassthrough = supportsGeometryShaderPassthrough;
            SupportsShaderBallot = supportsShaderBallot;
            SupportsShaderBarrierDivergence = supportsShaderBarrierDivergence;
            SupportsShaderFloat64 = supportsShaderFloat64;
            SupportsShaderNonUniformIndexing = supportsShaderNonUniformIndexing;
            SupportsTextureShadowLod = supportsTextureShadowLod;
            SupportsViewportMask = supportsViewportMask;
            SupportsSpirv15 = supportsSpirv15;
            SpirvLayerExt = spirvLayerExt;
            SpirvLayerNv = spirvLayerNv;
            LayerOutput = layerOutput;
            ViewportOutput = viewportOutput;
        }
    }
}
