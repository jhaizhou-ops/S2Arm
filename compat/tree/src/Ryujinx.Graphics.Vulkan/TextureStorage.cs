using Ryujinx.Common;
using Ryujinx.Graphics.GAL;
using Silk.NET.Vulkan;
using System;
using System.Collections.Generic;
using System.Numerics;
using System.Runtime.CompilerServices;
using Format = Ryujinx.Graphics.GAL.Format;
using VkBuffer = Silk.NET.Vulkan.Buffer;
using VkFormat = Silk.NET.Vulkan.Format;

namespace Ryujinx.Graphics.Vulkan
{
    class TextureStorage : IDisposable
    {
        private struct TextureSliceInfo
        {
            public int BindCount;
        }

        private const MemoryPropertyFlags DefaultImageMemoryFlags =
            MemoryPropertyFlags.DeviceLocalBit;

        private const ImageUsageFlags DefaultUsageFlags =
            ImageUsageFlags.SampledBit |
            ImageUsageFlags.TransferSrcBit |
            ImageUsageFlags.TransferDstBit;

        public const AccessFlags DefaultAccessMask =
            AccessFlags.ShaderReadBit |
            AccessFlags.ShaderWriteBit |
            AccessFlags.ColorAttachmentReadBit |
            AccessFlags.ColorAttachmentWriteBit |
            AccessFlags.DepthStencilAttachmentReadBit |
            AccessFlags.DepthStencilAttachmentWriteBit |
            AccessFlags.TransferReadBit |
            AccessFlags.TransferWriteBit;

        private readonly VulkanRenderer _gd;

        private readonly Device _device;

        private TextureCreateInfo _info;

        public TextureCreateInfo Info => _info;

        public bool Disposed { get; private set; }

        private readonly Image _image;
        private readonly Auto<DisposableImage> _imageAuto;
        private readonly Auto<MemoryAllocation> _allocationAuto;
        private readonly int _depthOrLayers;
        private Auto<MemoryAllocation> _foreignAllocationAuto;

        private Dictionary<Format, TextureStorage> _aliasedStorages;

        // S2A（SYNC-RAW）：最近一次对图内访问的记录。附件 loadOp=LOAD 前按它判断要不要发写→读屏障
        //   （dstAccess 必须含 *_READ，否则 SyncVal 报 READ-AFTER-WRITE）。写路径（布局迁移 / 上传拷贝 /
        //   blit / 辅助绘制 / 传输清图）都经 RecordModification 记上，loadOp 才看得见。
        internal struct LastAccessState
        {
            public AccessFlags WriteAccess;
            public PipelineStageFlags WriteStage;
            public AccessFlags ReadAccess;
            public PipelineStageFlags ReadStage;

            public readonly bool NeedsLoadOpBarrier => (WriteAccess | ReadAccess) != AccessFlags.None;

            public static AccessFlags LoadOpDstAccess(bool depthStencil) => depthStencil
                ? AccessFlags.DepthStencilAttachmentWriteBit | AccessFlags.DepthStencilAttachmentReadBit
                : AccessFlags.ColorAttachmentWriteBit | AccessFlags.ColorAttachmentReadBit;

            public void RecordWrite(AccessFlags access, PipelineStageFlags stage)
            {
                WriteAccess |= access;
                WriteStage |= stage;
            }

            public void RecordRead(AccessFlags access, PipelineStageFlags stage)
            {
                ReadAccess |= access;
                ReadStage |= stage;
            }

            // 附件一次写（storeOp 或 loadOp 屏障消费后）：写态改为附件写；
            //   loadOp 屏障消费时 clearReads=true（旧读已并进屏障源），storeOp 时 false（旧读保留，与上游语义一致）
            public void MarkAttachmentWrite(bool depthStencil, bool clearReads)
            {
                if (clearReads)
                {
                    ReadAccess = AccessFlags.None;
                    ReadStage = PipelineStageFlags.None;
                }

                WriteStage = depthStencil
                    ? PipelineStageFlags.LateFragmentTestsBit
                    : PipelineStageFlags.ColorAttachmentOutputBit;
                WriteAccess = depthStencil
                    ? AccessFlags.DepthStencilAttachmentWriteBit
                    : AccessFlags.ColorAttachmentWriteBit;
            }
        }

        private LastAccessState _last;

        private int _viewsCount;
        private readonly ulong _size;

        private int _bindCount;
        private readonly TextureSliceInfo[] _slices;

        public VkFormat VkFormat { get; }

        public ImageUsageFlags UsageFlags { get; }

        public unsafe TextureStorage(
            VulkanRenderer gd,
            Device device,
            TextureCreateInfo info,
            Auto<MemoryAllocation> foreignAllocation = null)
        {
            _gd = gd;
            _device = device;
            _info = info;

            bool isMsImageStorageSupported = gd.Capabilities.SupportsShaderStorageImageMultisample || !info.Target.IsMultisample;

            VkFormat format = _gd.FormatCapabilities.ConvertToVkFormat(info.Format, isMsImageStorageSupported);
            uint levels = (uint)info.Levels;
            uint layers = (uint)info.GetLayers();
            uint depth = (uint)(info.Target == Target.Texture3D ? info.Depth : 1);

            VkFormat = format;
            _depthOrLayers = info.GetDepthOrLayers();

            ImageType type = info.Target.Convert();

            Extent3D extent = new((uint)info.Width, (uint)info.Height, depth);

            SampleCountFlags sampleCountFlags = ConvertToSampleCountFlags(gd.Capabilities.SupportedSampleCounts, (uint)info.Samples);

            ImageUsageFlags usage = GetImageUsage(info.Format, gd.Capabilities, isMsImageStorageSupported);
            UsageFlags = usage;

            ImageCreateFlags flags = ImageCreateFlags.CreateMutableFormatBit | ImageCreateFlags.CreateExtendedUsageBit;

            // This flag causes mipmapped texture arrays to break on AMD GCN, so for that copy dependencies are forced for aliasing as cube.
            bool isCube = info.Target is Target.Cubemap or Target.CubemapArray;
            bool cubeCompatible = gd.IsAmdGcn ? isCube : (info.Width == info.Height && layers >= 6);

            if (type == ImageType.Type2D && cubeCompatible)
            {
                flags |= ImageCreateFlags.CreateCubeCompatibleBit;
            }

            if (type == ImageType.Type3D && !gd.Capabilities.PortabilitySubset.HasFlag(PortabilitySubsetFlags.No3DImageView))
            {
                flags |= ImageCreateFlags.Create2DArrayCompatibleBit;
            }

            ImageCreateInfo imageCreateInfo = new()
            {
                SType = StructureType.ImageCreateInfo,
                ImageType = type,
                Format = format,
                Extent = extent,
                MipLevels = levels,
                ArrayLayers = layers,
                Samples = sampleCountFlags,
                Tiling = ImageTiling.Optimal,
                Usage = usage,
                SharingMode = SharingMode.Exclusive,
                InitialLayout = ImageLayout.Undefined,
                Flags = flags,
            };

            gd.Api.CreateImage(device, in imageCreateInfo, null, out _image).ThrowOnError();

            if (foreignAllocation == null)
            {
                gd.Api.GetImageMemoryRequirements(device, _image, out MemoryRequirements requirements);
                MemoryAllocation allocation = gd.MemoryAllocator.AllocateDeviceMemory(requirements, DefaultImageMemoryFlags);

                if (allocation.Memory.Handle == 0UL)
                {
                    gd.Api.DestroyImage(device, _image, null);
                    throw new Exception("Image initialization failed.");
                }

                _size = requirements.Size;

                gd.Api.BindImageMemory(device, _image, allocation.Memory, allocation.Offset).ThrowOnError();

                _allocationAuto = new Auto<MemoryAllocation>(allocation);
                _imageAuto = new Auto<DisposableImage>(new DisposableImage(_gd.Api, device, _image), null, _allocationAuto);

                InitialTransition(ImageLayout.Undefined, ImageLayout.General);
            }
            else
            {
                _foreignAllocationAuto = foreignAllocation;
                foreignAllocation.IncrementReferenceCount();
                MemoryAllocation allocation = foreignAllocation.GetUnsafe();

                gd.Api.BindImageMemory(device, _image, allocation.Memory, allocation.Offset).ThrowOnError();

                _imageAuto = new Auto<DisposableImage>(new DisposableImage(_gd.Api, device, _image));

                InitialTransition(ImageLayout.Undefined, ImageLayout.General);
            }

            _slices = new TextureSliceInfo[levels * _depthOrLayers];
        }

        public TextureStorage CreateAliasedColorForDepthStorageUnsafe(Format format)
        {
            Format colorFormat = format switch
            {
                Format.S8Uint => Format.R8Unorm,
                Format.D16Unorm => Format.R16Unorm,
                Format.D24UnormS8Uint or Format.S8UintD24Unorm or Format.X8UintD24Unorm => Format.R8G8B8A8Unorm,
                Format.D32Float => Format.R32Float,
                Format.D32FloatS8Uint => Format.R32G32Float,
                _ => throw new ArgumentException($"\"{format}\" is not a supported depth or stencil format."),
            };

            return CreateAliasedStorageUnsafe(colorFormat);
        }

        public TextureStorage CreateAliasedStorageUnsafe(Format format)
        {
            if (_aliasedStorages == null || !_aliasedStorages.TryGetValue(format, out TextureStorage storage))
            {
                _aliasedStorages ??= new Dictionary<Format, TextureStorage>();

                TextureCreateInfo info = NewCreateInfoWith(ref _info, format, _info.BytesPerPixel);

                storage = new TextureStorage(_gd, _device, info, _allocationAuto);

                _aliasedStorages.Add(format, storage);
            }

            return storage;
        }

        public static TextureCreateInfo NewCreateInfoWith(ref TextureCreateInfo info, Format format, int bytesPerPixel)
        {
            return NewCreateInfoWith(ref info, format, bytesPerPixel, info.Width, info.Height);
        }

        public static TextureCreateInfo NewCreateInfoWith(
            ref TextureCreateInfo info,
            Format format,
            int bytesPerPixel,
            int width,
            int height)
        {
            return new TextureCreateInfo(
                width,
                height,
                info.Depth,
                info.Levels,
                info.Samples,
                info.BlockWidth,
                info.BlockHeight,
                bytesPerPixel,
                format,
                info.DepthStencilMode,
                info.Target,
                info.SwizzleR,
                info.SwizzleG,
                info.SwizzleB,
                info.SwizzleA);
        }

        public Auto<DisposableImage> GetImage()
        {
            return _imageAuto;
        }

        public Image GetImageForViewCreation()
        {
            return _image;
        }

        public bool HasCommandBufferDependency(CommandBufferScoped cbs)
        {
            if (_foreignAllocationAuto != null)
            {
                return _foreignAllocationAuto.HasCommandBufferDependency(cbs);
            }
            else if (_allocationAuto != null)
            {
                return _allocationAuto.HasCommandBufferDependency(cbs);
            }

            return false;
        }

        private unsafe void InitialTransition(ImageLayout srcLayout, ImageLayout dstLayout)
        {
            CommandBufferScoped cbs;
            bool useTempCbs = !_gd.CommandBufferPool.OwnedByCurrentThread;

            if (useTempCbs)
            {
                cbs = _gd.BackgroundResources.Get().GetPool().Rent();
            }
            else
            {
                if (_gd.PipelineInternal != null)
                {
                    cbs = _gd.PipelineInternal.GetPreloadCommandBuffer();
                }
                else
                {
                    cbs = _gd.CommandBufferPool.Rent();
                    useTempCbs = true;
                }
            }

            ImageAspectFlags aspectFlags = _info.Format.ConvertAspectFlags();

            ImageSubresourceRange subresourceRange = new(aspectFlags, 0, (uint)_info.Levels, 0, (uint)_info.GetLayers());

            ImageMemoryBarrier barrier = new()
            {
                SType = StructureType.ImageMemoryBarrier,
                SrcAccessMask = 0,
                DstAccessMask = DefaultAccessMask,
                OldLayout = srcLayout,
                NewLayout = dstLayout,
                SrcQueueFamilyIndex = Vk.QueueFamilyIgnored,
                DstQueueFamilyIndex = Vk.QueueFamilyIgnored,
                Image = _imageAuto.Get(cbs).Value,
                SubresourceRange = subresourceRange,
            };

            _gd.Api.CmdPipelineBarrier(
                cbs.CommandBuffer,
                PipelineStageFlags.TopOfPipeBit,
                PipelineStageFlags.AllCommandsBit,
                0,
                0,
                null,
                0,
                null,
                1,
                in barrier);

            // S2A（SYNC-RAW）：布局迁移本身也是一次写 —— 之后首次当附件 load 时屏障要看得见
            _last.RecordWrite(DefaultAccessMask, PipelineStageFlags.AllCommandsBit);

            if (useTempCbs)
            {
                cbs.Dispose();
            }
        }

        public static ImageUsageFlags GetImageUsage(Format format, in HardwareCapabilities capabilities, bool isMsImageStorageSupported)
        {
            ImageUsageFlags usage = DefaultUsageFlags;

            if (format.IsDepthOrStencil)
            {
                usage |= ImageUsageFlags.DepthStencilAttachmentBit;
            }
            else if (format.IsRtColorCompatible)
            {
                usage |= ImageUsageFlags.ColorAttachmentBit;
            }

            if (format.IsImageCompatible && isMsImageStorageSupported)
            {
                usage |= ImageUsageFlags.StorageBit;
            }

            if (capabilities.SupportsAttachmentFeedbackLoop &&
                (usage & (ImageUsageFlags.DepthStencilAttachmentBit | ImageUsageFlags.ColorAttachmentBit)) != 0)
            {
                usage |= ImageUsageFlags.AttachmentFeedbackLoopBitExt;
            }

            return usage;
        }

        public static SampleCountFlags ConvertToSampleCountFlags(SampleCountFlags supportedSampleCounts, uint samples)
        {
            if (samples is 0 or > ((uint)SampleCountFlags.Count64Bit))
            {
                return SampleCountFlags.Count1Bit;
            }

            // Round up to the nearest power of two.
            SampleCountFlags converted = (SampleCountFlags)(1u << (31 - BitOperations.LeadingZeroCount(samples)));

            // Pick nearest sample count that the host actually supports.
            while (converted != SampleCountFlags.Count1Bit && (converted & supportedSampleCounts) == 0)
            {
                converted = (SampleCountFlags)((uint)converted >> 1);
            }

            return converted;
        }

        public TextureView CreateView(TextureCreateInfo info, int firstLayer, int firstLevel)
        {
            return new TextureView(_gd, _device, info, this, firstLayer, firstLevel);
        }

        public void CopyFromOrToBuffer(
            CommandBuffer commandBuffer,
            VkBuffer buffer,
            Image image,
            int size,
            bool to,
            int x,
            int y,
            int dstLayer,
            int dstLevel,
            int dstLayers,
            int dstLevels,
            bool singleSlice,
            ImageAspectFlags aspectFlags,
            bool forFlush)
        {
            bool is3D = Info.Target == Target.Texture3D;
            int width = Info.Width;
            int height = Info.Height;
            int depth = is3D && !singleSlice ? Info.Depth : 1;
            int layer = is3D ? 0 : dstLayer;
            int layers = dstLayers;
            int levels = dstLevels;

            int offset = 0;

            for (int level = 0; level < levels; level++)
            {
                int mipSize = Info.GetMipSize(level);

                if (forFlush)
                {
                    mipSize = GetBufferDataLength(mipSize);
                }

                int endOffset = offset + mipSize;

                if ((uint)endOffset > (uint)size)
                {
                    break;
                }

                int rowLength = (Info.GetMipStride(level) / Info.BytesPerPixel) * Info.BlockWidth;

                ImageSubresourceLayers sl = new(
                    aspectFlags,
                    (uint)(dstLevel + level),
                    (uint)layer,
                    (uint)layers);

                Extent3D extent = new((uint)width, (uint)height, (uint)depth);

                int z = is3D ? dstLayer : 0;

                BufferImageCopy region = new(
                    (ulong)offset,
                    (uint)BitUtils.AlignUp(rowLength, Info.BlockWidth),
                    (uint)BitUtils.AlignUp(height, Info.BlockHeight),
                    sl,
                    new Offset3D(x, y, z),
                    extent);

                if (to)
                {
                    _gd.Api.CmdCopyImageToBuffer(commandBuffer, image, ImageLayout.General, buffer, 1, in region);
                    _last.RecordRead(AccessFlags.TransferReadBit, PipelineStageFlags.TransferBit);
                }
                else
                {
                    _gd.Api.CmdCopyBufferToImage(commandBuffer, buffer, image, ImageLayout.General, 1, in region);
                    _last.RecordWrite(AccessFlags.TransferWriteBit, PipelineStageFlags.TransferBit);
                }

                offset += mipSize;

                width = Math.Max(1, width >> 1);
                height = Math.Max(1, height >> 1);

                if (Info.Target == Target.Texture3D)
                {
                    depth = Math.Max(1, depth >> 1);
                }
            }
        }

        private int GetBufferDataLength(int length)
        {
            if (NeedsD24S8Conversion())
            {
                return length * 2;
            }

            return length;
        }

        private bool NeedsD24S8Conversion()
        {
            return FormatCapabilities.IsD24S8(Info.Format) && VkFormat == VkFormat.D32SfloatS8Uint;
        }

        // S2A（SYNC-RAW）：记录一次对本图的写入 / 读取（写态与读态分开累加，loadOp 屏障按组合源发）
        internal void RecordModification(AccessFlags access, PipelineStageFlags stage) => _last.RecordWrite(access, stage);

        internal void RecordRead(AccessFlags access, PipelineStageFlags stage) => _last.RecordRead(access, stage);

        public void AddStoreOpUsage(bool depthStencil)
        {
            _last.MarkAttachmentWrite(depthStencil, clearReads: false);
        }

        public void QueueLoadOpBarrier(CommandBufferScoped cbs, bool depthStencil)
        {
            PipelineStageFlags srcStageFlags = _last.ReadStage | _last.WriteStage;
            PipelineStageFlags dstStageFlags = depthStencil ?
                PipelineStageFlags.EarlyFragmentTestsBit | PipelineStageFlags.LateFragmentTestsBit :
                PipelineStageFlags.ColorAttachmentOutputBit;

            AccessFlags srcAccessFlags = _last.WriteAccess | _last.ReadAccess;
            AccessFlags dstAccessFlags = LastAccessState.LoadOpDstAccess(depthStencil);

            if (srcAccessFlags != AccessFlags.None)
            {
                ImageAspectFlags aspectFlags = Info.Format.ConvertAspectFlags();
                ImageMemoryBarrier barrier = TextureView.GetImageBarrier(
                    _imageAuto.Get(cbs).Value,
                    srcAccessFlags,
                    dstAccessFlags,
                    aspectFlags,
                    0,
                    0,
                    _info.GetLayers(),
                    _info.Levels);

                _gd.Barriers.QueueBarrier(barrier, this, srcStageFlags, dstStageFlags);
            }

            _last.MarkAttachmentWrite(depthStencil, clearReads: true);
        }

        public void QueueWriteToReadBarrier(CommandBufferScoped cbs, AccessFlags dstAccessFlags, PipelineStageFlags dstStageFlags)
        {
            _last.RecordRead(dstAccessFlags, dstStageFlags);

            if (_last.WriteAccess != AccessFlags.None)
            {
                ImageAspectFlags aspectFlags = Info.Format.ConvertAspectFlags();
                ImageMemoryBarrier barrier = TextureView.GetImageBarrier(
                    _imageAuto.Get(cbs).Value,
                    _last.WriteAccess,
                    dstAccessFlags,
                    aspectFlags,
                    0,
                    0,
                    _info.GetLayers(),
                    _info.Levels);

                _gd.Barriers.QueueBarrier(barrier, this, _last.WriteStage, dstStageFlags);

                _last.WriteAccess = AccessFlags.None;
            }
        }

        public void AddBinding(TextureView view)
        {
            // Assumes a view only has a first level.

            int index = view.FirstLevel * _depthOrLayers + view.FirstLayer;
            int layers = view.Layers;

            for (int i = 0; i < layers; i++)
            {
                ref TextureSliceInfo info = ref _slices[index++];

                info.BindCount++;
            }

            _bindCount++;
        }

        public void ClearBindings()
        {
            if (_bindCount != 0)
            {
                Array.Clear(_slices, 0, _slices.Length);

                _bindCount = 0;
            }
        }

        [MethodImpl(MethodImplOptions.AggressiveInlining)]
        public bool IsBound(TextureView view)
        {
            if (_bindCount != 0)
            {
                int index = view.FirstLevel * _depthOrLayers + view.FirstLayer;
                int layers = view.Layers;

                for (int i = 0; i < layers; i++)
                {
                    ref TextureSliceInfo info = ref _slices[index++];

                    if (info.BindCount != 0)
                    {
                        return true;
                    }
                }
            }

            return false;
        }

        public void IncrementViewsCount()
        {
            _viewsCount++;
        }

        public void DecrementViewsCount()
        {
            if (--_viewsCount == 0)
            {
                _gd.PipelineInternal?.FlushCommandsIfWeightExceeding(_imageAuto, _size);

                Dispose();
            }
        }

        public void Dispose()
        {
            Disposed = true;

            if (_aliasedStorages != null)
            {
                foreach (TextureStorage storage in _aliasedStorages.Values)
                {
                    storage.Dispose();
                }

                _aliasedStorages.Clear();
            }

            _imageAuto.Dispose();
            _allocationAuto?.Dispose();
            _foreignAllocationAuto?.DecrementReferenceCount();
            _foreignAllocationAuto = null;
        }
    }
}
