// GAL Metal 渲染器的能力表（IRenderer.GetCapabilities）：设备能力位的纯函数，单独成工程（NxGalCaps.csproj）。
// 运行时 NxRenderer 按 MTLDevice 查到的能力位调它；离线着色器烘焙器（graphics/tools/shbake）按出包目标设备的固定能力位调它——翻译结果依赖能力表，两边必须同一份。
// 单独成工程：着色器阶段键只认真正影响产物的输入（tools/csproj_closure.py），渲染器其余代码改了不让各款着色器重烘。
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Shader.Translation;

namespace NxGal
{
    public static class NxCaps
    {
        /// <summary>dc = nxgal_device_caps 同格式：[0] 位 1 BC、2 ASTC、4 ETC2、8 16 位紧凑格式、16 ASTC HDR；[1] 计算共享内存字节</summary>
        public static Capabilities Build(ulong[] dc)
        {
            // 着色器以 SPIR-V 交来（TargetApi.Vulkan），描述符集 0–3 + 额外 4 集 → 参数缓冲 [[buffer(0..7)]]（见 设计.md）。
            // 设备相关项一律按 MTLDevice 当场查询（nxgal_device_caps，初始化日志有一行查询结果）：BC / ASTC / ETC2 压缩、16 位紧凑格式、计算共享内存（显存预算见 maximumGpuMemory 注释）。
            // 原先 BC 写死「iOS 无」，iPhone 上 BC 贴图被 Gpu 层在 CPU 解成未压缩，采样带宽涨 4–8 倍（10-19 动森岛上稳态 269 张 BC 贴图）。
            // 其余固定项是 Metal 本身的语义（各设备相同）：没有三分量 / 缩放整数格式、R4G4、四边形图元、几何着色器 / 变换反馈（Gpu 层自有退路）。
            bool bc = (dc[0] & 1) != 0, astc = (dc[0] & 2) != 0, etc2 = (dc[0] & 4) != 0, packed16 = (dc[0] & 8) != 0;
            return new Capabilities(
                api: TargetApi.Vulkan,
                vendorName: "nxgal",   // 固定串：Ryujinx 着色器缓存文件名 = Api_VendorName，Mac 录种子局产、iOS 读，两边必须同名；也不与参照（MoltenVK 报 Apple）撞名
                memoryType: SystemMemoryType.UnifiedMemory,
                hasFrontFacingBug: false,
                hasVectorIndexingBug: false,
                needsFragmentOutputSpecialization: true,   // Metal 要求片元输出类型与渲染目标格式类别（float / int / uint）一致；Vulkan@MoltenVK 与社区 Metal 后端都报 true（架构线 10-18 特化普查指出）
                reduceShaderPrecision: false,
                supportsAstcCompression: astc,
                supportsBc123Compression: bc,
                supportsBc45Compression: bc,
                supportsBc67Compression: bc,
                supportsEtc2Compression: etc2,
                supports3DTextureCompression: false,
                supportsBgraFormat: true,
                supportsR4G4Format: false,
                supportsR4G4B4A4Format: packed16,   // 第 3 块已映射 ABGR4 + 旋转并实测
                supportsScaledVertexFormats: false,
                supportsSnormBufferTextureFormat: true,
                supports5BitComponentFormat: packed16,
                supportsSparseBuffer: false,
                supportsBlendEquationAdvanced: false,
                supportsFragmentShaderInterlock: false,
                supportsFragmentShaderOrderingIntel: false,
                supportsGeometryShader: false,
                // #1456：SupportsGeometryShaderOcclusionQuery 苹果侧恒为假、从不读
                // capprobe 结果文件——Metal 没有 Vulkan 设备也没有 GS+遮挡查询组合可探；
                // 该位只属于 Vulkan 设备构建路径（构造参数缺省值即为假）。
                supportsGeometryShaderPassthrough: false,
                supportsTransformFeedback: false,
                supportsImageLoadFormatted: true,
                supportsLayerVertexTessellation: true,
                supportsMismatchingViewFormat: true,
                supportsCubemapView: true,
                supportsNonConstantTextureOffset: false,
                supportsQuads: false,
                supportsSeparateSampler: true,
                supportsShaderBallot: false,
                // 分支 / 循环 / 子函数里的屏障（10-24 图形接口盘点静默 2）：照 Ryujinx Vulkan（VulkanRenderer.cs:792，非 Intel 一律 true，苹果设备上 true）。
                // 报 false 时翻译器删掉这些屏障（Spirv/Instructions.cs GenerateBarrier），共享内存读写失去同步
                supportsShaderBarrierDivergence: true,
                supportsShaderFloat64: false,
                supportsShaderNonUniformIndexing: true,
                supportsTextureGatherOffsets: false,
                supportsTextureShadowLod: false,
                supportsVertexStoreAndAtomics: false,
                // 顶点 / 曲面阶段写视口号（盘点静默 9）：照 Vulkan（VulkanRenderer.cs:801，ShaderOutputViewportIndex，苹果 GPU 有），Metal 顶点函数可写 [[viewport_array_index]]。
                //   视口掩码 supportsViewportMask 保持 false：Vulkan 取 NV 扩展 ViewportArray2（第 802 行），苹果设备上同为 false
                supportsViewportIndexVertexTessellation: true,
                supportsViewportMask: false,
                supportsViewportSwizzle: false,
                supportsIndirectParameters: true,
                supportsDepthClipControl: false,
                uniformBufferSetIndex: 0,
                storageBufferSetIndex: 1,
                textureSetIndex: 2,
                imageSetIndex: 3,
                extraSetBaseIndex: 4,
                maximumExtraSets: 4,
                maximumUniformBuffersPerStage: 18,
                maximumStorageBuffersPerStage: 16,
                maximumTexturesPerStage: 64,
                maximumImagesPerStage: 16,
                maximumComputeSharedMemorySize: System.Math.Max((int)dc[1], 48 * 1024),   // 报 Switch 的 48 KB：Ryujinx 照这个截共享内存；超出设备上限的部分由 gal_prog.m spill_msl 溢出到设备内存（10-21 画面着色器线合批）
                maximumSupportedAnisotropy: 16,
                shaderSubgroupSize: 32,
                storageBufferOffsetAlignment: 16,
                textureBufferOffsetAlignment: 16,
                gatherBiasPrecision: 0,
                // maximumGpuMemory 是 Ryujinx 贴图缓存的内存预算（策略值），不是设备能力：按建议工作集报会让 Mac 到百 GB 级、iPhone 也放大缓存，压进程内存上限；查询值只进日志
                maximumGpuMemory: 4UL << 30,
                // 顶点自取（gal_vpull.m）：顶点着色器按格式自己解码属性、产出 Maxwell 寄存器原始位；缩放整数格式原样交给渲染器，翻译器顶点输入按原始位声明（NXGAL_VPULL=0 关）
                s2aVertexPull: true,
                // The Metal SPIR-V conversion path consumes the legacy EXT capability.
                s2aSpirvLayerExt: true);
        }
    }
}
