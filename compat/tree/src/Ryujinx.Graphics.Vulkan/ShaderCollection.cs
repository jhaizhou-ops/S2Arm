using Ryujinx.Common.Logging;
using Ryujinx.Graphics.GAL;
using S2Arm.Backends.Vulkan.ProgramCache;
using Silk.NET.Vulkan;
using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.Linq;
using System.Threading.Tasks;

namespace Ryujinx.Graphics.Vulkan
{
    class ShaderCollection : IProgram, IS2APipelineWarm
    {
        private readonly PipelineShaderStageCreateInfo[] _infos;
        private readonly Shader[] _shaders;

        private readonly PipelineLayoutCacheEntry _plce;

        public PipelineLayout PipelineLayout => _plce.PipelineLayout;

        public bool HasMinimalLayout { get; }

        public bool UsePushDescriptors { get; }
        public bool IsCompute { get; }
        public bool HasTessellationControlShader => (Stages & (1u << 3)) != 0;

        public bool UpdateTexturesWithoutTemplate { get; }

        public uint Stages { get; }

        public PipelineStageFlags IncoherentBufferWriteStages { get; }
        public PipelineStageFlags IncoherentTextureWriteStages { get; }

        public ResourceBindingSegment[][] ClearSegments { get; }
        public ResourceBindingSegment[][] BindingSegments { get; }
        public DescriptorSetTemplate[] Templates { get; }

        /// <summary>S2A（F1）：本程序的越界记录段（布局里有记录绑定时才有；记录器分不到段时为 null，记录绑定落到空 / 占位缓冲）</summary>
        public S2AStorageOobRegion S2AOobRegion { get; }

        public ProgramLinkStatus LinkStatus { get; private set; }

        public readonly SpecDescription[] SpecDescriptions;

        public bool IsLinked
        {
            get
            {
                if (LinkStatus == ProgramLinkStatus.Incomplete)
                {
                    CheckProgramLink(true);
                }

                return LinkStatus == ProgramLinkStatus.Success;
            }
        }

        private string _s2aShaderHashes;

        /// <summary>S2A（#1360）：各阶段 SPIR-V 的前 8 字节 SHA-256，诊断报红时用来对上 AGI / 日志。</summary>
        public string S2AShaderHashes
        {
            get
            {
                if (_s2aShaderHashes != null)
                {
                    return _s2aShaderHashes;
                }

                System.Text.StringBuilder sb = new();
                Span<byte> hash = stackalloc byte[32];

                for (int i = 0; i < _s2aSources.Length; i++)
                {
                    if (i != 0)
                    {
                        sb.Append(',');
                    }

                    sb.Append(_s2aSources[i].Stage).Append(':');

                    byte[] code = _s2aSources[i].BinaryCode;

                    if (code == null)
                    {
                        sb.Append("null");
                        continue;
                    }

                    System.Security.Cryptography.SHA256.HashData(code, hash);
                    sb.Append(Convert.ToHexString(hash[..8]));
                }

                return _s2aShaderHashes = sb.ToString();
            }
        }

        private HashTableSlim<PipelineUid, Auto<DisposablePipeline>> _graphicsPipelineCache;
        private HashTableSlim<SpecData, Auto<DisposablePipeline>> _computePipelineCache;

        private readonly VulkanRenderer _gd;
        private Device _device;
        private bool _initialized;

        private ProgramPipelineState _state;
        private DisposableRenderPass _dummyRenderPass;
        private readonly Task _compileTask;
        private bool _firstBackgroundUse;

        // VKPB snapshot: sources and GAL metadata as seen when the program was created. It is
        // never reconstructed from VkShaderModule or the current pipeline state.
        private readonly ShaderSource[] _s2aSources;
        private readonly ResourceLayout _s2aLayout;
        private ProgramPipelineState _s2aState;
        private bool _s2aHasState;
        private bool _s2aCanSave;
        private byte[] _s2aBinary;
        private bool _s2aDisposed;

        public ShaderCollection(
            VulkanRenderer gd,
            Device device,
            ShaderSource[] shaders,
            ResourceLayout resourceLayout,
            SpecDescription[] specDescription = null,
            bool isMinimal = false)
        {
            _gd = gd;
            _device = device;

            if (specDescription != null && specDescription.Length != shaders.Length)
            {
                throw new ArgumentException($"{nameof(specDescription)} array length must match {nameof(shaders)} array if provided");
            }

            gd.Shaders.Add(this);

            Shader[] internalShaders = new Shader[shaders.Length];

            _infos = new PipelineShaderStageCreateInfo[shaders.Length];

            SpecDescriptions = specDescription;

            LinkStatus = ProgramLinkStatus.Incomplete;

            uint stages = 0;

            for (int i = 0; i < shaders.Length; i++)
            {
                Shader shader = new(gd, device, shaders[i]);

                stages |= 1u << shader.StageFlags switch
                {
                    ShaderStageFlags.FragmentBit => 1,
                    ShaderStageFlags.GeometryBit => 2,
                    ShaderStageFlags.TessellationControlBit => 3,
                    ShaderStageFlags.TessellationEvaluationBit => 4,
                    _ => 0,
                };

                if (shader.StageFlags == ShaderStageFlags.ComputeBit)
                {
                    IsCompute = true;
                }

                internalShaders[i] = shader;
            }

            _shaders = internalShaders;

            bool usePushDescriptors = !isMinimal &&
                VulkanConfiguration.UsePushDescriptors &&
                _gd.Capabilities.SupportsPushDescriptors &&
                !IsCompute &&
                !HasPushDescriptorsBug(gd) &&
                CanUsePushDescriptors(gd, resourceLayout, IsCompute);

            ReadOnlyCollection<ResourceDescriptorCollection> sets = usePushDescriptors ?
                BuildPushDescriptorSets(gd, resourceLayout.Sets) : resourceLayout.Sets;

            BindingSegments = BuildBindingSegments(resourceLayout.SetUsages, out bool usesBufferTextures);
            _plce = gd.PipelineLayoutCache.GetOrCreate(gd, device, sets, usePushDescriptors, BindingSegments);

            HasMinimalLayout = isMinimal;
            UsePushDescriptors = usePushDescriptors;

            Stages = stages;

            ClearSegments = BuildClearSegments(sets);
            Templates = BuildTemplates(usePushDescriptors);
            (IncoherentBufferWriteStages, IncoherentTextureWriteStages) = BuildIncoherentStages(resourceLayout.SetUsages);

            // Updating buffer texture bindings using template updates crashes the Adreno driver on Windows.
            UpdateTexturesWithoutTemplate = gd.IsQualcommProprietary && usesBufferTextures;

            _s2aSources = new ShaderSource[shaders.Length];
            _s2aCanSave = !isMinimal && specDescription == null;
            for (int i = 0; i < shaders.Length; i++)
            {
                ShaderSource source = shaders[i];
                _s2aCanSave &= source.BinaryCode != null;
                _s2aSources[i] = new ShaderSource(source.Code,
                    source.BinaryCode == null ? null : (byte[])source.BinaryCode.Clone(),
                    source.Stage, source.Language);
            }
            _s2aLayout = resourceLayout;

            S2AOobRegion = HasS2AOobRecordBinding(resourceLayout) ? gd.S2AStorageOob?.Allocate() : null;

            _compileTask = Task.CompletedTask;
            _firstBackgroundUse = false;
        }

        // S2A（F1）：布局的存储缓冲集合里有越界记录绑定（翻译期发现单目标 / 多目标全局访存的程序才有）
        private static bool HasS2AOobRecordBinding(ResourceLayout layout)
        {
            if (layout.Sets.Count <= PipelineBase.StorageSetIndex)
            {
                return false;
            }

            foreach (ResourceDescriptor descriptor in layout.Sets[PipelineBase.StorageSetIndex].Descriptors)
            {
                if (descriptor.Binding == Ryujinx.Graphics.Shader.S2AStorageOobRecord.Binding)
                {
                    return true;
                }
            }

            return false;
        }

        public ShaderCollection(
            VulkanRenderer gd,
            Device device,
            ShaderSource[] sources,
            ResourceLayout resourceLayout,
            ProgramPipelineState state,
            bool fromCache) : this(gd, device, sources, resourceLayout)
        {
            _state = state;
            _s2aState = state;
            _s2aHasState = true;

            _compileTask = BackgroundCompilation();
            _firstBackgroundUse = !fromCache;
        }

        private static bool HasPushDescriptorsBug(VulkanRenderer gd)
        {
            // Those GPUs/drivers do not work properly with push descriptors, so we must force disable them.
            return gd.IsNvidiaPreTuring || (gd.IsIntelArc && (gd.IsIntelWindows || gd.IsIntelLinux));
        }

        private static bool CanUsePushDescriptors(VulkanRenderer gd, ResourceLayout layout, bool isCompute)
        {
            // If binding 3 is immediately used, use an alternate set of reserved bindings.
            ReadOnlyCollection<ResourceUsage> uniformUsage = layout.SetUsages[0].Usages;
            bool hasBinding3 = uniformUsage.Any(x => x.Binding == 3);
            int[] reserved = isCompute ? [] : gd.GetPushDescriptorReservedBindings(hasBinding3);

            // Can't use any of the reserved usages.
            for (int i = 0; i < uniformUsage.Count; i++)
            {
                int binding = uniformUsage[i].Binding;

                if (reserved.Contains(binding) ||
                    binding >= Constants.MaxPushDescriptorBinding ||
                    binding >= gd.Capabilities.MaxPushDescriptors + reserved.Count(id => id < binding))
                {
                    return false;
                }
            }

            //Prevent the sum of descriptors from exceeding MaxPushDescriptors
            int totalDescriptors = 0;
            foreach (ResourceDescriptor desc in layout.Sets.First().Descriptors)
            {
                if (!reserved.Contains(desc.Binding))
                    totalDescriptors += desc.Count;
            }

            if (totalDescriptors > gd.Capabilities.MaxPushDescriptors)
                return false;

            return true;
        }

        private static ReadOnlyCollection<ResourceDescriptorCollection> BuildPushDescriptorSets(
            VulkanRenderer gd,
            ReadOnlyCollection<ResourceDescriptorCollection> sets)
        {
            // The reserved bindings were selected when determining if push descriptors could be used.
            int[] reserved = gd.GetPushDescriptorReservedBindings(false);

            ResourceDescriptorCollection[] result = new ResourceDescriptorCollection[sets.Count];

            for (int i = 0; i < sets.Count; i++)
            {
                if (i == 0)
                {
                    // Push descriptors apply here. Remove reserved bindings.
                    ResourceDescriptorCollection original = sets[i];

                    ResourceDescriptor[] pdUniforms = new ResourceDescriptor[original.Descriptors.Count];
                    int j = 0;

                    foreach (ResourceDescriptor descriptor in original.Descriptors)
                    {
                        if (reserved.Contains(descriptor.Binding))
                        {
                            // If the binding is reserved, set its descriptor count to 0.
                            pdUniforms[j++] = new ResourceDescriptor(
                                descriptor.Binding,
                                0,
                                descriptor.Type,
                                descriptor.Stages);
                        }
                        else
                        {
                            pdUniforms[j++] = descriptor;
                        }
                    }

                    result[i] = new ResourceDescriptorCollection(new(pdUniforms));
                }
                else
                {
                    result[i] = sets[i];
                }
            }

            return new(result);
        }

        private static ResourceBindingSegment[][] BuildClearSegments(ReadOnlyCollection<ResourceDescriptorCollection> sets)
        {
            ResourceBindingSegment[][] segments = new ResourceBindingSegment[sets.Count][];

            for (int setIndex = 0; setIndex < sets.Count; setIndex++)
            {
                List<ResourceBindingSegment> currentSegments = [];

                ResourceDescriptor currentDescriptor = default;
                int currentCount = 0;

                for (int index = 0; index < sets[setIndex].Descriptors.Count; index++)
                {
                    ResourceDescriptor descriptor = sets[setIndex].Descriptors[index];

                    if (currentDescriptor.Binding + currentCount != descriptor.Binding ||
                        currentDescriptor.Type != descriptor.Type ||
                        currentDescriptor.Stages != descriptor.Stages ||
                        currentDescriptor.Count > 1 ||
                        descriptor.Count > 1)
                    {
                        if (currentCount != 0)
                        {
                            currentSegments.Add(new ResourceBindingSegment(
                                currentDescriptor.Binding,
                                currentCount,
                                currentDescriptor.Type,
                                currentDescriptor.Stages,
                                currentDescriptor.Count > 1));
                        }

                        currentDescriptor = descriptor;
                        currentCount = descriptor.Count;
                    }
                    else
                    {
                        currentCount += descriptor.Count;
                    }
                }

                if (currentCount != 0)
                {
                    currentSegments.Add(new ResourceBindingSegment(
                        currentDescriptor.Binding,
                        currentCount,
                        currentDescriptor.Type,
                        currentDescriptor.Stages,
                        currentDescriptor.Count > 1));
                }

                segments[setIndex] = currentSegments.ToArray();
            }

            return segments;
        }

        private static ResourceBindingSegment[][] BuildBindingSegments(ReadOnlyCollection<ResourceUsageCollection> setUsages, out bool usesBufferTextures)
        {
            usesBufferTextures = false;

            ResourceBindingSegment[][] segments = new ResourceBindingSegment[setUsages.Count][];

            for (int setIndex = 0; setIndex < setUsages.Count; setIndex++)
            {
                List<ResourceBindingSegment> currentSegments = [];

                ResourceUsage currentUsage = default;
                int currentCount = 0;

                for (int index = 0; index < setUsages[setIndex].Usages.Count; index++)
                {
                    ResourceUsage usage = setUsages[setIndex].Usages[index];

                    if (usage.Type == ResourceType.BufferTexture)
                    {
                        usesBufferTextures = true;
                    }

                    if (currentUsage.Binding + currentCount != usage.Binding ||
                        currentUsage.Type != usage.Type ||
                        currentUsage.Stages != usage.Stages ||
                        currentUsage.ArrayLength > 1 ||
                        usage.ArrayLength > 1)
                    {
                        if (currentCount != 0)
                        {
                            currentSegments.Add(new ResourceBindingSegment(
                                currentUsage.Binding,
                                currentCount,
                                currentUsage.Type,
                                currentUsage.Stages,
                                currentUsage.ArrayLength > 1));
                        }

                        currentUsage = usage;
                        currentCount = usage.ArrayLength;
                    }
                    else
                    {
                        currentCount++;
                    }
                }

                if (currentCount != 0)
                {
                    currentSegments.Add(new ResourceBindingSegment(
                        currentUsage.Binding,
                        currentCount,
                        currentUsage.Type,
                        currentUsage.Stages,
                        currentUsage.ArrayLength > 1));
                }

                segments[setIndex] = currentSegments.ToArray();
            }

            return segments;
        }

        private DescriptorSetTemplate[] BuildTemplates(bool usePushDescriptors)
        {
            DescriptorSetTemplate[] templates = new DescriptorSetTemplate[BindingSegments.Length];

            for (int setIndex = 0; setIndex < BindingSegments.Length; setIndex++)
            {
                if (usePushDescriptors && setIndex == 0)
                {
                    // Push descriptors get updated using templates owned by the pipeline layout.
                    continue;
                }

                ResourceBindingSegment[] segments = BindingSegments[setIndex];

                if (segments != null && segments.Length > 0)
                {
                    templates[setIndex] = new DescriptorSetTemplate(
                        _gd,
                        _device,
                        segments,
                        _plce,
                        IsCompute ? PipelineBindPoint.Compute : PipelineBindPoint.Graphics,
                        setIndex);
                }
            }

            return templates;
        }

        private static PipelineStageFlags GetPipelineStages(ResourceStages stages)
        {
            PipelineStageFlags result = 0;

            if ((stages & ResourceStages.Compute) != 0)
            {
                result |= PipelineStageFlags.ComputeShaderBit;
            }

            if ((stages & ResourceStages.Vertex) != 0)
            {
                result |= PipelineStageFlags.VertexShaderBit;
            }

            if ((stages & ResourceStages.Fragment) != 0)
            {
                result |= PipelineStageFlags.FragmentShaderBit;
            }

            if ((stages & ResourceStages.Geometry) != 0)
            {
                result |= PipelineStageFlags.GeometryShaderBit;
            }

            if ((stages & ResourceStages.TessellationControl) != 0)
            {
                result |= PipelineStageFlags.TessellationControlShaderBit;
            }

            if ((stages & ResourceStages.TessellationEvaluation) != 0)
            {
                result |= PipelineStageFlags.TessellationEvaluationShaderBit;
            }

            return result;
        }

        private static (PipelineStageFlags Buffer, PipelineStageFlags Texture) BuildIncoherentStages(ReadOnlyCollection<ResourceUsageCollection> setUsages)
        {
            PipelineStageFlags buffer = PipelineStageFlags.None;
            PipelineStageFlags texture = PipelineStageFlags.None;

            foreach (ResourceUsageCollection set in setUsages)
            {
                foreach (ResourceUsage range in set.Usages)
                {
                    if (range.Write)
                    {
                        PipelineStageFlags stages = GetPipelineStages(range.Stages);

                        switch (range.Type)
                        {
                            case ResourceType.Image:
                                texture |= stages;
                                break;
                            case ResourceType.StorageBuffer:
                            case ResourceType.BufferImage:
                                buffer |= stages;
                                break;
                        }
                    }
                }
            }

            return (buffer, texture);
        }

        private async Task BackgroundCompilation()
        {
            try
            {
                await Task.WhenAll(_shaders.Select(shader => shader.CompileTask)).ConfigureAwait(false);
            }
            catch (Exception e) when (e is OperationCanceledException or VulkanException)
            {
                LinkStatus = ProgramLinkStatus.Failure;
                Logger.Error?.PrintMsg(LogClass.Gpu, $"Background module compilation failed: {e.Message}");
                return;
            }

            if (Array.Exists(_shaders, shader => shader.CompileStatus == ProgramLinkStatus.Failure))
            {
                LinkStatus = ProgramLinkStatus.Failure;

                return;
            }

            try
            {
                // Pipeline creation is a driver call: keep it on the single compile lane. The
                // module tasks above have completed before this item, so the lane cannot wait
                // on work queued behind it.
                CompileWorker worker = _gd.S2ACompileWorker;
                Task create = worker == null
                    ? Task.Run(() => { CreateBackgroundPipeline(); return true; })
                    : worker.Run(() => { CreateBackgroundPipeline(); return true; });
                await create.ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                LinkStatus = ProgramLinkStatus.Failure;
            }
            catch (VulkanException e)
            {
                Logger.Error?.PrintMsg(LogClass.Gpu, $"Background Compilation failed: {e.Message}");

                LinkStatus = ProgramLinkStatus.Failure;
            }
        }

        private void CreateBackgroundPipeline()
        {
            if (IsCompute)
            {
                CreateBackgroundComputePipeline();
            }
            else
            {
                CreateBackgroundGraphicsPipeline();
            }
        }

        private void EnsureShadersReady()
        {
            if (!_initialized)
            {
                CheckProgramLink(true);

                ProgramLinkStatus resultStatus = ProgramLinkStatus.Success;

                for (int i = 0; i < _shaders.Length; i++)
                {
                    Shader shader = _shaders[i];

                    if (shader.CompileStatus != ProgramLinkStatus.Success)
                    {
                        resultStatus = ProgramLinkStatus.Failure;
                    }

                    _infos[i] = shader.GetInfo();
                }

                // If the link status was already set as failure by background compilation, prefer that decision.
                if (LinkStatus != ProgramLinkStatus.Failure)
                {
                    LinkStatus = resultStatus;
                }

                _initialized = true;
            }
        }

        public PipelineShaderStageCreateInfo[] GetInfos()
        {
            EnsureShadersReady();

            return _infos;
        }

        protected DisposableRenderPass CreateDummyRenderPass()
        {
            if (_dummyRenderPass.Value.Handle != 0)
            {
                return _dummyRenderPass;
            }

            return _dummyRenderPass = _state.ToRenderPass(_gd, _device);
        }

        public void CreateBackgroundComputePipeline()
        {
            PipelineState pipeline = new();
            pipeline.Initialize();

            pipeline.Stages[0] = _shaders[0].GetInfo();
            pipeline.StagesCount = 1;
            pipeline.PipelineLayout = PipelineLayout;

            pipeline.CreateComputePipeline(_gd, _device, this, (_gd.Pipeline as PipelineBase).PipelineCache);
            pipeline.Dispose();
        }

        public void CreateBackgroundGraphicsPipeline()
        {
            // To compile shaders in the background in Vulkan, we need to create valid pipelines using the shader modules.
            // The GPU provides pipeline state via the GAL that can be converted into our internal Vulkan pipeline state.
            // This should match the pipeline state at the time of the first draw. If it doesn't, then it'll likely be
            // close enough that the GPU driver will reuse the compiled shader for the different state.

            // First, we need to create a render pass object compatible with the one that will be used at runtime.
            // The active attachment formats have been provided by the abstraction layer.
            DisposableRenderPass renderPass = CreateDummyRenderPass();

            PipelineState pipeline = _state.ToVulkanPipelineState(_gd);

            // Copy the shader stage info to the pipeline.
            Span<PipelineShaderStageCreateInfo> stages = pipeline.Stages.AsSpan();

            for (int i = 0; i < _shaders.Length; i++)
            {
                stages[i] = _shaders[i].GetInfo();
            }

            pipeline.HasTessellationControlShader = HasTessellationControlShader;
            pipeline.StagesCount = (uint)_shaders.Length;
            pipeline.PipelineLayout = PipelineLayout;

            pipeline.CreateGraphicsPipeline(_gd, _device, this, (_gd.Pipeline as PipelineBase).PipelineCache, renderPass.Value, throwOnError: true);
            pipeline.Dispose();
        }

        public ProgramLinkStatus CheckProgramLink(bool blocking)
        {
            if (LinkStatus == ProgramLinkStatus.Incomplete)
            {
                ProgramLinkStatus resultStatus = ProgramLinkStatus.Success;

                foreach (Shader shader in _shaders)
                {
                    if (shader.CompileStatus == ProgramLinkStatus.Incomplete)
                    {
                        if (blocking)
                        {
                            // Wait for this shader to finish compiling; the owner keeps
                            // servicing the window lease/stop events while the single
                            // compile lane runs the driver call.
                            shader.WaitForCompile(_gd.S2AWaitPump);

                            if (shader.CompileStatus != ProgramLinkStatus.Success)
                            {
                                resultStatus = ProgramLinkStatus.Failure;
                            }
                        }
                        else
                        {
                            return ProgramLinkStatus.Incomplete;
                        }
                    }
                }

                if (!_compileTask.IsCompleted)
                {
                    if (blocking)
                    {
                        _gd.S2AWaitForTask(_compileTask);

                        if (LinkStatus == ProgramLinkStatus.Failure)
                        {
                            return ProgramLinkStatus.Failure;
                        }
                    }
                    else
                    {
                        return ProgramLinkStatus.Incomplete;
                    }
                }

                return resultStatus;
            }

            return LinkStatus;
        }

        public byte[] GetBinary()
        {
            // GLSL-only backends and minimal/helper layouts are outside VKPB v1. Returning
            // null keeps the existing "not persisted" behavior instead of writing empty bytes.
            if (!_s2aCanSave)
            {
                return null;
            }

            byte[] binary = _s2aBinary;
            if (binary != null)
            {
                return binary;
            }

            ProgramBinaryStageSpecialization[] specializations = new ProgramBinaryStageSpecialization[_s2aSources.Length];
            for (int i = 0; i < specializations.Length; i++)
            {
                specializations[i] = new ProgramBinaryStageSpecialization(
                    Array.Empty<ProgramBinarySpecializationEntry>(), Array.Empty<byte>());
            }

            ShaderInfo info = _s2aHasState
                ? new ShaderInfo(0, _s2aLayout, _s2aState)
                : new ShaderInfo(0, _s2aLayout);

            ProgramBinary recipe = new(
                _gd.S2AProgramBinaryIdentity,
                new ProgramBinaryOptions(false, false, false),
                _s2aSources,
                info,
                specializations);

            if (!ProgramBinaryCodec.TryEncode(recipe, out binary, out string error))
            {
                // A legal program may still be outside VKPB v1's persisted stage set (for
                // example a vertex-only pipeline). Keep running it and do not poison the
                // background cache writer with an exception.
                _s2aCanSave = false;
                Console.Error.WriteLine($"[vkpb] 程序不写入记录（{error}）");
                return null;
            }

            _s2aBinary = binary;
            return binary;
        }

        public DescriptorSetTemplate GetPushDescriptorTemplate(long updateMask)
        {
            return _plce.GetPushDescriptorTemplate(IsCompute ? PipelineBindPoint.Compute : PipelineBindPoint.Graphics, updateMask);
        }

        public void AddComputePipeline(ref SpecData key, Auto<DisposablePipeline> pipeline)
        {
            (_computePipelineCache ??= new()).Add(ref key, pipeline);
        }

        public void AddGraphicsPipeline(ref PipelineUid key, Auto<DisposablePipeline> pipeline)
        {
            (_graphicsPipelineCache ??= new()).Add(ref key, pipeline);
        }

        public bool TryGetComputePipeline(ref SpecData key, out Auto<DisposablePipeline> pipeline)
        {
            if (_computePipelineCache == null)
            {
                pipeline = default;
                return false;
            }

            if (_computePipelineCache.TryGetValue(ref key, out pipeline))
            {
                return true;
            }

            return false;
        }

        /// <summary>
        /// S2A：加载屏预热用。等待本程序的 BackgroundCompilation 完成（管线已进 _graphicsPipelineCache）；
        /// 等待期间交给编译通道边等边泵宿主事件，超时/失败返回 false，不把加载屏无限卡住。
        /// </summary>
        public bool S2AWaitForBackgroundPipeline(int timeoutMs)
        {
            if (timeoutMs <= 0)
            {
                return false;
            }

            return _gd.S2AWaitForTask(_compileTask, timeoutMs);
        }

        public bool TryGetGraphicsPipeline(ref PipelineUid key, out Auto<DisposablePipeline> pipeline)
        {
            if (_graphicsPipelineCache == null)
            {
                pipeline = default;
                return false;
            }

            if (!_graphicsPipelineCache.TryGetValue(ref key, out pipeline))
            {
                if (_firstBackgroundUse)
                {
                    Logger.Warning?.Print(LogClass.Gpu, "Background pipeline compile missed on draw - incorrect pipeline state?");
                    _firstBackgroundUse = false;
                }

                return false;
            }

            _firstBackgroundUse = false;

            return true;
        }

        public void UpdateDescriptorCacheCommandBufferIndex(int commandBufferIndex)
        {
            _plce.UpdateCommandBufferIndex(commandBufferIndex);
        }

        public Auto<DescriptorSetCollection> GetNewDescriptorSetCollection(int setIndex, out bool isNew)
        {
            return _plce.GetNewDescriptorSetCollection(setIndex, out isNew);
        }

        public Auto<DescriptorSetCollection> GetNewManualDescriptorSetCollection(CommandBufferScoped cbs, int setIndex, out int cacheIndex)
        {
            return _plce.GetNewManualDescriptorSetCollection(cbs, setIndex, out cacheIndex);
        }

        public void UpdateManualDescriptorSetCollectionOwnership(CommandBufferScoped cbs, int setIndex, int cacheIndex)
        {
            _plce.UpdateManualDescriptorSetCollectionOwnership(cbs, setIndex, cacheIndex);
        }

        public void ReleaseManualDescriptorSetCollection(int setIndex, int cacheIndex)
        {
            _plce.ReleaseManualDescriptorSetCollection(setIndex, cacheIndex);
        }

        public bool HasSameLayout(ShaderCollection other)
        {
            return other != null && _plce == other._plce;
        }

        protected virtual void Dispose(bool disposing)
        {
            if (disposing && !_s2aDisposed)
            {
                _s2aDisposed = true;

                // S2A（F1）：段由最后一个引用它的命令缓冲完成时归还（期间仍会按完成读计数）
                S2AOobRegion?.Release();

                // Active module/pipeline jobs own the VkShaderModule and pipelines. A partial
                // VTG load can dispose a valid part before its background job finishes; wait
                // for that job first. A timed-out driver call retains the objects (leak) and
                // the host stop policy terminates; never destroy a module under a running job.
                bool quiesced = true;
                try
                {
                    _gd.S2AWaitForTask(_compileTask);
                }
                catch (TimeoutException)
                {
                    quiesced = false;
                }
                catch (Exception)
                {
                    // Canceled/faulted module or pipeline task: the worker has already joined
                    // or the task completed before it could touch the module.
                }

                if (quiesced)
                {
                    foreach (Shader shader in _shaders)
                    {
                        try
                        {
                            shader.WaitForCompile(_gd.S2AWaitPump);
                        }
                        catch (TimeoutException)
                        {
                            quiesced = false;
                            break;
                        }
                        catch (Exception)
                        {
                        }
                    }
                }

                if (!quiesced)
                {
                    Console.Error.WriteLine("[vkpb] 程序编译未在期限内退出，保留顶点/管线对象交宿主终止");
                    return;
                }

                if (!_gd.Shaders.Remove(this))
                {
                    return;
                }

                for (int i = 0; i < _shaders.Length; i++)
                {
                    _shaders[i].Dispose();
                }

                if (_graphicsPipelineCache != null)
                {
                    foreach (Auto<DisposablePipeline> pipeline in _graphicsPipelineCache.Values)
                    {
                        pipeline?.Dispose();
                    }
                }

                if (_computePipelineCache != null)
                {
                    foreach (Auto<DisposablePipeline> pipeline in _computePipelineCache.Values)
                    {
                        pipeline.Dispose();
                    }
                }

                for (int i = 0; i < Templates.Length; i++)
                {
                    Templates[i]?.Dispose();
                }

                if (_dummyRenderPass.Value.Handle != 0)
                {
                    _dummyRenderPass.Dispose();
                }
            }
        }

        public void Dispose()
        {
            Dispose(true);
        }
    }
}
