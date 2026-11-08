// IPipeline：状态设置与绘制，全部直调 C（第 5 / 6 块，gal_state.m / gal_pass.m / gal_draw.m）。
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Shader;
using System;
using System.Runtime.InteropServices;

namespace NxGal
{
    static unsafe partial class N
    {
        [DllImport(Lib), SuppressGCTransition] public static extern void nxgal_set_render_targets(uint* colors, int n, uint depth);
        [DllImport(Lib), SuppressGCTransition] public static extern void nxgal_set_scissors(NRect* rects, int n);
        [DllImport(Lib)] public static extern void nxgal_clear_color(int index, int layer, int layerCount, uint mask, float* rgba);
        [DllImport(Lib)] public static extern void nxgal_clear_ds(int layer, int layerCount, float depth, int depthMask, int stencil, int stencilMask);
        [DllImport(Lib), SuppressGCTransition] public static extern void nxgal_set_program(uint prog);
        [DllImport(Lib), SuppressGCTransition] public static extern void nxgal_set_blend(int index, NBlend* b);
        [DllImport(Lib), SuppressGCTransition] public static extern void nxgal_set_blend_advanced(int op, int overlap, int srcPremul);
        [DllImport(Lib), SuppressGCTransition] public static extern void nxgal_set_color_masks(uint* masks, int n);
        [DllImport(Lib), SuppressGCTransition] public static extern void nxgal_set_depth_bias(int enables, float factor, float units, float clamp);
        [DllImport(Lib), SuppressGCTransition] public static extern void nxgal_set_depth_clamp(int clamp);
        [DllImport(Lib), SuppressGCTransition] public static extern void nxgal_set_depth_mode(int mode);
        [DllImport(Lib), SuppressGCTransition] public static extern void nxgal_set_depth_test(NDepthTest* d);
        [DllImport(Lib), SuppressGCTransition] public static extern void nxgal_set_stencil_test(NStencil* s);
        [DllImport(Lib), SuppressGCTransition] public static extern void nxgal_set_face_culling(int enable, int face);
        [DllImport(Lib), SuppressGCTransition] public static extern void nxgal_set_front_face(int frontFace);
        [DllImport(Lib), SuppressGCTransition] public static extern void nxgal_set_line_params(float width, int smooth);
        [DllImport(Lib), SuppressGCTransition] public static extern void nxgal_set_point_params(float size, int programSize, int sprite, int origin);
        [DllImport(Lib), SuppressGCTransition] public static extern void nxgal_set_logic_op(int enable, int op);
        [DllImport(Lib), SuppressGCTransition] public static extern void nxgal_set_multisample(int a2c, int a2cDither, int alphaToOne);
        [DllImport(Lib), SuppressGCTransition] public static extern void nxgal_set_patch_params(int vertices, float* outer, float* inner);
        [DllImport(Lib), SuppressGCTransition] public static extern void nxgal_set_polygon_mode(int front, int back);
        [DllImport(Lib), SuppressGCTransition] public static extern void nxgal_set_primitive_restart(int enable, int index);
        [DllImport(Lib), SuppressGCTransition] public static extern void nxgal_set_topology(int topology);
        [DllImport(Lib), SuppressGCTransition] public static extern void nxgal_set_rasterizer_discard(int discard);
        [DllImport(Lib), SuppressGCTransition] public static extern void nxgal_set_user_clip(int index, int enable);
        [DllImport(Lib), SuppressGCTransition] public static extern void nxgal_set_viewports(NViewport* v, int n);
        [DllImport(Lib), SuppressGCTransition] public static extern void nxgal_set_vertex_attribs(NVAttr* a, int n);
        [DllImport(Lib), SuppressGCTransition] public static extern void nxgal_set_vertex_buffers(NVBuf* b, int n);
        [DllImport(Lib), SuppressGCTransition] public static extern void nxgal_set_index_buffer(NBufRange* r, int type);
        [DllImport(Lib), SuppressGCTransition] public static extern void nxgal_set_alpha_test(int enable, float reference, int op);
        [DllImport(Lib), SuppressGCTransition] public static extern void nxgal_set_uniform_buffers(NBufAssign* a, int n);
        [DllImport(Lib), SuppressGCTransition] public static extern void nxgal_set_storage_buffers(NBufAssign* a, int n);
        [DllImport(Lib), SuppressGCTransition] public static extern void nxgal_set_texture_sampler(int stage, int binding, uint tex, uint smp);
        [DllImport(Lib), SuppressGCTransition] public static extern void nxgal_set_image(int stage, int binding, uint tex);
        [DllImport(Lib), SuppressGCTransition] public static extern void nxgal_set_texture_array(int stage, int binding, uint arr);
        [DllImport(Lib), SuppressGCTransition] public static extern void nxgal_set_texture_array_separate(int stage, int set, uint arr);
        [DllImport(Lib), SuppressGCTransition] public static extern void nxgal_set_transform_feedback_buffers(NBufRange* r, int n);
        [DllImport(Lib)] public static extern void nxgal_draw(int vertexCount, int instanceCount, int firstVertex, int firstInstance);
        [DllImport(Lib)] public static extern void nxgal_draw_indexed(int indexCount, int instanceCount, int firstIndex, int firstVertex, int firstInstance);
        [DllImport(Lib)] public static extern void nxgal_draw_indirect(NBufRange* ind, int indexed);
        [DllImport(Lib)] public static extern void nxgal_draw_indirect_count(NBufRange* ind, NBufRange* param, int maxDraws, int stride, int indexed);
        [DllImport(Lib)] public static extern void nxgal_draw_texture(uint tex, uint smp, float* src, float* dst);
        [DllImport(Lib)] public static extern void nxgal_dispatch(int x, int y, int z);
        [DllImport(Lib)] public static extern void nxgal_begin_transform_feedback(int topology);
        [DllImport(Lib)] public static extern void nxgal_end_transform_feedback();
        [DllImport(Lib)] public static extern int nxgal_cond_begin(uint ev, ulong compare, uint ev2, int isEqual);
        [DllImport(Lib)] public static extern void nxgal_cond_end();
    }

    public sealed unsafe class NxPipeline : IPipeline
    {
        readonly NxRenderer _r;
        public NxPipeline(NxRenderer r) => _r = r;
        static uint T(ITexture t) => t is NxTexture x ? x.Id : 0;
        static uint S(ISampler s) => s is NxSampler x ? x.Id : 0;

        public void Barrier() => N.nxgal_barrier(0);
        public void CommandBufferBarrier() => N.nxgal_barrier(1);
        public void TextureBarrier() => N.nxgal_barrier(2);
        public void TextureBarrierTiled() => N.nxgal_barrier(3);

        public void BeginTransformFeedback(PrimitiveTopology topology) => N.nxgal_begin_transform_feedback((int)topology);
        public void EndTransformFeedback() => N.nxgal_end_transform_feedback();
        public void SetTransformFeedbackBuffers(ReadOnlySpan<BufferRange> buffers)
        {
            NBufRange* r = stackalloc NBufRange[buffers.Length];
            for (int i = 0; i < buffers.Length; i++) r[i] = Conv.Range(buffers[i]);
            N.nxgal_set_transform_feedback_buffers(r, buffers.Length);
        }

        public void ClearBuffer(BufferHandle destination, int offset, int size, uint value) => N.nxgal_buf_clear((uint)(int)destination, offset, size, value);
        public void CopyBuffer(BufferHandle source, BufferHandle destination, int srcOffset, int dstOffset, int size) => N.nxgal_buf_copy((uint)(int)source, (uint)(int)destination, srcOffset, dstOffset, size);

        public void ClearRenderTargetColor(int index, int layer, int layerCount, uint componentMask, ColorF color)
        {
            float* c = stackalloc float[4] { color.Red, color.Green, color.Blue, color.Alpha };
            N.nxgal_clear_color(index, layer, layerCount, componentMask, c);
        }
        public void ClearRenderTargetDepthStencil(int layer, int layerCount, float depthValue, bool depthMask, int stencilValue, int stencilMask)
            => N.nxgal_clear_ds(layer, layerCount, depthValue, depthMask ? 1 : 0, stencilValue, stencilMask);

        public void DispatchCompute(int groupsX, int groupsY, int groupsZ) => N.nxgal_dispatch(groupsX, groupsY, groupsZ);
        public void Draw(int vertexCount, int instanceCount, int firstVertex, int firstInstance) => N.nxgal_draw(vertexCount, instanceCount, firstVertex, firstInstance);
        public void DrawIndexed(int indexCount, int instanceCount, int firstIndex, int firstVertex, int firstInstance) => N.nxgal_draw_indexed(indexCount, instanceCount, firstIndex, firstVertex, firstInstance);
        public void DrawIndexedIndirect(BufferRange indirectBuffer) { NBufRange r = Conv.Range(indirectBuffer); N.nxgal_draw_indirect(&r, 1); }
        public void DrawIndirect(BufferRange indirectBuffer) { NBufRange r = Conv.Range(indirectBuffer); N.nxgal_draw_indirect(&r, 0); }
        public void DrawIndexedIndirectCount(BufferRange indirectBuffer, BufferRange parameterBuffer, int maxDrawCount, int stride)
        { NBufRange a = Conv.Range(indirectBuffer), b = Conv.Range(parameterBuffer); N.nxgal_draw_indirect_count(&a, &b, maxDrawCount, stride, 1); }
        public void DrawIndirectCount(BufferRange indirectBuffer, BufferRange parameterBuffer, int maxDrawCount, int stride)
        { NBufRange a = Conv.Range(indirectBuffer), b = Conv.Range(parameterBuffer); N.nxgal_draw_indirect_count(&a, &b, maxDrawCount, stride, 0); }
        public void DrawTexture(ITexture texture, ISampler sampler, Extents2DF srcRegion, Extents2DF dstRegion)
        {
            float* s = stackalloc float[4] { srcRegion.X1, srcRegion.Y1, srcRegion.X2, srcRegion.Y2 };
            float* d = stackalloc float[4] { dstRegion.X1, dstRegion.Y1, dstRegion.X2, dstRegion.Y2 };
            N.nxgal_draw_texture(T(texture), S(sampler), s, d);
        }

        public void SetAlphaTest(bool enable, float reference, CompareOp op) => N.nxgal_set_alpha_test(enable ? 1 : 0, reference, (int)op);
        public void SetBlendState(AdvancedBlendDescriptor blend) => N.nxgal_set_blend_advanced((int)blend.Op, (int)blend.Overlap, blend.SrcPreMultiplied ? 1 : 0);
        public void SetBlendState(int index, BlendDescriptor blend)
        {
            NBlend b = new()
            {
                Enable = blend.Enable ? 1 : 0, ColorOp = (int)blend.ColorOp, ColorSrc = (int)blend.ColorSrcFactor, ColorDst = (int)blend.ColorDstFactor,
                AlphaOp = (int)blend.AlphaOp, AlphaSrc = (int)blend.AlphaSrcFactor, AlphaDst = (int)blend.AlphaDstFactor,
            };
            b.Constant[0] = blend.BlendConstant.Red; b.Constant[1] = blend.BlendConstant.Green; b.Constant[2] = blend.BlendConstant.Blue; b.Constant[3] = blend.BlendConstant.Alpha;
            N.nxgal_set_blend(index, &b);
        }
        public void SetDepthBias(PolygonModeMask enables, float factor, float units, float clamp) => N.nxgal_set_depth_bias((int)enables, factor, units, clamp);
        public void SetDepthClamp(bool clamp) => N.nxgal_set_depth_clamp(clamp ? 1 : 0);
        public void SetDepthMode(DepthMode mode) => N.nxgal_set_depth_mode((int)mode);
        public void SetDepthTest(DepthTestDescriptor depthTest) { NDepthTest d = new() { Test = depthTest.TestEnable ? 1 : 0, Write = depthTest.WriteEnable ? 1 : 0, Func = (int)depthTest.Func }; N.nxgal_set_depth_test(&d); }
        public void SetFaceCulling(bool enable, Face face) => N.nxgal_set_face_culling(enable ? 1 : 0, (int)face);
        public void SetFrontFace(FrontFace frontFace) => N.nxgal_set_front_face((int)frontFace);
        public void SetIndexBuffer(BufferRange buffer, IndexType type) { NBufRange r = Conv.Range(buffer); N.nxgal_set_index_buffer(&r, (int)type); }
        public void SetImage(ShaderStage stage, int binding, ITexture texture) => N.nxgal_set_image((int)stage, binding, T(texture));
        public void SetImageArray(ShaderStage stage, int binding, IImageArray array) => N.nxgal_set_texture_array((int)stage, binding, array is NxTextureArray a ? a.Id : 0);
        public void SetImageArraySeparate(ShaderStage stage, int setIndex, IImageArray array) => N.nxgal_set_texture_array_separate((int)stage, setIndex, array is NxTextureArray a ? a.Id : 0);
        public void SetLineParameters(float width, bool smooth) => N.nxgal_set_line_params(width, smooth ? 1 : 0);
        public void SetLogicOpState(bool enable, LogicalOp op) => N.nxgal_set_logic_op(enable ? 1 : 0, (int)op);
        public void SetMultisampleState(MultisampleDescriptor m) => N.nxgal_set_multisample(m.AlphaToCoverageEnable ? 1 : 0, m.AlphaToCoverageDitherEnable ? 1 : 0, m.AlphaToOneEnable ? 1 : 0);
        public void SetPatchParameters(int vertices, ReadOnlySpan<float> defaultOuterLevel, ReadOnlySpan<float> defaultInnerLevel)
        {
            float* o = stackalloc float[4]; float* i = stackalloc float[2];
            for (int k = 0; k < 4 && k < defaultOuterLevel.Length; k++) o[k] = defaultOuterLevel[k];
            for (int k = 0; k < 2 && k < defaultInnerLevel.Length; k++) i[k] = defaultInnerLevel[k];
            N.nxgal_set_patch_params(vertices, o, i);
        }
        public void SetPointParameters(float size, bool isProgramPointSize, bool enablePointSprite, Origin origin) => N.nxgal_set_point_params(size, isProgramPointSize ? 1 : 0, enablePointSprite ? 1 : 0, (int)origin);
        public void SetPolygonMode(PolygonMode frontMode, PolygonMode backMode) => N.nxgal_set_polygon_mode((int)frontMode, (int)backMode);
        public void SetPrimitiveRestart(bool enable, int index) => N.nxgal_set_primitive_restart(enable ? 1 : 0, index);
        public void SetPrimitiveTopology(PrimitiveTopology topology) => N.nxgal_set_topology((int)topology);
        public void SetProgram(IProgram program) => N.nxgal_set_program(program is NxProgram p ? p.Id : 0);
        public void SetRasterizerDiscard(bool discard) => N.nxgal_set_rasterizer_discard(discard ? 1 : 0);
        public void SetRenderTargetColorMasks(ReadOnlySpan<uint> componentMask) { fixed (uint* m = componentMask) N.nxgal_set_color_masks(m, componentMask.Length); }
        public void SetRenderTargets(Span<ITexture> colors, ITexture depthStencil)
        {
            uint* c = stackalloc uint[8]; int n = Math.Min(colors.Length, 8);
            for (int i = 0; i < n; i++) c[i] = T(colors[i]);
            N.nxgal_set_render_targets(c, n, T(depthStencil));
        }
        public void SetScissors(ReadOnlySpan<Rectangle<int>> regions)
        {
            NRect* r = stackalloc NRect[regions.Length];
            for (int i = 0; i < regions.Length; i++) r[i] = new NRect { X = regions[i].X, Y = regions[i].Y, W = regions[i].Width, H = regions[i].Height };
            N.nxgal_set_scissors(r, regions.Length);
        }
        public void SetStencilTest(StencilTestDescriptor s)
        {
            NStencil n = new()
            {
                Enable = s.TestEnable ? 1 : 0,
                FrontFunc = (int)s.FrontFunc, FrontSFail = (int)s.FrontSFail, FrontDpPass = (int)s.FrontDpPass, FrontDpFail = (int)s.FrontDpFail,
                FrontRef = s.FrontFuncRef, FrontFuncMask = s.FrontFuncMask, FrontMask = s.FrontMask,
                BackFunc = (int)s.BackFunc, BackSFail = (int)s.BackSFail, BackDpPass = (int)s.BackDpPass, BackDpFail = (int)s.BackDpFail,
                BackRef = s.BackFuncRef, BackFuncMask = s.BackFuncMask, BackMask = s.BackMask,
            };
            N.nxgal_set_stencil_test(&n);
        }
        static void Assign(ReadOnlySpan<BufferAssignment> buffers, NBufAssign* a)
        {
            for (int i = 0; i < buffers.Length; i++) a[i] = new NBufAssign { Binding = buffers[i].Binding, R = Conv.Range(buffers[i].Range) };
        }
        public void SetStorageBuffers(ReadOnlySpan<BufferAssignment> buffers) { NBufAssign* a = stackalloc NBufAssign[buffers.Length]; Assign(buffers, a); N.nxgal_set_storage_buffers(a, buffers.Length); }
        public void SetUniformBuffers(ReadOnlySpan<BufferAssignment> buffers) { NBufAssign* a = stackalloc NBufAssign[buffers.Length]; Assign(buffers, a); N.nxgal_set_uniform_buffers(a, buffers.Length); }
        public void SetTextureAndSampler(ShaderStage stage, int binding, ITexture texture, ISampler sampler) => N.nxgal_set_texture_sampler((int)stage, binding, T(texture), S(sampler));
        public void SetTextureArray(ShaderStage stage, int binding, ITextureArray array) => N.nxgal_set_texture_array((int)stage, binding, array is NxTextureArray a ? a.Id : 0);
        public void SetTextureArraySeparate(ShaderStage stage, int setIndex, ITextureArray array) => N.nxgal_set_texture_array_separate((int)stage, setIndex, array is NxTextureArray a ? a.Id : 0);
        public void SetUserClipDistance(int index, bool enableClip) => N.nxgal_set_user_clip(index, enableClip ? 1 : 0);
        public void SetVertexAttribs(ReadOnlySpan<VertexAttribDescriptor> vertexAttribs)
        {
            NVAttr* a = stackalloc NVAttr[vertexAttribs.Length];
            for (int i = 0; i < vertexAttribs.Length; i++) a[i] = new NVAttr { Buffer = vertexAttribs[i].BufferIndex, Offset = vertexAttribs[i].Offset, IsZero = vertexAttribs[i].IsZero ? 1 : 0, Format = (int)vertexAttribs[i].Format };
            N.nxgal_set_vertex_attribs(a, vertexAttribs.Length);
        }
        public void SetVertexBuffers(ReadOnlySpan<VertexBufferDescriptor> vertexBuffers)
        {
            NVBuf* b = stackalloc NVBuf[vertexBuffers.Length];
            for (int i = 0; i < vertexBuffers.Length; i++) b[i] = new NVBuf { R = Conv.Range(vertexBuffers[i].Buffer), Stride = vertexBuffers[i].Stride, Divisor = vertexBuffers[i].Divisor };
            N.nxgal_set_vertex_buffers(b, vertexBuffers.Length);
        }
        public void SetViewports(ReadOnlySpan<Viewport> viewports)
        {
            NViewport* v = stackalloc NViewport[viewports.Length];
            for (int i = 0; i < viewports.Length; i++)
            {
                Viewport s = viewports[i];
                v[i] = new NViewport { X = s.Region.X, Y = s.Region.Y, W = s.Region.Width, H = s.Region.Height, ZNear = s.DepthNear, ZFar = s.DepthFar };
                v[i].Swz[0] = (int)s.SwizzleX; v[i].Swz[1] = (int)s.SwizzleY; v[i].Swz[2] = (int)s.SwizzleZ; v[i].Swz[3] = (int)s.SwizzleW;
            }
            N.nxgal_set_viewports(v, viewports.Length);
        }

        public bool TryHostConditionalRendering(ICounterEvent value, ulong compare, bool isEqual)
            => N.nxgal_cond_begin(value is NxCounterEvent e ? e.Id : 0, compare, 0, isEqual ? 1 : 0) != 0;
        public bool TryHostConditionalRendering(ICounterEvent value, ICounterEvent compare, bool isEqual)
            => N.nxgal_cond_begin(value is NxCounterEvent e ? e.Id : 0, 0, compare is NxCounterEvent c ? c.Id : 0, isEqual ? 1 : 0) != 0;
        public void EndHostConditionalRendering() => N.nxgal_cond_end();
    }
}
