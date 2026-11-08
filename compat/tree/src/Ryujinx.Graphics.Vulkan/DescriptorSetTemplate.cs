using Ryujinx.Graphics.GAL;
using Silk.NET.Vulkan;
using System;
using System.Numerics;
using System.Runtime.CompilerServices;

namespace Ryujinx.Graphics.Vulkan
{
    class DescriptorSetTemplate : IDisposable
    {
        /// <summary>
        /// Renderdoc seems to crash when doing a templated uniform update with count > 1 on a push descriptor.
        /// When this is true, consecutive buffers are always updated individually.
        /// </summary>
        private const bool RenderdocPushCountBug = true;

        private readonly VulkanRenderer _gd;
        private readonly Device _device;

        public readonly DescriptorUpdateTemplate Template;
        public readonly int Size;

        public unsafe DescriptorSetTemplate(
            VulkanRenderer gd,
            Device device,
            ResourceBindingSegment[] segments,
            PipelineLayoutCacheEntry plce,
            PipelineBindPoint pbp,
            int setIndex)
        {
            _gd = gd;
            _device = device;

            // Create a template from the set usages. Assumes the descriptor set is updated in segment order then binding order.
            //
            // A non-array segment of Count consecutive bindings is not one array binding: the set layout declares
            // each of them as its own binding with DescriptorCount 1. Writing them with a single entry of
            // DescriptorCount = Count goes past the end of the first binding. Most drivers happen to work because
            // the descriptors are physically adjacent, but Adreno drops everything after the first one, so the
            // following slots stay uninitialized and sample as (0, 0, 0, 0). Expand those segments to one entry
            // per binding; array segments keep their single entry.
            int entryCount = 0;

            for (int seg = 0; seg < segments.Length; seg++)
            {
                entryCount += segments[seg].IsArray ? 1 : segments[seg].Count;
            }

            DescriptorUpdateTemplateEntry* entries = stackalloc DescriptorUpdateTemplateEntry[entryCount];
            nuint structureOffset = 0;
            int entryIndex = 0;

            for (int seg = 0; seg < segments.Length; seg++)
            {
                ResourceBindingSegment segment = segments[seg];

                int binding = segment.Binding;
                int count = segment.Count;

                DescriptorType descriptorType = segment.Type.Convert();
                nuint entrySize = IsBufferType(segment.Type)
                    ? (nuint)Unsafe.SizeOf<DescriptorBufferInfo>()
                    : IsBufferTextureType(segment.Type)
                        ? (nuint)Unsafe.SizeOf<BufferView>()
                        : (nuint)Unsafe.SizeOf<DescriptorImageInfo>();

                if (segment.IsArray)
                {
                    entries[entryIndex++] = new DescriptorUpdateTemplateEntry()
                    {
                        DescriptorType = descriptorType,
                        DstBinding = (uint)binding,
                        DescriptorCount = (uint)count,
                        Offset = structureOffset,
                        Stride = entrySize
                    };

                    structureOffset += entrySize * (nuint)count;
                }
                else
                {
                    for (int i = 0; i < count; i++)
                    {
                        entries[entryIndex++] = new DescriptorUpdateTemplateEntry()
                        {
                            DescriptorType = descriptorType,
                            DstBinding = (uint)(binding + i),
                            DescriptorCount = 1,
                            Offset = structureOffset,
                            Stride = entrySize
                        };

                        structureOffset += entrySize;
                    }
                }
            }

            Size = (int)structureOffset;

            DescriptorUpdateTemplateCreateInfo info = new()
            {
                SType = StructureType.DescriptorUpdateTemplateCreateInfo,
                DescriptorUpdateEntryCount = (uint)entryCount,
                PDescriptorUpdateEntries = entries,

                TemplateType = DescriptorUpdateTemplateType.DescriptorSet,
                DescriptorSetLayout = plce.DescriptorSetLayouts[setIndex],
                PipelineBindPoint = pbp,
                PipelineLayout = plce.PipelineLayout,
                Set = (uint)setIndex,
            };

            DescriptorUpdateTemplate result;
            gd.Api.CreateDescriptorUpdateTemplate(device, &info, null, &result).ThrowOnError();

            Template = result;
        }

        public unsafe DescriptorSetTemplate(
            VulkanRenderer gd,
            Device device,
            ResourceDescriptorCollection descriptors,
            long updateMask,
            PipelineLayoutCacheEntry plce,
            PipelineBindPoint pbp,
            int setIndex)
        {
            _gd = gd;
            _device = device;

            // Create a template from the set usages. Assumes the descriptor set is updated in segment order then binding order.
            int segmentCount = BitOperations.PopCount((ulong)updateMask);

            DescriptorUpdateTemplateEntry* entries = stackalloc DescriptorUpdateTemplateEntry[segmentCount];
            int entry = 0;
            nuint structureOffset = 0;

            void AddBinding(int binding, int count)
            {
                entries[entry++] = new DescriptorUpdateTemplateEntry()
                {
                    DescriptorType = DescriptorType.UniformBuffer,
                    DstBinding = (uint)binding,
                    DescriptorCount = (uint)count,
                    Offset = structureOffset,
                    Stride = (nuint)Unsafe.SizeOf<DescriptorBufferInfo>()
                };

                structureOffset += (nuint)(Unsafe.SizeOf<DescriptorBufferInfo>() * count);
            }

            int startBinding = 0;
            int bindingCount = 0;

            foreach (ResourceDescriptor descriptor in descriptors.Descriptors)
            {
                for (int i = 0; i < descriptor.Count; i++)
                {
                    int binding = descriptor.Binding + i;

                    if ((updateMask & (1L << binding)) != 0)
                    {
                        if (bindingCount > 0 && (RenderdocPushCountBug || startBinding + bindingCount != binding))
                        {
                            AddBinding(startBinding, bindingCount);

                            bindingCount = 0;
                        }

                        if (bindingCount == 0)
                        {
                            startBinding = binding;
                        }

                        bindingCount++;
                    }
                }
            }

            if (bindingCount > 0)
            {
                AddBinding(startBinding, bindingCount);
            }

            Size = (int)structureOffset;

            DescriptorUpdateTemplateCreateInfo info = new()
            {
                SType = StructureType.DescriptorUpdateTemplateCreateInfo,
                DescriptorUpdateEntryCount = (uint)entry,
                PDescriptorUpdateEntries = entries,

                TemplateType = DescriptorUpdateTemplateType.PushDescriptorsKhr,
                DescriptorSetLayout = plce.DescriptorSetLayouts[setIndex],
                PipelineBindPoint = pbp,
                PipelineLayout = plce.PipelineLayout,
                Set = (uint)setIndex,
            };

            DescriptorUpdateTemplate result;
            gd.Api.CreateDescriptorUpdateTemplate(device, &info, null, &result).ThrowOnError();

            Template = result;
        }

        private static bool IsBufferType(ResourceType type)
        {
            return type is ResourceType.UniformBuffer or ResourceType.StorageBuffer;
        }

        private static bool IsBufferTextureType(ResourceType type)
        {
            return type is ResourceType.BufferTexture or ResourceType.BufferImage;
        }

        public unsafe void Dispose()
        {
            _gd.Api.DestroyDescriptorUpdateTemplate(_device, Template, null);
        }
    }
}
