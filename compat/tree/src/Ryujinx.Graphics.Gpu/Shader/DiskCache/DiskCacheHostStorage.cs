using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Shader;
using Ryujinx.Graphics.Shader.Translation;
using System;
using System.Collections.Generic;
using System.IO;
using System.Numerics;
using System.Runtime.CompilerServices;

namespace Ryujinx.Graphics.Gpu.Shader.DiskCache
{
    /// <summary>
    /// On-disk shader cache storage for host code.
    /// </summary>
    class DiskCacheHostStorage
    {
        private const uint TocsMagic = (byte)'T' | ((byte)'O' << 8) | ((byte)'C' << 16) | ((byte)'S' << 24);
        private const uint TochMagic = (byte)'T' | ((byte)'O' << 8) | ((byte)'C' << 16) | ((byte)'H' << 24);
        private const uint ShdiMagic = (byte)'S' | ((byte)'H' << 8) | ((byte)'D' << 16) | ((byte)'I' << 24);
        private const uint BufdMagic = (byte)'B' | ((byte)'U' << 8) | ((byte)'F' << 16) | ((byte)'D' << 24);
        private const uint TexdMagic = (byte)'T' | ((byte)'E' << 8) | ((byte)'X' << 16) | ((byte)'D' << 24);

        private const ushort FileFormatVersionMajor = 1;
        private const ushort FileFormatVersionMinor = 2;
        private const uint FileFormatVersionPacked = ((uint)FileFormatVersionMajor << 16) | FileFormatVersionMinor;
        // S2A：特化状态运行时化改了翻译结果，旧磁盘缓存整份作废（+1 DepthMode / 绘制参数，+2 透明测试，+3 支持缓冲加 s2a_widen，
        //   +4（10-21 画面着色器线合批一次升）：点大小运行时化（支持缓冲在 s2a_widen 前加 s2a_point）+ 转计算程序进缓存（阶段掩码口径改、复合宿主二进制））
        //   +5（10-21 画面·着色器线）：顶点输入按原始位读（宿主顶点自取，翻译结果不随属性类型变，补丁 vattr-raw）
        // Invalidate host programs emitted before explicit SSBO permissions and linked Vulkan interfaces.
        // This is compiler identity, independent of package source keys and device capability identity.
        // +8: SupportBuffer's unconditional shader declaration grows to 3776 bytes
        // with ABI2 member 12. Re-translate old host binaries rather than assuming
        // that every backend treats the added uniform-block member as compatible.
        // +9: VTG texel-buffer image declarations now use the sampler's declared
        // sampled type instead of unconditional FP32; host binaries translated
        // with the old declaration must be re-translated.
        // +10: SPIR-V output changes (gl_PerVertex no longer declares gl_CullDistance) and
        // the support-buffer descriptor stage mask now covers VTG. Old host caches must be
        // re-translated; offline shader packages baked with the old codegen must be re-baked.
        // +11: Guest texel-buffer declarations and reads follow the bound view's
        // numeric type rather than float (VUID-07753); float-declared caches must
        // be re-translated.
        // +12: Storage texel-buffer image format is decoupled from numeric type
        // (VUID-08737); caches with the coupled declaration must be re-translated.
        internal const uint CodeGenVersion = 7354 + 12;

        private const string SharedTocFileName = "shared.toc";
        private const string SharedDataFileName = "shared.data";

        private readonly string _basePath;
        private static bool _s2aHostPathLogged;
        private static int _s2aHostWrites;
        private System.Threading.Thread _s2aWarmThread;
        private volatile bool _s2aWarmStop;

        internal void S2AStopWarm()
        {
            _s2aWarmStop = true;
            if (_s2aWarmThread != null && !_s2aWarmThread.Join(3000))
                throw new TimeoutException("着色器预热线程未停止；仍持有旧渲染器");
            _s2aWarmThread = null;
            lock (_lazyLock) _s2aPre.Clear();
        }

        // After warm and writer threads have joined and shader programs were
        // disposed, no lazy materialization can read these session handles.
        internal void S2ACloseSession()
        {
            lock (_lazyLock)
            {
                _lazySharedData?.Dispose(); _lazySharedData = null;
                _lazyHostToc?.Dispose(); _lazyHostToc = null;
                _lazyHostData?.Dispose(); _lazyHostData = null;
                _s2aGuest = null;
                _s2aPre.Clear();
            }
            lock (_s2aPendingLink) _s2aPendingLink.Clear();
        }

        public bool CacheEnabled => !string.IsNullOrEmpty(_basePath);

        /// <summary>
        /// TOC (Table of contents) file header.
        /// </summary>
        private struct TocHeader
        {
            /// <summary>
            /// Magic value, for validation and identification.
            /// </summary>
            public uint Magic;

            /// <summary>
            /// File format version.
            /// </summary>
            public uint FormatVersion;

            /// <summary>
            /// Generated shader code version.
            /// </summary>
            public uint CodeGenVersion;

            /// <summary>
            /// Header padding.
            /// </summary>
            public uint Padding;

            /// <summary>
            /// Timestamp of when the file was first created.
            /// </summary>
            public ulong Timestamp;

            /// <summary>
            /// Reserved space, to be used in the future. Write as zero.
            /// </summary>
            public ulong Reserved;
        }

        internal static uint S2AReadCodeGenVersion(string directory)
        {
            using FileStream stream = File.OpenRead(Path.Combine(directory, SharedTocFileName));
            BinarySerializer reader = new(stream);
            TocHeader header = new();
            if (!reader.TryRead(ref header) || header.Magic != TocsMagic || header.FormatVersion != FileFormatVersionPacked)
            {
                throw new InvalidDataException($"着色器缓存目录表格式无效：{directory}");
            }
            return header.CodeGenVersion;
        }

        /// <summary>
        /// Offset and size pair.
        /// </summary>
        private struct OffsetAndSize
        {
            /// <summary>
            /// Offset.
            /// </summary>
            public ulong Offset;

            /// <summary>
            /// Size of uncompressed data.
            /// </summary>
            public uint UncompressedSize;

            /// <summary>
            /// Size of compressed data.
            /// </summary>
            public uint CompressedSize;
        }

        /// <summary>
        /// Per-stage data entry.
        /// </summary>
        private struct DataEntryPerStage
        {
            /// <summary>
            /// Index of the guest code on the guest code cache TOC file.
            /// </summary>
            public int GuestCodeIndex;
        }

        /// <summary>
        /// Per-program data entry.
        /// </summary>
        private struct DataEntry
        {
            /// <summary>
            /// Bit mask where each bit set is a used shader stage. Should be zero for compute shaders.
            /// </summary>
            public uint StagesBitMask;
        }

        /// <summary>
        /// Per-stage shader information, returned by the translator.
        /// </summary>
        private struct DataShaderInfo
        {
            /// <summary>
            /// Total constant buffers used.
            /// </summary>
            public ushort CBuffersCount;

            /// <summary>
            /// Total storage buffers used.
            /// </summary>
            public ushort SBuffersCount;

            /// <summary>
            /// Total textures used.
            /// </summary>
            public ushort TexturesCount;

            /// <summary>
            /// Total images used.
            /// </summary>
            public ushort ImagesCount;

            /// <summary>
            /// Shader stage.
            /// </summary>
            public ShaderStage Stage;

            /// <summary>
            /// Number of vertices that each output primitive has on a geometry shader.
            /// </summary>
            public byte GeometryVerticesPerPrimitive;

            /// <summary>
            /// Maximum number of vertices that a geometry shader may generate.
            /// </summary>
            public ushort GeometryMaxOutputVertices;

            /// <summary>
            /// Number of invocations per primitive on tessellation or geometry shaders.
            /// </summary>
            public ushort ThreadsPerInputPrimitive;

            /// <summary>
            /// Indicates if the fragment shader accesses the fragment coordinate built-in variable.
            /// </summary>
            public bool UsesFragCoord;

            /// <summary>
            /// Indicates if the shader accesses the Instance ID built-in variable.
            /// </summary>
            public bool UsesInstanceId;

            /// <summary>
            /// Indicates if the shader modifies the Layer built-in variable.
            /// </summary>
            public bool UsesRtLayer;

            /// <summary>
            /// Bit mask with the clip distances written on the vertex stage.
            /// </summary>
            public byte ClipDistancesWritten;

            /// <summary>
            /// Bit mask of the render target components written by the fragment stage.
            /// </summary>
            public int FragmentOutputMap;

            /// <summary>
            /// Indicates if the vertex shader accesses draw parameters.
            /// </summary>
            public bool UsesDrawParameters;
        }

        private readonly DiskCacheGuestStorage _guestStorage;

        /// <summary>
        /// Creates a disk cache host storage.
        /// </summary>
        /// <param name="basePath">Base path of the shader cache</param>
        public DiskCacheHostStorage(string basePath)
        {
            _basePath = string.IsNullOrEmpty(basePath) ? basePath : Path.GetFullPath(basePath);
            _guestStorage = new DiskCacheGuestStorage(_basePath);

            if (CacheEnabled)
            {
                Directory.CreateDirectory(_basePath);
            }
        }

        /// <summary>
        /// Gets the total of host programs on the cache.
        /// </summary>
        /// <returns>Host programs count</returns>
        public int GetProgramCount()
        {
            string tocFilePath = Path.Combine(_basePath, SharedTocFileName);

            if (!File.Exists(tocFilePath))
            {
                return 0;
            }

            return Math.Max((int)((new FileInfo(tocFilePath).Length - Unsafe.SizeOf<TocHeader>()) / sizeof(ulong)), 0);
        }

        /// <summary>
        /// Guest the name of the host program cache file, with extension.
        /// </summary>
        /// <param name="context">GPU context</param>
        /// <returns>Name of the file, without extension</returns>
        private static string GetHostFileName(GpuContext context)
        {
            Capabilities capabilities = GpuAccessorBase.S2ATranslationCapabilities(context);
            string apiName = capabilities.Api.ToString().ToLowerInvariant();
            string vendorName = RemoveInvalidCharacters(capabilities.VendorName.ToLowerInvariant());
            // Legacy host files have no effective-capability identity and are deliberately not
            // trusted. Guest/shared records remain usable for on-demand translation. The same
            // identity is used by ShBake and runtime (including NxGal, which reports Vulkan).
            string name = $"{apiName}_{vendorName}_bin_{HostCacheCapabilities.GetIdentity(capabilities, GpuAccessorBase.S2AProfileProvider(context)?.ComputeTranslationProfile)}";
            string discriminator = GetHostCacheDiscriminator(context);
            return string.IsNullOrEmpty(discriminator) ? name : $"{name}_{discriminator}";
        }

        private static string GetHostCacheDiscriminator(GpuContext context)
        {
            if (!string.IsNullOrEmpty(context.S2AHostProgramCacheDiscriminator))
            {
                return context.S2AHostProgramCacheDiscriminator;
            }

            IRenderer renderer = context.Renderer is Ryujinx.Graphics.GAL.Multithreading.ThreadedRenderer t ? t.BaseRenderer : context.Renderer;
            return renderer is IHostProgramCachePolicy policy ? policy.HostProgramCacheDiscriminator : null;
        }

        /// <summary>
        /// Removes invalid path characters and spaces from a file name.
        /// </summary>
        /// <param name="fileName">File name</param>
        /// <returns>Filtered file name</returns>
        private static string RemoveInvalidCharacters(string fileName)
        {
            int indexOfSpace = fileName.IndexOf(' ');
            if (indexOfSpace >= 0)
            {
                fileName = fileName[..indexOfSpace];
            }

            return string.Concat(fileName.Split(Path.GetInvalidFileNameChars(), StringSplitOptions.RemoveEmptyEntries));
        }

        /// <summary>
        /// Gets the name of the TOC host file.
        /// </summary>
        /// <param name="context">GPU context</param>
        /// <returns>File name</returns>
        private static string GetHostTocFileName(GpuContext context)
        {
            return GetHostFileName(context) + ".toc";
        }

        /// <summary>
        /// Gets the name of the data host file.
        /// </summary>
        /// <param name="context">GPU context</param>
        /// <returns>File name</returns>
        private static string GetHostDataFileName(GpuContext context)
        {
            return GetHostFileName(context) + ".data";
        }

        /// <summary>
        /// Checks if a disk cache exists for the current application.
        /// </summary>
        /// <returns>True if a disk cache exists, false otherwise</returns>
        public bool CacheExists()
        {
            string tocFilePath = Path.Combine(_basePath, SharedTocFileName);
            string dataFilePath = Path.Combine(_basePath, SharedDataFileName);

            if (!File.Exists(tocFilePath) || !File.Exists(dataFilePath) || !_guestStorage.TocFileExists() || !_guestStorage.DataFileExists())
            {
                return false;
            }

            return true;
        }

        /// <summary>
        /// Loads all shaders from the cache.
        /// </summary>
        /// <param name="context">GPU context</param>
        /// <param name="loader">Parallel disk cache loader</param>
        public void LoadShaders(GpuContext context, ParallelDiskCacheLoader loader)
        {
            if (!CacheExists())
            {
                // S2A（#1411）：缓存文件缺失 = 真没读到（包布局与 cache root 不一致的红由 ShaderCache 按 ShouldReportPackZero 报）
                loader.S2AOutcome = ParallelDiskCacheLoader.S2ALoadOutcome.Missing;
                return;
            }

            Stream hostTocFileStream = null;
            Stream hostDataFileStream = null;
            bool discardAll = false;
            System.Collections.Generic.Dictionary<int, int> warm = null;   // S2A：提前热程序号 → 表内次序
            S2ALazyProgram[] warmLazy = null;
            System.Collections.Generic.Dictionary<string, System.Collections.Generic.List<S2ALazyProgram>> s2aGroups = null;   // S2A：客体代码组（各阶段客体代码号）→ 组内程序，提前热整组预读用
            System.Collections.Generic.Dictionary<S2ALazyProgram, string> s2aGroupOf = null;

            try
            {
                using FileStream tocFileStream = DiskCacheCommon.OpenFile(_basePath, SharedTocFileName, writable: false);
                using FileStream dataFileStream = DiskCacheCommon.OpenFile(_basePath, SharedDataFileName, writable: false);

                using Stream guestTocFileStream = _guestStorage.OpenTocFileStream();
                using Stream guestDataFileStream = _guestStorage.OpenDataFileStream();

                BinarySerializer tocReader = new(tocFileStream);
                BinarySerializer dataReader = new(dataFileStream);

                TocHeader header = new();

                if (!tocReader.TryRead(ref header) || header.Magic != TocsMagic)
                {
                    throw new DiskCacheLoadException(DiskCacheLoadResult.FileCorruptedGeneric);
                }

                if (header.FormatVersion != FileFormatVersionPacked)
                {
                    throw new DiskCacheLoadException(DiskCacheLoadResult.IncompatibleVersion);
                }

                bool loadHostCache = header.CodeGenVersion == CodeGenVersion;

                // S2A（#1411）：装载结局在版本判定点定案——读到且版本匹配 = 已加载；读到但版本不符 = 整批作废（不是漏读）
                loader.S2AOutcome = loadHostCache
                    ? ParallelDiskCacheLoader.S2ALoadOutcome.Loaded
                    : ParallelDiskCacheLoader.S2ALoadOutcome.StaleVersion;

                // S2Arm: a cache written by another translator version would be recompiled program by program before the
                // first frame; drop the whole cache instead (deleted below, after the streams are closed)
                if (!loadHostCache)
                {
                    // S2A（#1411）：作废数单独计；红字写明两边版本号与宿主能力身份，一眼分清是没读到还是包旧了
                    int stale = GetProgramCount();
                    loader.S2AVersionDiscarded = stale;
                    S2AShaderCacheGuard.Report(stale, $"缓存的翻译器版本 {header.CodeGenVersion} ≠ 当前 {CodeGenVersion}；" +
                        $"宿主能力身份 本机 {GetHostFileName(context)} / 缓存 {S2AHostIdentities()}");
                    discardAll = true;
                }

                int programIndex = 0;

                // S2A：提前热程序表（S2AShaderCacheGuard.WarmList）里的包内程序，登记时记下，载完后后台先载一次（S2AWarmStart）
                if (loadHostCache && S2AShaderCacheGuard.WarmList != null)
                {
                    warm = S2AWarmRead(S2AShaderCacheGuard.WarmList);
                    warmLazy = warm == null ? null : new S2ALazyProgram[warm.Count];
                    if (warm != null) { s2aGroups = new(); s2aGroupOf = new(); }
                    S2AWarmIndices = warm == null ? null : new HashSet<int>(warm.Keys);
                }
                else
                {
                    S2AWarmIndices = null;
                }

                DataEntry entry = new();

                while (!discardAll && tocFileStream.Position < tocFileStream.Length && loader.Active)
                {
                    ulong dataOffset = 0;
                    tocReader.Read(ref dataOffset);

                    if ((ulong)dataOffset >= (ulong)dataFileStream.Length)
                    {
                        throw new DiskCacheLoadException(DiskCacheLoadResult.FileCorruptedGeneric);
                    }

                    dataFileStream.Seek((long)dataOffset, SeekOrigin.Begin);

                    dataReader.BeginCompression();
                    dataReader.Read(ref entry);
                    uint stagesBitMask = entry.StagesBitMask;

                    if ((stagesBitMask & ~0x3fu) != 0)
                    {
                        throw new DiskCacheLoadException(DiskCacheLoadResult.FileCorruptedGeneric);
                    }

                    bool isCompute = stagesBitMask == 0;
                    if (isCompute)
                    {
                        stagesBitMask = 1;
                    }

                    GuestCodeAndCbData?[] guestShaders = new GuestCodeAndCbData?[isCompute ? 1 : Constants.ShaderStages + 1];
                    S2AStageIndices s2aStages = S2AStageIndices.None;

                    DataEntryPerStage stageEntry = new();
                    System.Text.StringBuilder s2aKey = s2aGroups != null ? new System.Text.StringBuilder(isCompute ? "c " : "g ") : null;

                    while (stagesBitMask != 0)
                    {
                        int stageIndex = BitOperations.TrailingZeroCount(stagesBitMask);

                        dataReader.Read(ref stageEntry);

                        guestShaders[stageIndex] = _guestStorage.LoadShader(
                            guestTocFileStream,
                            guestDataFileStream,
                            stageEntry.GuestCodeIndex);
                        s2aKey?.Append(stageIndex).Append(':').Append(stageEntry.GuestCodeIndex).Append(' ');
                        s2aStages[stageIndex] = (int)stageEntry.GuestCodeIndex;

                        stagesBitMask &= ~(1u << stageIndex);
                    }

                    // S2Arm: index only (guest code, deduplicated and shared with the lookup tables); the specialization state,
                    // program info and host program are read the first time a lookup reaches the program (S2ALazyProgram)
                    if (loadHostCache)
                    {
                        dataReader.EndCompression();
                        S2ALazyProgram lazy = new(this, context, programIndex, dataOffset, header.Timestamp, isCompute, s2aStages);
                        loader.AddLazy(lazy);
                        if (warm != null && warm.TryGetValue(programIndex, out int slot)) warmLazy[slot] = lazy;
                        if (s2aGroups != null)
                        {
                            string gk = s2aKey.ToString();
                            if (!s2aGroups.TryGetValue(gk, out var gl)) s2aGroups.Add(gk, gl = new());
                            gl.Add(lazy); s2aGroupOf[lazy] = gk;
                        }
                        programIndex++;
                        continue;
                    }

                    ShaderSpecializationState specState = ShaderSpecializationState.Read(ref dataReader);
                    dataReader.EndCompression();

                    if (loadHostCache)
                    {
                        (byte[] hostCode, CachedShaderStage[] shaders) = ReadHostCode(
                            context,
                            ref hostTocFileStream,
                            ref hostDataFileStream,
                            guestShaders,
                            programIndex,
                            header.Timestamp);

                        if (hostCode != null)
                        {
                            // S2A：Vulkan 接口下也按渲染器程序二进制读（原版 Vulkan 存的是各阶段 SPIR-V 打包，重建要整段 SPIR-V；
                            // nxgal 的二进制只有每阶段的键与参数布局，函数按键从离线库取，旧库动森全量 260 MB → 7 MB）
                            bool hasFragmentShader = shaders.Length > 5 && shaders[5] != null;

                            // S2A：资源布局在二进制里，渲染器载入不读 ShaderInfo（S2AHostBinaryInfo）
                            IProgram hostProgram = context.Renderer.LoadProgramBinary(hostCode, hasFragmentShader, S2AHostBinaryInfo);

                            CachedShaderProgram program = new(hostProgram, specState, shaders);

                            loader.QueueHostProgram(program, hostCode, programIndex, isCompute);
                        }
                        else
                        {
                            // S2Arm: host code missing for this program — skip it (compiled on demand) instead of
                            // recompiling it and every following program from guest code at boot
                            S2AShaderCacheGuard.Report(1, $"程序 {programIndex} 缺主机代码");
                        }
                    }

                    loader.CheckCompilation();
                    programIndex++;
                }
            }
            finally
            {
                System.Threading.Volatile.Write(ref _s2aGuest, _guestStorage.S2ACache);   // S2Arm：按需程序按下标共用这份（见 S2ALazyProgram._stages），清掉前接过来
                _guestStorage.ClearMemoryCache();

                hostTocFileStream?.Dispose();
                hostDataFileStream?.Dispose();
            }

            if (discardAll)
            {
                ClearSharedCache();
                ClearGuestCache();
                ClearHostCache(context);
            }
            else if (warmLazy != null)
            {
                S2AWarmStart(context, S2AWarmWholeGroups(warmLazy, s2aGroups, s2aGroupOf));
            }
        }

        // S2A（#1411）：缓存目录里宿主程序文件名携带的能力身份清单（<api>_<厂商>_bin_<身份> 等），
        //   报版本不符时与本机需要的身份两边对照；一个都没有写「无」
        private string S2AHostIdentities()
        {
            List<string> names = new();
            foreach (string file in Directory.GetFiles(_basePath, "*_bin_*.toc"))
            {
                names.Add(Path.GetFileNameWithoutExtension(file));
            }
            names.Sort(StringComparer.Ordinal);
            return names.Count == 0 ? "无" : string.Join("、", names);
        }

        // S2A：提前热按整组预读（10-23 马车8 进赛道首帧：热表 498 个程序所在组共 1046 个，组内兄弟 548 个没预读；
        //   按需实化是整组一起实化（ShaderSpecializationList.Materialize），没预读的兄弟照样在渲染路径上读缓存 + 解压，首帧仍 104.7 ms / 312 次）。
        //   组 = 各阶段客体代码号完全相同的程序（同一份客体代码、特化不同的变体）。按热表次序：每个程序后面紧跟它的组内兄弟，去重
        private static S2ALazyProgram[] S2AWarmWholeGroups(S2ALazyProgram[] list,
            System.Collections.Generic.Dictionary<string, System.Collections.Generic.List<S2ALazyProgram>> groups,
            System.Collections.Generic.Dictionary<S2ALazyProgram, string> groupOf)
        {
            if (groups == null) return list;
            System.Collections.Generic.List<S2ALazyProgram> outp = new(list.Length * 2);
            System.Collections.Generic.HashSet<S2ALazyProgram> seen = new();
            foreach (S2ALazyProgram lazy in list)
            {
                if (lazy == null) { outp.Add(null); continue; }   // 「缓存里没有」照旧计数
                if (groupOf.TryGetValue(lazy, out string gk))
                {
                    foreach (S2ALazyProgram s in groups[gk]) if (seen.Add(s)) outp.Add(s);
                }
                else if (seen.Add(lazy)) outp.Add(lazy);
            }
            Console.Error.WriteLine($"[gal] 提前热按客体代码组整组预读：热表 {list.Length} 个程序 → 连组内兄弟 {outp.Count} 个");
            return outp.ToArray();
        }

        // S2A：读提前热程序表（每行「程序号\t首用帧\t函数名串」，# 注释；只收包内条目：序号 < S2AShaderCacheGuard.PackPrograms，之后的是运行时追加的、和出包对不上）。
        //   返回 程序号 → 表内次序（去重，保持首用帧升序）；读不了 = null（打一行，照旧按需）
        private static System.Collections.Generic.Dictionary<int, int> S2AWarmRead(string path)
        {
            try
            {
                System.Collections.Generic.Dictionary<int, int> d = new();
                foreach (string line in File.ReadLines(path))
                {
                    if (line.Length == 0 || line[0] == '#') continue;
                    int tab = line.IndexOf('\t');
                    if (int.TryParse(tab < 0 ? line : line[..tab], out int idx) && idx >= 0 && idx < S2AShaderCacheGuard.PackPrograms) d.TryAdd(idx, d.Count);
                }
                return d.Count == 0 ? null : d;
            }
            catch (IOException e)
            {
                Console.Error.WriteLine($"[gal] 【红】提前热程序表读不了（{e.Message}）：照旧按需实化");
                return null;
            }
        }

        // S2A：提前热程序（10-23 画面·着色器线）：缓存只登记、程序到第一次查到才实化（补丁 shader-cache-lazy），换场景那帧的程序当帧才实化。
        //   这里按表（首用帧升序）在后台线程做两件事：
        //   1) 把实化要读的缓存部分（共享数据记录解压 + 特化状态 + 宿主二进制 + 各阶段信息）读好挂到程序上（S2ALazyProgram.Pre*），
        //      游戏真正查到时实化直接用，读缓存 + 解压不上渲染路径（马车8 进赛道首帧按需实化 324 次 128.9 ms，其中建宿主程序只占 0.24 ms）；
        //   2) 把宿主二进制交底层渲染器载入一次再放掉：渲染器程序一建成就把它在首用表里的管线排进后台预取（graphics/metal/gal_state.m gal_pso_pf_prog）。
        //   宿主程序本身仍由实化在 GPU 模拟线程上经多线程渲染器建（命令队列只认这一个生产者）；底层载入 / 释放走渲染器自己的 API 锁。
        //   与实化共用 _lazyLock：已先被实化（Done）的不读。转计算复合二进制（S2AVtg）只做 1)
        private void S2AWarmStart(GpuContext context, S2ALazyProgram[] list)
        {
            IRenderer renderer = context.Renderer is Ryujinx.Graphics.GAL.Multithreading.ThreadedRenderer t ? t.BaseRenderer : context.Renderer;
            if (S2APipelineWarm.S2AEnabled(S2APipelineWarm.S2APolicy(context.Renderer)))
            {
                // S1: this backend loads versioned program records on demand through its single
                // compile lane. The old "load, wait, dispose" prefetch would create and drop
                // host programs that no draw can reuse. Backends without the policy (Apple
                // NxGal) keep the prefetch, joined before the renderer is retired.
                S2AShaderCacheGuard.Report(0, "宿主程序预读关闭（S1：按需加载，不后台载入/释放）");
                return;
            }
            _s2aWarmThread = new(() =>
            {
                long t0 = System.Diagnostics.Stopwatch.GetTimestamp();
                // 本线程托管分配（含解压临时缓冲）：预读挂在程序上的常驻量的上界
                long a0 = GC.GetAllocatedBytesForCurrentThread();
                int ok = 0, fail = 0, none = 0, vtg = 0, late = 0;
                long bytes = 0;
                foreach (S2ALazyProgram lazy in list)
                {
                    if (_s2aWarmStop) break;
                    if (lazy == null) { none++; continue; }
                    byte[] hostCode;
                    CachedShaderStage[] shaders;
                    try
                    {
                        lock (_lazyLock)
                        {
                            // 渲染路径已经先实化了它：不再读（读了也没人用）
                            if (lazy.Done) { late++; continue; }
                            ShaderSpecializationState specState;
                            (specState, hostCode, shaders) = S2AReadParts(lazy);
                            if (hostCode == null) { fail++; continue; }
                            // 读好的部分交给它：实化时不再读缓存 / 解压（S2AMaterializeCore）
                            _s2aPre[lazy.ProgramIndex] = (specState, hostCode, shaders);
                            bytes += hostCode.Length;
                        }
                    }
                    catch (Exception e) when (e is DiskCacheLoadException or IOException or InvalidDataException)
                    {
                        fail++;
                        continue;
                    }
                    if (!lazy.IsCompute && S2AVtg.IsPacked(hostCode)) { vtg++; continue; }
                    bool hasFragmentShader = shaders.Length > 5 && shaders[5] != null;
                    IProgram p = renderer.LoadProgramBinary(hostCode, hasFragmentShader, S2AHostBinaryInfo);
                    if (p.CheckProgramLink(true) == ProgramLinkStatus.Success) ok++; else fail++;
                    p.Dispose();
                }
                double ms = System.Diagnostics.Stopwatch.GetElapsedTime(t0).TotalMilliseconds;
                Console.Error.WriteLine($"[gal] 提前热程序：表 {list.Length} 个，预读缓存并载入宿主 {ok}、转计算只预读 {vtg}、失败 {fail}、缓存里没有 {none}、已先被实化 {late}，宿主二进制 {bytes >> 10} KB，本线程托管分配 {(GC.GetAllocatedBytesForCurrentThread() - a0) >> 10} KB，后台用时 {ms:0} ms");
            })
            { IsBackground = true, Name = "S2A.ShaderWarm", Priority = System.Threading.ThreadPriority.BelowNormal };
            _s2aWarmThread.Start();
        }

        // S2Arm: read-only handles kept for materializing lazily indexed programs (opened on first use, live for the session)
        private Stream _lazySharedData;
        private Stream _lazyHostToc;
        private Stream _lazyHostData;
        private ulong _lazyTimestamp;
        private readonly object _lazyLock = new();

        // S2Arm（帧率能耗线 10-24，GC）：启动时载入的客体代码共享表（下标 = 客体代码号），按需程序只存下标；
        //   提前热读好的部分放旁表（按程序号，持 _lazyLock 读写，实化取用即删），不挂在按需程序对象上
        private (byte[], byte[])[] _s2aGuest;

        /// <summary>S2A：本包热表里的程序号（加载屏预热用）；没有表/读不了 = null。</summary>
        internal HashSet<int> S2AWarmIndices { get; private set; }
        private readonly System.Collections.Generic.Dictionary<int, (ShaderSpecializationState, byte[], CachedShaderStage[])> _s2aPre = new();

        /// <summary>
        /// S2Arm (tests): adds guest code to the shared table and returns the stage indices (production indexes guest code at disk cache load).
        /// </summary>
        internal S2AStageIndices S2ARegisterGuests(GuestCodeAndCbData?[] guests)
        {
            lock (_lazyLock)
            {
                S2AStageIndices st = S2AStageIndices.None;
                (byte[], byte[])[] cur = System.Threading.Volatile.Read(ref _s2aGuest) ?? Array.Empty<(byte[], byte[])>();
                System.Collections.Generic.List<(byte[], byte[])> t = new(cur);

                for (int i = 0; i < guests.Length; i++)
                {
                    if (guests[i] is GuestCodeAndCbData g)
                    {
                        st[i] = t.Count;
                        t.Add((g.Code, g.Cb1Data));
                    }
                }

                System.Threading.Volatile.Write(ref _s2aGuest, t.ToArray());
                return st;
            }
        }

        /// <summary>
        /// S2Arm: builds the guest code array of a lazily indexed program from the shared guest cache (not retained by the caller's owner).
        /// </summary>
        internal GuestCodeAndCbData?[] S2AGuestShaders(S2AStageIndices stages, bool isCompute)
        {
            // 先看客体存储的（载入中），清掉后看接过来的（载入结束时先写这边再清那边，见 finally）
            (byte[], byte[])[] cache = _guestStorage.S2ACache ?? System.Threading.Volatile.Read(ref _s2aGuest);
            GuestCodeAndCbData?[] g = new GuestCodeAndCbData?[isCompute ? 1 : Constants.ShaderStages + 1];

            for (int i = 0; i < g.Length; i++)
            {
                int idx = stages[i];

                if (idx >= 0)
                {
                    (byte[] code, byte[] cb1) = cache[idx];
                    g[i] = new GuestCodeAndCbData(code, cb1);
                }
            }

            return g;
        }

        /// <summary>
        /// S2A：载入宿主程序二进制时传给渲染器的着色器信息——空。本缓存的宿主二进制是 nxgal 程序二进制（每阶段键 + 参数布局），
        /// 渲染器从二进制自身建程序、不读 ShaderInfo（graphics/metal/cs/NxProgram.cs Load）。原先每次按缓存条目重建资源布局（ShaderInfoBuilder），
        /// 动森包实测每个程序 17.2 KB 托管分配、占按需实化的 68%（10-21 画面·着色器线），建出来没人读。
        /// </summary>
        internal static readonly ShaderInfo S2AHostBinaryInfo = default;

        /// <summary>
        /// S2Arm: reads a program indexed at boot from the cache files and creates its host program.
        /// </summary>
        /// <param name="lazy">Program to materialize</param>
        /// <returns>The program, or null if it can't be used (then compiled on demand like an uncached shader)</returns>
        internal CachedShaderProgram S2AMaterialize(S2ALazyProgram lazy)
        {
            long s2aM = S2AAllocTrace.On ? S2AAllocTrace.Now() : 0;   // S2A：分配拆账（按需实化整段）
            try
            {
                return S2AMaterializeCore(lazy);
            }
            finally
            {
                if (S2AAllocTrace.On) S2AAllocTrace.Raw(0x40_000f, S2AAllocTrace.Now() - s2aM);
            }
        }

        /// <summary>
        /// S2A：读一个按需程序的缓存部分（特化状态 + 宿主二进制 + 各阶段信息）：读共享数据记录 + 解压 + 读宿主目录 / 数据。
        /// 调用方须持 _lazyLock（共用读句柄）。缓存坏了抛 DiskCacheLoadException / IOException / InvalidDataException；没有宿主二进制时 hostCode 为 null
        /// </summary>
        private (ShaderSpecializationState specState, byte[] hostCode, CachedShaderStage[] shaders) S2AReadParts(S2ALazyProgram lazy)
        {
            ShaderSpecializationState specState = S2AReadSpecStateLocked(lazy);

            (byte[] hostCode, CachedShaderStage[] shaders) = ReadHostCode(
                lazy.Context,
                ref _lazyHostToc,
                ref _lazyHostData,
                lazy.GuestShaders,
                lazy.ProgramIndex,
                lazy.Timestamp);

            return (specState, hostCode, shaders);
        }

        /// <summary>
        /// S2A（10-27）：只读一个按需程序的共享记录（特化状态），不读宿主二进制。宿主二进制缺失的条目在查找不中时用它按运行时状态
        /// 核对「是不是真的需要这一支」（见 <see cref="ShaderSpecializationList"/>）；读失败由调用方按缓存坏处理，不在这里报。
        /// </summary>
        internal ShaderSpecializationState S2AReadSpecState(S2ALazyProgram lazy)
        {
            lock (_lazyLock)
            {
                return S2AReadSpecStateLocked(lazy);
            }
        }

        /// <summary>S2A：<see cref="S2AReadSpecState"/> 的实际读取；调用方须持 _lazyLock。</summary>
        private ShaderSpecializationState S2AReadSpecStateLocked(S2ALazyProgram lazy)
        {
            if (_lazyTimestamp != lazy.Timestamp)
            {
                _lazySharedData?.Dispose();
                _lazySharedData = null;
                CloseHostStreams(ref _lazyHostToc, ref _lazyHostData);
                _lazyTimestamp = lazy.Timestamp;
            }
            _lazySharedData ??= DiskCacheCommon.OpenFile(_basePath, SharedDataFileName, writable: false);
            _lazySharedData.Seek((long)lazy.DataOffset, SeekOrigin.Begin);

            BinarySerializer dataReader = new(_lazySharedData);
            DataEntry entry = new();

            dataReader.BeginCompression();
            dataReader.Read(ref entry);

            uint stagesBitMask = lazy.IsCompute ? 1u : entry.StagesBitMask;
            DataEntryPerStage stageEntry = new();

            while (stagesBitMask != 0)
            {
                dataReader.Read(ref stageEntry);
                stagesBitMask &= stagesBitMask - 1;
            }

            ShaderSpecializationState specState = ShaderSpecializationState.Read(ref dataReader);
            dataReader.EndCompression();

            return specState;
        }

        // S2A（10-24）：按需实化不在 GPU 模拟线程上同步查链接。多线程渲染器里 CheckProgramLink 是 InvokeCommand，要等渲染线程排空；
        //   渲染线程正等一支首遇现编时，GPU 模拟线程就停在这里，翻不了下一支、排不出下一批编译，现编被串成一支一支
        //   （10-24 测试机1 xc3 冷局第 703 帧：GPU 模拟线程 S2AMaterializeCore → CheckProgramLink 等渲染线程、渲染线程 WaitForProgram 等现编，停 12 秒）。
        //   改成登记、由 ShaderCache.ProcessShaderCacheQueue 每帧不等渲染线程补查（S2AVtg.LinkStatusNoWait）：补查到失败 → 条目作废（S2ARejectLink，之后查找跳过、首遇照常翻译）。
        //   上游翻译路径（CreateProgram）本来就不在 GPU 线程上查链接，这里与它一致
        private readonly List<(CachedShaderProgram Program, int Index)> _s2aPendingLink = new();

        private CachedShaderProgram S2APendLink(CachedShaderProgram program, int programIndex)
        {
            lock (_s2aPendingLink)
            {
                _s2aPendingLink.Add((program, programIndex));
            }

            return program;
        }

        /// <summary>
        /// S2A：补查按需实化程序的链接（GPU 模拟线程每帧，不等渲染线程）。链接失败的作废、报红、交 onFailed（调用方把它从按地址的快表里摘掉）后释放；返回还没得出结果的个数
        /// </summary>
        internal int S2AProcessPendingLink(Action<CachedShaderProgram> onFailed)
        {
            lock (_s2aPendingLink)
            {
                for (int i = 0; i < _s2aPendingLink.Count; i++)
                {
                    (CachedShaderProgram program, int index) = _s2aPendingLink[i];
                    ProgramLinkStatus status = S2AVtg.LinkStatusNoWait(program);

                    if (status == ProgramLinkStatus.Incomplete)
                    {
                        continue;
                    }

                    _s2aPendingLink.RemoveAt(i--);

                    if (status == ProgramLinkStatus.Failure)
                    {
                        program.SpecializationState.S2ARejectLink();
                        S2AShaderCacheGuard.Report(1, $"程序 {index} 主机二进制载入失败（按需实化补查，条目作废、之后首遇照常翻译）");
                        onFailed?.Invoke(program);
                        program.Dispose();
                    }
                }

                return _s2aPendingLink.Count;
            }
        }

        private CachedShaderProgram S2AMaterializeCore(S2ALazyProgram lazy)
        {
            ShaderSpecializationState specState;
            byte[] hostCode;
            CachedShaderStage[] shaders;

            // The lazy lock protects only the shared cache streams and the pre-read handoff.
            // Renderer/program creation runs outside it so a slow driver call cannot block
            // another materialization or the cache writer.
            lock (_lazyLock)
            {
                try
                {
                    // S2A：提前热已在后台读好就直接用（读缓存 + 解压不上渲染路径），没读到再现读
                    lazy.Done = true;
                    _s2aPre.Remove(lazy.ProgramIndex, out (ShaderSpecializationState, byte[], CachedShaderStage[]) pre);
                    (specState, hostCode, shaders) = pre;

                    if (hostCode == null)
                    {
                        (specState, hostCode, shaders) = S2AReadParts(lazy);
                    }
                }
                catch (Exception e) when (e is DiskCacheLoadException or IOException or InvalidDataException)
                {
                    S2AShaderCacheGuard.Report(1, $"程序 {lazy.ProgramIndex} 按需实化读缓存失败：{e.Message}");
                    return null;
                }
            }

            if (hostCode == null)
            {
                // S2Arm（10-27）：这里不再直接报红。缓存里同一份客体代码有很多特化变体，宿主二进制按「构建 + 设备 profile」
                //   身份分开存；身份一变（换包 / 重建）绝大多数变体都不会有宿主二进制，但同包下一次查找常常用另一个有宿主
                //   二进制的变体命中。旧口径把整组缺宿主二进制的变体都报成「作废」，同一批变体每局重报（8E 同包两局 643 行 /
                //   第 1 局 551 次现编、第 2 局 0 次现编）。改由 ShaderSpecializationList 在查找不中时按运行时状态核对，
                //   只有真的匹配到这条却没有宿主二进制才报一次（= 一次首遇现编）。
                lazy.HostMissing = true;
                return null;
            }

            // S2A：顶点 / 几何转计算的程序是复合二进制（图形 / 顶点计算 / 几何计算三个宿主程序 + 保留布局，S2AVtg）：分段建、不翻译
            if (!lazy.IsCompute && S2AVtg.IsPacked(hostCode))
            {
                return S2AMaterializeVtg(lazy, hostCode, shaders, specState);
            }

            bool hasFragmentShader = shaders.Length > 5 && shaders[5] != null;
            long s2aL = S2AAllocTrace.On ? S2AAllocTrace.Now() : 0;
            IProgram hostProgram = lazy.Context.Renderer.LoadProgramBinary(hostCode, hasFragmentShader, S2AHostBinaryInfo);
            if (S2AAllocTrace.On) S2AAllocTrace.Raw(0x40_0010, S2AAllocTrace.Now() - s2aL);

            // A rejected VKPB record must become an on-demand translation before any draw can
            // bind it; the deferred link queue is too late (SetProgram requires ShaderCollection).
            if (HostProgramRejected(hostProgram, lazy.ProgramIndex, out string rejectReason))
            {
                hostProgram.Dispose();
                return null;
            }

            // S2A：来自磁盘缓存（含出包种入的包内条目）：首次命中时按运行时真值核对全部翻译读过的字段（ShaderCache.S2AVerify）
            specState.S2AMarkLoaded(lazy.ProgramIndex);

            return S2APendLink(new CachedShaderProgram(hostProgram, specState, shaders), lazy.ProgramIndex);
        }

        private static bool HostProgramRejected(IProgram program, int programIndex, out string reason)
        {
            reason = (program as IProgramBinaryLoadFailure)?.ProgramBinaryLoadFailure;
            if (reason == null)
            {
                return false;
            }

            S2AShaderCacheGuard.Report(1, $"程序 {programIndex} 主机记录拒绝（{reason}），改为按需翻译");
            return true;
        }

        /// <summary>S2A：着色器信息读写（转计算复合二进制里的直通顶点信息用同一格式，S2AVtg）。</summary>
        internal static ShaderProgramInfo S2AReadShaderProgramInfo(ref BinarySerializer dataReader) => ReadShaderProgramInfo(ref dataReader);

        internal static void S2AWriteShaderProgramInfo(ref BinarySerializer dataWriter, ShaderProgramInfo info) => WriteShaderProgramInfo(ref dataWriter, info);

        private static int _s2aVtgMaterialized;

        // S2A：按需实化一个转计算程序：拆复合二进制、建三个宿主程序、三个都链接成功才用（任一失败 = 当未缓存，首遇照常翻译）
        private static CachedShaderProgram S2AMaterializeVtg(S2ALazyProgram lazy, byte[] hostCode, CachedShaderStage[] shaders, ShaderSpecializationState specState)
        {
            S2AVtg.Unpacked vtg = S2AVtg.Unpack(hostCode);

            if (vtg == null)
            {
                S2AShaderCacheGuard.Report(1, $"程序 {lazy.ProgramIndex} 转计算复合二进制坏（按需实化）");
                return null;
            }

            CachedShaderProgram program = S2AVtg.Load(lazy.Context, vtg, shaders, specState);

            if (program == null)
            {
                S2AShaderCacheGuard.Report(1, $"程序 {lazy.ProgramIndex} 转计算宿主记录拒绝，改为按需翻译");
                return null;
            }

            lazy.Storage.S2APendLink(program, lazy.ProgramIndex);

            int n = System.Threading.Interlocked.Increment(ref _s2aVtgMaterialized);

            if (n <= 32)
            {
                Console.Error.WriteLine($"[gal] 转计算程序按需实化 #{n}：程序 {lazy.ProgramIndex}（复合宿主二进制，不翻译）");
            }

            return program;
        }

        /// <summary>
        /// Reads the host code for a given shader, if existent.
        /// </summary>
        /// <param name="context">GPU context</param>
        /// <param name="tocFileStream">Host TOC file stream, intialized if needed</param>
        /// <param name="dataFileStream">Host data file stream, initialized if needed</param>
        /// <param name="guestShaders">Guest shader code for each active stage</param>
        /// <param name="programIndex">Index of the program on the cache</param>
        /// <param name="expectedTimestamp">Creation token of the shared cache generation; the host file must match it</param>
        /// <returns>Host binary code, or null if not found</returns>
        private (byte[], CachedShaderStage[]) ReadHostCode(
            GpuContext context,
            ref Stream tocFileStream,
            ref Stream dataFileStream,
            GuestCodeAndCbData?[] guestShaders,
            int programIndex,
            ulong expectedTimestamp)
        {
            string tocFilePath = Path.Combine(_basePath, GetHostTocFileName(context));
            string dataFilePath = Path.Combine(_basePath, GetHostDataFileName(context));

            // A context capability change must not keep using handles opened for another
            // identity. A rejected header must not become accepted on the next lazy read.
            if (tocFileStream is not FileStream tocFile || tocFile.Name != tocFilePath ||
                dataFileStream is not FileStream dataFile || dataFile.Name != dataFilePath)
            {
                CloseHostStreams(ref tocFileStream, ref dataFileStream);

                if (!File.Exists(tocFilePath) || !File.Exists(dataFilePath))
                {
                    return (null, null);
                }

                try
                {
                    // Admission must observe the current header, not FileStream's buffered
                    // copy of a generation that a writer has since replaced in this file.
                    tocFileStream = DiskCacheCommon.OpenFile(_basePath, GetHostTocFileName(context), writable: false, bufferSize: 1);
                    dataFileStream = DiskCacheCommon.OpenFile(_basePath, GetHostDataFileName(context), writable: false);
                }
                catch
                {
                    CloseHostStreams(ref tocFileStream, ref dataFileStream);
                    throw;
                }
            }

            tocFileStream.Seek(0, SeekOrigin.Begin);
            BinarySerializer tocReader = new(tocFileStream);
            TocHeader header = new();

            if (!tocReader.TryRead(ref header) || header.Magic != TochMagic ||
                header.FormatVersion != FileFormatVersionPacked || header.CodeGenVersion != CodeGenVersion ||
                header.Timestamp != expectedTimestamp)
            {
                CloseHostStreams(ref tocFileStream, ref dataFileStream);
                return (null, null);
            }

            long offset = Unsafe.SizeOf<TocHeader>() + (long)programIndex * Unsafe.SizeOf<OffsetAndSize>();
            if (programIndex < 0 || offset + Unsafe.SizeOf<OffsetAndSize>() > tocFileStream.Length)
            {
                return (null, null);
            }

            tocFileStream.Seek(offset, SeekOrigin.Begin);
            OffsetAndSize offsetAndSize = new();
            tocReader.Read(ref offsetAndSize);

            // Sparse TOC slots are zero-filled. Offset 0 is a valid first data record;
            // only an empty size pair denotes a missing host program.
            if (offsetAndSize.UncompressedSize == 0 && offsetAndSize.CompressedSize == 0)
            {
                return (null, null);
            }

            if (offsetAndSize.UncompressedSize == 0 || offsetAndSize.UncompressedSize > int.MaxValue ||
                offsetAndSize.CompressedSize == 0 || offsetAndSize.Offset >= (ulong)dataFileStream.Length ||
                offsetAndSize.CompressedSize > (ulong)dataFileStream.Length - offsetAndSize.Offset)
            {
                throw new DiskCacheLoadException(DiskCacheLoadResult.FileCorruptedGeneric);
            }

            dataFileStream.Seek((long)offsetAndSize.Offset, SeekOrigin.Begin);
            byte[] hostCode = new byte[offsetAndSize.UncompressedSize];
            using (BoundedReadStream compressedRecord = new(dataFileStream, offsetAndSize.CompressedSize))
            {
                BinarySerializer.ReadCompressed(compressedRecord, hostCode);
            }

            CachedShaderStage[] shaders = new CachedShaderStage[guestShaders.Length];
            BinarySerializer dataReader = new(dataFileStream);

            dataFileStream.Seek((long)(offsetAndSize.Offset + offsetAndSize.CompressedSize), SeekOrigin.Begin);

            dataReader.BeginCompression();

            for (int index = 0; index < guestShaders.Length; index++)
            {
                if (!guestShaders[index].HasValue)
                {
                    continue;
                }

                GuestCodeAndCbData guestShader = guestShaders[index].Value;
                ShaderProgramInfo info = index != 0 || guestShaders.Length == 1 ? ReadShaderProgramInfo(ref dataReader) : null;

                shaders[index] = new CachedShaderStage(info, guestShader.Code, guestShader.Cb1Data);
            }

            dataReader.EndCompression();

            return (hostCode, shaders);
        }

        private static void CloseHostStreams(ref Stream tocFileStream, ref Stream dataFileStream)
        {
            tocFileStream?.Dispose();
            dataFileStream?.Dispose();
            tocFileStream = null;
            dataFileStream = null;
        }

        /// <summary>
        /// Gets output streams for the disk cache, for faster batch writing.
        /// </summary>
        /// <param name="context">The GPU context, used to determine the host disk cache</param>
        /// <returns>A collection of disk cache output streams</returns>
        public DiskCacheOutputStreams GetOutputStreams(GpuContext context)
        {
            FileStream tocFileStream = null;
            FileStream dataFileStream = null;
            FileStream hostTocFileStream = null;
            FileStream hostDataFileStream = null;
            try
            {
                tocFileStream = DiskCacheCommon.OpenFile(_basePath, SharedTocFileName, writable: true);
                dataFileStream = DiskCacheCommon.OpenFile(_basePath, SharedDataFileName, writable: true);
                hostTocFileStream = DiskCacheCommon.OpenFile(_basePath, GetHostTocFileName(context), writable: true);
                hostDataFileStream = DiskCacheCommon.OpenFile(_basePath, GetHostDataFileName(context), writable: true);
                return new DiskCacheOutputStreams(tocFileStream, dataFileStream, hostTocFileStream, hostDataFileStream);
            }
            catch
            {
                tocFileStream?.Dispose();
                dataFileStream?.Dispose();
                hostTocFileStream?.Dispose();
                hostDataFileStream?.Dispose();
                throw;
            }
        }

        /// <summary>
        /// Adds a shader to the cache.
        /// </summary>
        /// <param name="context">GPU context</param>
        /// <param name="program">Cached program</param>
        /// <param name="hostCode">Optional host binary code</param>
        /// <param name="streams">Output streams to use</param>
        public void AddShader(GpuContext context, CachedShaderProgram program, ReadOnlySpan<byte> hostCode, DiskCacheOutputStreams streams = null)
        {
            // Batch handles belong to one cache root and one capability identity. Reject
            // cross-domain use before appending either guest code or shared indices.
            if (streams != null &&
                (streams.TocFileStream.Name != Path.Combine(_basePath, SharedTocFileName) ||
                 streams.DataFileStream.Name != Path.Combine(_basePath, SharedDataFileName) ||
                 streams.HostTocFileStream.Name != Path.Combine(_basePath, GetHostTocFileName(context)) ||
                 streams.HostDataFileStream.Name != Path.Combine(_basePath, GetHostDataFileName(context))))
            {
                throw new InvalidOperationException("Disk cache output streams belong to another cache or capability identity.");
            }

            uint stagesBitMask = 0;

            for (int index = 0; index < program.Shaders.Length; index++)
            {
                CachedShaderStage shader = program.Shaders[index];

                // S2A：计算程序（只有一个阶段）的掩码为 0；图形程序全部非空阶段都进掩码。上游按「阶段信息是计算」跳过，
                // 转计算程序的顶点 / 几何阶段信息就是计算版，会被漏掉而下面照写它们的阶段条目，读回错位（S2AVtg）
                if (shader == null || program.Shaders.Length == 1)
                {
                    continue;
                }

                stagesBitMask |= 1u << index;
            }

            FileStream tocFileStream = streams?.TocFileStream;
            FileStream dataFileStream = streams?.DataFileStream;

            TocHeader sharedHeader = new();
            try
            {
                tocFileStream ??= DiskCacheCommon.OpenFile(_basePath, SharedTocFileName, writable: true);
                dataFileStream ??= DiskCacheCommon.OpenFile(_basePath, SharedDataFileName, writable: true);
                if (tocFileStream.Length == 0)
                {
                    // Use the shared header's creation token for every host append, rather
                    // than the time of the append. Ticks reduce same-second collisions; this
                    // is a generation consistency check, not a globally unique cache ID.
                    CreateToc(tocFileStream, ref sharedHeader, TocsMagic, CodeGenVersion, (ulong)DateTime.UtcNow.Ticks);
                }
                else
                {
                    tocFileStream.Seek(0, SeekOrigin.Begin);
                    BinarySerializer headerReader = new(tocFileStream);
                    if (!headerReader.TryRead(ref sharedHeader) || sharedHeader.Magic != TocsMagic ||
                        sharedHeader.FormatVersion != FileFormatVersionPacked || sharedHeader.CodeGenVersion != CodeGenVersion ||
                        (tocFileStream.Length - Unsafe.SizeOf<TocHeader>()) % sizeof(ulong) != 0)
                    {
                        throw new DiskCacheLoadException(DiskCacheLoadResult.FileCorruptedGeneric);
                    }
                }

                long programIndex = (tocFileStream.Length - Unsafe.SizeOf<TocHeader>()) / sizeof(ulong);
                tocFileStream.Seek(0, SeekOrigin.End);
                dataFileStream.Seek(0, SeekOrigin.End);

                BinarySerializer tocWriter = new(tocFileStream);
                BinarySerializer dataWriter = new(dataFileStream);

                ulong dataOffset = (ulong)dataFileStream.Position;

                DataEntry entry = new()
                {
                    StagesBitMask = stagesBitMask,
                };

                dataWriter.BeginCompression(DiskCacheCommon.GetCompressionAlgorithm());
                dataWriter.Write(ref entry);

                DataEntryPerStage stageEntry = new();

                for (int index = 0; index < program.Shaders.Length; index++)
                {
                    CachedShaderStage shader = program.Shaders[index];
                    if (shader == null)
                    {
                        continue;
                    }

                    stageEntry.GuestCodeIndex = _guestStorage.AddShader(shader.Code, shader.Cb1Data);

                    dataWriter.Write(ref stageEntry);
                }

                program.SpecializationState.Write(ref dataWriter);
                dataWriter.EndCompression();

                // Publish shared indices only after the corresponding record is readable.
                dataFileStream.Flush();
                tocWriter.Write(ref dataOffset);
                tocFileStream.Flush();

                if (!hostCode.IsEmpty)
                {
                    WriteHostCode(context, hostCode, program.Shaders, streams, sharedHeader.Timestamp, programIndex);
                }
            }
            finally
            {
                if (streams == null)
                {
                    tocFileStream?.Dispose();
                    dataFileStream?.Dispose();
                }
            }
        }

        /// <summary>
        /// Clears all content from the guest cache files.
        /// </summary>
        public void ClearGuestCache()
        {
            _guestStorage.ClearCache();
        }

        /// <summary>
        /// Clears all content from the shared cache files.
        /// </summary>
        /// <param name="context">GPU context</param>
        public void ClearSharedCache()
        {
            using FileStream tocFileStream = DiskCacheCommon.OpenFile(_basePath, SharedTocFileName, writable: true);
            using FileStream dataFileStream = DiskCacheCommon.OpenFile(_basePath, SharedDataFileName, writable: true);

            tocFileStream.SetLength(0);
            dataFileStream.SetLength(0);
        }

        /// <summary>
        /// Deletes all content from the host cache files.
        /// </summary>
        /// <param name="context">GPU context</param>
        public void ClearHostCache(GpuContext context)
        {
            using FileStream tocFileStream = DiskCacheCommon.OpenFile(_basePath, GetHostTocFileName(context), writable: true);
            using FileStream dataFileStream = DiskCacheCommon.OpenFile(_basePath, GetHostDataFileName(context), writable: true);

            tocFileStream.SetLength(0);
            dataFileStream.SetLength(0);
        }

        /// <summary>
        /// Writes the host binary code on the host cache.
        /// </summary>
        /// <param name="context">GPU context</param>
        /// <param name="hostCode">Host binary code</param>
        /// <param name="shaders">Shader stages to be added to the host cache</param>
        /// <param name="streams">Output streams to use</param>
        /// <param name="timestamp">File creation timestamp</param>
        /// <param name="programIndex">Shared TOC index; missing host programs must not compact it</param>
        private void WriteHostCode(
            GpuContext context,
            ReadOnlySpan<byte> hostCode,
            CachedShaderStage[] shaders,
            DiskCacheOutputStreams streams,
            ulong timestamp,
            long programIndex)
        {
            FileStream tocFileStream = streams?.HostTocFileStream;
            FileStream dataFileStream = streams?.HostDataFileStream;

            try
            {
                tocFileStream ??= DiskCacheCommon.OpenFile(_basePath, GetHostTocFileName(context), writable: true);
                dataFileStream ??= DiskCacheCommon.OpenFile(_basePath, GetHostDataFileName(context), writable: true);
                if (DiskCacheCommon.S2ACacheDiagnostics && !_s2aHostPathLogged)
                {
                    _s2aHostPathLogged = true;
                    Console.Error.WriteLine($"[vkpb] 宿主缓存路径：base={_basePath} toc={Path.GetFullPath(GetHostTocFileName(context))}");
                }
                TocHeader header = new();
                tocFileStream.Seek(0, SeekOrigin.Begin);
                BinarySerializer headerReader = new(tocFileStream);
                if (!headerReader.TryRead(ref header) || header.Magic != TochMagic ||
                    header.FormatVersion != FileFormatVersionPacked || header.CodeGenVersion != CodeGenVersion ||
                    header.Timestamp != timestamp)
                {
                    // S2A 诊断：宿主 TOC 身份不符会清空整份宿主缓存；统计旧/新时间戳与长度。
                    if (DiskCacheCommon.S2ACacheDiagnostics)
                    {
                        Console.Error.WriteLine($"[vkpb] 宿主 TOC 重置：{tocFileStream.Name} " +
                            $"旧 ts={header.Timestamp:x} 新 ts={timestamp:x} toc={tocFileStream.Length} data={dataFileStream.Length} " +
                            $"程序 {programIndex} base={_basePath}");
                    }
                    CreateToc(tocFileStream, ref header, TochMagic, CodeGenVersion, timestamp);
                    dataFileStream.SetLength(0);
                }

                // Host slots use the shared program index even if earlier programs had no
                // binary or this host identity did not exist when those programs were added.
                long tocOffset = checked(Unsafe.SizeOf<TocHeader>() + programIndex * Unsafe.SizeOf<OffsetAndSize>());
                if (tocFileStream.Length < tocOffset)
                {
                    tocFileStream.SetLength(tocOffset);
                }
                tocFileStream.Seek(tocOffset, SeekOrigin.Begin);
                dataFileStream.Seek(0, SeekOrigin.End);

                BinarySerializer tocWriter = new(tocFileStream);
                BinarySerializer dataWriter = new(dataFileStream);

                OffsetAndSize offsetAndSize = new()
                {
                    Offset = (ulong)dataFileStream.Position,
                    UncompressedSize = (uint)hostCode.Length,
                };

                long dataStartPosition = dataFileStream.Position;

                BinarySerializer.WriteCompressed(dataFileStream, hostCode, DiskCacheCommon.GetCompressionAlgorithm());

                offsetAndSize.CompressedSize = (uint)(dataFileStream.Position - dataStartPosition);

                dataWriter.BeginCompression(DiskCacheCommon.GetCompressionAlgorithm());

                for (int index = 0; index < shaders.Length; index++)
                {
                    if (shaders[index] != null)
                    {
                        WriteShaderProgramInfo(ref dataWriter, shaders[index].Info);
                    }
                }

                dataWriter.EndCompression();

                // Complete and flush host data before making this slot visible to lazy readers.
                dataFileStream.Flush();
                tocWriter.Write(ref offsetAndSize);
                tocFileStream.Flush();
                if (DiskCacheCommon.S2ACacheDiagnostics && (_s2aHostWrites++ < 8 || _s2aHostWrites % 128 == 0))
                {
                    Console.Error.WriteLine($"[vkpb] 宿主 TOC 写：idx={programIndex} off={tocOffset} " +
                        $"len={tocFileStream.Length} bytes={hostCode.Length} data={dataFileStream.Length}");
                }
            }
            finally
            {
                if (streams == null)
                {
                    tocFileStream?.Dispose();
                    dataFileStream?.Dispose();
                }
            }
        }

        /// <summary>
        /// Creates a TOC file for the host or shared cache.
        /// </summary>
        /// <param name="tocFileStream">TOC file stream</param>
        /// <param name="header">Set to the TOC file header</param>
        /// <param name="magic">Magic value to be written</param>
        /// <param name="codegenVersion">Shader codegen version, only valid for the host file</param>
        /// <param name="timestamp">File creation timestamp</param>
        private static void CreateToc(FileStream tocFileStream, ref TocHeader header, uint magic, uint codegenVersion, ulong timestamp)
        {
            BinarySerializer writer = new(tocFileStream);

            header.Magic = magic;
            header.FormatVersion = FileFormatVersionPacked;
            header.CodeGenVersion = codegenVersion;
            header.Padding = 0;
            header.Reserved = 0;
            header.Timestamp = timestamp;

            if (tocFileStream.Length > 0)
            {
                tocFileStream.Seek(0, SeekOrigin.Begin);
                tocFileStream.SetLength(0);
            }

            writer.Write(ref header);
        }

        /// <summary>
        /// Reads the shader program info from the cache.
        /// </summary>
        /// <param name="dataReader">Cache data reader</param>
        /// <returns>Shader program info</returns>
        private static ShaderProgramInfo ReadShaderProgramInfo(ref BinarySerializer dataReader)
        {
            DataShaderInfo dataInfo = new();

            dataReader.ReadWithMagicAndSize(ref dataInfo, ShdiMagic);

            BufferDescriptor[] cBuffers = new BufferDescriptor[dataInfo.CBuffersCount];
            BufferDescriptor[] sBuffers = new BufferDescriptor[dataInfo.SBuffersCount];
            TextureDescriptor[] textures = new TextureDescriptor[dataInfo.TexturesCount];
            TextureDescriptor[] images = new TextureDescriptor[dataInfo.ImagesCount];

            for (int index = 0; index < dataInfo.CBuffersCount; index++)
            {
                dataReader.ReadWithMagicAndSize(ref cBuffers[index], BufdMagic);
            }

            for (int index = 0; index < dataInfo.SBuffersCount; index++)
            {
                dataReader.ReadWithMagicAndSize(ref sBuffers[index], BufdMagic);
            }

            for (int index = 0; index < dataInfo.TexturesCount; index++)
            {
                dataReader.ReadWithMagicAndSize(ref textures[index], TexdMagic);
            }

            for (int index = 0; index < dataInfo.ImagesCount; index++)
            {
                dataReader.ReadWithMagicAndSize(ref images[index], TexdMagic);
            }

            return new ShaderProgramInfo(
                cBuffers,
                sBuffers,
                textures,
                images,
                dataInfo.Stage,
                dataInfo.GeometryVerticesPerPrimitive,
                dataInfo.GeometryMaxOutputVertices,
                dataInfo.ThreadsPerInputPrimitive,
                dataInfo.UsesFragCoord,
                dataInfo.UsesInstanceId,
                dataInfo.UsesDrawParameters,
                dataInfo.UsesRtLayer,
                dataInfo.ClipDistancesWritten,
                dataInfo.FragmentOutputMap);
        }

        /// <summary>
        /// Writes the shader program info into the cache.
        /// </summary>
        /// <param name="dataWriter">Cache data writer</param>
        /// <param name="info">Program info</param>
        private static void WriteShaderProgramInfo(ref BinarySerializer dataWriter, ShaderProgramInfo info)
        {
            if (info == null)
            {
                return;
            }

            DataShaderInfo dataInfo = new()
            {
                CBuffersCount = (ushort)info.CBuffers.Count,
                SBuffersCount = (ushort)info.SBuffers.Count,
                TexturesCount = (ushort)info.Textures.Count,
                ImagesCount = (ushort)info.Images.Count,
                Stage = info.Stage,
                GeometryVerticesPerPrimitive = (byte)info.GeometryVerticesPerPrimitive,
                GeometryMaxOutputVertices = (ushort)info.GeometryMaxOutputVertices,
                ThreadsPerInputPrimitive = (ushort)info.ThreadsPerInputPrimitive,
                UsesFragCoord = info.UsesFragCoord,
                UsesInstanceId = info.UsesInstanceId,
                UsesDrawParameters = info.UsesDrawParameters,
                UsesRtLayer = info.UsesRtLayer,
                ClipDistancesWritten = info.ClipDistancesWritten,
                FragmentOutputMap = info.FragmentOutputMap,
            };

            dataWriter.WriteWithMagicAndSize(ref dataInfo, ShdiMagic);

            for (int index = 0; index < info.CBuffers.Count; index++)
            {
                BufferDescriptor entry = info.CBuffers[index];
                dataWriter.WriteWithMagicAndSize(ref entry, BufdMagic);
            }

            for (int index = 0; index < info.SBuffers.Count; index++)
            {
                BufferDescriptor entry = info.SBuffers[index];
                dataWriter.WriteWithMagicAndSize(ref entry, BufdMagic);
            }

            for (int index = 0; index < info.Textures.Count; index++)
            {
                TextureDescriptor entry = info.Textures[index];
                dataWriter.WriteWithMagicAndSize(ref entry, TexdMagic);
            }

            for (int index = 0; index < info.Images.Count; index++)
            {
                TextureDescriptor entry = info.Images[index];
                dataWriter.WriteWithMagicAndSize(ref entry, TexdMagic);
            }
        }
    }
}
