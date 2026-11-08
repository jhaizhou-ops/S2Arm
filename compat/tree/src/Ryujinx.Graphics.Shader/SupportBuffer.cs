using Ryujinx.Common.Memory;
using Ryujinx.Graphics.Shader.StructuredIr;
using Ryujinx.Graphics.Shader.Translation;
using System.Runtime.CompilerServices;

namespace Ryujinx.Graphics.Shader
{
    public struct Vector4<T>
    {
        public T X;
        public T Y;
        public T Z;
        public T W;
    }

    enum SupportBufferField
    {
        // Must match the order of the fields on the struct.
        FragmentAlphaTest,
        FragmentIsBgra,
        ViewportInverse,
        ViewportSize,
        FragmentRenderScaleCount,
        RenderScale,
        TfeOffset,
        TfeVertexCount,
        S2AFlags,   // S2A：运行时化的特化状态（见 SupportBuffer.S2AFlags）
        // S2A：点大小运行时化（见 SupportBuffer.S2APoint）；插在 s2a_widen 之前，不放最后：放最后时 Ryujinx 的脏区（连续一段）会跨过包装层自己写的 s2a_widen 把它盖成 0
        S2APoint,
        S2AWiden,   // S2A：宽屏边缘外推参数（见 SupportBuffer.S2AWiden）
        RenderScaleY,   // S2A：分辨率纵向倍率；宽屏只覆盖原 RenderScale 的横向值
        TextureSizes,
    }

    public struct SupportBuffer
    {
        public const int Binding = 0;
        public const int TextureSizeTableAbi = 2;

        public static readonly int FieldSize;
        public static readonly int RequiredSize;

        public static readonly int FragmentAlphaTestOffset;
        public static readonly int FragmentIsBgraOffset;
        public static readonly int ViewportInverseOffset;
        public static readonly int ViewportSizeOffset;
        public static readonly int FragmentRenderScaleCountOffset;
        public static readonly int GraphicsRenderScaleOffset;
        public static readonly int ComputeRenderScaleOffset;
        public static readonly int TfeOffsetOffset;
        public static readonly int TfeVertexCountOffset;
        public static readonly int S2AFlagsOffset;
        public static readonly int S2APointOffset;
        public static readonly int S2AWidenOffset;
        public static readonly int RenderScaleYOffset;
        public static readonly int TextureSizesOffset;

        public const int FragmentIsBgraCount = 8;
        // One for the render target, 64 for the textures, and 8 for the images.
        public const int RenderScaleMaxCount = 1 + 64 + 8;

        private static int OffsetOf<T>(ref SupportBuffer storage, ref T target)
        {
            return (int)Unsafe.ByteOffset(ref Unsafe.As<SupportBuffer, T>(ref storage), ref target);
        }

        static SupportBuffer()
        {
            FieldSize = Unsafe.SizeOf<Vector4<float>>();
            RequiredSize = Unsafe.SizeOf<SupportBuffer>();

            SupportBuffer instance = new();

            FragmentAlphaTestOffset = OffsetOf(ref instance, ref instance.FragmentAlphaTest);
            FragmentIsBgraOffset = OffsetOf(ref instance, ref instance.FragmentIsBgra);
            ViewportInverseOffset = OffsetOf(ref instance, ref instance.ViewportInverse);
            ViewportSizeOffset = OffsetOf(ref instance, ref instance.ViewportSize);
            FragmentRenderScaleCountOffset = OffsetOf(ref instance, ref instance.FragmentRenderScaleCount);
            GraphicsRenderScaleOffset = OffsetOf(ref instance, ref instance.RenderScale);
            ComputeRenderScaleOffset = GraphicsRenderScaleOffset + FieldSize;
            TfeOffsetOffset = OffsetOf(ref instance, ref instance.TfeOffset);
            TfeVertexCountOffset = OffsetOf(ref instance, ref instance.TfeVertexCount);
            S2AFlagsOffset = OffsetOf(ref instance, ref instance.S2AFlags);
            S2APointOffset = OffsetOf(ref instance, ref instance.S2APoint);
            S2AWidenOffset = OffsetOf(ref instance, ref instance.S2AWiden);
            RenderScaleYOffset = OffsetOf(ref instance, ref instance.RenderScaleY);
            TextureSizesOffset = OffsetOf(ref instance, ref instance.TextureSizes);
            S2ARegistry = S2AMakeRegistry();
            S2ACheckLayout();
        }

        /// <summary>
        /// S2A：我方在支持缓冲里新增的全部字段，细到分量登记（偏移 / 字节数 / 用途 / 所有者）。类型初始化时断言互不重叠、不越界——
        /// 10-20 补丁 0044（贴图非归一化位图，s2a_flags.y/z/w）与画幅线外推参数（读 s2a_flags.y/z）同占一处，外推绘制时片元贴图按非归一化坐标采样画错；
        /// 新加字段先在这里登记，撞了第一次用到支持缓冲就抛异常（门禁 / 起局即红），不再靠人看。
        /// </summary>
        public static readonly (string Name, int Offset, int Size, string Owner)[] S2ARegistry;   // 在静态构造里、算完偏移之后赋值（字段初始化器先于构造体执行，偏移还是 0）

        private static (string Name, int Offset, int Size, string Owner)[] S2AMakeRegistry() =>
        [
            ("s2a_flags.x：位 0 深度 −1..1、位 1 绘制参数取内建", S2AFlagsOffset, 4, "帧率能耗线 0042"),
            ("s2a_flags.y：顶点 / 计算阶段贴图非归一化位图", S2AFlagsOffset + 4, 4, "帧率能耗线 0044"),
            ("s2a_flags.z：片元阶段贴图非归一化位图", S2AFlagsOffset + 8, 4, "帧率能耗线 0044"),
            ("s2a_flags.w：几何阶段贴图非归一化位图", S2AFlagsOffset + 12, 4, "帧率能耗线 0044"),
            ("alpha_test.x/y：透明测试比较方式 / 参考值", FragmentAlphaTestOffset, 8, "帧率能耗线 0056"),
            ("s2a_point.x：点大小（浮点位，原 GpuGraphicsState.PointSize 特化）", S2APointOffset, 4, "画面·着色器线 spec（10-21）"),
            ("s2a_widen.x：边缘外推量（浮点位）", S2AWidenOffset, 4, "画幅线 SpirvEdgePush"),
            ("s2a_widen.y：边缘外推门限²（浮点位）", S2AWidenOffset + 4, 4, "画幅线 SpirvEdgePush"),
            ("s2a_widen.z：横向收缩量（浮点位；原尺寸居中层全宽视口 + 收缩 1/k）", S2AWidenOffset + 8, 4, "画幅线 SpirvEdgePush"),
            ("s2a_widen.w：原画框外推的 pad（浮点位；0 = 关，SpirvExtrap 片元平移 / 插值外推、SpirvEdgePush 写 location 31）", S2AWidenOffset + 12, 4, "画幅线 SpirvExtrap"),
            ("render_scale_y：纵向分辨率倍率，沿用逐纹理黑名单", RenderScaleYOffset, FieldSize * RenderScaleMaxCount, "画幅线 分辨率倍率"),
            ("texture_sizes：视图逻辑及物理宽高，ABI 2", TextureSizesOffset, FieldSize * RenderScaleMaxCount, "直连分辨率 ABI 2"),
        ];

        private static void S2ACheckLayout()
        {
            var r = S2ARegistry;
            for (int i = 0; i < r.Length; i++)
            {
                if (r[i].Offset < 0 || r[i].Size <= 0 || r[i].Offset + r[i].Size > RequiredSize)
                {
                    throw new System.InvalidOperationException($"S2A 支持缓冲登记越界：{r[i].Name}（{r[i].Owner}）偏移 {r[i].Offset} 长 {r[i].Size}，结构 {RequiredSize} 字节");
                }

                for (int j = 0; j < i; j++)
                {
                    if (r[i].Offset < r[j].Offset + r[j].Size && r[j].Offset < r[i].Offset + r[i].Size)
                    {
                        throw new System.InvalidOperationException($"S2A 支持缓冲字段重叠：{r[i].Name}（{r[i].Owner}）与 {r[j].Name}（{r[j].Owner}）");
                    }
                }
            }
        }

        internal static StructureType GetStructureType()
        {
            return new StructureType([
                new StructureField(AggregateType.Vector4 | AggregateType.U32, "alpha_test"),   // S2A：x = 比较方式、y = 参考值（EmitterContext.S2AAlphaTestRuntime 按分量读；声明成标量时访问链多一级索引，spirv-val 判非法，#199）
                new StructureField(AggregateType.Array | AggregateType.U32, "is_bgra", FragmentIsBgraCount),
                new StructureField(AggregateType.Vector4 | AggregateType.FP32, "viewport_inverse"),
                new StructureField(AggregateType.Vector4 | AggregateType.FP32, "viewport_size"),
                new StructureField(AggregateType.S32, "frag_scale_count"),
                new StructureField(AggregateType.Array | AggregateType.FP32, "render_scale", RenderScaleMaxCount),
                new StructureField(AggregateType.Vector4 | AggregateType.S32, "tfe_offset"),
                new StructureField(AggregateType.S32, "tfe_vertex_count"),
                new StructureField(AggregateType.Vector4 | AggregateType.S32, "s2a_flags"),
                new StructureField(AggregateType.Vector4 | AggregateType.S32, "s2a_point"),
                new StructureField(AggregateType.Vector4 | AggregateType.S32, "s2a_widen"),
                new StructureField(AggregateType.Array | AggregateType.FP32, "render_scale_y", RenderScaleMaxCount),
                new StructureField(AggregateType.Array | AggregateType.Vector4 | AggregateType.S32, "texture_sizes", RenderScaleMaxCount),
            ]);
        }

        public Vector4<int> FragmentAlphaTest;   // S2A：X = AlphaTestOp（关时 Always）、Y = 参考值 float 位（透明测试运行时化，EmitterContext.S2AAlphaTestRuntime）
        public Array8<Vector4<int>> FragmentIsBgra;
        public Vector4<float> ViewportInverse;
        public Vector4<float> ViewportSize;
        public Vector4<int> FragmentRenderScaleCount;

        // Render scale max count: 1 + 64 + 8. First scale is fragment output scale, others are textures/image inputs.
        public Array73<Vector4<float>> RenderScale;

        public Vector4<int> TfeOffset;
        public Vector4<int> TfeVertexCount;

        // S2A（着色器全量预编，10-19）：原先编进着色器的特化状态改由这里运行时给，一份客体代码只出一个程序。X 位 0 = DepthMode 为 −1..1（顶点出口 z 变换），位 1 = 绘制参数取内建（宏 HLE 绘制，原 HasConstantBufferDrawParameters）
        public const int S2AFlagDepthMinusOneToOne = 1, S2AFlagCbDrawParameters = 2;
        // Y / Z / W：贴图非归一化坐标位图（原 QueryTextureCoordNormalized 特化），Y = 顶点 / 计算、Z = 片元、W = 几何阶段的前 32 个贴图绑定。
        // Vulkan 口径贴图绑定号 = 阶段组 × 128 + 序号（GpuAccessorBase.GetBindingFromIndex），这里按阶段组 × 32 + 序号排位；映射不了（细分阶段、序号 ≥ 32）返回 −1，退回编译期特化
        public static int S2ATexUnnormBit(int binding)
        {
            int group = binding / 128, index = binding % 128;
            return binding >= 0 && group < 3 && index < 32 ? group * 32 + index : -1;
        }
        public Vector4<int> S2AFlags;

        // S2A（画面·着色器线 spec，10-21）：点大小运行时化。x = 点大小（浮点位），y / z / w 留空。原先每个顶点着色器开头把 GpuGraphicsState.PointSize 编成常量写 gl_PointSize，
        // 出包离线烘焙取不到运行时值（零配置缺省 0，10-21 怪猎 27 支顶点函数全因它不在离线库、首遇现编），改为从这里读：一份顶点着色器覆盖所有点大小，翻译不再读这项特化
        public Vector4<int> S2APoint;

        // S2A：宽屏边缘外推参数，x = 外推量、y = 门限² / 原画框外推比例、z = 收缩量、w = 原画框外推 pad（浮点位）。
        // 包装层逐次绘制写；RenderScaleY 更新使连续上传区间经过这里时，包装层跟踪并在下次绘制恢复参数。s2a_flags 整个归 0042 / 0044。
        public Vector4<int> S2AWiden;
        public Array73<Vector4<float>> RenderScaleY;
        // ABI 2, byte 2608: logical view width/height, physical view width/height.
        // Entry zero is the fragment target's selected mip; zero entries use legacy helpers.
        public Array73<Vector4<int>> TextureSizes;
    }
}
