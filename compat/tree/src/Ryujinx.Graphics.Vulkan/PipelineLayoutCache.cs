using Ryujinx.Graphics.GAL;
using Silk.NET.Vulkan;
using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.Collections.ObjectModel;

namespace Ryujinx.Graphics.Vulkan
{
    class PipelineLayoutCache
    {
        private readonly record struct BindingCoverage(int Set, int Binding, ResourceType Type, int Count, bool IsArray, ResourceStages Stages);

        // Created once per program, never on the draw/descriptor update path.
        private static BindingCoverage[] FreezeCoverage(ResourceBindingSegment[][] segments)
        {
            List<BindingCoverage> coverage = new();
            for (int set = 0; set < segments.Length; set++)
            {
                foreach (ResourceBindingSegment segment in segments[set])
                {
                    if (segment.IsArray)
                    {
                        coverage.Add(new(set, segment.Binding, segment.Type, segment.Count, true, segment.Stages));
                    }
                    else
                    {
                        for (int index = 0; index < segment.Count; index++)
                        {
                            coverage.Add(new(set, segment.Binding + index, segment.Type, 1, false, segment.Stages));
                        }
                    }
                }
            }

            coverage.Sort(static (a, b) =>
            {
                int result = a.Set.CompareTo(b.Set);
                if (result == 0) result = a.Binding.CompareTo(b.Binding);
                if (result == 0) result = a.Type.CompareTo(b.Type);
                if (result == 0) result = a.Count.CompareTo(b.Count);
                if (result == 0) result = a.IsArray.CompareTo(b.IsArray);
                if (result == 0) result = a.Stages.CompareTo(b.Stages);
                return result;
            });
            return coverage.ToArray();
        }

        private readonly struct PlceKey : IEquatable<PlceKey>
        {
            public readonly ReadOnlyCollection<ResourceDescriptorCollection> SetDescriptors;
            public readonly bool UsePushDescriptors;
            private readonly BindingCoverage[] _coverage;

            public PlceKey(ReadOnlyCollection<ResourceDescriptorCollection> setDescriptors, bool usePushDescriptors, ResourceBindingSegment[][] bindingSegments)
            {
                if (setDescriptors != null)
                {
                    ResourceDescriptorCollection[] frozenSets = new ResourceDescriptorCollection[setDescriptors.Count];
                    for (int set = 0; set < setDescriptors.Count; set++)
                    {
                        ReadOnlyCollection<ResourceDescriptor> source = setDescriptors[set].Descriptors;
                        ResourceDescriptor[] frozenDescriptors = new ResourceDescriptor[source.Count];
                        source.CopyTo(frozenDescriptors, 0);
                        frozenSets[set] = new ResourceDescriptorCollection(Array.AsReadOnly(frozenDescriptors));
                    }
                    SetDescriptors = Array.AsReadOnly(frozenSets);
                }
                else
                {
                    SetDescriptors = null;
                }
                _coverage = FreezeCoverage(bindingSegments);
                UsePushDescriptors = usePushDescriptors;
            }

            public override int GetHashCode()
            {
                HashCode hasher = new();

                if (SetDescriptors != null)
                {
                    foreach (ResourceDescriptorCollection setDescriptor in SetDescriptors)
                    {
                        hasher.Add(setDescriptor);
                    }
                }

                hasher.Add(UsePushDescriptors);
                foreach (BindingCoverage entry in _coverage) hasher.Add(entry);

                return hasher.ToHashCode();
            }

            public override bool Equals(object obj)
            {
                return obj is PlceKey other && Equals(other);
            }

            public bool Equals(PlceKey other)
            {
                if ((SetDescriptors == null) != (other.SetDescriptors == null))
                {
                    return false;
                }

                if (SetDescriptors != null)
                {
                    if (SetDescriptors.Count != other.SetDescriptors.Count)
                    {
                        return false;
                    }

                    for (int index = 0; index < SetDescriptors.Count; index++)
                    {
                        if (!SetDescriptors[index].Equals(other.SetDescriptors[index]))
                        {
                            return false;
                        }
                    }
                }

                if (_coverage.Length != other._coverage.Length) return false;
                for (int index = 0; index < _coverage.Length; index++)
                {
                    if (_coverage[index] != other._coverage[index]) return false;
                }
                return UsePushDescriptors == other.UsePushDescriptors;
            }
        }

        private readonly ConcurrentDictionary<PlceKey, PipelineLayoutCacheEntry> _plces;

        public PipelineLayoutCache()
        {
            _plces = new ConcurrentDictionary<PlceKey, PipelineLayoutCacheEntry>();
        }

        public PipelineLayoutCacheEntry GetOrCreate(
            VulkanRenderer gd,
            Device device,
            ReadOnlyCollection<ResourceDescriptorCollection> setDescriptors,
            bool usePushDescriptors,
            ResourceBindingSegment[][] bindingSegments)
        {
            PlceKey key = new(setDescriptors, usePushDescriptors, bindingSegments);

            return _plces.GetOrAdd(key, newKey => new PipelineLayoutCacheEntry(gd, device, newKey.SetDescriptors, newKey.UsePushDescriptors));
        }

        protected virtual void Dispose(bool disposing)
        {
            if (disposing)
            {
                foreach (PipelineLayoutCacheEntry plce in _plces.Values)
                {
                    plce.Dispose();
                }

                _plces.Clear();
            }
        }

        public void Dispose()
        {
            Dispose(true);
        }
    }
}
