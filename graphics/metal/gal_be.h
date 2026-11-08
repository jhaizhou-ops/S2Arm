// GAL 后端抽象（10-19 jhz：下限 iOS 17 / macOS 14；Metal 4 为主路径（新机省 CPU、能耗好），Metal 3 为兼容路径，运行时按系统选）。
// 下限修正（10-19 总指挥据小菠萝 ~/xbl/docs/Metal3退回评估_秘境线_1013.md）：iOS 18 / macOS 15——驻留集在 18 / 15 就有、挂老队列照用；
// 再往下要回到逐资源 useResource（正是换 Metal 4 要摆脱的开销），不做。
// 规矩：新代码只经下表这些入口碰「Metal 4 专有概念」，不再新增直接的 MTL4 调用（门禁 graphics/gate.sh 按 graphics/metal 下 MTL4 出现处数棘轮，只减不增）。
// 现状（10-23 M3-6 #113 起）：「选路径」「驻留」「编码器」三行的 Metal 3 侧已落地，提交段见 M3-5，其余（绑定 / 管线 / 上屏）待 M3-5 第二段、M3-7、M3-8。
// 选路径：26 起缺省 Metal 4；26 以下缺省 Metal 3；26 上用 NXGAL_BE=mtl3 强制走 Metal 3（A/B 用，缺省关，日志一行「后端：Metal 3（强制）」）。
//
// | 概念 | 入口 | Metal 4 | Metal 3（待做） |
// |---|---|---|---|
// | 选路径 | gal_be_kind()；nxgal_init 调 gal_be_select() 定（gal_core.m） | macOS / iOS 26 起（缺省） | 26 以下缺省走它；26 上只由 NXGAL_BE=mtl3 强制（10-23 已落地） |
// | 命令提交 / 分配器 | gal_cb_begin / gal_commit / gal_finish（gal_internal.h） | MTL4CommandQueue + 每帧轮转 MTL4CommandAllocator | MTLCommandQueue + 每次新命令缓冲 |
// | 栅栏 | gal_wait / gal_done / gal_committed_fence | MTLSharedEvent signal / waitUntilSignaledValue | 同（MTLSharedEvent 两边都有） |
// | 驻留 | gal_res_add / gal_res_remove | MTLResidencySet 挂 MTL4 队列 | 同一个 MTLResidencySet 用 addResidencySet 挂普通 MTLCommandQueue（18 / 15 就有，10-23 已落地）；图层上的驻留集 layer.residencySet 是 26 才有，老路径不用 |
// | 参数绑定 | gal_be_bind(table, index, buf, off) / gal_be_table_* | MTL4ArgumentTable setAddress | 编码器 setVertexBuffer / setFragmentBuffer / setBuffer |
// | 编码器 | gal_render_enc / gal_blit_enc / gal_cmp_enc / gal_preload_enc / gal_be_compute_dispatch；通道描述 gal_be_pass_desc | MTL4RenderCommandEncoder / MTL4ComputeCommandEncoder（拷贝也走计算编码器，gal_cmp_enc = gal_blit_enc） | MTLRenderCommandEncoder / MTLBlitCommandEncoder（拷贝，一条一个编码器）/ MTLComputeCommandEncoder（派发，编码器内 memoryBarrierWithScope）；编码器之间用栅栏 g_fence3 全序；预载是单独一条老命令缓冲，先提交；不分遍前段（10-23 M3-6 已落地，派发 / 绘制要等参数绑定）|
// | 管线与归档 | gal_new_render_pso / gal_new_compute_pso / gal_be_compute_desc | MTL4Compiler + MTL4Archive | newRenderPipelineState + MTLBinaryArchive |
// | 设备归档 | gal_core.m 设备归档（M4 用 gal_be_capture_compiler） | 挂只收二进制的 MTL4PipelineDataSetSerializer 的编译器，写 MTL4Archive | NXGAL_M3_ARCHIVE=1 开启完整描述的 MTLBinaryArchive 读取与 add/serialize，缺省关；设备目录另带 .mtl3 |
// | 管线特化 | gal_pso_can_specialize / gal_specialize_render_pso / gal_pso_unspecialize_color（gal_core.m） | 片元输出留空的基础管线 + newRenderPipelineStateBySpecialization（实测中位 0.00 ms） | 没有特化接口：gal_pso_can_specialize 为假，按完整描述现建（首遇现建计数报红，见 设计.md 管线预建） |
#pragma once
enum { GAL_BE_NONE = 0, GAL_BE_MTL4 = 1, GAL_BE_MTL3 = 2 };
// 本段也由纯 C 单测引用，不依赖 Objective-C / Metal 头里的 API_AVAILABLE 宏。
extern int g_gal_be __attribute__((availability(macos, introduced=15.0), availability(ios, introduced=18.0)));
static inline int gal_be_kind(void) __attribute__((availability(macos, introduced=15.0), availability(ios, introduced=18.0)));
static inline int gal_be_kind(void) { return g_gal_be; }
#ifdef __OBJC__
#import <Metal/Metal.h>
// 库里按名取函数的描述（Metal 4：MTL4LibraryFunctionDescriptor；管线描述的顶点 / 片元函数字段收它）
API_AVAILABLE(macos(26.0), ios(26.0)) static inline id gal_be_fn_desc(id<MTLLibrary> lib, NSString *name) { __auto_type g = [MTL4LibraryFunctionDescriptor new]; g.library = lib; g.name = name; return g; }
// 计算管线的函数描述；常量为空时不特化。
API_AVAILABLE(macos(26.0), ios(26.0)) static inline id gal_be_compute_desc(id fn, MTLFunctionConstantValues *values) {
    if (values) { __auto_type s = [MTL4SpecializedFunctionDescriptor new]; s.functionDescriptor = fn; s.constantValues = values; fn = s; }
    __auto_type d = [MTL4ComputePipelineDescriptor new]; d.computeFunctionDescriptor = fn; return d;
}
// 计算参数表：地址、贴图和采样器各自从槽 0 编起；调用方保留表以供同一遍重复绑定。
API_AVAILABLE(macos(26.0), ios(26.0)) static inline id gal_be_table_new(id<MTLDevice> dev, NSUInteger buffers, NSUInteger textures, NSUInteger samplers, NSError **e) {
    __auto_type d = [MTL4ArgumentTableDescriptor new]; d.maxBufferBindCount = buffers; d.maxTextureBindCount = textures; d.maxSamplerStateBindCount = samplers;
    return [dev newArgumentTableWithDescriptor:d error:e];
}
API_AVAILABLE(macos(26.0), ios(26.0)) static inline void gal_be_table_address(id<MTL4ArgumentTable> t, uint64_t address, NSUInteger index) { [t setAddress:address atIndex:index]; }
API_AVAILABLE(macos(26.0), ios(26.0)) static inline void gal_be_table_texture(id<MTL4ArgumentTable> t, id<MTLTexture> texture, NSUInteger index) { [t setTexture:texture.gpuResourceID atIndex:index]; }
API_AVAILABLE(macos(26.0), ios(26.0)) static inline void gal_be_table_sampler(id<MTL4ArgumentTable> t, id<MTLSamplerState> sampler, NSUInteger index) { [t setSamplerState:sampler.gpuResourceID atIndex:index]; }
API_AVAILABLE(macos(26.0), ios(26.0)) static inline void gal_be_compute_dispatch(id<MTL4ComputeCommandEncoder> e, id<MTLComputePipelineState> pso, id table, MTLSize threads, MTLSize group) {
    [e setComputePipelineState:pso]; [e setArgumentTable:table]; [e dispatchThreads:threads threadsPerThreadgroup:group];
}
// 渲染通道描述（gal_pass.m / gal_tex.m 建，交给 gal_render_begin_desc）：Metal 4 建 MTL4RenderPassDescriptor，Metal 3 建 MTLRenderPassDescriptor。
// 两个类的附件 / 目标宽高 / 层数 / 光栅采样数 / 可见性缓冲属性同名同义，调用方按 Metal 4 的类型写、只用这几项；visibilityResultType 老类 26 起才有（gal_cnt.m 判了）
API_AVAILABLE(macos(26.0), ios(26.0)) static inline MTL4RenderPassDescriptor *gal_be_pass_desc(void) {
    if (gal_be_kind() == GAL_BE_MTL4) return [MTL4RenderPassDescriptor new];
    return (MTL4RenderPassDescriptor *)[MTLRenderPassDescriptor new];
}
// 设备归档（gal_core.m）：新建一个挂「只收二进制」序列化器的编译器，*ser 返回序列化器（写盘 serializeAsArchiveAndFlushToURL）；失败返回 nil
API_AVAILABLE(macos(26.0), ios(26.0)) static inline id gal_be_capture_compiler(id<MTLDevice> d, id *ser, NSError **e) {
    __auto_type sd = [MTL4PipelineDataSetSerializerDescriptor new]; sd.configuration = MTL4PipelineDataSetSerializerConfigurationCaptureBinaries;
    id s = [d newPipelineDataSetSerializerWithDescriptor:sd]; if (!s) return nil;
    __auto_type cd = [MTL4CompilerDescriptor new]; cd.pipelineDataSetSerializer = s;
    id c = [d newCompilerWithDescriptor:cd error:e]; if (c) *ser = s; return c;
}
// 编码器时间戳（诊断 NXGAL_ENC_TS，gal_core.m ets_*）：时间戳计数堆、编码器开头 / 命令缓冲尾写时间戳、CPU 解出
API_AVAILABLE(macos(26.0), ios(26.0)) static inline id gal_be_ts_heap(id<MTLDevice> d, NSUInteger n) {
    MTL4CounterHeapDescriptor *x = [MTL4CounterHeapDescriptor new]; x.type = MTL4CounterHeapTypeTimestamp; x.count = n;
    return [d newCounterHeapWithDescriptor:x error:NULL];
}
// 渲染编码器在第一条绘制之前写：时间戳落在顶点阶段开始前（MTL4RenderCommandEncoder.h writeTimestampWithGranularity 说明）。
// 用 Precise：Relaxed 实测不在编码器开头写（10-22 怪猎：预载编码器的 Relaxed 起点比它里面第一条的 Precise 时间戳晚 425 ms），间隔归属会错
API_AVAILABLE(macos(26.0), ios(26.0)) static inline void gal_be_ts_enc(id e, int render, id h, NSUInteger i) {
    if (render) [(id<MTL4RenderCommandEncoder>)e writeTimestampWithGranularity:MTL4TimestampGranularityPrecise afterStage:MTLRenderStageVertex intoHeap:h atIndex:i];
    else [(id<MTL4ComputeCommandEncoder>)e writeTimestampWithGranularity:MTL4TimestampGranularityPrecise intoHeap:h atIndex:i];
}
// 计算编码器里两条命令之间：Precise 粒度（前面的派发 / 拷贝做完才写），预载内逐条定位用
API_AVAILABLE(macos(26.0), ios(26.0)) static inline void gal_be_ts_cmp_precise(id e, id h, NSUInteger i) { [(id<MTL4ComputeCommandEncoder>)e writeTimestampWithGranularity:MTL4TimestampGranularityPrecise intoHeap:h atIndex:i]; }
API_AVAILABLE(macos(26.0), ios(26.0)) static inline void gal_be_ts_cb(id cb, id h, NSUInteger i) { [(id<MTL4CommandBuffer>)cb writeTimestampIntoHeap:h atIndex:i]; }
API_AVAILABLE(macos(26.0), ios(26.0)) static inline NSData *gal_be_ts_resolve(id h, NSUInteger n) { return [(id<MTL4CounterHeap>)h resolveCounterRange:NSMakeRange(0, n)]; }
#endif
