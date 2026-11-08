using Ryujinx.Common.Memory;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Shader;
using Silk.NET.Vulkan;
using System;
using System.Collections.Generic;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using System.Threading;
using Buffer = Silk.NET.Vulkan.Buffer;
using CompareOp = Ryujinx.Graphics.GAL.CompareOp;
using Format = Ryujinx.Graphics.GAL.Format;
using SamplerCreateInfo = Ryujinx.Graphics.GAL.SamplerCreateInfo;
using VkFormat = Silk.NET.Vulkan.Format;

namespace Ryujinx.Graphics.Vulkan
{
    class DescriptorSetUpdater
    {
        private const ulong StorageBufferMaxMirrorable = 0x2000;
        private const int S2ANullImageFallbackLogLines = 8;
        private static int _s2aNullImageFallbackLogs;

        // S2A：无 nullDescriptor 时把空 texel buffer view 写进描述符违反 VUID-VkWriteDescriptorSet-descriptorType-02995
        //   （模板路径对应 VUID-vkUpdateDescriptorSetWithTemplate-pData-01685）；Mali r32p1 在
        //   vkUpdateDescriptorSetWithTemplate 内解引用该句柄 → NULL+0x20 SIGSEGV（#1456 规避后 9000 崩因）。
        //   转计算保留 34 个 buffer texture 槽、RunVertex 只填 17 个，首个转计算 draw 必命中。
        //   与下方 null storage image 回退同口径：换 R32_UINT dummy view、计数、报黄、收局汇总。
        private const int S2ADummyTexelBufferSize = 16;
        private const int S2ANullTexelFallbackLogLines = 8;
        private static int _s2aNullTexelFallbackLogs;
        private Auto<DisposableBufferView> _dummyBufferView;

        // S2A（F1）：存储缓冲集合的绑定号上限要装下越界记录绑定（在各阶段 5 × 16 与保留绑定之上）
        private const int StorageBufferBindings = S2AStorageOobRecord.Binding + 1;

        private const int ArrayGrowthSize = 16;

        private record struct BufferRef
        {
            public Auto<DisposableBuffer> Buffer;
            public int Offset;
            public bool Write;

            public BufferRef(Auto<DisposableBuffer> buffer)
            {
                Buffer = buffer;
                Offset = 0;
                Write = true;
            }

            public BufferRef(Auto<DisposableBuffer> buffer, ref BufferRange range)
            {
                Buffer = buffer;
                Offset = range.Offset;
                Write = range.Write;
            }
        }

        private record struct TextureRef
        {
            public ShaderStage Stage;
            public TextureView View;
            public Auto<DisposableImageView> ImageView;
            public Auto<DisposableSampler> Sampler;

            public TextureRef(ShaderStage stage, TextureView view, Auto<DisposableImageView> imageView, Auto<DisposableSampler> sampler)
            {
                Stage = stage;
                View = view;
                ImageView = imageView;
                Sampler = sampler;
            }
        }

        private record struct ImageRef
        {
            public ShaderStage Stage;
            public TextureView View;
            public Auto<DisposableImageView> ImageView;

            public ImageRef(ShaderStage stage, TextureView view, Auto<DisposableImageView> imageView)
            {
                Stage = stage;
                View = view;
                ImageView = imageView;
            }
        }

        private readonly record struct ArrayRef<T>(ShaderStage Stage, T Array);

        private readonly VulkanRenderer _gd;
        private readonly Device _device;
        private ShaderCollection _program;

        private readonly BufferRef[] _uniformBufferRefs;
        private readonly BufferRef[] _storageBufferRefs;
        private readonly TextureRef[] _textureRefs;
        private readonly ImageRef[] _imageRefs;
        private readonly TextureBuffer[] _bufferTextureRefs;
        private readonly TextureBuffer[] _bufferImageRefs;

        private ArrayRef<TextureArray>[] _textureArrayRefs;
        private ArrayRef<ImageArray>[] _imageArrayRefs;

        private ArrayRef<TextureArray>[] _textureArrayExtraRefs;
        private ArrayRef<ImageArray>[] _imageArrayExtraRefs;

        private readonly DescriptorBufferInfo[] _uniformBuffers;
        private readonly DescriptorBufferInfo[] _storageBuffers;
        private readonly DescriptorImageInfo[] _textures;
        private readonly DescriptorImageInfo[] _images;
        private readonly BufferView[] _bufferTextures;
        private readonly BufferView[] _bufferImages;

        private readonly DescriptorSetTemplateUpdater _templateUpdater;

        private BitMapStruct<Array2<long>> _uniformSet;
        private BitMapStruct<Array2<long>> _storageSet;
        private BitMapStruct<Array2<long>> _uniformMirrored;
        private BitMapStruct<Array2<long>> _storageMirrored;
        private readonly int[] _uniformSetPd;
        private int _pdSequence = 1;

        private bool _updateDescriptorCacheCbIndex;

        [Flags]
        private enum DirtyFlags
        {
            None = 0,
            Uniform = 1 << 0,
            Storage = 1 << 1,
            Texture = 1 << 2,
            Image = 1 << 3,
            All = Uniform | Storage | Texture | Image,
        }

        private DirtyFlags _dirty;

        private readonly BufferHolder _dummyBuffer;
        private BufferHolder _emptyUniformDummyBuffer;
        private readonly TextureView _dummyTexture;
        private readonly SamplerHolder _dummySampler;

        public List<TextureView> FeedbackLoopHazards { get; private set; }

        public DescriptorSetUpdater(VulkanRenderer gd, Device device)
        {
            _gd = gd;
            _device = device;

            // Some of the bindings counts needs to be multiplied by 2 because we have buffer and
            // regular textures/images interleaved on the same descriptor set.

            _uniformBufferRefs = new BufferRef[Constants.MaxUniformBufferBindings];
            _storageBufferRefs = new BufferRef[StorageBufferBindings];
            _textureRefs = new TextureRef[Constants.MaxTextureBindings * 2 + Constants.ReservedTextureBindings];
            _imageRefs = new ImageRef[Constants.MaxImageBindings * 2];
            _bufferTextureRefs = new TextureBuffer[Constants.MaxTextureBindings * 2 + Constants.ReservedTextureBindings];
            _bufferImageRefs = new TextureBuffer[Constants.MaxImageBindings * 2];

            _textureArrayRefs = [];
            _imageArrayRefs = [];

            _textureArrayExtraRefs = [];
            _imageArrayExtraRefs = [];

            _uniformBuffers = new DescriptorBufferInfo[Constants.MaxUniformBufferBindings];
            _storageBuffers = new DescriptorBufferInfo[StorageBufferBindings];
            _textures = new DescriptorImageInfo[Constants.MaxTexturesPerStage];
            _images = new DescriptorImageInfo[Constants.MaxImagesPerStage];
            _bufferTextures = new BufferView[Constants.MaxTexturesPerStage];
            _bufferImages = new BufferView[Constants.MaxImagesPerStage];

            _uniformSetPd = new int[Constants.MaxUniformBufferBindings];

            DescriptorImageInfo initialImageInfo = new()
            {
                ImageLayout = ImageLayout.General,
            };

            _textures.AsSpan().Fill(initialImageInfo);
            _images.AsSpan().Fill(initialImageInfo);

            if (gd.Capabilities.SupportsNullDescriptors)
            {
                // If null descriptors are supported, we can pass null as the handle.
                _dummyBuffer = null;
            }
            else
            {
                // If null descriptors are not supported, we need to pass the handle of a dummy buffer on unused bindings.
                _dummyBuffer = gd.BufferManager.Create(gd, 0x10000, forConditionalRendering: false, baseType: BufferAllocationType.DeviceLocal);
            }

            _dummyTexture = gd.CreateTextureView(new TextureCreateInfo(
                1,
                1,
                1,
                1,
                1,
                1,
                1,
                4,
                Format.R8G8B8A8Unorm,
                DepthStencilMode.Depth,
                Target.Texture2D,
                SwizzleComponent.Red,
                SwizzleComponent.Green,
                SwizzleComponent.Blue,
                SwizzleComponent.Alpha));

            _dummySampler = (SamplerHolder)gd.CreateSampler(new SamplerCreateInfo(
                MinFilter.Nearest,
                MagFilter.Nearest,
                false,
                AddressMode.Repeat,
                AddressMode.Repeat,
                AddressMode.Repeat,
                CompareMode.None,
                CompareOp.Always,
                new ColorF(0, 0, 0, 0),
                0,
                0,
                0,
                1f));

            _templateUpdater = new();
        }

        public void Initialize(bool isMainPipeline)
        {
            MemoryOwner<byte> dummyTextureData = MemoryOwner<byte>.RentCleared(4);
            _dummyTexture.SetData(dummyTextureData);

            if (isMainPipeline)
            {
                FeedbackLoopHazards = [];
            }
        }

        private static bool BindingOverlaps(ref DescriptorBufferInfo info, int bindingOffset, int offset, int size)
        {
            return offset < bindingOffset + (int)info.Range && (offset + size) > bindingOffset;
        }

        private readonly struct BufferRebindListener : IBitMapListener
        {
            private readonly DescriptorSetUpdater _owner;
            private readonly Auto<DisposableBuffer> _buffer;
            private readonly int _offset;
            private readonly int _size;
            private readonly bool _storage;

            public BufferRebindListener(DescriptorSetUpdater owner, Auto<DisposableBuffer> buffer, int offset, int size, bool storage)
            {
                _owner = owner;
                _buffer = buffer;
                _offset = offset;
                _size = size;
                _storage = storage;
            }

            public void BitMapSignal(int binding, int count)
            {
                BufferRef[] refs = _storage ? _owner._storageBufferRefs : _owner._uniformBufferRefs;
                DescriptorBufferInfo[] infos = _storage ? _owner._storageBuffers : _owner._uniformBuffers;

                for (int i = 0; i < count; i++)
                {
                    ref BufferRef bufferRef = ref refs[binding];
                    if (bufferRef.Buffer == _buffer)
                    {
                        ref DescriptorBufferInfo info = ref infos[binding];
                        int bindingOffset = bufferRef.Offset;

                        if (BindingOverlaps(ref info, bindingOffset, _offset, _size))
                        {
                            if (_storage)
                            {
                                _owner._storageSet.Clear(binding);
                                _owner.SignalDirty(DirtyFlags.Storage);
                            }
                            else
                            {
                                _owner._uniformSet.Clear(binding);
                                _owner._uniformSetPd[binding] = 0;
                                _owner.SignalDirty(DirtyFlags.Uniform);
                            }
                        }
                    }

                    binding++;
                }
            }
        }

        internal void Rebind(Auto<DisposableBuffer> buffer, int offset, int size)
        {
            if (_program == null)
            {
                return;
            }

            BufferRebindListener uniform = new(this, buffer, offset, size, storage: false);
            _uniformMirrored.Union(_uniformSet).SignalSet(ref uniform);

            BufferRebindListener storage = new(this, buffer, offset, size, storage: true);
            _storageMirrored.Union(_storageSet).SignalSet(ref storage);
        }

        public void InsertBindingBarriers(CommandBufferScoped cbs)
        {
            if ((FeedbackLoopHazards?.Count ?? 0) > 0)
            {
                // Clear existing hazards - they will be rebuilt.

                foreach (TextureView hazard in FeedbackLoopHazards)
                {
                    hazard.DecrementHazardUses();
                }

                FeedbackLoopHazards.Clear();
            }

            foreach (ResourceBindingSegment segment in _program.BindingSegments[PipelineBase.TextureSetIndex])
            {
                if (segment.Type == ResourceType.TextureAndSampler)
                {
                    if (!segment.IsArray)
                    {
                        for (int i = 0; i < segment.Count; i++)
                        {
                            ref TextureRef texture = ref _textureRefs[segment.Binding + i];
                            texture.View?.PrepareForUsage(cbs, texture.Stage.ConvertToPipelineStageFlags(), FeedbackLoopHazards);
                        }
                    }
                    else
                    {
                        ref ArrayRef<TextureArray> arrayRef = ref _textureArrayRefs[segment.Binding];
                        PipelineStageFlags stageFlags = arrayRef.Stage.ConvertToPipelineStageFlags();
                        arrayRef.Array?.QueueWriteToReadBarriers(cbs, stageFlags);
                    }
                }
            }

            foreach (ResourceBindingSegment segment in _program.BindingSegments[PipelineBase.ImageSetIndex])
            {
                if (segment.Type == ResourceType.Image)
                {
                    if (!segment.IsArray)
                    {
                        for (int i = 0; i < segment.Count; i++)
                        {
                            ref ImageRef image = ref _imageRefs[segment.Binding + i];
                            image.View?.PrepareForUsage(cbs, image.Stage.ConvertToPipelineStageFlags(), FeedbackLoopHazards);
                        }
                    }
                    else
                    {
                        ref ArrayRef<ImageArray> arrayRef = ref _imageArrayRefs[segment.Binding];
                        PipelineStageFlags stageFlags = arrayRef.Stage.ConvertToPipelineStageFlags();
                        arrayRef.Array?.QueueWriteToReadBarriers(cbs, stageFlags);
                    }
                }
            }

            for (int setIndex = PipelineBase.DescriptorSetLayouts; setIndex < _program.BindingSegments.Length; setIndex++)
            {
                ResourceBindingSegment[] bindingSegments = _program.BindingSegments[setIndex];

                if (bindingSegments.Length == 0)
                {
                    continue;
                }

                ResourceBindingSegment segment = bindingSegments[0];

                if (segment.IsArray)
                {
                    if (segment.Type is ResourceType.Texture or
                        ResourceType.Sampler or
                        ResourceType.TextureAndSampler or
                        ResourceType.BufferTexture)
                    {
                        ref ArrayRef<TextureArray> arrayRef = ref _textureArrayExtraRefs[setIndex - PipelineBase.DescriptorSetLayouts];
                        PipelineStageFlags stageFlags = arrayRef.Stage.ConvertToPipelineStageFlags();
                        arrayRef.Array?.QueueWriteToReadBarriers(cbs, stageFlags);
                    }
                    else if (segment.Type is ResourceType.Image or ResourceType.BufferImage)
                    {
                        ref ArrayRef<ImageArray> arrayRef = ref _imageArrayExtraRefs[setIndex - PipelineBase.DescriptorSetLayouts];
                        PipelineStageFlags stageFlags = arrayRef.Stage.ConvertToPipelineStageFlags();
                        arrayRef.Array?.QueueWriteToReadBarriers(cbs, stageFlags);
                    }
                }
            }
        }

        public void AdvancePdSequence()
        {
            if (++_pdSequence == 0)
            {
                _pdSequence = 1;
            }
        }

        public void SetProgram(CommandBufferScoped cbs, ShaderCollection program, bool isBound)
        {
            if (!program.HasSameLayout(_program))
            {
                // When the pipeline layout changes, push descriptor bindings are invalidated.

                AdvancePdSequence();
            }

            _program = program;
            _updateDescriptorCacheCbIndex = true;
            _dirty = DirtyFlags.All;

            SetS2AOobRecord(program.S2AOobRegion);
        }

        // S2A（F1）：越界记录绑定指向本程序的记录段（Gpu 层不绑它）。只有布局里有记录绑定的程序才有段（分不到自己的段时
        //   是记录器的共用丢弃段，见 S2AStorageOobRecorder.Discard），没有段的程序布局里没有这个绑定，原值不会被它读写。
        private void SetS2AOobRecord(S2AStorageOobRegion region)
        {
            if (region == null)
            {
                return;
            }

            const int Binding = S2AStorageOobRecord.Binding;

            BufferRef newRef = new(region.Buffer) { Offset = region.Offset };
            ref BufferRef currentRef = ref _storageBufferRefs[Binding];

            if (!currentRef.Equals(newRef))
            {
                currentRef = newRef;
                _storageBuffers[Binding] = new DescriptorBufferInfo
                {
                    Offset = (ulong)region.Offset,
                    Range = (ulong)region.Size,
                };
                _storageSet.Clear(Binding);
            }
        }

        public void SetImage(CommandBufferScoped cbs, ShaderStage stage, int binding, ITexture image)
        {
            if (image is TextureBuffer imageBuffer)
            {
                _bufferImageRefs[binding] = imageBuffer;
            }
            else if (image is TextureView view)
            {
                ref ImageRef iRef = ref _imageRefs[binding];

                iRef.View?.ClearUsage(FeedbackLoopHazards);
                view?.PrepareForUsage(cbs, stage.ConvertToPipelineStageFlags(), FeedbackLoopHazards);

                iRef = new(stage, view, view.GetIdentityImageView());
            }
            else
            {
                _imageRefs[binding] = default;
                _bufferImageRefs[binding] = null;
            }

            SignalDirty(DirtyFlags.Image);
        }

        public void SetImage(int binding, Auto<DisposableImageView> image)
        {
            _imageRefs[binding] = new(ShaderStage.Compute, null, image);

            SignalDirty(DirtyFlags.Image);
        }

        public void SetStorageBuffers(CommandBuffer commandBuffer, ReadOnlySpan<BufferAssignment> buffers)
        {
            for (int i = 0; i < buffers.Length; i++)
            {
                BufferAssignment assignment = buffers[i];
                BufferRange buffer = assignment.Range;
                int index = assignment.Binding;

                Auto<DisposableBuffer> vkBuffer = buffer.Handle == BufferHandle.Null
                    ? null
                    : _gd.BufferManager.GetBuffer(commandBuffer, buffer.Handle, buffer.Write, isSSBO: true);

                ref BufferRef currentBufferRef = ref _storageBufferRefs[index];

                DescriptorBufferInfo info = new()
                {
                    Offset = (ulong)buffer.Offset,
                    Range = (ulong)buffer.Size,
                };

                BufferRef newRef = new(vkBuffer, ref buffer);

                ref DescriptorBufferInfo currentInfo = ref _storageBuffers[index];

                if (!currentBufferRef.Equals(newRef) || currentInfo.Range != info.Range)
                {
                    _storageSet.Clear(index);

                    currentInfo = info;
                    currentBufferRef = newRef;
                }
            }

            SignalDirty(DirtyFlags.Storage);
        }

        public void SetStorageBuffers(CommandBuffer commandBuffer, int first, ReadOnlySpan<Auto<DisposableBuffer>> buffers)
        {
            for (int i = 0; i < buffers.Length; i++)
            {
                Auto<DisposableBuffer> vkBuffer = buffers[i];
                int index = first + i;

                ref BufferRef currentBufferRef = ref _storageBufferRefs[index];

                DescriptorBufferInfo info = new()
                {
                    Offset = 0,
                    Range = Vk.WholeSize,
                };

                BufferRef newRef = new(vkBuffer);

                ref DescriptorBufferInfo currentInfo = ref _storageBuffers[index];

                if (!currentBufferRef.Equals(newRef) || currentInfo.Range != info.Range)
                {
                    _storageSet.Clear(index);

                    currentInfo = info;
                    currentBufferRef = newRef;
                }
            }

            SignalDirty(DirtyFlags.Storage);
        }

        public void SetTextureAndSampler(
            CommandBufferScoped cbs,
            ShaderStage stage,
            int binding,
            ITexture texture,
            ISampler sampler)
        {
            if (texture is TextureBuffer textureBuffer)
            {
                _bufferTextureRefs[binding] = textureBuffer;
            }
            else if (texture is TextureView view)
            {
                ref TextureRef iRef = ref _textureRefs[binding];

                iRef.View?.ClearUsage(FeedbackLoopHazards);
                view?.PrepareForUsage(cbs, stage.ConvertToPipelineStageFlags(), FeedbackLoopHazards);

                iRef = new(stage, view, view.GetImageView(), ((SamplerHolder)sampler)?.SelectSampler(view));
            }
            else
            {
                _textureRefs[binding] = default;
                _bufferTextureRefs[binding] = null;
            }

            SignalDirty(DirtyFlags.Texture);
        }

        public void SetTextureAndSamplerIdentitySwizzle(
            CommandBufferScoped cbs,
            ShaderStage stage,
            int binding,
            ITexture texture,
            ISampler sampler)
        {
            if (texture is TextureView view)
            {
                view.Storage.QueueWriteToReadBarrier(cbs, AccessFlags.ShaderReadBit, stage.ConvertToPipelineStageFlags());

                _textureRefs[binding] = new(stage, view, view.GetIdentityImageView(), ((SamplerHolder)sampler)?.SelectSampler(view));

                SignalDirty(DirtyFlags.Texture);
            }
            else
            {
                SetTextureAndSampler(cbs, stage, binding, texture, sampler);
            }
        }

        public void SetTextureArray(CommandBufferScoped cbs, ShaderStage stage, int binding, ITextureArray array)
        {
            ref ArrayRef<TextureArray> arrayRef = ref GetArrayRef(ref _textureArrayRefs, binding, ArrayGrowthSize);

            if (arrayRef.Stage != stage || arrayRef.Array != array)
            {
                arrayRef.Array?.DecrementBindCount();

                if (array is TextureArray textureArray)
                {
                    textureArray.IncrementBindCount();
                    textureArray.QueueWriteToReadBarriers(cbs, stage.ConvertToPipelineStageFlags());
                }

                arrayRef = new ArrayRef<TextureArray>(stage, array as TextureArray);

                SignalDirty(DirtyFlags.Texture);
            }
        }

        public void SetTextureArraySeparate(CommandBufferScoped cbs, ShaderStage stage, int setIndex, ITextureArray array)
        {
            ref ArrayRef<TextureArray> arrayRef = ref GetArrayRef(ref _textureArrayExtraRefs, setIndex - PipelineBase.DescriptorSetLayouts);

            if (arrayRef.Stage != stage || arrayRef.Array != array)
            {
                arrayRef.Array?.DecrementBindCount();

                if (array is TextureArray textureArray)
                {
                    textureArray.IncrementBindCount();
                    textureArray.QueueWriteToReadBarriers(cbs, stage.ConvertToPipelineStageFlags());
                }

                arrayRef = new ArrayRef<TextureArray>(stage, array as TextureArray);

                SignalDirty(DirtyFlags.Texture);
            }
        }

        public void SetImageArray(CommandBufferScoped cbs, ShaderStage stage, int binding, IImageArray array)
        {
            ref ArrayRef<ImageArray> arrayRef = ref GetArrayRef(ref _imageArrayRefs, binding, ArrayGrowthSize);

            if (arrayRef.Stage != stage || arrayRef.Array != array)
            {
                arrayRef.Array?.DecrementBindCount();

                if (array is ImageArray imageArray)
                {
                    imageArray.IncrementBindCount();
                    imageArray.QueueWriteToReadBarriers(cbs, stage.ConvertToPipelineStageFlags());
                }

                arrayRef = new ArrayRef<ImageArray>(stage, array as ImageArray);

                SignalDirty(DirtyFlags.Image);
            }
        }

        public void SetImageArraySeparate(CommandBufferScoped cbs, ShaderStage stage, int setIndex, IImageArray array)
        {
            ref ArrayRef<ImageArray> arrayRef = ref GetArrayRef(ref _imageArrayExtraRefs, setIndex - PipelineBase.DescriptorSetLayouts);

            if (arrayRef.Stage != stage || arrayRef.Array != array)
            {
                arrayRef.Array?.DecrementBindCount();

                if (array is ImageArray imageArray)
                {
                    imageArray.IncrementBindCount();
                    imageArray.QueueWriteToReadBarriers(cbs, stage.ConvertToPipelineStageFlags());
                }

                arrayRef = new ArrayRef<ImageArray>(stage, array as ImageArray);

                SignalDirty(DirtyFlags.Image);
            }
        }

        private static ref ArrayRef<T> GetArrayRef<T>(ref ArrayRef<T>[] array, int index, int growthSize = 1)
        {
            ArgumentOutOfRangeException.ThrowIfNegative(index);

            if (array.Length <= index)
            {
                Array.Resize(ref array, index + growthSize);
            }

            return ref array[index];
        }

        public void SetUniformBuffers(CommandBuffer commandBuffer, ReadOnlySpan<BufferAssignment> buffers)
        {
            for (int i = 0; i < buffers.Length; i++)
            {
                BufferAssignment assignment = buffers[i];
                BufferRange buffer = assignment.Range;
                int index = assignment.Binding;

                Auto<DisposableBuffer> vkBuffer = buffer.Handle == BufferHandle.Null
                    ? null
                    : _gd.BufferManager.GetBuffer(commandBuffer, buffer.Handle, false);

                ref BufferRef currentBufferRef = ref _uniformBufferRefs[index];

                DescriptorBufferInfo info = new()
                {
                    Offset = (ulong)buffer.Offset,
                    Range = (ulong)buffer.Size,
                };

                BufferRef newRef = new(vkBuffer, ref buffer);

                ref DescriptorBufferInfo currentInfo = ref _uniformBuffers[index];

                if (!currentBufferRef.Equals(newRef) || currentInfo.Range != info.Range)
                {
                    _uniformSet.Clear(index);
                    _uniformSetPd[index] = 0;

                    currentInfo = info;
                    currentBufferRef = newRef;
                }
            }

            SignalDirty(DirtyFlags.Uniform);
        }

        private void SignalDirty(DirtyFlags flag)
        {
            _dirty |= flag;
        }

        public void UpdateAndBindDescriptorSets(CommandBufferScoped cbs, PipelineBindPoint pbp)
        {
            if ((_dirty & DirtyFlags.All) == 0)
            {
                return;
            }

            ShaderCollection program = _program;

            // S2A（F1）：本命令缓冲用到这个程序，它的越界记录段在命令缓冲完成时读回
            program.S2AOobRegion?.Use(cbs);

            if ((_dirty & DirtyFlags.Uniform) == DirtyFlags.Uniform)
            {
                if (program.UsePushDescriptors)
                {
                    UpdateAndBindUniformBufferPd(cbs);
                }
                else
                {
                    UpdateAndBind(cbs, program, PipelineBase.UniformSetIndex, pbp);
                }
            }

            if ((_dirty & DirtyFlags.Storage) == DirtyFlags.Storage)
            {
                UpdateAndBind(cbs, program, PipelineBase.StorageSetIndex, pbp);
            }

            if ((_dirty & DirtyFlags.Texture) == DirtyFlags.Texture)
            {
                if (program.UpdateTexturesWithoutTemplate)
                {
                    UpdateAndBindTexturesWithoutTemplate(cbs, program, pbp);
                }
                else
                {
                    UpdateAndBind(cbs, program, PipelineBase.TextureSetIndex, pbp);
                }
            }

            if ((_dirty & DirtyFlags.Image) == DirtyFlags.Image)
            {
                UpdateAndBind(cbs, program, PipelineBase.ImageSetIndex, pbp);
            }

            if (program.BindingSegments.Length > PipelineBase.DescriptorSetLayouts)
            {
                // Program is using extra sets, we need to bind those too.

                BindExtraSets(cbs, program, pbp);
            }

            _dirty = DirtyFlags.None;
        }

        // S2A：着色器声明的常量缓冲大小（Maxwell cbuffer 恒 64KiB；Shader.Constants 是 Shader 程序集内部常量）。
        private const ulong ShaderCBufferDeclaredSize = 0x10000;

        // S2A（VUID-00332）：UBO 描述符 range 按设备 maxUniformBufferRange 钳制。
        //   VK_WHOLE_SIZE 先按解析出的后备缓冲 (bufferSize - offset) 展开；显式 range 也不许越过缓冲末端。
        //   展开后再收到 maxRange 内。insufficient：钳后范围盖不住 min(请求, 着色器声明常量缓冲 64KiB)，
        //   说明设备上限低于着色器实际可访问范围 —— 不静默截断，调用方按绑定报红。
        internal static ulong ClampBufferRange(ulong requestedRange, long bufferSize, long offset, ulong maxRange, out bool insufficient)
        {
            ulong bound = bufferSize > offset && offset >= 0 ? (ulong)(bufferSize - offset) : 0;
            ulong wanted = requestedRange == Vk.WholeSize ? bound : Math.Min(requestedRange, bound);
            ulong clamped = Math.Min(wanted, maxRange);

            insufficient = clamped < Math.Min(wanted, ShaderCBufferDeclaredSize);

            return clamped;
        }

        internal static void ClampAndReportUniformBufferRange(ref DescriptorBufferInfo info, long bufferSize, ulong maxRange, VulkanRenderer gd)
        {
            ulong requestedRange = info.Range;
            info.Range = ClampBufferRange(requestedRange, bufferSize, (long)info.Offset, maxRange, out bool insufficient);
            if (insufficient)
            {
                if (gd.S2ANoteUniformBufferRangeError() == 1)
                {
                    Ryujinx.Common.Logging.Logger.Error?.Print(Ryujinx.Common.Logging.LogClass.Gpu,
                        $"【红】Uniform buffer descriptor range {requestedRange} exceeds device maxUniformBufferRange {maxRange} " +
                        $"(buffer size {bufferSize}, offset {info.Offset}); clamped below shader-declared constant buffer size.");
                }
            }
        }

        internal static bool UniformRangeNeedsDummy(long bufferSize, long offset, ulong range) =>
            offset < 0 || offset >= bufferSize || range == 0;

        // 越界或空范围不能写入 Vulkan 描述符；使用合法的 dummy 窗口。
        internal static void BindEmptyUniformDummy(ref DescriptorBufferInfo info, Buffer dummy, long dummySize, ulong maxRange)
        {
            info.Buffer = dummy;
            info.Offset = 0;
            info.Range = Math.Min((ulong)dummySize, maxRange);
        }

        private void BindEmptyUniformDummy(CommandBufferScoped cbs, ref DescriptorBufferInfo info, ulong maxRange)
        {
            // 支持 null descriptor 的设备平常不建 dummy；此处按需建一个并由 updater 释放。
            _emptyUniformDummyBuffer ??= _dummyBuffer ?? _gd.BufferManager.Create(_gd, 0x10000, forConditionalRendering: false, baseType: BufferAllocationType.DeviceLocal);
            DisposableBuffer dummy = _emptyUniformDummyBuffer.GetBuffer().Get(cbs);
            BindEmptyUniformDummy(ref info, dummy.Value, dummy.Size, maxRange);
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        private bool UpdateBuffer(
            CommandBufferScoped cbs,
            ref DescriptorBufferInfo info,
            ref BufferRef buffer,
            Auto<DisposableBuffer> dummyBuffer,
            bool mirrorable,
            ulong maxRange)
        {
            int offset = buffer.Offset;
            bool mirrored = false;
            DisposableBuffer? resolved;

            // 先排除越界，避免 mirror/使用跟踪在无效范围上运行。
            if (maxRange != 0 && buffer.Buffer != null && UniformRangeNeedsDummy(buffer.Buffer.GetUnsafe().Size, offset, info.Range))
            {
                BindEmptyUniformDummy(cbs, ref info, maxRange);
                return false;
            }

            if (mirrorable)
            {
                resolved = buffer.Buffer?.GetMirrorable(cbs, ref offset, (int)info.Range, out mirrored);
            }
            else
            {
                resolved = buffer.Buffer?.Get(cbs, offset, (int)info.Range, buffer.Write);
            }

            info.Buffer = resolved?.Value ?? default;
            info.Offset = (ulong)offset;

            // The spec requires that buffers with null handle have offset as 0 and range as VK_WHOLE_SIZE.
            if (info.Buffer.Handle == 0)
            {
                resolved = dummyBuffer?.Get(cbs);
                info.Buffer = resolved?.Value ?? default;
                info.Offset = 0;
                info.Range = Vk.WholeSize;
            }

            // S2A（VUID-00332）：range 收进设备上限；仍盖不住着色器声明范围时报红（不静默截断）。
            if (maxRange != 0 && info.Buffer.Handle != 0)
            {
                ClampAndReportUniformBufferRange(ref info, resolved?.Size ?? 0, maxRange, _gd);
                if (info.Range == 0)
                {
                    BindEmptyUniformDummy(cbs, ref info, maxRange);
                    mirrored = false;
                }
            }

            return mirrored;
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        private void UpdateAndBind(CommandBufferScoped cbs, ShaderCollection program, int setIndex, PipelineBindPoint pbp)
        {
            ResourceBindingSegment[] bindingSegments = program.BindingSegments[setIndex];

            if (bindingSegments.Length == 0)
            {
                return;
            }

            Auto<DisposableBuffer> dummyBuffer = _dummyBuffer?.GetBuffer();

            if (_updateDescriptorCacheCbIndex)
            {
                _updateDescriptorCacheCbIndex = false;
                program.UpdateDescriptorCacheCommandBufferIndex(cbs.CommandBufferIndex);
            }

            DescriptorSetCollection dsc = program.GetNewDescriptorSetCollection(setIndex, out bool isNew).Get(cbs);

            if (!program.HasMinimalLayout)
            {
                if (isNew)
                {
                    Initialize(cbs, setIndex, dsc);
                }
            }

            DescriptorSetTemplate template = program.Templates[setIndex];

            DescriptorSetTemplateWriter tu = _templateUpdater.Begin(template);

            foreach (ResourceBindingSegment segment in bindingSegments)
            {
                int binding = segment.Binding;
                int count = segment.Count;

                if (setIndex == PipelineBase.UniformSetIndex)
                {
                    for (int i = 0; i < count; i++)
                    {
                        int index = binding + i;

                        if (_uniformSet.Set(index))
                        {
                            ref BufferRef buffer = ref _uniformBufferRefs[index];

                            bool mirrored = UpdateBuffer(
                                cbs,
                                ref _uniformBuffers[index],
                                ref buffer,
                                dummyBuffer,
                                true,
                                _gd.Capabilities.MaxUniformBufferRange);

                            _uniformMirrored.Set(index, mirrored);
                        }
                    }

                    ReadOnlySpan<DescriptorBufferInfo> uniformBuffers = _uniformBuffers;

                    tu.Push(uniformBuffers.Slice(binding, count));
                }
                else if (setIndex == PipelineBase.StorageSetIndex)
                {
                    for (int i = 0; i < count; i++)
                    {
                        int index = binding + i;

                        ref BufferRef buffer = ref _storageBufferRefs[index];

                        if (_storageSet.Set(index))
                        {
                            ref DescriptorBufferInfo info = ref _storageBuffers[index];

                            bool mirrored = UpdateBuffer(cbs,
                                ref info,
                                ref _storageBufferRefs[index],
                                dummyBuffer,
                                !buffer.Write && info.Range <= StorageBufferMaxMirrorable,
                                0);

                            _storageMirrored.Set(index, mirrored);
                        }
                    }

                    ReadOnlySpan<DescriptorBufferInfo> storageBuffers = _storageBuffers;

                    tu.Push(storageBuffers.Slice(binding, count));
                }
                else if (setIndex == PipelineBase.TextureSetIndex)
                {
                    if (!segment.IsArray)
                    {
                        if (segment.Type != ResourceType.BufferTexture)
                        {
                            Span<DescriptorImageInfo> textures = _textures;

                            for (int i = 0; i < count; i++)
                            {
                                ref DescriptorImageInfo texture = ref textures[i];
                                ref TextureRef refs = ref _textureRefs[binding + i];

                                texture.ImageView = refs.ImageView?.Get(cbs).Value ?? default;
                                texture.Sampler = refs.Sampler?.Get(cbs).Value ?? default;

                                if (texture.ImageView.Handle == 0)
                                {
                                    texture.ImageView = _dummyTexture.GetImageView().Get(cbs).Value;
                                }

                                if (texture.Sampler.Handle == 0)
                                {
                                    texture.Sampler = _dummySampler.GetSampler().Get(cbs).Value;
                                }
                            }

                            tu.Push<DescriptorImageInfo>(textures[..count]);
                        }
                        else
                        {
                            Span<BufferView> bufferTextures = _bufferTextures;

                            for (int i = 0; i < count; i++)
                            {
                                bufferTextures[i] = S2AResolveTexelView(cbs, _bufferTextureRefs[binding + i]?.GetBufferView(cbs, false) ?? default, setIndex, binding + i);
                            }

                            tu.Push<BufferView>(bufferTextures[..count]);
                        }
                    }
                    else
                    {
                        if (segment.Type != ResourceType.BufferTexture)
                        {
                            tu.Push(_textureArrayRefs[binding].Array.GetImageInfos(_gd, cbs, _dummyTexture, _dummySampler));
                        }
                        else
                        {
                            tu.Push(_textureArrayRefs[binding].Array.GetBufferViews(cbs, (view, i) => S2AResolveTexelView(cbs, view, setIndex, binding + i)));
                        }
                    }
                }
                else if (setIndex == PipelineBase.ImageSetIndex)
                {
                    if (!segment.IsArray)
                    {
                        if (segment.Type != ResourceType.BufferImage)
                        {
                            Span<DescriptorImageInfo> images = _images;

                            for (int i = 0; i < count; i++)
                            {
                                images[i].ImageView = _imageRefs[binding + i].ImageView?.Get(cbs).Value ?? default;

                                // S2A：空 image view 以 0 描述符写入是 Vulkan 未定义行为（未启用 nullDescriptor 时）。
                                //   这里与 texture / ImageArray 路径一致，回退到 1×1 dummy（R8G8B8A8_UNORM，带 STORAGE
                                //   usage），同时计数并在收局汇总行报出——null 绑定本身仍然可见，不是静默兜底。
                                //   与 9000 / 歧路旅人 II 的 DeviceLost 无关；9000 上本回退命中 0 次。
                                if (images[i].ImageView.Handle == 0)
                                {
                                    images[i].ImageView = _dummyTexture.GetImageView().Get(cbs).Value;
                                    _gd.S2ANoteNullImageFallback();

                                    int n = Interlocked.Increment(ref _s2aNullImageFallbackLogs);
                                    if (n <= S2ANullImageFallbackLogLines || (n & (n - 1)) == 0)
                                    {
                                        Console.Error.WriteLine(
                                            $"[s2a] 【黄】null storage image 回退：set={setIndex} binding={binding + i} program={_program.S2AShaderHashes}（第 {n} 次）");
                                    }
                                }
                            }

                            tu.Push<DescriptorImageInfo>(images[..count]);
                        }
                        else
                        {
                            Span<BufferView> bufferImages = _bufferImages;

                            for (int i = 0; i < count; i++)
                            {
                                bufferImages[i] = S2AResolveTexelView(cbs, _bufferImageRefs[binding + i]?.GetBufferView(cbs, true) ?? default, setIndex, binding + i);
                            }

                            tu.Push<BufferView>(bufferImages[..count]);
                        }
                    }
                    else
                    {
                        if (segment.Type != ResourceType.BufferTexture)
                        {
                            tu.Push(_imageArrayRefs[binding].Array.GetImageInfos(_gd, cbs, _dummyTexture));
                        }
                        else
                        {
                            tu.Push(_imageArrayRefs[binding].Array.GetBufferViews(cbs, (view, i) => S2AResolveTexelView(cbs, view, setIndex, binding + i)));
                        }
                    }
                }
            }

            DescriptorSet[] sets = dsc.GetSets();
            _templateUpdater.Commit(_gd, _device, sets[0]);

            _gd.Api.CmdBindDescriptorSets(cbs.CommandBuffer, pbp, _program.PipelineLayout, (uint)setIndex, 1, sets, 0, ReadOnlySpan<uint>.Empty);
        }

        // R32_UINT：Mali-G710（9000）bufferFeatures=0x78，UNIFORM/STORAGE_TEXEL_BUFFER 都支持；
        //   有 nullDescriptor 的设备 _dummyBuffer==null，这里原样返回不建 view。
        private BufferView S2AResolveTexelView(CommandBufferScoped cbs, BufferView view, int setIndex, int binding)
        {
            if (view.Handle != 0 || _dummyBuffer == null)
            {
                return view;
            }

            _dummyBufferView ??= _dummyBuffer.CreateView(VkFormat.R32Uint, 0, S2ADummyTexelBufferSize, null, cbs, out _);
            _gd.S2ANoteNullTexelFallback();

            int n = Interlocked.Increment(ref _s2aNullTexelFallbackLogs);
            if (n <= S2ANullTexelFallbackLogLines || (n & (n - 1)) == 0)
            {
                Console.Error.WriteLine(
                    $"[s2a] 【黄】null texel buffer view 回退：set={setIndex} binding={binding} program={_program.S2AShaderHashes}（第 {n} 次）");
            }

            return _dummyBufferView.Get(cbs, 0, S2ADummyTexelBufferSize, false).Value;
        }

        private void UpdateAndBindTexturesWithoutTemplate(CommandBufferScoped cbs, ShaderCollection program, PipelineBindPoint pbp)
        {
            int setIndex = PipelineBase.TextureSetIndex;
            ResourceBindingSegment[] bindingSegments = program.BindingSegments[setIndex];

            if (bindingSegments.Length == 0)
            {
                return;
            }

            if (_updateDescriptorCacheCbIndex)
            {
                _updateDescriptorCacheCbIndex = false;
                program.UpdateDescriptorCacheCommandBufferIndex(cbs.CommandBufferIndex);
            }

            DescriptorSetCollection dsc = program.GetNewDescriptorSetCollection(setIndex, out _).Get(cbs);

            foreach (ResourceBindingSegment segment in bindingSegments)
            {
                int binding = segment.Binding;
                int count = segment.Count;

                if (!segment.IsArray)
                {
                    if (segment.Type != ResourceType.BufferTexture)
                    {
                        Span<DescriptorImageInfo> textures = _textures;

                        for (int i = 0; i < count; i++)
                        {
                            ref DescriptorImageInfo texture = ref textures[i];
                            ref TextureRef refs = ref _textureRefs[binding + i];

                            texture.ImageView = refs.ImageView?.Get(cbs).Value ?? default;
                            texture.Sampler = refs.Sampler?.Get(cbs).Value ?? default;

                            if (texture.ImageView.Handle == 0)
                            {
                                texture.ImageView = _dummyTexture.GetImageView().Get(cbs).Value;
                            }

                            if (texture.Sampler.Handle == 0)
                            {
                                texture.Sampler = _dummySampler.GetSampler().Get(cbs).Value;
                            }
                        }

                        dsc.UpdateImagesPerBinding(0, binding, textures[..count], DescriptorType.CombinedImageSampler);
                    }
                    else
                    {
                        Span<BufferView> bufferTextures = _bufferTextures;

                        for (int i = 0; i < count; i++)
                        {
                            bufferTextures[i] = S2AResolveTexelView(cbs, _bufferTextureRefs[binding + i]?.GetBufferView(cbs, false) ?? default, setIndex, binding + i);
                        }

                        dsc.UpdateBufferImages(0, binding, bufferTextures[..count], DescriptorType.UniformTexelBuffer);
                    }
                }
                else
                {
                    if (segment.Type != ResourceType.BufferTexture)
                    {
                        dsc.UpdateImages(0, binding, _textureArrayRefs[binding].Array.GetImageInfos(_gd, cbs, _dummyTexture, _dummySampler), DescriptorType.CombinedImageSampler);
                    }
                    else
                    {
                        dsc.UpdateBufferImages(0, binding, _textureArrayRefs[binding].Array.GetBufferViews(cbs, (view, i) => S2AResolveTexelView(cbs, view, setIndex, binding + i)), DescriptorType.UniformTexelBuffer);
                    }
                }
            }

            DescriptorSet[] sets = dsc.GetSets();

            _gd.Api.CmdBindDescriptorSets(cbs.CommandBuffer, pbp, _program.PipelineLayout, (uint)setIndex, 1, sets, 0, ReadOnlySpan<uint>.Empty);
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        private void UpdateAndBindUniformBufferPd(CommandBufferScoped cbs)
        {
            int sequence = _pdSequence;
            ResourceBindingSegment[] bindingSegments = _program.BindingSegments[PipelineBase.UniformSetIndex];
            Auto<DisposableBuffer> dummyBuffer = _dummyBuffer?.GetBuffer();

            long updatedBindings = 0;
            DescriptorSetTemplateWriter writer = _templateUpdater.Begin(32 * Unsafe.SizeOf<DescriptorBufferInfo>());

            foreach (ResourceBindingSegment segment in bindingSegments)
            {
                int binding = segment.Binding;
                int count = segment.Count;

                ReadOnlySpan<DescriptorBufferInfo> uniformBuffers = _uniformBuffers;

                for (int i = 0; i < count; i++)
                {
                    int index = binding + i;

                    if (_uniformSet.Set(index))
                    {
                        ref BufferRef buffer = ref _uniformBufferRefs[index];

                        bool mirrored = UpdateBuffer(
                            cbs,
                            ref _uniformBuffers[index],
                            ref buffer,
                            dummyBuffer,
                            true,
                            _gd.Capabilities.MaxUniformBufferRange);

                        _uniformMirrored.Set(index, mirrored);
                    }

                    if (_uniformSetPd[index] != sequence)
                    {
                        // Need to set this push descriptor (even if the buffer binding has not changed)

                        _uniformSetPd[index] = sequence;
                        updatedBindings |= 1L << index;

                        writer.Push(MemoryMarshal.CreateReadOnlySpan(ref _uniformBuffers[index], 1));
                    }
                }
            }

            if (updatedBindings > 0)
            {
                DescriptorSetTemplate template = _program.GetPushDescriptorTemplate(updatedBindings);
                _templateUpdater.CommitPushDescriptor(_gd, cbs, template, _program.PipelineLayout);
            }
        }

        private void Initialize(CommandBufferScoped cbs, int setIndex, DescriptorSetCollection dsc)
        {
            // We don't support clearing texture descriptors currently.
            if (setIndex is not PipelineBase.UniformSetIndex and not PipelineBase.StorageSetIndex)
            {
                return;
            }

            Buffer dummyBuffer = _dummyBuffer?.GetBuffer().Get(cbs).Value ?? default;

            foreach (ResourceBindingSegment segment in _program.ClearSegments[setIndex])
            {
                dsc.InitializeBuffers(0, segment.Binding, segment.Count, segment.Type.Convert(), dummyBuffer);
            }
        }

        private void BindExtraSets(CommandBufferScoped cbs, ShaderCollection program, PipelineBindPoint pbp)
        {
            for (int setIndex = PipelineBase.DescriptorSetLayouts; setIndex < program.BindingSegments.Length; setIndex++)
            {
                ResourceBindingSegment[] bindingSegments = program.BindingSegments[setIndex];

                if (bindingSegments.Length == 0)
                {
                    continue;
                }

                ResourceBindingSegment segment = bindingSegments[0];

                if (segment.IsArray)
                {
                    DescriptorSet[] sets = null;

                    if (segment.Type is ResourceType.Texture or
                        ResourceType.Sampler or
                        ResourceType.TextureAndSampler or
                        ResourceType.BufferTexture)
                    {
                        sets = _textureArrayExtraRefs[setIndex - PipelineBase.DescriptorSetLayouts].Array.GetDescriptorSets(
                            _device,
                            cbs,
                            _templateUpdater,
                            program,
                            setIndex,
                            _dummyTexture,
                            _dummySampler,
                            (view, i) => S2AResolveTexelView(cbs, view, setIndex, i));
                    }
                    else if (segment.Type is ResourceType.Image or ResourceType.BufferImage)
                    {
                        sets = _imageArrayExtraRefs[setIndex - PipelineBase.DescriptorSetLayouts].Array.GetDescriptorSets(
                            _device,
                            cbs,
                            _templateUpdater,
                            program,
                            setIndex,
                            _dummyTexture,
                            (view, i) => S2AResolveTexelView(cbs, view, setIndex, i));
                    }

                    if (sets != null)
                    {
                        _gd.Api.CmdBindDescriptorSets(cbs.CommandBuffer, pbp, _program.PipelineLayout, (uint)setIndex, 1, sets, 0, ReadOnlySpan<uint>.Empty);
                    }
                }
            }
        }

        public void SignalCommandBufferChange()
        {
            _updateDescriptorCacheCbIndex = true;
            _dirty = DirtyFlags.All;

            _uniformSet.Clear();
            _storageSet.Clear();
            AdvancePdSequence();
        }

        public void ForceTextureDirty()
        {
            SignalDirty(DirtyFlags.Texture);
        }

        public void ForceImageDirty()
        {
            SignalDirty(DirtyFlags.Image);
        }

        private static void SwapBuffer(BufferRef[] list, Auto<DisposableBuffer> from, Auto<DisposableBuffer> to)
        {
            for (int i = 0; i < list.Length; i++)
            {
                if (list[i].Buffer == from)
                {
                    list[i].Buffer = to;
                }
            }
        }

        public void SwapBuffer(Auto<DisposableBuffer> from, Auto<DisposableBuffer> to)
        {
            SwapBuffer(_uniformBufferRefs, from, to);
            SwapBuffer(_storageBufferRefs, from, to);
        }

        protected virtual void Dispose(bool disposing)
        {
            if (disposing)
            {
                _dummyTexture.Dispose();
                _dummySampler.Dispose();
                _dummyBufferView?.Dispose();
                if (_emptyUniformDummyBuffer != _dummyBuffer) _emptyUniformDummyBuffer?.Dispose();
                _dummyBuffer?.Dispose();
                _templateUpdater.Dispose();
            }
        }

        public void Dispose()
        {
            Dispose(true);
        }
    }
}
