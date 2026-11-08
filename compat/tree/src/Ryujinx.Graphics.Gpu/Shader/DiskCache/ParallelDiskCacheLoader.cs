using Ryujinx.Common;
using Ryujinx.Common.Logging;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Shader;
using Ryujinx.Graphics.Shader.Translation;
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using static Ryujinx.Graphics.Gpu.Shader.ShaderCache;

namespace Ryujinx.Graphics.Gpu.Shader.DiskCache
{
    class ParallelDiskCacheLoader
    {
        private const int ThreadCount = 8;

        private readonly GpuContext _context;
        private readonly ShaderCacheHashTable _graphicsCache;
        private readonly ComputeShaderCacheHashTable _computeCache;
        private readonly DiskCacheHostStorage _hostStorage;
        private readonly CancellationToken _cancellationToken;
        private readonly Action<ShaderCacheState, int, int> _stateChangeCallback;

        /// <summary>
        /// Indicates if the cache should be loaded.
        /// </summary>
        public bool Active => !_cancellationToken.IsCancellationRequested;

        private bool _needsHostRegen;

        /// <summary>
        /// Number of shaders that failed to compile from the cache.
        /// </summary>
        public int ErrorCount { get; private set; }

        /// <summary>
        /// Program validation entry.
        /// </summary>
        private readonly struct ProgramEntry
        {
            /// <summary>
            /// Cached shader program.
            /// </summary>
            public readonly CachedShaderProgram CachedProgram;

            /// <summary>
            /// Optional binary code. If not null, it is used instead of the backend host binary.
            /// </summary>
            public readonly byte[] BinaryCode;

            /// <summary>
            /// Program index.
            /// </summary>
            public readonly int ProgramIndex;

            /// <summary>
            /// Indicates if the program is a compute shader.
            /// </summary>
            public readonly bool IsCompute;

            /// <summary>
            /// Indicates if the program is a host binary shader.
            /// </summary>
            public readonly bool IsBinary;

            /// <summary>
            /// Creates a new program validation entry.
            /// </summary>
            /// <param name="cachedProgram">Cached shader program</param>
            /// <param name="binaryCode">Optional binary code. If not null, it is used instead of the backend host binary</param>
            /// <param name="programIndex">Program index</param>
            /// <param name="isCompute">Indicates if the program is a compute shader</param>
            /// <param name="isBinary">Indicates if the program is a host binary shader</param>
            public ProgramEntry(
                CachedShaderProgram cachedProgram,
                byte[] binaryCode,
                int programIndex,
                bool isCompute,
                bool isBinary)
            {
                CachedProgram = cachedProgram;
                BinaryCode = binaryCode;
                ProgramIndex = programIndex;
                IsCompute = isCompute;
                IsBinary = isBinary;
            }
        }

        /// <summary>
        /// Translated shader compilation entry.
        /// </summary>
        private readonly struct ProgramCompilation
        {
            /// <summary>
            /// Translated shader stages.
            /// </summary>
            public readonly ShaderProgram[] TranslatedStages;

            /// <summary>
            /// Cached shaders.
            /// </summary>
            public readonly CachedShaderStage[] Shaders;

            /// <summary>
            /// Specialization state.
            /// </summary>
            public readonly ShaderSpecializationState SpecializationState;

            /// <summary>
            /// Program index.
            /// </summary>
            public readonly int ProgramIndex;

            /// <summary>
            /// Indicates if the program is a compute shader.
            /// </summary>
            public readonly bool IsCompute;

            /// <summary>
            /// S2A：顶点 / 几何转计算的程序（非空时按它建三个宿主程序，TranslatedStages 不用）。
            /// </summary>
            public readonly S2AVtg.Translation Vtg;

            /// <summary>
            /// Creates a new translated shader compilation entry.
            /// </summary>
            /// <param name="translatedStages">Translated shader stages</param>
            /// <param name="shaders">Cached shaders</param>
            /// <param name="specState">Specialization state</param>
            /// <param name="programIndex">Program index</param>
            /// <param name="isCompute">Indicates if the program is a compute shader</param>
            public ProgramCompilation(
                ShaderProgram[] translatedStages,
                CachedShaderStage[] shaders,
                ShaderSpecializationState specState,
                int programIndex,
                bool isCompute,
                S2AVtg.Translation vtg = null)
            {
                TranslatedStages = translatedStages;
                Shaders = shaders;
                SpecializationState = specState;
                ProgramIndex = programIndex;
                IsCompute = isCompute;
                Vtg = vtg;
            }
        }

        /// <summary>
        /// Program translation entry.
        /// </summary>
        private readonly struct AsyncProgramTranslation
        {
            /// <summary>
            /// Guest code for each active stage.
            /// </summary>
            public readonly GuestCodeAndCbData?[] GuestShaders;

            /// <summary>
            /// Specialization state.
            /// </summary>
            public readonly ShaderSpecializationState SpecializationState;

            /// <summary>
            /// Program index.
            /// </summary>
            public readonly int ProgramIndex;

            /// <summary>
            /// Indicates if the program is a compute shader.
            /// </summary>
            public readonly bool IsCompute;

            /// <summary>
            /// Creates a new program translation entry.
            /// </summary>
            /// <param name="guestShaders">Guest code for each active stage</param>
            /// <param name="specState">Specialization state</param>
            /// <param name="programIndex">Program index</param>
            /// <param name="isCompute">Indicates if the program is a compute shader</param>
            public AsyncProgramTranslation(
                GuestCodeAndCbData?[] guestShaders,
                ShaderSpecializationState specState,
                int programIndex,
                bool isCompute)
            {
                GuestShaders = guestShaders;
                SpecializationState = specState;
                ProgramIndex = programIndex;
                IsCompute = isCompute;
            }
        }

        private readonly Queue<ProgramEntry> _validationQueue;
        private readonly ConcurrentQueue<ProgramCompilation> _compilationQueue;
        private readonly BlockingCollection<AsyncProgramTranslation> _asyncTranslationQueue;
        private readonly SortedList<int, (CachedShaderProgram, byte[])> _programList;

        private readonly int _backendParallelCompileThreads;
        private int _compiledCount;
        private int _totalCount;

        // S2Arm: programs indexed by AddLazy (not in _programList)
        private int _lazyCount;

        /// <summary>Number of programs the disk cache loader actually indexed at boot.</summary>
        public int LoadedPrograms => _lazyCount;

        // S2Arm（#1411）：装载结局三态——读到并索引 / 版本不符整批作废 / 文件缺失。
        //   为 null = 装载没走到可判定处（magic / FormatVersion 损坏等抛异常被装载器接住），
        //   S2AShaderCacheGuard.ShouldReportPackZero 对 null 照样报「读到 0 支」红（#1546 复审：损坏不许静音）。
        internal enum S2ALoadOutcome { Missing, StaleVersion, Loaded }

        /// <summary>S2Arm（#1411）：本次装载的结局，由 DiskCacheHostStorage.LoadShaders 在三个判定点写入。</summary>
        internal S2ALoadOutcome? S2AOutcome { get; set; }

        /// <summary>S2Arm（#1411）：StaleVersion 结局作废的程序数（版本不符的 shared.toc 条目数）；其余结局为 0。</summary>
        internal int S2AVersionDiscarded { get; set; }

        /// <summary>
        /// Creates a new parallel disk cache loader.
        /// </summary>
        /// <param name="context">GPU context</param>
        /// <param name="graphicsCache">Graphics shader cache</param>
        /// <param name="computeCache">Compute shader cache</param>
        /// <param name="hostStorage">Disk cache host storage</param>
        /// <param name="stateChangeCallback">Function to be called when there is a state change, reporting state, compiled and total shaders count</param>
        /// <param name="cancellationToken">Cancellation token</param>
        public ParallelDiskCacheLoader(GpuContext context,
            ShaderCacheHashTable graphicsCache,
            ComputeShaderCacheHashTable computeCache,
            DiskCacheHostStorage hostStorage,
            Action<ShaderCacheState, int, int> stateChangeCallback,
            CancellationToken cancellationToken)
        {
            _context = context;
            _graphicsCache = graphicsCache;
            _computeCache = computeCache;
            _hostStorage = hostStorage;
            _stateChangeCallback = stateChangeCallback;
            _cancellationToken = cancellationToken;
            _validationQueue = new Queue<ProgramEntry>();
            _compilationQueue = new ConcurrentQueue<ProgramCompilation>();
            _asyncTranslationQueue = new BlockingCollection<AsyncProgramTranslation>(ThreadCount);
            _programList = new SortedList<int, (CachedShaderProgram, byte[])>();
            _backendParallelCompileThreads = Math.Min(Environment.ProcessorCount, 8); // Must be kept in sync with the backend code.
        }

        /// <summary>
        /// Loads all shaders from the cache.
        /// </summary>
        public void LoadShaders()
        {
            Thread[] workThreads = new Thread[ThreadCount];

            for (int index = 0; index < ThreadCount; index++)
            {
                workThreads[index] = new Thread(ProcessAsyncQueue)
                {
                    Name = $"GPU.AsyncTranslationThread.{index}",
                };
            }

            int programCount = _hostStorage.GetProgramCount();

            _compiledCount = 0;
            _totalCount = programCount;

            _stateChangeCallback(ShaderCacheState.Start, 0, programCount);

            Logger.Info?.Print(LogClass.Gpu, $"Loading {programCount} shaders from the cache...");

            for (int index = 0; index < ThreadCount; index++)
            {
                workThreads[index].Start(_cancellationToken);
            }

            try
            {
                _hostStorage.LoadShaders(_context, this);
            }
            catch (DiskCacheLoadException diskCacheLoadException)
            {
                Logger.Warning?.Print(LogClass.Gpu, $"Error loading the shader cache. {diskCacheLoadException.Message}");

                // If we can't even access the file, then we also can't rebuild.
                if (diskCacheLoadException.Result != DiskCacheLoadResult.NoAccess)
                {
                    _needsHostRegen = true;
                }
            }
            catch (InvalidDataException invalidDataException)
            {
                Logger.Warning?.Print(LogClass.Gpu, $"Error decompressing the shader cache file. {invalidDataException.Message}");
                _needsHostRegen = true;
            }
            catch (IOException ioException)
            {
                Logger.Warning?.Print(LogClass.Gpu, $"Error reading the shader cache file. {ioException.Message}");
                _needsHostRegen = true;
            }

            _asyncTranslationQueue.CompleteAdding();

            for (int index = 0; index < ThreadCount; index++)
            {
                workThreads[index].Join();
            }

            CheckCompilationBlocking();

            // S2Arm: lazily indexed programs are not in _programList; rebuilding the cache files from it would delete them
            if (_needsHostRegen && _lazyCount != 0)
            {
                Console.Error.WriteLine($"[gal] 【红】着色器磁盘缓存装载中出错、原本要整份重建；{_lazyCount} 个程序是按需索引的（不在内存里），重建会删掉它们，故不重建、保留现有缓存文件");
                _needsHostRegen = false;
            }

            if (_needsHostRegen && Active)
            {
                // Rebuild both shared and host cache files.
                // Rebuilding shared is required because the shader information returned by the translator
                // might have changed, and so we have to reconstruct the file with the new information.
                try
                {
                    _hostStorage.ClearSharedCache();
                    _hostStorage.ClearHostCache(_context);

                    if (_programList.Count != 0)
                    {
                        _stateChangeCallback(ShaderCacheState.Packaging, 0, _programList.Count);

                        Logger.Info?.Print(LogClass.Gpu, $"Rebuilding {_programList.Count} shaders...");

                        using DiskCacheOutputStreams streams = _hostStorage.GetOutputStreams(_context);

                        int packagedShaders = 0;
                        foreach (KeyValuePair<int, (CachedShaderProgram, byte[])> kv in _programList)
                        {
                            if (!Active)
                            {
                                break;
                            }

                            (CachedShaderProgram program, byte[] binaryCode) = kv.Value;

                            _hostStorage.AddShader(_context, program, binaryCode, streams);

                            _stateChangeCallback(ShaderCacheState.Packaging, ++packagedShaders, _programList.Count);
                        }

                        Logger.Info?.Print(LogClass.Gpu, $"Rebuilt {_programList.Count} shaders successfully.");
                    }
                    else
                    {
                        _hostStorage.ClearGuestCache();

                        Logger.Info?.Print(LogClass.Gpu, "Shader cache deleted due to corruption.");
                    }
                }
                catch (DiskCacheLoadException diskCacheLoadException)
                {
                    Logger.Warning?.Print(LogClass.Gpu, $"Error deleting the shader cache. {diskCacheLoadException.Message}");
                }
                catch (IOException ioException)
                {
                    Logger.Warning?.Print(LogClass.Gpu, $"Error deleting the shader cache file. {ioException.Message}");
                }
            }

            Logger.Info?.Print(LogClass.Gpu, "Shader cache loaded.");

            _stateChangeCallback(ShaderCacheState.Loaded, programCount, programCount);
        }

        /// <summary>
        /// S2Arm: indexes a cached program without materializing it (see <see cref="S2ALazyProgram"/>).
        /// </summary>
        /// <param name="program">Program indexed from the disk cache</param>
        public void AddLazy(S2ALazyProgram program)
        {
            if (program.IsCompute)
            {
                _computeCache.AddLazy(program);
            }
            else
            {
                _graphicsCache.AddLazy(program);
            }

            _lazyCount++;
            SignalCompiled();
        }

        /// <summary>
        /// Enqueues a host program for compilation.
        /// </summary>
        /// <param name="cachedProgram">Cached program</param>
        /// <param name="binaryCode">Host binary code</param>
        /// <param name="programIndex">Program index</param>
        /// <param name="isCompute">Indicates if the program is a compute shader</param>
        public void QueueHostProgram(CachedShaderProgram cachedProgram, byte[] binaryCode, int programIndex, bool isCompute)
        {
            EnqueueForValidation(new ProgramEntry(cachedProgram, binaryCode, programIndex, isCompute, isBinary: true));
        }

        /// <summary>
        /// Enqueues a guest program for compilation.
        /// </summary>
        /// <param name="guestShaders">Guest code for each active stage</param>
        /// <param name="specState">Specialization state</param>
        /// <param name="programIndex">Program index</param>
        /// <param name="isCompute">Indicates if the program is a compute shader</param>
        public void QueueGuestProgram(GuestCodeAndCbData?[] guestShaders, ShaderSpecializationState specState, int programIndex, bool isCompute)
        {
            try
            {
                AsyncProgramTranslation asyncTranslation = new(guestShaders, specState, programIndex, isCompute);
                _asyncTranslationQueue.Add(asyncTranslation, _cancellationToken);
            }
            catch (OperationCanceledException)
            {
            }
        }

        /// <summary>
        /// Check the state of programs that have already been compiled,
        /// and add to the cache if the compilation was successful.
        /// </summary>
        public void CheckCompilation()
        {
            ProcessCompilationQueue();

            // Process programs that already finished compiling.
            // If not yet compiled, do nothing. This avoids blocking to wait for shader compilation.
            while (_validationQueue.TryPeek(out ProgramEntry entry))
            {
                ProgramLinkStatus result = S2AVtg.CheckLink(entry.CachedProgram, false);

                if (result != ProgramLinkStatus.Incomplete)
                {
                    ProcessCompiledProgram(ref entry, result);
                    _validationQueue.Dequeue();
                }
                else
                {
                    break;
                }
            }
        }

        /// <summary>
        /// Waits until all programs finishes compiling, then adds the ones
        /// with successful compilation to the cache.
        /// </summary>
        private void CheckCompilationBlocking()
        {
            ProcessCompilationQueue();

            while (_validationQueue.TryDequeue(out ProgramEntry entry) && Active)
            {
                ProcessCompiledProgram(ref entry, S2AVtg.CheckLink(entry.CachedProgram, true), asyncCompile: false);
            }
        }

        /// <summary>
        /// Process a compiled program result.
        /// </summary>
        /// <param name="entry">Compiled program entry</param>
        /// <param name="result">Compilation result</param>
        /// <param name="asyncCompile">For failed host compilations, indicates if a guest compilation should be done asynchronously</param>
        private void ProcessCompiledProgram(ref ProgramEntry entry, ProgramLinkStatus result, bool asyncCompile = true)
        {
            if (result == ProgramLinkStatus.Success)
            {
                // S2A：来自磁盘缓存（含出包种入的包内条目）：首次命中时按运行时真值核对全部翻译读过的字段（ShaderCache.S2AVerify）
                entry.CachedProgram.SpecializationState.S2AMarkLoaded(entry.ProgramIndex);

                // Compilation successful, add to memory cache.
                if (entry.IsCompute)
                {
                    _computeCache.Add(entry.CachedProgram);
                }
                else
                {
                    _graphicsCache.Add(entry.CachedProgram);
                }

                if (!entry.IsBinary)
                {
                    _needsHostRegen = true;
                }

                // Fetch the binary code from the backend if it isn't already present.
                byte[] binaryCode = entry.BinaryCode ?? S2AVtg.GetBinary(entry.CachedProgram);   // S2A：转计算程序取复合二进制

                _programList.Add(entry.ProgramIndex, (entry.CachedProgram, binaryCode));
                SignalCompiled();
            }
            else if (entry.IsBinary)
            {
                // If this is a host binary and compilation failed,
                // we still have a chance to recompile from the guest binary.
                CachedShaderProgram program = entry.CachedProgram;

                GuestCodeAndCbData?[] guestShaders = new GuestCodeAndCbData?[program.Shaders.Length];

                for (int index = 0; index < program.Shaders.Length; index++)
                {
                    CachedShaderStage shader = program.Shaders[index];

                    if (shader != null)
                    {
                        guestShaders[index] = new GuestCodeAndCbData(shader.Code, shader.Cb1Data);
                    }
                }

                if (asyncCompile)
                {
                    QueueGuestProgram(guestShaders, program.SpecializationState, entry.ProgramIndex, entry.IsCompute);
                }
                else
                {
                    RecompileFromGuestCode(guestShaders, program.SpecializationState, entry.ProgramIndex, entry.IsCompute);
                    ProcessCompilationQueue();
                }
            }
            else
            {
                // Failed to compile from both host and guest binary.
                ErrorCount++;
                SignalCompiled();
            }
        }

        /// <summary>
        /// Processes the queue of translated guest programs that should be compiled on the host.
        /// </summary>
        private void ProcessCompilationQueue()
        {
            while (_compilationQueue.TryDequeue(out ProgramCompilation compilation) && Active)
            {
                if (compilation.Vtg != null)
                {
                    CachedShaderProgram vtgProgram = S2AVtg.CreatePrograms(_context, compilation.Vtg, compilation.SpecializationState, compilation.SpecializationState.PipelineState, fromCache: true);

                    EnqueueForValidation(new ProgramEntry(vtgProgram, null, compilation.ProgramIndex, isCompute: false, isBinary: false));

                    continue;
                }

                ShaderSource[] shaderSources = new ShaderSource[compilation.TranslatedStages.Length];

                ShaderInfoBuilder shaderInfoBuilder = new(_context, compilation.SpecializationState.TransformFeedbackDescriptors != null);

                for (int index = 0; index < compilation.TranslatedStages.Length; index++)
                {
                    ShaderProgram shader = compilation.TranslatedStages[index];
                    shaderSources[index] = CreateShaderSource(shader);
                    shaderInfoBuilder.AddStageInfo(shader.Info);
                }

                ShaderInfo shaderInfo = shaderInfoBuilder.Build(compilation.SpecializationState.PipelineState, fromCache: true);
                IProgram hostProgram = _context.Renderer.CreateProgram(shaderSources, shaderInfo);
                CachedShaderProgram program = new(hostProgram, compilation.SpecializationState, compilation.Shaders);

                // S2A：一律存渲染器程序二进制（编完后取），不存 SPIR-V 打包
                byte[] binaryCode = null;

                EnqueueForValidation(new ProgramEntry(program, binaryCode, compilation.ProgramIndex, compilation.IsCompute, isBinary: false));
            }
        }

        /// <summary>
        /// Enqueues a program for validation, which will check if the program was compiled successfully.
        /// </summary>
        /// <param name="newEntry">Program entry to be validated</param>
        private void EnqueueForValidation(ProgramEntry newEntry)
        {
            _validationQueue.Enqueue(newEntry);

            // Do not allow more than N shader compilation in-flight, where N is the maximum number of threads
            // the driver will be using for parallel compilation.
            // Submitting more seems to cause NVIDIA OpenGL driver to crash.
            if (_validationQueue.Count >= _backendParallelCompileThreads && _validationQueue.TryDequeue(out ProgramEntry entry))
            {
                ProcessCompiledProgram(ref entry, S2AVtg.CheckLink(entry.CachedProgram, true), asyncCompile: false);
            }
        }

        /// <summary>
        /// Processses the queue of programs that should be translated from guest code.
        /// </summary>
        /// <param name="state">Cancellation token</param>
        private void ProcessAsyncQueue(object state)
        {
            CancellationToken ct = (CancellationToken)state;

            try
            {
                foreach (AsyncProgramTranslation asyncCompilation in _asyncTranslationQueue.GetConsumingEnumerable(ct))
                {
                    RecompileFromGuestCode(
                        asyncCompilation.GuestShaders,
                        asyncCompilation.SpecializationState,
                        asyncCompilation.ProgramIndex,
                        asyncCompilation.IsCompute);
                }
            }
            catch (OperationCanceledException)
            {
            }
        }

        /// <summary>
        /// Recompiles a program from guest code.
        /// </summary>
        /// <param name="guestShaders">Guest code for each active stage</param>
        /// <param name="specState">Specialization state</param>
        /// <param name="programIndex">Program index</param>
        /// <param name="isCompute">Indicates if the program is a compute shader</param>
        private void RecompileFromGuestCode(GuestCodeAndCbData?[] guestShaders, ShaderSpecializationState specState, int programIndex, bool isCompute)
        {
            try
            {
                if (isCompute)
                {
                    RecompileComputeFromGuestCode(guestShaders, specState, programIndex);
                }
                else
                {
                    RecompileGraphicsFromGuestCode(guestShaders, specState, programIndex);
                }
            }
            catch (Exception exception)
            {
                Logger.Error?.Print(LogClass.Gpu, $"Error translating guest shader. {exception.Message}");

                ErrorCount++;
                SignalCompiled();
            }
        }

        /// <summary>
        /// Recompiles a graphics program from guest code.
        /// </summary>
        /// <param name="guestShaders">Guest code for each active stage</param>
        /// <param name="specState">Specialization state</param>
        /// <param name="programIndex">Program index</param>
        private void RecompileGraphicsFromGuestCode(GuestCodeAndCbData?[] guestShaders, ShaderSpecializationState specState, int programIndex)
        {
            ShaderSpecializationState newSpecState = new(
                ref specState.GraphicsState,
                specState.PipelineState,
                specState.TransformFeedbackDescriptors);

            ResourceCounts counts = new();

            DiskCacheGpuAccessor[] gpuAccessors = new DiskCacheGpuAccessor[Constants.ShaderStages];
            TranslatorContext[] translatorContexts = new TranslatorContext[Constants.ShaderStages + 1];
            TranslatorContext nextStage = null;

            TargetApi api = GpuAccessorBase.S2ATranslationCapabilities(_context).Api;

            bool hasCachedGs = guestShaders[4].HasValue;

            for (int stageIndex = Constants.ShaderStages - 1; stageIndex >= 0; stageIndex--)
            {
                if (guestShaders[stageIndex + 1].HasValue)
                {
                    GuestCodeAndCbData shader = guestShaders[stageIndex + 1].Value;

                    byte[] guestCode = shader.Code;
                    byte[] cb1Data = shader.Cb1Data;

                    DiskCacheGpuAccessor gpuAccessor = new(_context, guestCode, cb1Data, specState, newSpecState, counts, stageIndex, hasCachedGs);
                    TranslatorContext currentStage = DecodeGraphicsShader(gpuAccessor, api, DefaultFlags, 0);

                    if (nextStage != null)
                    {
                        currentStage.SetNextStage(nextStage);
                    }

                    if (stageIndex == 0 && guestShaders[0].HasValue)
                    {
                        byte[] guestCodeA = guestShaders[0].Value.Code;
                        byte[] cb1DataA = guestShaders[0].Value.Cb1Data;

                        DiskCacheGpuAccessor gpuAccessorA = new(_context, guestCodeA, cb1DataA, specState, newSpecState, counts, 0, hasCachedGs);
                        translatorContexts[0] = DecodeGraphicsShader(gpuAccessorA, api, DefaultFlags | TranslationFlags.VertexA, 0);
                    }

                    gpuAccessors[stageIndex] = gpuAccessor;
                    translatorContexts[stageIndex + 1] = currentStage;
                    nextStage = currentStage;
                }
            }

            bool hasGeometryShader = translatorContexts[4] != null;
            bool vertexHasStore = translatorContexts[1] != null && translatorContexts[1].HasStore;
            bool geometryHasStore = hasGeometryShader && translatorContexts[4].HasStore;
            bool vertexToCompute = ShouldConvertVertexToCompute(_context, vertexHasStore, geometryHasStore, hasGeometryShader);

            // S2A：转计算的程序照 GetGraphicsShader 同一路径翻译（S2AVtg），建三个宿主程序；上游在这里把它们丢掉
            if (vertexToCompute)
            {
                S2AVtg.Translation vtg = S2AVtg.Translate(_context, translatorContexts, gpuAccessors, guestShaders, specState.TransformFeedbackDescriptors != null);

                _compilationQueue.Enqueue(new ProgramCompilation(null, vtg.Shaders, newSpecState, programIndex, isCompute: false, vtg));

                return;
            }

            CachedShaderStage[] shaders = new CachedShaderStage[guestShaders.Length];
            List<ShaderProgram> translatedStages = [];

            TranslatorContext previousStage = null;

            for (int stageIndex = 0; stageIndex < Constants.ShaderStages; stageIndex++)
            {
                TranslatorContext currentStage = translatorContexts[stageIndex + 1];

                if (currentStage != null)
                {
                    gpuAccessors[stageIndex].InitializeReservedCounts(specState.TransformFeedbackDescriptors != null, vertexToCompute);

                    ShaderProgram program;

                    byte[] guestCode = guestShaders[stageIndex + 1].Value.Code;
                    byte[] cb1Data = guestShaders[stageIndex + 1].Value.Cb1Data;

                    if (stageIndex == 0 && guestShaders[0].HasValue)
                    {
                        program = currentStage.Translate(translatorContexts[0]);

                        byte[] guestCodeA = guestShaders[0].Value.Code;
                        byte[] cb1DataA = guestShaders[0].Value.Cb1Data;

                        shaders[0] = new CachedShaderStage(null, guestCodeA, cb1DataA);
                        shaders[1] = new CachedShaderStage(program.Info, guestCode, cb1Data);
                    }
                    else
                    {
                        program = currentStage.Translate();

                        shaders[stageIndex + 1] = new CachedShaderStage(program.Info, guestCode, cb1Data);
                    }

                    if (program != null)
                    {
                        translatedStages.Add(program);
                    }

                    previousStage = currentStage;
                }
                else
                {
                    switch (S2ALayerRouteFor(_context, previousStage, stageIndex))
                    {
                        case S2ALayerRoute.GeometryPassthrough:
                            S2AGsDiag.NotePassthrough("DiskCacheLoader");   // #1456：追加点来源
                            translatedStages.Add(previousStage.GenerateGeometryPassthrough());
                            break;
                        case S2ALayerRoute.Unsupported:
                            S2ARejectLayerRoute();
                            break;
                    }
                }
            }

            _compilationQueue.Enqueue(new ProgramCompilation(translatedStages.ToArray(), shaders, newSpecState, programIndex, isCompute: false));
        }

        /// <summary>
        /// Recompiles a compute program from guest code.
        /// </summary>
        /// <param name="guestShaders">Guest code for each active stage</param>
        /// <param name="specState">Specialization state</param>
        /// <param name="programIndex">Program index</param>
        private void RecompileComputeFromGuestCode(GuestCodeAndCbData?[] guestShaders, ShaderSpecializationState specState, int programIndex)
        {
            GuestCodeAndCbData shader = guestShaders[0].Value;
            ResourceCounts counts = new();
            ShaderSpecializationState newSpecState = new(ref specState.ComputeState);
            DiskCacheGpuAccessor gpuAccessor = new(_context, shader.Code, shader.Cb1Data, specState, newSpecState, counts, 0, false);
            gpuAccessor.InitializeReservedCounts(tfEnabled: false, vertexAsCompute: false);

            TranslatorContext translatorContext = DecodeComputeShader(gpuAccessor, GpuAccessorBase.S2ATranslationCapabilities(_context).Api, 0);

            ShaderProgram program = translatorContext.Translate();

            CachedShaderStage[] shaders = [new(program.Info, shader.Code, shader.Cb1Data)];

            _compilationQueue.Enqueue(new ProgramCompilation([program], shaders, newSpecState, programIndex, isCompute: true));
        }

        /// <summary>
        /// Signals that compilation of a program has been finished successfully,
        /// or that it failed and guest recompilation has also been attempted.
        /// </summary>
        private void SignalCompiled()
        {
            _stateChangeCallback(ShaderCacheState.Loading, ++_compiledCount, _totalCount);
        }
    }
}
