using Ryujinx.Common;
using Ryujinx.Common.Configuration;
using Ryujinx.Common.Logging;
using Ryujinx.Common.Memory;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Gpu.Engine.Threed;
using Ryujinx.Graphics.Gpu.Engine.Types;
using Ryujinx.Graphics.Gpu.Image;
using Ryujinx.Graphics.Gpu.Memory;
using Ryujinx.Graphics.Gpu.Shader.DiskCache;
using Ryujinx.Graphics.Shader;
using Ryujinx.Graphics.Shader.Translation;
using Ryujinx.Memory.Range;
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Threading;

namespace Ryujinx.Graphics.Gpu.Shader
{
    /// <summary>
    /// Memory cache of shader code.
    /// </summary>
    class ShaderCache : IDisposable
    {
        /// <summary>
        /// Default flags used on the shader translation process.
        /// </summary>
        public const TranslationFlags DefaultFlags = TranslationFlags.DebugMode;

        private readonly struct TranslatedShader
        {
            public readonly CachedShaderStage Shader;
            public readonly ShaderProgram Program;

            public TranslatedShader(CachedShaderStage shader, ShaderProgram program)
            {
                Shader = shader;
                Program = program;
            }
        }

        private readonly struct TranslatedShaderVertexPair
        {
            public readonly CachedShaderStage VertexA;
            public readonly CachedShaderStage VertexB;
            public readonly ShaderProgram Program;

            public TranslatedShaderVertexPair(CachedShaderStage vertexA, CachedShaderStage vertexB, ShaderProgram program)
            {
                VertexA = vertexA;
                VertexB = vertexB;
                Program = program;
            }
        }

        private readonly GpuContext _context;

        private readonly ShaderDumper _dumper;

        private readonly Dictionary<ulong, CachedShaderProgram> _cpPrograms;
        private readonly Dictionary<ShaderAddresses, CachedShaderProgram> _gpPrograms;

        private readonly struct ProgramToSave
        {
            public readonly CachedShaderProgram CachedProgram;
            public readonly IProgram HostProgram;
            public readonly byte[] BinaryCode;

            public ProgramToSave(CachedShaderProgram cachedProgram, IProgram hostProgram, byte[] binaryCode)
            {
                CachedProgram = cachedProgram;
                HostProgram = hostProgram;
                BinaryCode = binaryCode;
            }
        }

        private readonly Queue<ProgramToSave> _programsToSaveQueue;

        private readonly ComputeShaderCacheHashTable _computeShaderCache;
        private readonly ShaderCacheHashTable _graphicsShaderCache;
        private readonly DiskCacheHostStorage _diskCacheHostStorage;
        private readonly BackgroundDiskCacheWriter _cacheWriter;

        /// <summary>
        /// Event for signalling shader cache loading progress.
        /// </summary>
        public event Action<ShaderCacheState, int, int> ShaderCacheStateChanged;

        /// <summary>
        /// Creates a new instance of the shader cache.
        /// </summary>
        /// <param name="context">GPU context that the shader cache belongs to</param>
        public ShaderCache(GpuContext context)
        {
            _context = context;

            _dumper = new ShaderDumper();

            _cpPrograms = new Dictionary<ulong, CachedShaderProgram>();
            _gpPrograms = new Dictionary<ShaderAddresses, CachedShaderProgram>();

            _programsToSaveQueue = new Queue<ProgramToSave>();

            string diskCacheTitleId = GetDiskCachePath();

            _computeShaderCache = new ComputeShaderCacheHashTable();
            _graphicsShaderCache = new ShaderCacheHashTable();
            _diskCacheHostStorage = new DiskCacheHostStorage(diskCacheTitleId);

            if (_diskCacheHostStorage.CacheEnabled)
            {
                _cacheWriter = new BackgroundDiskCacheWriter(context, _diskCacheHostStorage);
            }
        }

        /// <summary>
        /// Gets the path where the disk cache for the current application is stored.
        /// </summary>
        private static string GetDiskCachePath()
        {
            return GraphicsConfig.EnableShaderCache && GraphicsConfig.TitleId != null
                ? Path.Combine(AppDataManager.GamesDirPath, GraphicsConfig.TitleId.ToLower(), "cache", "shader")
                : null;
        }

        /// <summary>
        /// Processes the queue of shaders that must save their binaries to the disk cache.
        /// </summary>
        public void ProcessShaderCacheQueue()
        {
            // S2A：按需实化的程序不再同步查链接，这里补查；失败的从按地址的快表里摘掉（之后查找跳过作废条目、首遇照常翻译）
            _diskCacheHostStorage.S2AProcessPendingLink(S2AForget);

            // Check to see if the binaries for previously compiled shaders are ready, and save them out.

            // S2A（10-25）：不再在队首 Incomplete 时整体停写。真机上一条永不完成的程序
            //   （编译任务被丢弃 / 转计算子程序没被使用）会让它后面所有已完成程序一直不落盘，
            //   下次启动仍然全部现翻（Redmi 实测 525 条客体记录只落 19 条宿主记录）。
            //   每次只走一遍当前队列：完成的保存、失败的丢弃、未完成的移到队尾下帧再查。
            int pending = _programsToSaveQueue.Count;
            for (int i = 0; i < pending; i++)
            {
                ProgramToSave programToSave = _programsToSaveQueue.Dequeue();
                // S2A：转计算程序有三个宿主程序，全部编完才取（复合）二进制（S2AVtg）
                // S2A（10-24）：不等渲染线程查（S2AVtg.LinkStatusNoWait）。原先 CheckLink 是 InvokeCommand，渲染线程正等一条管线 / 一支现编时 GPU 模拟线程就停在这里
                //   （10-24 Mac xc3 冷局第 1230 帧停 10 秒：GPU 模拟线程 ProcessShaderCacheQueue → CheckLink 等渲染线程、渲染线程 gal_pso_job_wait 等后台管线）；二进制由渲染线程编完时顺手取好
                ProgramLinkStatus result = S2AVtg.LinkStatusNoWait(programToSave.CachedProgram);

                if (result == ProgramLinkStatus.Incomplete)
                {
                    _programsToSaveQueue.Enqueue(programToSave);
                    continue;
                }

                if (result == ProgramLinkStatus.Success)
                {
                    byte[] binary = programToSave.BinaryCode ?? S2AVtg.GetBinary(programToSave.CachedProgram);
                    if (DiskCacheCommon.S2ACacheDiagnostics)
                    {
                        if (binary == null || binary.Length == 0) _s2aSaveEmpty++;
                        else _s2aSaveWritten++;
                    }
                    _cacheWriter.AddShader(programToSave.CachedProgram, binary);
                }
                else
                {
                    // A failed link is actionable even when periodic diagnostics are off.
                    Console.Error.WriteLine("[gal] 【红】着色器程序链接失败，未写入宿主缓存");
                    if (DiskCacheCommon.S2ACacheDiagnostics) _s2aSaveFailed++;
                }
            }

            // S2A 诊断：每 5 s 一行，判断宿主记录不落盘是“没入队 / 永远 Incomplete / 二进制为空”。
            if (DiskCacheCommon.S2ACacheDiagnostics)
            {
                _s2aSaveIncomplete = _programsToSaveQueue.Count;
                long now = Environment.TickCount64;
                if (now - _s2aSaveReported >= 5000 &&
                    (_s2aSaveEnqueued | _s2aSaveWritten | _s2aSaveEmpty | _s2aSaveFailed) != 0)
                {
                    _s2aSaveReported = now;
                    Console.Error.WriteLine($"[vkpb] 存缓存计数：翻译 {_s2aTranslated}、入队 {_s2aSaveEnqueued}、已写 {_s2aSaveWritten}、" +
                        $"空二进制 {_s2aSaveEmpty}、失败 {_s2aSaveFailed}、队列 {_s2aSaveIncomplete}");
                    _s2aTranslated = _s2aSaveEnqueued = _s2aSaveWritten = _s2aSaveEmpty = _s2aSaveFailed = 0;
                }
            }
        }

        private long _s2aSaveReported;
        private int _s2aSaveEnqueued, _s2aSaveWritten, _s2aSaveEmpty, _s2aSaveFailed, _s2aSaveIncomplete;
        private int _s2aTranslated;

        private void S2AForget(CachedShaderProgram program)
        {
            foreach (KeyValuePair<ShaderAddresses, CachedShaderProgram> kv in _gpPrograms.Where(kv => kv.Value == program).ToList())
            {
                _gpPrograms.Remove(kv.Key);
            }

            foreach (KeyValuePair<ulong, CachedShaderProgram> kv in _cpPrograms.Where(kv => kv.Value == program).ToList())
            {
                _cpPrograms.Remove(kv.Key);
            }
        }

        /// <summary>
        /// Initialize the cache.
        /// </summary>
        /// <param name="cancellationToken">Cancellation token to cancel the shader cache initialization process</param>
        internal void Initialize(CancellationToken cancellationToken)
        {
            if (_diskCacheHostStorage.CacheEnabled)
            {
                ParallelDiskCacheLoader loader = new(
                    _context,
                    _graphicsShaderCache,
                    _computeShaderCache,
                    _diskCacheHostStorage,
                    ShaderCacheStateUpdate,
                    cancellationToken);

                loader.LoadShaders();

                int errorCount = loader.ErrorCount;
                if (errorCount != 0)
                {
                    Logger.Warning?.Print(LogClass.Gpu, $"Failed to load {errorCount} shaders from the disk cache.");
                }

                // S2A：离线包种入成功却一支都没被磁盘缓存读到 = 包布局与 cache root 不一致
                // （11-02 8E 实测：种入 7 个文件但 LoadShaders 0 支，首遇重翻 26 不受影响）。
                // #1411/#1546：唯一不报的结局是版本不符整批作废（装载时已单独报红）；文件缺失与
                // 装载没走到定结局处（magic / FormatVersion 损坏抛异常被接住，结局为 null）都照报。
                if (S2AShaderCacheGuard.ShouldReportPackZero(S2AShaderCacheGuard.PackPrograms, loader.LoadedPrograms, loader.S2AOutcome))
                {
                    Console.Error.WriteLine($"[gal] 【红】着色器离线包：种入 {S2AShaderCacheGuard.PackPrograms} 支，" +
                        "但运行时从磁盘缓存读到 0 支（检查包文件是否落在 cache root 而不是 shcache/<title>/）");
                }

                // S2A：加载屏预热。包内 pso_warm.tsv 给出路线程序号；在 GPU 线程上同步实化这些组
                // 并等待 BackgroundCompilation 完成，把首启的驱动管线编译移到加载屏。清单缺失/为空
                // 只报一行、不假装成功。
                S2APreloadWarm();
            }
        }

        /// <summary>
        /// S2A（加载屏预热）：按包内热表实化路线程序组并等待后台管线预建。
        /// 在 ShaderCache.Initialize 的载入线程（GPU 线程）上同步执行；整批共用总等待预算，
        /// 超时 / 预算用尽只记失败并停止等待。只在关闭宿主程序预读的后端（安卓 Vulkan）执行，
        /// 苹果通用路径保持原来的后台预读，不进入这里。
        /// </summary>
        private void S2APreloadWarm()
        {
            HashSet<int> warm = _diskCacheHostStorage.S2AWarmIndices;

            S2APipelineWarm.Result result = S2APipelineWarm.Run(
                S2APipelineWarm.S2APolicy(_context.Renderer),
                warm,
                _graphicsShaderCache.S2AGroups.Concat(_computeShaderCache.S2ALazyGroups),
                S2APipelineWarm.TotalBudgetMs,
                S2APipelineWarm.PerProgramTimeoutMs);

            if (result.SkippedByBackend)
            {
                Console.Error.WriteLine("[s2a] 加载屏预热：后端未关闭宿主程序预读（苹果路径），跳过");
                return;
            }

            if (!result.Ran)
            {
                Console.Error.WriteLine("[s2a] 加载屏预热：清单缺失/为空，跳过");
                return;
            }

            Console.Error.WriteLine($"[s2a] 加载屏预热：清单 {warm.Count}、命中组 {result.Groups}、程序 {result.Programs}、" +
                $"管线等待 {result.Waited}、超时/失败 {result.Failed}、总预算用尽 {(result.BudgetExhausted ? "是" : "否")}、用时 {result.Milliseconds:0} ms");
        }

        /// <summary>
        /// Shader cache state update handler.
        /// </summary>
        /// <param name="state">Current state of the shader cache load process</param>
        /// <param name="current">Number of the current shader being processed</param>
        /// <param name="total">Total number of shaders to process</param>
        private void ShaderCacheStateUpdate(ShaderCacheState state, int current, int total)
        {
            ShaderCacheStateChanged?.Invoke(state, current, total);
        }

        /// <summary>
        /// Gets a compute shader from the cache.
        /// </summary>
        /// <remarks>
        /// This automatically translates, compiles and adds the code to the cache if not present.
        /// </remarks>
        /// <param name="channel">GPU channel</param>
        /// <param name="samplerPoolMaximumId">Maximum ID that an entry in the sampler pool may have</param>
        /// <param name="poolState">Texture pool state</param>
        /// <param name="computeState">Compute engine state</param>
        /// <param name="gpuVa">GPU virtual address of the binary shader code</param>
        /// <returns>Compiled compute shader code</returns>
        public CachedShaderProgram GetComputeShader(
            GpuChannel channel,
            int samplerPoolMaximumId,
            GpuChannelPoolState poolState,
            GpuChannelComputeState computeState,
            ulong gpuVa)
        {
            // One request span: lookup, decode/translation, and host-program creation.
            // Native debug gate disables this entire trace outside opted-in Android sessions.
            using var s2aEvent = S2ACompileEvents.Begin(S2ACompileEvents.Kind.Translation);
            if (_cpPrograms.TryGetValue(gpuVa, out CachedShaderProgram cpShader) && IsShaderEqual(channel, poolState, computeState, cpShader, gpuVa))
            {
                s2aEvent?.Complete(S2ACompileEvents.Result.Hit);
                return cpShader;
            }

            S2AComputeFetchEnd[0] = 0;

            // S2A（#723 P1）：同一地址上次取码失败、碰过的页此后没被写过、映射也没挪 → 直接抛上次的消息，不再解码。
            S2AFaultHostOf s2aHost = new(channel.MemoryManager);
            string s2aFault = _s2aFaults.Check(gpuVa, s2aHost);
            if (s2aFault != null) throw new InvalidOperationException(s2aFault);

            byte[] cachedGuestCode;

            // S2A：磁盘缓存（包内）条目首次命中先核对运行时真值，不符就作废、接着找下一个（作废的查找时跳过，循环必然结束）
            while (_computeShaderCache.TryFind(channel, poolState, computeState, gpuVa, out cpShader, out cachedGuestCode))
            {
                if (cpShader.SpecializationState.S2ANeedsVerify && !S2AVerify(cpShader, channel, ref poolState, samplerPoolMaximumId, isCompute: true, default, computeState, null))
                {
                    continue;
                }

                _cpPrograms[gpuVa] = cpShader;
                S2ASeen.Note(cpShader);   // S2A：双轨覆盖率就绪，见过的着色器记 seen（S2ASeen）
                s2aEvent?.Complete(S2ACompileEvents.Result.Hit);
                return cpShader;
            }

            S2ALogMiss(isCompute: true);
            ShaderSpecializationState specState = new(ref computeState);
            GpuAccessorState gpuAccessorState = new(samplerPoolMaximumId, poolState, computeState, default, specState);
            GpuAccessor gpuAccessor = new(_context, channel, gpuAccessorState);
            gpuAccessor.InitializeReservedCounts(tfEnabled: false, vertexAsCompute: false);

            // S2A（#723 P1）：解码时记下碰过的每一页。失败后先武装这些页的写跟踪、再用一次性状态重解一遍确认：
            //   确认仍失败且碰的页都在武装范围内 → 其间没有写，记入负缓存（之后写任意一页、或页被挪走即作废）；
            //   确认成功 → 第一次失败是并发写造成的瞬时现象，用确认那次的上下文与状态继续，不记。
            S2AFaultProbe s2aProbe = new();
            gpuAccessor.S2AProbe = s2aProbe;
            gpuAccessor.S2AFetchEnd = S2AComputeFetchEnd;

            TranslatorContext translatorContext;
            try
            {
                translatorContext = DecodeComputeShader(gpuAccessor, GpuAccessorBase.S2ATranslationCapabilities(_context).Api, gpuVa);
                _s2aFaults.Forget(gpuVa);
            }
            catch (InvalidOperationException e) when (e.Message.StartsWith("S2A: shader code fetch"))
            {
                S2AFaultPage[] s2aPages = s2aProbe.Take();
                IS2AFaultWatch[] s2aWatches = S2AArmFaultPages(s2aHost, s2aPages);

                ShaderSpecializationState s2aSpec2 = new(ref computeState);
                GpuAccessorState s2aAccState2 = new(samplerPoolMaximumId, poolState, computeState, default, s2aSpec2);
                GpuAccessor s2aAccessor2 = new(_context, channel, s2aAccState2);
                s2aAccessor2.InitializeReservedCounts(tfEnabled: false, vertexAsCompute: false);
                S2AFaultProbe s2aProbe2 = new();
                s2aAccessor2.S2AProbe = s2aProbe2;
                s2aAccessor2.S2AFetchEnd = S2AComputeFetchEnd;

                try
                {
                    translatorContext = DecodeComputeShader(s2aAccessor2, GpuAccessorBase.S2ATranslationCapabilities(_context).Api, gpuVa);
                    specState = s2aSpec2;
                    S2ADisposeWatches(s2aWatches);
                    _s2aFaults.Forget(gpuVa);
                }
                catch (InvalidOperationException e2) when (e2.Message.StartsWith("S2A: shader code fetch"))
                {
                    if (S2APagesCovered(s2aProbe2.Take(), s2aPages)) _s2aFaults.Record(gpuVa, s2aHost, S2AFaultProbe.PagesOf(s2aPages), s2aWatches, e.Message);
                    else S2ADisposeWatches(s2aWatches);   // 确认那次碰了范围外的页：判不了有没有写过，不记
                    throw;
                }
                catch
                {
                    S2ADisposeWatches(s2aWatches);
                    throw;
                }
            }
            TranslatedShader translatedShader = TranslateShader(_dumper, channel, translatorContext, cachedGuestCode, asCompute: false);

            ShaderSource[] shaderSourcesArray = new ShaderSource[] { CreateShaderSource(translatedShader.Program) };
            ShaderInfo info = ShaderInfoBuilder.BuildForCompute(_context, translatedShader.Program.Info);
            IProgram hostProgram = _context.Renderer.CreateProgram(shaderSourcesArray, info);

            cpShader = new CachedShaderProgram(hostProgram, specState, translatedShader.Shader);

            _computeShaderCache.Add(cpShader);
            if (DiskCacheCommon.S2ACacheDiagnostics) _s2aTranslated++;
            EnqueueProgramToSave(cpShader, hostProgram, shaderSourcesArray);
            _cpPrograms[gpuVa] = cpShader;
            S2ASeen.Note(cpShader);   // S2A：双轨覆盖率就绪，见过的着色器记 seen（S2ASeen）

            s2aEvent?.Complete(S2ACompileEvents.Result.Miss);
            return cpShader;
        }

        /// <summary>
        /// Updates the shader pipeline state based on the current GPU state.
        /// </summary>
        /// <param name="state">Current GPU 3D engine state</param>
        /// <param name="pipeline">Shader pipeline state to be updated</param>
        /// <param name="graphicsState">Current graphics state</param>
        /// <param name="channel">Current GPU channel</param>
        private static void UpdatePipelineInfo(
            ref ThreedClassState state,
            ref ProgramPipelineState pipeline,
            GpuChannelGraphicsState graphicsState,
            GpuChannel channel)
        {
            channel.TextureManager.UpdateRenderTargets();

            RtControl rtControl = state.RtControl;
            TextureMsaaMode msaaMode = state.RtMsaaMode;

            pipeline.SamplesCount = msaaMode.SamplesInX() * msaaMode.SamplesInY();

            int count = rtControl.UnpackCount();

            Span<RtColorState> rtColorStateSpan = state.RtColorState.AsSpan();
            Span<bool> attachmentEnableSpan = pipeline.AttachmentEnable.AsSpan();
            Span<Format> attachmentFormatsSpan = pipeline.AttachmentFormats.AsSpan();

            for (int index = 0; index < Constants.TotalRenderTargets; index++)
            {
                int rtIndex = rtControl.UnpackPermutationIndex(index);

                RtColorState colorState = rtColorStateSpan[rtIndex];

                if (index >= count || colorState.Format == 0 || colorState.WidthOrStride == 0)
                {
                    attachmentEnableSpan[index] = false;
                    attachmentFormatsSpan[index] = Format.R8G8B8A8Unorm;
                }
                else
                {
                    attachmentEnableSpan[index] = true;
                    attachmentFormatsSpan[index] = colorState.Format.Convert().Format;
                }
            }

            pipeline.DepthStencilEnable = state.RtDepthStencilEnable;
            pipeline.DepthStencilFormat = pipeline.DepthStencilEnable ? state.RtDepthStencilState.Format.Convert().Format : Format.D24UnormS8Uint;

            pipeline.VertexBufferCount = Constants.TotalVertexBuffers;
            pipeline.Topology = graphicsState.Topology;
        }

        /// <summary>
        /// Gets a graphics shader program from the shader cache.
        /// This includes all the specified shader stages.
        /// </summary>
        /// <remarks>
        /// This automatically translates, compiles and adds the code to the cache if not present.
        /// </remarks>
        /// <param name="state">GPU state</param>
        /// <param name="pipeline">Pipeline state</param>
        /// <param name="channel">GPU channel</param>
        /// <param name="samplerPoolMaximumId">Maximum ID that an entry in the sampler pool may have</param>
        /// <param name="poolState">Texture pool state</param>
        /// <param name="graphicsState">3D engine state</param>
        /// <param name="addresses">Addresses of the shaders for each stage</param>
        /// <returns>Compiled graphics shader code</returns>
        // S2A（10-21）：首遇重翻诊断——缓存（含包内条目）查找不中、即将翻译时记一行拒因：缺哪个阶段的客体代码 / 阶段组合没配进缓存 / 特化不符（哪个字段）。
        //   同一拒因第 1、2、4、8… 次打一行（host.log），按拒因统计「包里漏了什么」，作第二层通用版兜底的输入（画面·着色器线缩键测算）
        private static readonly Dictionary<string, int> _s2aMissCounts = new();

        // S2A（#723 P1）：取码失败负缓存。命中时抛的消息前缀与安全阀同一条，两个调用方的 catch 不用改。
        private readonly S2AShaderFaultCache _s2aFaults = new();

        /// <summary>
        /// S2A（着色器防线红行现场，10-29）：最近一次取图形 / 计算着色器时各阶段取码读到的最远 GPU 地址（不含；下标同 ShaderAddresses，计算用 [0]）。
        /// 缓存没命中、要解码时清零，解码时 GpuAccessor 逐次更新；调用方（StateUpdater / ComputeClass）在 GPU 线程上接住异常后读。0 = 这次没读（如负缓存命中）
        /// </summary>
        internal readonly ulong[] S2AGraphicsFetchEnd = new ulong[Constants.ShaderStages + 1];
        internal readonly ulong[] S2AComputeFetchEnd = new ulong[1];

        /// <summary>S2A：给这些页武装写跟踪并记下读过区间的内容（未映射页返回 null，不武装）。</summary>
        private static IS2AFaultWatch[] S2AArmFaultPages(S2AFaultHostOf host, S2AFaultPage[] pages)
        {
            List<IS2AFaultWatch> watches = new(pages.Length);
            foreach (S2AFaultPage page in pages)
            {
                IS2AFaultWatch watch = host.Arm(page.Page, page.Lo, page.Hi);
                if (watch != null) watches.Add(watch);
            }
            return watches.ToArray();
        }

        private static void S2ADisposeWatches(IS2AFaultWatch[] watches)
        {
            foreach (IS2AFaultWatch watch in watches) watch.Dispose();
        }

        /// <summary>S2A：确认那次解码碰的页是否都在已武装的页里（都在 ⇒ 其间没有写过，可以记入）。</summary>
        private static bool S2APagesCovered(S2AFaultPage[] pages, S2AFaultPage[] armed)
        {
            HashSet<ulong> set = new(S2AFaultProbe.PagesOf(armed));
            foreach (S2AFaultPage page in pages)
            {
                if (!set.Contains(page.Page)) return false;
            }
            return true;
        }

        /// <summary>S2A：图形着色器的负缓存键（六个阶段的 GPU 地址）。</summary>
        private static S2AFaultKey S2AFaultKeyOf(ShaderAddresses addresses)
        {
            Span<ulong> v = addresses.AsSpan();
            return new S2AFaultKey(v[0], v[1], v[2], v[3], v[4], v[5]);
        }
        /// <summary>S2A（#723 P1）：图形着色器各阶段解码（原 GetGraphicsShader 内联循环，抽出来供确认解码复用同一套顺序）。</summary>
        private TranslatorContext[] S2ADecodeStages(
            GpuContext context,
            GpuChannel channel,
            GpuAccessorState gpuAccessorState,
            ReadOnlySpan<ulong> addressesSpan,
            ShaderAddresses addresses,
            S2AFaultProbe probe,
            out GpuAccessor[] gpuAccessors)
        {
            gpuAccessors = new GpuAccessor[Constants.ShaderStages];
            TranslatorContext[] translatorContexts = new TranslatorContext[Constants.ShaderStages + 1];
            TranslatorContext nextStage = null;

            TargetApi api = GpuAccessorBase.S2ATranslationCapabilities(context).Api;

            for (int stageIndex = Constants.ShaderStages - 1; stageIndex >= 0; stageIndex--)
            {
                ulong gpuVa = addressesSpan[stageIndex + 1];

                if (gpuVa != 0)
                {
                    GpuAccessor gpuAccessor = new(context, channel, gpuAccessorState, stageIndex, addresses.Geometry != 0);
                    gpuAccessor.S2AProbe = probe;
                    gpuAccessor.S2AFetchEnd = S2AGraphicsFetchEnd;
                    gpuAccessor.S2AFetchSlot = stageIndex + 1;
                    TranslatorContext currentStage = DecodeGraphicsShader(gpuAccessor, api, DefaultFlags, gpuVa);

                    if (nextStage != null)
                    {
                        currentStage.SetNextStage(nextStage);
                    }

                    if (stageIndex == 0 && addresses.VertexA != 0)
                    {
                        gpuAccessor.S2AFetchSlot = 0;   // 顶点 A 与顶点 B 共用这个取码器：记到 [0]，解完切回 [1]
                        translatorContexts[0] = DecodeGraphicsShader(gpuAccessor, api, DefaultFlags | TranslationFlags.VertexA, addresses.VertexA);
                        gpuAccessor.S2AFetchSlot = 1;
                    }

                    gpuAccessors[stageIndex] = gpuAccessor;
                    translatorContexts[stageIndex + 1] = currentStage;
                    nextStage = currentStage;
                }
            }

            return translatorContexts;
        }

        private static void S2ALogMiss(bool isCompute)
        {
            string why = (isCompute ? "计算：" : "图形：") + (ShaderSpecializationState.S2AMiss ?? "缓存里没有（未分类）");
            ShaderSpecializationState.S2AMiss = null;
            int n;
            lock (_s2aMissCounts) { _s2aMissCounts.TryGetValue(why, out n); _s2aMissCounts[why] = ++n; }
            if ((n & (n - 1)) == 0) Console.Error.WriteLine($"[gal] 首遇重翻拒因：{why}（第 {n} 次）");
        }

        public CachedShaderProgram GetGraphicsShader(
            ref ThreedClassState state,
            ref ProgramPipelineState pipeline,
            GpuChannel channel,
            int samplerPoolMaximumId,
            ref GpuChannelPoolState poolState,
            ref GpuChannelGraphicsState graphicsState,
            ShaderAddresses addresses)
        {
            // One request span: lookup, decode/translation, and host-program creation.
            // Native debug gate disables this entire trace outside opted-in Android sessions.
            using var s2aEvent = S2ACompileEvents.Begin(S2ACompileEvents.Kind.Translation);
            if (_gpPrograms.TryGetValue(addresses, out CachedShaderProgram gpShaders) && IsShaderEqual(channel, ref poolState, ref graphicsState, gpShaders, addresses))
            {
                s2aEvent?.Complete(S2ACompileEvents.Result.Hit);
                return gpShaders;
            }

            Array.Clear(S2AGraphicsFetchEnd);

            // S2A（#723 P1）：这组地址上次取码失败、碰过的页此后没被写过、映射也没挪 → 直接抛上次的消息，不再解码（计算路径同）。
            S2AFaultHostOf s2aHost = new(channel.MemoryManager);
            S2AFaultKey s2aKey = S2AFaultKeyOf(addresses);
            string s2aFault = _s2aFaults.Check(s2aKey, s2aHost);
            if (s2aFault != null) throw new InvalidOperationException(s2aFault);

            CachedGraphicsGuestCode cachedGuestCode;

            // S2A：同上（计算着色器那段）。拆账（S2A_ALLOC_TRACE）：查缓存 + 按需实化 / 首次命中核对分开记
            long s2aF = S2AAllocTrace.On ? S2AAllocTrace.Now() : 0;
            while (_graphicsShaderCache.TryFind(channel, ref poolState, ref graphicsState, addresses, out gpShaders, out cachedGuestCode))
            {
                long s2aV = S2AAllocTrace.On ? S2AAllocTrace.Now() : 0;
                bool s2aBad = gpShaders.SpecializationState.S2ANeedsVerify &&
                    !S2AVerify(gpShaders, channel, ref poolState, samplerPoolMaximumId, isCompute: false, graphicsState, default, state.TfEnable ? GetTransformFeedbackDescriptors(ref state) : null);
                if (S2AAllocTrace.On) { long v = S2AAllocTrace.Now() - s2aV; S2AAllocTrace.Raw(0x40_000e, v); s2aF += v; }
                if (s2aBad)
                {
                    continue;
                }

                _gpPrograms[addresses] = gpShaders;
                S2ASeen.Note(gpShaders);   // S2A：双轨覆盖率就绪，见过的着色器记 seen（S2ASeen）
                if (S2AAllocTrace.On) S2AAllocTrace.Raw(0x40_000d, S2AAllocTrace.Now() - s2aF);
                s2aEvent?.Complete(S2ACompileEvents.Result.Hit);
                return gpShaders;
            }
            if (S2AAllocTrace.On) S2AAllocTrace.Raw(0x40_000d, S2AAllocTrace.Now() - s2aF);

            S2ALogMiss(isCompute: false);
            TransformFeedbackDescriptor[] transformFeedbackDescriptors = GetTransformFeedbackDescriptors(ref state);

            UpdatePipelineInfo(ref state, ref pipeline, graphicsState, channel);

            ShaderSpecializationState specState = new(ref graphicsState, ref pipeline, transformFeedbackDescriptors);
            GpuAccessorState gpuAccessorState = new(samplerPoolMaximumId, poolState, default, graphicsState, specState, transformFeedbackDescriptors);

            ReadOnlySpan<ulong> addressesSpan = addresses.AsSpan();

            // S2A（#723 P1）：解码时记下碰过的每一页。失败后武装这些页的写跟踪、用一次性状态再解一遍确认：
            //   确认仍失败且碰的页都在武装范围内 → 其间没写过，记入负缓存；确认成功 → 第一次失败是并发写造成的瞬时现象，照确认那次的上下文与状态继续，不记。
            //   图形是多阶段循环，任一阶段抛即整体失败，所以探针整个循环共用一个。
            S2AFaultProbe s2aProbe = new();
            TranslatorContext[] translatorContexts;
            GpuAccessor[] gpuAccessors;
            try
            {
                translatorContexts = S2ADecodeStages(_context, channel, gpuAccessorState, addressesSpan, addresses, s2aProbe, out gpuAccessors);
                _s2aFaults.Forget(s2aKey);
            }
            catch (InvalidOperationException e) when (e.Message.StartsWith("S2A: shader code fetch"))
            {
                S2AFaultPage[] s2aPages = s2aProbe.Take();
                IS2AFaultWatch[] s2aWatches = S2AArmFaultPages(s2aHost, s2aPages);

                ShaderSpecializationState s2aSpec2 = new(ref graphicsState, ref pipeline, transformFeedbackDescriptors);
                GpuAccessorState s2aAccState2 = new(samplerPoolMaximumId, poolState, default, graphicsState, s2aSpec2, transformFeedbackDescriptors);
                S2AFaultProbe s2aProbe2 = new();

                try
                {
                    translatorContexts = S2ADecodeStages(_context, channel, s2aAccState2, addressesSpan, addresses, s2aProbe2, out gpuAccessors);
                    specState = s2aSpec2;
                    S2ADisposeWatches(s2aWatches);
                    _s2aFaults.Forget(s2aKey);
                }
                catch (InvalidOperationException e2) when (e2.Message.StartsWith("S2A: shader code fetch"))
                {
                    if (S2APagesCovered(s2aProbe2.Take(), s2aPages)) _s2aFaults.Record(s2aKey, s2aHost, S2AFaultProbe.PagesOf(s2aPages), s2aWatches, e.Message);
                    else S2ADisposeWatches(s2aWatches);   // 确认那次碰了范围外的页：判不了有没有写过，不记
                    throw;
                }
                catch
                {
                    S2ADisposeWatches(s2aWatches);
                    throw;
                }
            }

            bool hasGeometryShader = translatorContexts[4] != null;
            bool vertexHasStore = translatorContexts[1] != null && translatorContexts[1].HasStore;
            bool geometryHasStore = hasGeometryShader && translatorContexts[4].HasStore;
            bool vertexToCompute = ShouldConvertVertexToCompute(_context, vertexHasStore, geometryHasStore, hasGeometryShader);
            bool geometryToCompute = ShouldConvertGeometryToCompute(_context, geometryHasStore);

            CachedShaderStage[] shaders = new CachedShaderStage[Constants.ShaderStages + 1];
            List<ShaderSource> shaderSources = new();

            TranslatorContext previousStage = null;
            ShaderInfoBuilder infoBuilder = new(_context, transformFeedbackDescriptors != null, vertexToCompute);

            if (geometryToCompute && translatorContexts[4] != null)
            {
                translatorContexts[4].SetVertexOutputMapForGeometryAsCompute(translatorContexts[1]);
            }

            ShaderAsCompute vertexAsCompute = null;
            ShaderAsCompute geometryAsCompute = null;
            ShaderProgramInfo passthroughInfo = null;

            for (int stageIndex = 0; stageIndex < Constants.ShaderStages; stageIndex++)
            {
                TranslatorContext currentStage = translatorContexts[stageIndex + 1];

                if (currentStage != null)
                {
                    gpuAccessors[stageIndex].InitializeReservedCounts(transformFeedbackDescriptors != null, vertexToCompute);

                    ShaderProgram program;

                    bool asCompute = (stageIndex == 0 && vertexToCompute) || (stageIndex == 3 && geometryToCompute);

                    if (stageIndex == 0 && translatorContexts[0] != null)
                    {
                        TranslatedShaderVertexPair translatedShader = TranslateShader(
                            _dumper,
                            channel,
                            currentStage,
                            translatorContexts[0],
                            cachedGuestCode.VertexACode,
                            cachedGuestCode.VertexBCode,
                            asCompute);

                        shaders[0] = translatedShader.VertexA;
                        shaders[1] = translatedShader.VertexB;
                        program = translatedShader.Program;
                    }
                    else
                    {
                        byte[] code = cachedGuestCode.GetByIndex(stageIndex);

                        TranslatedShader translatedShader = TranslateShader(_dumper, channel, currentStage, code, asCompute);

                        shaders[stageIndex + 1] = translatedShader.Shader;
                        program = translatedShader.Program;
                    }

                    if (asCompute)
                    {
                        bool tfEnabled = transformFeedbackDescriptors != null;

                        if (stageIndex == 0)
                        {
                            ShaderProgram vertexComputeProgram = program;
                            TranslatorContext lastInVertexPipeline = geometryToCompute ? translatorContexts[4] ?? currentStage : currentStage;

                            // If VS is the final guest vertex stage, this is the
                            // same decision made at the empty geometry slot below.
                            // Reject before allocating a compute program that would
                            // otherwise lose its owner on the exception path.
                            if (!hasGeometryShader && translatorContexts[2] == null && translatorContexts[3] == null &&
                                S2ALayerRouteFor(_context, currentStage, 3) == S2ALayerRoute.Unsupported)
                            {
                                S2ARejectLayerRoute();
                            }

                            // Validate the passthrough before allocating a host compute
                            // program: a rejected Layer route has no owner for it.
                            program = lastInVertexPipeline.GenerateVertexPassthroughForCompute();
                            S2ACheckLayerPassthrough(_context, program);
                            passthroughInfo = program.Info;
                            vertexAsCompute = CreateHostVertexAsComputeProgram(vertexComputeProgram, currentStage, tfEnabled);
                        }
                        else
                        {
                            geometryAsCompute = CreateHostVertexAsComputeProgram(program, currentStage, tfEnabled);
                            program = null;
                        }
                    }

                    if (program != null)
                    {
                        shaderSources.Add(CreateShaderSource(program));
                        infoBuilder.AddStageInfo(program.Info);
                    }

                    previousStage = currentStage;
                }
                else
                {
                    switch (S2ALayerRouteFor(_context, previousStage, stageIndex))
                    {
                        case S2ALayerRoute.GeometryPassthrough:
                            S2AGsDiag.NotePassthrough("ShaderCache");   // #1456：追加点来源
                            shaderSources.Add(CreateShaderSource(previousStage.GenerateGeometryPassthrough()));
                            break;
                        case S2ALayerRoute.Unsupported:
                            S2ARejectLayerRoute();
                            break;
                    }
                }
            }

            ShaderSource[] shaderSourcesArray = shaderSources.ToArray();

            ShaderInfo info = infoBuilder.Build(pipeline);

            IProgram hostProgram = _context.Renderer.CreateProgram(shaderSourcesArray, info);

            gpShaders = new(hostProgram, vertexAsCompute, geometryAsCompute, specState, shaders) { S2APassthroughInfo = passthroughInfo };

            _graphicsShaderCache.Add(gpShaders);

            // S2A：转计算的程序也进磁盘缓存（复合宿主二进制，S2AVtg；上游不缓存，每局首遇现翻）
            if (DiskCacheCommon.S2ACacheDiagnostics) _s2aTranslated++;
            EnqueueProgramToSave(gpShaders, hostProgram, shaderSourcesArray);

            if (vertexAsCompute != null)
            {
                S2AVtg.NoteRuntime(shaders);
            }

            _gpPrograms[addresses] = gpShaders;
            S2ASeen.Note(gpShaders);   // S2A：双轨覆盖率就绪，见过的着色器记 seen（S2ASeen）

            s2aEvent?.Complete(S2ACompileEvents.Result.Miss);
            return gpShaders;
        }

        /// <summary>
        /// Checks if a vertex shader should be converted to a compute shader due to it making use of
        /// features that are not supported on the host.
        /// </summary>
        /// <param name="context">GPU context of the shader</param>
        /// <param name="vertexHasStore">Whether the vertex shader has image or storage buffer store operations</param>
        /// <param name="geometryHasStore">Whether the geometry shader has image or storage buffer store operations, if one exists</param>
        /// <param name="hasGeometryShader">Whether a geometry shader exists</param>
        /// <returns>True if the vertex shader should be converted to compute, false otherwise</returns>
        public static bool ShouldConvertVertexToCompute(GpuContext context, bool vertexHasStore, bool geometryHasStore, bool hasGeometryShader)
        {
            // If the host does not support store operations on vertex,
            // we need to emulate it on a compute shader.
            if (!GpuAccessorBase.S2ATranslationCapabilities(context).SupportsVertexStoreAndAtomics && vertexHasStore)
            {
                return true;
            }

            // If any stage after the vertex stage is converted to compute,
            // we need to convert vertex to compute too.
            return hasGeometryShader && ShouldConvertGeometryToCompute(context, geometryHasStore);
        }

        /// <summary>
        /// Checks if a geometry shader should be converted to a compute shader due to it making use of
        /// features that are not supported on the host.
        /// </summary>
        /// <param name="context">GPU context of the shader</param>
        /// <param name="geometryHasStore">Whether the geometry shader has image or storage buffer store operations, if one exists</param>
        /// <returns>True if the geometry shader should be converted to compute, false otherwise</returns>
        public static bool ShouldConvertGeometryToCompute(GpuContext context, bool geometryHasStore)
        {
            return (!GpuAccessorBase.S2ATranslationCapabilities(context).SupportsVertexStoreAndAtomics && geometryHasStore) ||
                   !GpuAccessorBase.S2ATranslationCapabilities(context).SupportsGeometryShader;
        }

        /// <summary>
        /// Checks if it might be necessary for any vertex, tessellation or geometry shader to be converted to compute,
        /// based on the supported host features.
        /// </summary>
        /// <param name="capabilities">Host capabilities</param>
        /// <returns>True if the possibility of a shader being converted to compute exists, false otherwise</returns>
        public static bool MayConvertVtgToCompute(ref Capabilities capabilities)
        {
            return !capabilities.SupportsVertexStoreAndAtomics || !capabilities.SupportsGeometryShader;
        }

        /// <summary>
        /// S2A：顶点管线末段（顶点 / 细分求值）写了渲染目标层（gl_Layer）、本程序又没有客体几何着色器时，宿主侧的合法通路。
        /// 四处直通几何追加点（当场编译、磁盘缓存重建、转计算翻译、离线烘焙）共用一个判定；能力表取冻结档
        /// （GpuAccessorBase.S2ATranslationCapabilities），与转计算判据同一份，不各查各的 context.Capabilities。
        /// 旧判定只查 SupportsLayerVertexTessellation、漏了 SupportsGeometryShader：A-GSOCC 把 Arm 的 geometryShader
        /// 关掉后（9000 Mali-G710，#1456 系规避）照样追加 GenerateGeometryPassthrough 的真硬件几何阶段，
        /// 管线带着硬件 GS 创建、一画设备就丢（generic Z-A）。
        /// </summary>
        public enum S2ALayerRoute
        {
            /// <summary>不需要补段：没写层，或宿主认顶点 / 细分求值直接写层（Vulkan 1.2 shaderOutputLayer、VK_EXT_shader_viewport_index_layer、Metal）。</summary>
            Native,
            /// <summary>唯一通路是追加硬件直通几何着色器：层值在翻译时走私进通用属性输出，由它转成真 gl_Layer。</summary>
            GeometryPassthrough,
            /// <summary>没有任何通路：宿主既不支持几何着色器、也不认顶点写层。补段 = 往管线塞硬件 GS；调用方必须拒建，不得产出阶段。</summary>
            Unsupported,
        }

        /// <summary>层输出通路判定（见 S2ALayerRoute）。previousStage / stageIndex 照各调用点循环里的原值传入。</summary>
        /// <param name="context">GPU context of the shader</param>
        /// <param name="previousStage">Translation context of the previous active stage (vertex or tessellation evaluation)</param>
        /// <param name="stageIndex">Current stage index in the shader stages loop (3 = empty geometry slot)</param>
        /// <returns>The legal route for the layer output</returns>
        public static S2ALayerRoute S2ALayerRouteFor(GpuContext context, TranslatorContext previousStage, int stageIndex)
        {
            if (previousStage == null || stageIndex != 3 || !previousStage.LayerOutputWritten)
            {
                return S2ALayerRoute.Native;
            }

            Capabilities caps = GpuAccessorBase.S2ATranslationCapabilities(context);

            if (caps.SupportsLayerVertexTessellation)
            {
                return S2ALayerRoute.Native;
            }

            return caps.SupportsGeometryShader ? S2ALayerRoute.GeometryPassthrough : S2ALayerRoute.Unsupported;
        }

        private static int _s2aLayerRouteRed;

        /// <summary>
        /// 层输出通路 Unsupported 时调（含转计算直通顶点自己写 gl_Layer 而宿主不认顶点写层：那条通路同样不存在）：
        /// 报红一次（同 S2AVtg 空二进制口径），然后抛。运行时由 StateUpdater 的着色器异常捕获按组补现场并跳过本组绘制，
        /// GPU 线程不退出；加载器计入 ErrorCount、不排队；烘焙记 error_b。不建含非法阶段的管线，也不静默丢层画错。
        /// </summary>
        public static void S2ARejectLayerRoute()
        {
            if (Interlocked.Exchange(ref _s2aLayerRouteRed, 1) == 0)
            {
                Console.Error.WriteLine("[gal] 【红】着色器写渲染目标层（gl_Layer）：宿主不支持几何着色器、也不支持顶点 / 细分直接写层（Vulkan 1.2 shaderOutputLayer / VK_EXT_shader_viewport_index_layer）——没有合法通路，本组着色器不建管线、相关绘制跳过");
            }

            throw new InvalidOperationException("S2A: shader writes gl_Layer but the host supports neither geometryShader nor layer output from vertex/tessellation; no legal route exists.");
        }

        /// <summary>
        /// 转计算通路的直通顶点着色器生成后调：直通顶点若带层输出（客体几何以计算跑、往渲染目标层写过），
        /// 它自己要写 gl_Layer，同样需要宿主认顶点写层——不认就没有合法通路，照拒建处理。
        /// </summary>
        /// <param name="context">GPU context of the shader</param>
        /// <param name="passthrough">The generated vertex passthrough program</param>
        public static void S2ACheckLayerPassthrough(GpuContext context, ShaderProgram passthrough)
        {
            if (passthrough.Info.UsesRtLayer &&
                !GpuAccessorBase.S2ATranslationCapabilities(context).SupportsLayerVertexTessellation)
            {
                S2ARejectLayerRoute();
            }
        }

        /// <summary>
        /// Creates a compute shader from a vertex, tessellation or geometry shader that has been converted to compute.
        /// </summary>
        /// <param name="program">Shader program</param>
        /// <param name="context">Translation context of the shader</param>
        /// <param name="tfEnabled">Whether transform feedback is enabled</param>
        /// <returns>Compute shader</returns>
        private ShaderAsCompute CreateHostVertexAsComputeProgram(ShaderProgram program, TranslatorContext context, bool tfEnabled)
        {
            ShaderSource source = new(program.Code, program.BinaryCode, ShaderStage.Compute, program.Language);
            ShaderInfo info = ShaderInfoBuilder.BuildForVertexAsCompute(_context, program.Info, tfEnabled);

            return new(_context.Renderer.CreateProgram(new[] { source }, info), program.Info, context.GetResourceReservations());
        }

        /// <summary>
        /// Creates a shader source for use with the backend from a translated shader program.
        /// </summary>
        /// <param name="program">Translated shader program</param>
        /// <returns>Shader source</returns>
        public static ShaderSource CreateShaderSource(ShaderProgram program)
        {
            return new ShaderSource(program.Code, program.BinaryCode, program.Info.Stage, program.Language);
        }

        /// <summary>
        /// Puts a program on the queue of programs to be saved on the disk cache.
        /// </summary>
        /// <remarks>
        /// This will not do anything if disk shader cache is disabled.
        /// </remarks>
        /// <param name="program">Cached shader program</param>
        /// <param name="hostProgram">Host program</param>
        /// <param name="sources">Source for each shader stage</param>
        private void EnqueueProgramToSave(CachedShaderProgram program, IProgram hostProgram, ShaderSource[] sources)
        {
            if (_diskCacheHostStorage.CacheEnabled)
            {
                byte[] binaryCode = null; // S2A：一律存渲染器程序二进制（编完后取），不存 SPIR-V 打包
                ProgramToSave programToSave = new(program, hostProgram, binaryCode);
                Ryujinx.Graphics.GAL.Multithreading.ThreadedRenderer.S2AWantBinary(hostProgram);   // S2A：编完时渲染线程顺手取二进制（ProcessShaderCacheQueue 取时不等渲染线程）
                Ryujinx.Graphics.GAL.Multithreading.ThreadedRenderer.S2AWantBinary(program.VertexAsCompute?.HostProgram);
                Ryujinx.Graphics.GAL.Multithreading.ThreadedRenderer.S2AWantBinary(program.GeometryAsCompute?.HostProgram);

                _programsToSaveQueue.Enqueue(programToSave);
                if (DiskCacheCommon.S2ACacheDiagnostics) _s2aSaveEnqueued++;
            }
        }

        // S2A：包内条目首次命中核对（ShaderSpecializationState.S2AVerify）。只在磁盘缓存条目第一次被找到时跑，结论记在条目上；运行时真值对象与不符清单复用（GPU 线程独占）
        private readonly S2AChannelSpecRuntime _s2aRuntime = new();
        private readonly List<ShaderSpecializationState.S2ASpecMismatch> _s2aMismatches = new();

        private bool S2AVerify(
            CachedShaderProgram program,
            GpuChannel channel,
            ref GpuChannelPoolState poolState,
            int samplerPoolMaximumId,
            bool isCompute,
            GpuChannelGraphicsState graphicsState,
            GpuChannelComputeState computeState,
            TransformFeedbackDescriptor[] transformFeedback)
        {
            S2AChannelSpecRuntime rt = _s2aRuntime;
            rt.Channel = channel;
            rt.Pool = poolState;
            rt.IsCompute = isCompute;
            rt.Graphics = graphicsState;
            rt.Compute = computeState;
            rt.TransformFeedback = transformFeedback;
            rt.TexturePoolLength = poolState.TexturePoolMaximumId + 1;
            rt.SamplerPoolLength = samplerPoolMaximumId + 1;

            _s2aMismatches.Clear();
            ShaderSpecializationState spec = program.SpecializationState;
            spec.S2AVerify(rt, program.Shaders, GpuAccessorBase.S2ATranslationCapabilities(_context).Api == TargetApi.Vulkan, GpuAccessorBase.S2ATranslationCapabilities(_context).SupportsQuads, _s2aMismatches);
            int index = spec.S2ADiskIndex;
            ShaderSpecializationState.S2AReport(_s2aMismatches, index, isCompute, index < S2AShaderCacheGuard.PackPrograms, static line => Console.Error.WriteLine(line));
            rt.Channel = null;

            return _s2aMismatches.Count == 0;
        }

        /// <summary>S2A：按当前通道状态给出翻译器会读到的值（与 GpuAccessor 同一取法）</summary>
        private sealed class S2AChannelSpecRuntime : S2ASpecRuntime
        {
            public GpuChannel Channel;
            public GpuChannelPoolState Pool;
            public bool IsCompute;

            public override Image.TextureDescriptor GetTextureDescriptor(int stageIndex, int handle, int cbufSlot) => IsCompute
                ? Channel.TextureManager.GetComputeTextureDescriptor(Pool.TexturePoolGpuVa, Pool.TextureBufferIndex, Pool.TexturePoolMaximumId, handle, cbufSlot)
                : Channel.TextureManager.GetGraphicsTextureDescriptor(Pool.TexturePoolGpuVa, Pool.TextureBufferIndex, Pool.TexturePoolMaximumId, stageIndex, handle, cbufSlot);

            public override int UniformBufferSize(int stageIndex, int slot) => IsCompute
                ? Channel.BufferManager.GetComputeUniformBufferSize(slot)
                : Channel.BufferManager.GetGraphicsUniformBufferSize(stageIndex, slot);

            public override bool TryGetCb1(int stageIndex, int size, out ReadOnlySpan<byte> data)
            {
                ulong address = IsCompute ? Channel.BufferManager.GetComputeUniformBufferAddress(1) : Channel.BufferManager.GetGraphicsUniformBufferAddress(stageIndex, 1);
                if (address == MemoryManager.PteUnmapped || size == 0)
                {
                    data = default;
                    return false;
                }

                data = Channel.MemoryManager.Physical.GetSpan(address, size);
                return true;
            }
        }

        /// <summary>
        /// Gets transform feedback state from the current GPU state.
        /// </summary>
        /// <param name="state">Current GPU state</param>
        /// <returns>Four transform feedback descriptors for the enabled TFBs, or null if TFB is disabled</returns>
        private static TransformFeedbackDescriptor[] GetTransformFeedbackDescriptors(ref ThreedClassState state)
        {
            bool tfEnable = state.TfEnable;
            if (!tfEnable)
            {
                return null;
            }

            TransformFeedbackDescriptor[] descs = new TransformFeedbackDescriptor[Constants.TotalTransformFeedbackBuffers];

            Span<TfState> tfStateSpan = state.TfState.AsSpan();
            Span<Array32<uint>> tfVaryingLocationsSpan = state.TfVaryingLocations.AsSpan();
            
            for (int i = 0; i < Constants.TotalTransformFeedbackBuffers; i++)
            {
                TfState tf = tfStateSpan[i];

                descs[i] = new TransformFeedbackDescriptor(
                    tf.BufferIndex,
                    tf.Stride,
                    tf.VaryingsCount,
                    ref tfVaryingLocationsSpan[i]);
            }

            return descs;
        }

        /// <summary>
        /// Checks if compute shader code in memory is equal to the cached shader.
        /// </summary>
        /// <param name="channel">GPU channel using the shader</param>
        /// <param name="poolState">GPU channel state to verify shader compatibility</param>
        /// <param name="computeState">GPU channel compute state to verify shader compatibility</param>
        /// <param name="cpShader">Cached compute shader</param>
        /// <param name="gpuVa">GPU virtual address of the shader code in memory</param>
        /// <returns>True if the code is different, false otherwise</returns>
        private static bool IsShaderEqual(
            GpuChannel channel,
            GpuChannelPoolState poolState,
            GpuChannelComputeState computeState,
            CachedShaderProgram cpShader,
            ulong gpuVa)
        {
            if (IsShaderEqual(channel.MemoryManager, cpShader.Shaders[0], gpuVa))
            {
                return cpShader.SpecializationState.MatchesCompute(channel, ref poolState, computeState, true);
            }

            return false;
        }

        /// <summary>
        /// Checks if graphics shader code from all stages in memory are equal to the cached shaders.
        /// </summary>
        /// <param name="channel">GPU channel using the shader</param>
        /// <param name="poolState">GPU channel state to verify shader compatibility</param>
        /// <param name="graphicsState">GPU channel graphics state to verify shader compatibility</param>
        /// <param name="gpShaders">Cached graphics shaders</param>
        /// <param name="addresses">GPU virtual addresses of all enabled shader stages</param>
        /// <returns>True if the code is different, false otherwise</returns>
        private static bool IsShaderEqual(
            GpuChannel channel,
            ref GpuChannelPoolState poolState,
            ref GpuChannelGraphicsState graphicsState,
            CachedShaderProgram gpShaders,
            ShaderAddresses addresses)
        {
            ReadOnlySpan<ulong> addressesSpan = addresses.AsSpan();

            for (int stageIndex = 0; stageIndex < gpShaders.Shaders.Length; stageIndex++)
            {
                CachedShaderStage shader = gpShaders.Shaders[stageIndex];

                ulong gpuVa = addressesSpan[stageIndex];

                if (!IsShaderEqual(channel.MemoryManager, shader, gpuVa))
                {
                    return false;
                }
            }

            bool vertexAsCompute = gpShaders.VertexAsCompute != null;
            bool usesDrawParameters = gpShaders.Shaders[1]?.Info.UsesDrawParameters ?? false;

            return gpShaders.SpecializationState.MatchesGraphics(
                channel,
                ref poolState,
                ref graphicsState,
                vertexAsCompute,
                usesDrawParameters,
                checkTextures: true);
        }

        /// <summary>
        /// Checks if the code of the specified cached shader is different from the code in memory.
        /// </summary>
        /// <param name="memoryManager">Memory manager used to access the GPU memory where the shader is located</param>
        /// <param name="shader">Cached shader to compare with</param>
        /// <param name="gpuVa">GPU virtual address of the binary shader code</param>
        /// <returns>True if the code is different, false otherwise</returns>
        private static bool IsShaderEqual(MemoryManager memoryManager, CachedShaderStage shader, ulong gpuVa)
        {
            if (shader == null)
            {
                return true;
            }

            // S2A：代码区登记了跟踪句柄、自上次核对相等后没被写过（句柄不脏）、映射代数号也没变 → 内容必然相同，免逐字节比较（读整段代码）。
            // 旧库热机符号化 SequenceEqual 1.8%（每次切着色器、每个阶段一整段）；precise 双算 535 万次 0 不一致。
            // 比旧库多两处：先重新武装句柄再读内存比较（旧库比完才武装，中间被写会漏）；比较不等时记为无效，不拿来免比较。
            S2ACodeCheck chk;
            lock (_s2aCodeChecks)
            {
                _s2aCodeChecks.TryGetValue((shader, gpuVa, memoryManager), out chk);
            }

            int gen = Volatile.Read(ref memoryManager.S2AMapGen);

            if (chk != null && chk.Equal && chk.Gen == gen && !chk.Handle.Dirty)
            {
                return true;
            }

            if (chk == null)
            {
                MultiRange range = memoryManager.GetPhysicalRegions(gpuVa, (ulong)shader.Code.Length);
                if (!range.IsUnmapped)
                {
                    chk = new S2ACodeCheck { Handle = memoryManager.Physical.BeginTracking(range, ResourceKind.None) };
                    lock (_s2aCodeChecks)
                    {
                        _s2aCodeChecks[(shader, gpuVa, memoryManager)] = chk;
                    }
                }
            }

            chk?.Handle.Reprotect(); // S2A：清脏、重新武装，之后一写就标脏；必须在读内存之前

            ReadOnlySpan<byte> memoryCode = memoryManager.GetSpanMapped(gpuVa, shader.Code.Length);

            bool equal = memoryCode.SequenceEqual(shader.Code);

            if (chk != null)
            {
                chk.Equal = equal;
                chk.Gen = gen;
            }

            return equal;
        }

        /// <summary>
        /// S2A: 着色器代码区的跟踪句柄与上次核对结果。
        /// </summary>
        private sealed class S2ACodeCheck
        {
            public GpuRegionHandle Handle;
            public int Gen;
            public bool Equal;
        }

        private static readonly Dictionary<(CachedShaderStage, ulong, MemoryManager), S2ACodeCheck> _s2aCodeChecks = new();

        internal static void S2AResetSession()
        {
            lock (_s2aCodeChecks)
            {
                foreach (S2ACodeCheck check in _s2aCodeChecks.Values) check.Handle.Dispose();
                _s2aCodeChecks.Clear();
            }
            lock (_s2aMissCounts) _s2aMissCounts.Clear();
        }

        /// <summary>
        /// Decode the binary Maxwell shader code to a translator context.
        /// </summary>
        /// <param name="gpuAccessor">GPU state accessor</param>
        /// <param name="api">Graphics API that will be used with the shader</param>
        /// <param name="gpuVa">GPU virtual address of the binary shader code</param>
        /// <returns>The generated translator context</returns>
        public static TranslatorContext DecodeComputeShader(IGpuAccessor gpuAccessor, TargetApi api, ulong gpuVa)
        {
            TranslationOptions options = CreateTranslationOptions(gpuAccessor, api, DefaultFlags | TranslationFlags.Compute);
            return Translator.CreateContext(gpuVa, gpuAccessor, options);
        }

        /// <summary>
        /// Decode the binary Maxwell shader code to a translator context.
        /// </summary>
        /// <remarks>
        /// This will combine the "Vertex A" and "Vertex B" shader stages, if specified, into one shader.
        /// </remarks>
        /// <param name="gpuAccessor">GPU state accessor</param>
        /// <param name="api">Graphics API that will be used with the shader</param>
        /// <param name="flags">Flags that controls shader translation</param>
        /// <param name="gpuVa">GPU virtual address of the shader code</param>
        /// <returns>The generated translator context</returns>
        public static TranslatorContext DecodeGraphicsShader(IGpuAccessor gpuAccessor, TargetApi api, TranslationFlags flags, ulong gpuVa)
        {
            TranslationOptions options = CreateTranslationOptions(gpuAccessor, api, flags);
            return Translator.CreateContext(gpuVa, gpuAccessor, options);
        }

        /// <summary>
        /// Translates a previously generated translator context to something that the host API accepts.
        /// </summary>
        /// <param name="dumper">Optional shader code dumper</param>
        /// <param name="channel">GPU channel using the shader</param>
        /// <param name="currentStage">Translator context of the stage to be translated</param>
        /// <param name="vertexA">Optional translator context of the shader that should be combined</param>
        /// <param name="codeA">Optional Maxwell binary code of the Vertex A shader, if present</param>
        /// <param name="codeB">Optional Maxwell binary code of the Vertex B or current stage shader, if present on cache</param>
        /// <param name="asCompute">Indicates that the vertex shader should be converted to a compute shader</param>
        /// <returns>Compiled graphics shader code</returns>
        private static TranslatedShaderVertexPair TranslateShader(
            ShaderDumper dumper,
            GpuChannel channel,
            TranslatorContext currentStage,
            TranslatorContext vertexA,
            byte[] codeA,
            byte[] codeB,
            bool asCompute)
        {
            ulong cb1DataAddress = channel.BufferManager.GetGraphicsUniformBufferAddress(0, 1);

            MemoryManager memoryManager = channel.MemoryManager;

            codeA ??= memoryManager.GetSpan(vertexA.Address, vertexA.Size).ToArray();
            codeB ??= memoryManager.GetSpan(currentStage.Address, currentStage.Size).ToArray();
            byte[] cb1DataA = ReadArray(memoryManager, cb1DataAddress, vertexA.Cb1DataSize);
            byte[] cb1DataB = ReadArray(memoryManager, cb1DataAddress, currentStage.Cb1DataSize);

            ShaderDumpPaths pathsA = default;
            ShaderDumpPaths pathsB = default;

            if (dumper != null)
            {
                pathsA = dumper.Dump(codeA, compute: false);
                pathsB = dumper.Dump(codeB, compute: false);
            }

            ShaderProgram program = currentStage.Translate(vertexA, asCompute);

            pathsB.Prepend(program);
            pathsA.Prepend(program);

            CachedShaderStage vertexAStage = new(null, codeA, cb1DataA);
            CachedShaderStage vertexBStage = new(program.Info, codeB, cb1DataB);

            return new TranslatedShaderVertexPair(vertexAStage, vertexBStage, program);
        }

        /// <summary>
        /// Translates a previously generated translator context to something that the host API accepts.
        /// </summary>
        /// <param name="dumper">Optional shader code dumper</param>
        /// <param name="channel">GPU channel using the shader</param>
        /// <param name="context">Translator context of the stage to be translated</param>
        /// <param name="code">Optional Maxwell binary code of the current stage shader, if present on cache</param>
        /// <param name="asCompute">Indicates that the vertex shader should be converted to a compute shader</param>
        /// <returns>Compiled graphics shader code</returns>
        private static TranslatedShader TranslateShader(ShaderDumper dumper, GpuChannel channel, TranslatorContext context, byte[] code, bool asCompute)
        {
            MemoryManager memoryManager = channel.MemoryManager;

            ulong cb1DataAddress = context.Stage == ShaderStage.Compute
                ? channel.BufferManager.GetComputeUniformBufferAddress(1)
                : channel.BufferManager.GetGraphicsUniformBufferAddress(StageToStageIndex(context.Stage), 1);

            byte[] cb1Data = ReadArray(memoryManager, cb1DataAddress, context.Cb1DataSize);
            code ??= memoryManager.GetSpan(context.Address, context.Size).ToArray();

            ShaderDumpPaths paths = dumper?.Dump(code, context.Stage == ShaderStage.Compute) ?? default;
            ShaderProgram program = context.Translate(asCompute);

            paths.Prepend(program);

            return new TranslatedShader(new CachedShaderStage(program.Info, code, cb1Data), program);
        }

        /// <summary>
        /// Reads data from physical memory, returns an empty array if the memory is unmapped or size is 0.
        /// </summary>
        /// <param name="memoryManager">Memory manager with the physical memory to read from</param>
        /// <param name="address">Physical address of the region to read</param>
        /// <param name="size">Size in bytes of the data</param>
        /// <returns>An array with the data at the specified memory location</returns>
        private static byte[] ReadArray(MemoryManager memoryManager, ulong address, int size)
        {
            if (address == MemoryManager.PteUnmapped || size == 0)
            {
                return Array.Empty<byte>();
            }

            return memoryManager.Physical.GetSpan(address, size).ToArray();
        }

        /// <summary>
        /// Gets the index of a stage from a <see cref="ShaderStage"/>.
        /// </summary>
        /// <param name="stage">Stage to get the index from</param>
        /// <returns>Stage index</returns>
        private static int StageToStageIndex(ShaderStage stage)
        {
            return stage switch
            {
                ShaderStage.TessellationControl => 1,
                ShaderStage.TessellationEvaluation => 2,
                ShaderStage.Geometry => 3,
                ShaderStage.Fragment => 4,
                _ => 0,
            };
        }

        /// <summary>
        /// Creates shader translation options with the requested graphics API and flags.
        /// The shader language is choosen based on the current configuration and graphics API.
        /// </summary>
        /// <param name="api">Target graphics API</param>
        /// <param name="flags">Translation flags</param>
        /// <returns>Translation options</returns>
        private static TranslationOptions CreateTranslationOptions(IGpuAccessor gpuAccessor, TargetApi api, TranslationFlags flags)
        {
            ComputeTranslationProfile selected = (gpuAccessor as IComputeTranslationProfileProvider)?.ComputeTranslationProfile;
            if (selected != null)
            {
                if (api != TargetApi.Vulkan) throw new InvalidOperationException("A Vulkan compute profile cannot select another API.");
                return selected.Options(flags);
            }

            TargetLanguage lang = GraphicsConfig.EnableSpirvCompilationOnVulkan && api == TargetApi.Vulkan
                ? TargetLanguage.Spirv
                : TargetLanguage.Glsl;

            return new TranslationOptions(lang, api, flags);
        }

        /// <summary>
        /// Disposes the shader cache, deleting all the cached shaders.
        /// It's an error to use the shader cache after disposal.
        /// </summary>
        public void Dispose()
        {
            _diskCacheHostStorage?.S2AStopWarm();
            // The stopped GPU producer can leave ready/compiling programs in
            // its save queue. Let the live encoder finish them before closing
            // the writer; no new producer may enter during this stage.
            long saveDeadline = Environment.TickCount64 + 10000;
            while (_programsToSaveQueue.Count != 0)
            {
                int remaining = (int)Math.Max(0, saveDeadline - Environment.TickCount64);
                if (remaining == 0) throw new TimeoutException("待保存的着色器编译未完成；保留程序和缓存句柄");
                if (_context.Renderer is Ryujinx.Graphics.GAL.Multithreading.ThreadedRenderer threaded)
                    threaded.S2AAdvanceProgramsForShutdown(remaining);
                ProcessShaderCacheQueue();
                if (_programsToSaveQueue.Count != 0) System.Threading.Thread.Sleep(1);
            }
            // Writer tasks still inspect CachedShaderProgram and guest code.
            // Finish them before disposing either program or lazy file owners.
            _cacheWriter?.Dispose();
            _s2aFaults.Dispose();
            foreach (CachedShaderProgram program in _graphicsShaderCache.GetPrograms())
            {
                program.Dispose();
            }

            foreach (CachedShaderProgram program in _computeShaderCache.GetPrograms())
            {
                program.Dispose();
            }

            _diskCacheHostStorage?.S2ACloseSession();
        }
    }
}
