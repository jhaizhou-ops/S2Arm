using Ryujinx.Graphics.GAL;
using Silk.NET.Vulkan;
using System.Collections.Generic;
using SamplerCreateInfo = Ryujinx.Graphics.GAL.SamplerCreateInfo;
using VkFormat = Silk.NET.Vulkan.Format;

namespace Ryujinx.Graphics.Vulkan
{
    class SamplerHolder : ISampler
    {
        private static readonly HashSet<VkFormat> _linearFilterFallbackWarnedFormats = new();

        private readonly VulkanRenderer _gd;
        private readonly Device _device;
        private readonly SamplerCreateInfo _info;
        private readonly Auto<DisposableSampler> _sampler;
        private Auto<DisposableSampler> _nearestSampler;

        internal bool UsesLinearFiltering { get; }

        public SamplerHolder(VulkanRenderer gd, Device device, SamplerCreateInfo info)
        {
            _gd = gd;
            _device = device;
            _info = info;

            gd.Samplers.Add(this);

            _sampler = CreateSampler(device, info, forceNearest: false, out bool usesLinearFiltering);
            UsesLinearFiltering = usesLinearFiltering;
        }

        internal static void ForceNearestFiltering(ref Silk.NET.Vulkan.SamplerCreateInfo samplerCreateInfo)
        {
            samplerCreateInfo.MagFilter = Filter.Nearest;
            samplerCreateInfo.MinFilter = Filter.Nearest;
            samplerCreateInfo.MipmapMode = SamplerMipmapMode.Nearest;
            samplerCreateInfo.AnisotropyEnable = false;
            samplerCreateInfo.MaxAnisotropy = 1f;
        }

        internal static bool ComputeUsesLinearFiltering(in Silk.NET.Vulkan.SamplerCreateInfo samplerCreateInfo)
        {
            return
                samplerCreateInfo.MagFilter == Filter.Linear ||
                samplerCreateInfo.MinFilter == Filter.Linear ||
                samplerCreateInfo.MipmapMode == SamplerMipmapMode.Linear ||
                samplerCreateInfo.AnisotropyEnable;
        }

        private unsafe Auto<DisposableSampler> CreateSampler(Device device, SamplerCreateInfo info, bool forceNearest, out bool usesLinearFiltering)
        {
            (Filter minFilter, SamplerMipmapMode mipFilter) = info.MinFilter.Convert();

            float minLod = info.MinLod;
            float maxLod = info.MaxLod;

            if (info.MinFilter is MinFilter.Nearest or MinFilter.Linear)
            {
                minLod = 0;
                maxLod = 0.25f;
            }

            BorderColor borderColor = GetConstrainedBorderColor(info.BorderColor, out bool cantConstrain);

            Silk.NET.Vulkan.SamplerCreateInfo samplerCreateInfo = new()
            {
                SType = StructureType.SamplerCreateInfo,
                MagFilter = info.MagFilter.Convert(),
                MinFilter = minFilter,
                MipmapMode = mipFilter,
                AddressModeU = info.AddressU.Convert(),
                AddressModeV = info.AddressV.Convert(),
                AddressModeW = info.AddressP.Convert(),
                MipLodBias = info.MipLodBias,
                AnisotropyEnable = info.MaxAnisotropy != 1f,
                MaxAnisotropy = info.MaxAnisotropy,
                CompareEnable = info.CompareMode == CompareMode.CompareRToTexture,
                CompareOp = info.CompareOp.Convert(),
                MinLod = minLod,
                MaxLod = maxLod,
                BorderColor = borderColor,
                UnnormalizedCoordinates = false, // TODO: Use unnormalized coordinates.
            };

            usesLinearFiltering = ComputeUsesLinearFiltering(in samplerCreateInfo);

            if (forceNearest)
            {
                // VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT is not guaranteed
                // for every sampled format (e.g. R16G16_UNORM on Mali). VUID 04552 /
                // 04553 forbid binding a linear-filtering sampler to such views, so a
                // nearest variant is used for that pairing instead.
                ForceNearestFiltering(ref samplerCreateInfo);
            }

            SamplerCustomBorderColorCreateInfoEXT customBorderColor;

            if (cantConstrain && _gd.Capabilities.SupportsCustomBorderColor)
            {
                ClearColorValue color = new(
                    info.BorderColor.Red,
                    info.BorderColor.Green,
                    info.BorderColor.Blue,
                    info.BorderColor.Alpha);

                customBorderColor = new SamplerCustomBorderColorCreateInfoEXT
                {
                    SType = StructureType.SamplerCustomBorderColorCreateInfoExt,
                    CustomBorderColor = color,
                };

                samplerCreateInfo.PNext = &customBorderColor;
                samplerCreateInfo.BorderColor = BorderColor.FloatCustomExt;
            }

            _gd.Api.CreateSampler(device, in samplerCreateInfo, null, out Sampler sampler).ThrowOnError();

            return new Auto<DisposableSampler>(new DisposableSampler(_gd.Api, device, sampler));
        }

        public Auto<DisposableSampler> GetNearestSampler()
        {
            return _nearestSampler ??= CreateSampler(_device, _info, forceNearest: true, out _);
        }

        internal static bool WarnLinearFilterFallbackOnce(VkFormat format)
        {
            return _linearFilterFallbackWarnedFormats.Add(format);
        }

        // VUID-04552 / 04553 pairing points (descriptor writes and texture arrays) must go through
        // this shared check: a linear-filtering sampler bound to a view whose VkFormat lacks
        // SAMPLED_IMAGE_FILTER_LINEAR_BIT is paired with the lazy NEAREST variant instead.
        internal Auto<DisposableSampler> SelectSampler(TextureView view)
        {
            if (view != null &&
                UsesLinearFiltering &&
                !_gd.FormatCapabilities.OptimalFormatSupports(FormatFeatureFlags.SampledImageFilterLinearBit, view.VkFormat))
            {
                if (WarnLinearFilterFallbackOnce(view.VkFormat))
                {
                    Ryujinx.Common.Logging.Logger.Warning?.Print(
                        Ryujinx.Common.Logging.LogClass.Gpu,
                        $"【黄】Format \"{view.VkFormat}\" does not support VK_FORMAT_FEATURE_SAMPLED_IMAGE_FILTER_LINEAR_BIT; " +
                        "linear-filtering sampler downgraded to nearest for this pairing.");
                }

                return GetNearestSampler();
            }

            return GetSampler();
        }

        private static BorderColor GetConstrainedBorderColor(ColorF arbitraryBorderColor, out bool cantConstrain)
        {
            float r = arbitraryBorderColor.Red;
            float g = arbitraryBorderColor.Green;
            float b = arbitraryBorderColor.Blue;
            float a = arbitraryBorderColor.Alpha;

            if (r == 0f && g == 0f && b == 0f)
            {
                if (a == 1f)
                {
                    cantConstrain = false;
                    return BorderColor.FloatOpaqueBlack;
                }

                if (a == 0f)
                {
                    cantConstrain = false;
                    return BorderColor.FloatTransparentBlack;
                }
            }
            else if (r == 1f && g == 1f && b == 1f && a == 1f)
            {
                cantConstrain = false;
                return BorderColor.FloatOpaqueWhite;
            }

            cantConstrain = true;
            return BorderColor.FloatOpaqueBlack;
        }

        public Auto<DisposableSampler> GetSampler()
        {
            return _sampler;
        }

        public void Dispose()
        {
            if (_gd.Samplers.Remove(this))
            {
                _sampler.Dispose();
                _nearestSampler?.Dispose();
            }
        }
    }
}
