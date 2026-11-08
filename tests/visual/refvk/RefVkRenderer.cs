// 参照渲染器：Ryujinx 自带 Vulkan 后端（VulkanRenderer）无窗口跑在本机 MoltenVK 上。
// 做法：离屏 CAMetalLayer（不挂任何窗口）→ VK_EXT_metal_surface 建 surface → VulkanRenderer.Initialize 建交换链。
// 与 Ryujinx macOS 前端同口径：不经 Vulkan loader，直接把 libMoltenVK 当 libvulkan 载入（见 MVKInitialization.InitializeResolver），
// 实例扩展只要 VK_KHR_surface + VK_EXT_metal_surface（SPB VulkanHelper 在 macOS 上给的就是这两个）。
// MoltenVK 路径：环境变量 REFVK_MOLTENVK，缺省 /opt/homebrew/lib/libMoltenVK.dylib。
using Ryujinx.Common.Configuration;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Vulkan;
using Silk.NET.Core.Loader;
using Silk.NET.Vulkan;
using Silk.NET.Vulkan.Extensions.EXT;
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;

namespace RefVk
{
    public static unsafe class RefVkRenderer
    {
        public const int Width = 1280;
        public const int Height = 720;

        private const string DefaultMoltenVk = "/opt/homebrew/lib/libMoltenVK.dylib";
        private const string QuartzCore = "/System/Library/Frameworks/QuartzCore.framework/QuartzCore";
        private const string ObjC = "/usr/lib/libobjc.A.dylib";

        private static readonly object _lock = new();
        private static bool _resolversInstalled;
        private static nint _layer;

        /// <summary>最近一次 Create 里 Initialize 的耗时（毫秒）。</summary>
        public static double LastInitializeMs { get; private set; }

        /// <summary>实际载入的 MoltenVK 路径。</summary>
        public static string MoltenVkPath { get; private set; }

        /// <summary>建一个已 Initialize 的 VulkanRenderer（离屏 1280×720，MoltenVK）。</summary>
        public static IRenderer Create(GraphicsDebugLevel logLevel = GraphicsDebugLevel.None)
        {
            if (!OperatingSystem.IsMacOS())
            {
                throw new PlatformNotSupportedException("RefVk 只支持 macOS（MoltenVK）");
            }

            lock (_lock)
            {
                InstallResolvers();

                if (_layer == 0)
                {
                    _layer = CreateOffscreenLayer(Width, Height);
                }
            }

            nint layer = _layer;

            VulkanRenderer renderer = VulkanRenderer.Create(
                string.Empty,
                (instance, vk) => CreateSurface(instance, vk, layer),
                () => ["VK_KHR_surface", "VK_EXT_metal_surface"]);

            Stopwatch sw = Stopwatch.StartNew();
            renderer.Initialize(logLevel);
            LastInitializeMs = sw.Elapsed.TotalMilliseconds;

            return renderer;
        }

        private static void InstallResolvers()
        {
            if (_resolversInstalled)
            {
                return;
            }

            string mvk = Environment.GetEnvironmentVariable("REFVK_MOLTENVK");
            if (string.IsNullOrEmpty(mvk))
            {
                mvk = DefaultMoltenVk;
            }

            if (!System.IO.File.Exists(mvk))
            {
                throw new DllNotFoundException($"找不到 MoltenVK：{mvk}（可用 REFVK_MOLTENVK 指定）");
            }

            MoltenVkPath = mvk;

            // Silk 载 Vulkan 时把任何 libvulkan* 名字都换成 MoltenVK 绝对路径（同 Ryujinx MVKInitialization.InitializeResolver 的意图，路径改为绝对）。
            ((DefaultPathResolver)PathResolver.Default).Resolvers.Insert(0, path =>
                path.Contains("vulkan", StringComparison.OrdinalIgnoreCase) ? new[] { mvk } : Array.Empty<string>());

            // Vulkan 后端里 [LibraryImport("libMoltenVK.dylib")]（vkGet/SetMoltenVKConfigurationMVK）解析到同一个库。
            NativeLibrary.SetDllImportResolver(typeof(VulkanRenderer).Assembly, (name, asm, searchPath) =>
                name.Contains("MoltenVK", StringComparison.OrdinalIgnoreCase) ? NativeLibrary.Load(mvk) : 0);

            _resolversInstalled = true;
        }

        private static SurfaceKHR CreateSurface(Instance instance, Vk vk, nint layer)
        {
            if (!vk.TryGetInstanceExtension(instance, out ExtMetalSurface metalSurface))
            {
                throw new InvalidOperationException("实例上拿不到 VK_EXT_metal_surface");
            }

            MetalSurfaceCreateInfoEXT info = new()
            {
                SType = StructureType.MetalSurfaceCreateInfoExt,
                PLayer = (nint*)layer,
            };

            Result r = metalSurface.CreateMetalSurface(instance, &info, null, out SurfaceKHR surface);
            if (r != Result.Success)
            {
                throw new InvalidOperationException($"vkCreateMetalSurfaceEXT 失败：{r}");
            }

            return surface;
        }

        // ---- 离屏 CAMetalLayer（ObjC 运行时直调，不建窗口、不连 WindowServer 显示） ----

        [StructLayout(LayoutKind.Sequential)]
        private struct CGSize
        {
            public double Width;
            public double Height;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct CGRect
        {
            public double X;
            public double Y;
            public double Width;
            public double Height;
        }

        [DllImport(ObjC)]
        private static extern nint objc_getClass(string name);

        [DllImport(ObjC)]
        private static extern nint sel_registerName(string name);

        [DllImport(ObjC, EntryPoint = "objc_msgSend")]
        private static extern nint MsgSend(nint receiver, nint selector);

        [DllImport(ObjC, EntryPoint = "objc_msgSend")]
        private static extern void MsgSendSize(nint receiver, nint selector, CGSize size);

        [DllImport(ObjC, EntryPoint = "objc_msgSend")]
        private static extern void MsgSendRect(nint receiver, nint selector, CGRect rect);

        [DllImport(ObjC, EntryPoint = "objc_msgSend")]
        private static extern void MsgSendDouble(nint receiver, nint selector, double value);

        private static nint CreateOffscreenLayer(int width, int height)
        {
            NativeLibrary.Load(QuartzCore);

            nint cls = objc_getClass("CAMetalLayer");
            if (cls == 0)
            {
                throw new InvalidOperationException("objc_getClass(CAMetalLayer) 失败");
            }

            nint layer = MsgSend(cls, sel_registerName("layer"));
            if (layer == 0)
            {
                throw new InvalidOperationException("[CAMetalLayer layer] 返回空");
            }

            MsgSend(layer, sel_registerName("retain")); // [CAMetalLayer layer] 是 autorelease 对象，进程内常驻，手动持有

            MsgSendDouble(layer, sel_registerName("setContentsScale:"), 1.0);
            MsgSendRect(layer, sel_registerName("setFrame:"), new CGRect { Width = width, Height = height });
            MsgSendSize(layer, sel_registerName("setDrawableSize:"), new CGSize { Width = width, Height = height });

            return layer;
        }
    }
}
