using NxGal;
using Ryujinx.Common.Configuration;
using Ryujinx.Common.Memory;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Gpu;
using S2A.Services;
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;

static unsafe class Program
{
    [DllImport("nxgal")] static extern int nxgal_screenshot(byte* data, int cap, out int w, out int h);
    [DllImport("nxgal")] static extern int nxgal_screenshot_processed(byte* data, int cap, out int w, out int h);
    [DllImport("nxgal")] static extern int nxgal_window_render_to(uint tex);
    static readonly string[] Variables = ["S2A_RES_SCALE", "S2A_ANTI_ALIASING", "S2A_SCALING_FILTER"];

    static void Check(bool ok, string what)
    {
        if (!ok) throw new InvalidOperationException(what);
    }
    static TextureCreateInfo Info(int w, int h) => new(w, h, 1, 1, 1, 1, 1, 4, Format.B8G8R8A8Unorm,
        DepthStencilMode.Depth, Target.Texture2D, SwizzleComponent.Red, SwizzleComponent.Green, SwizzleComponent.Blue, SwizzleComponent.Alpha);

    static byte[] Snapshot(bool processed, int w, int h)
    {
        int n = processed ? nxgal_screenshot_processed(null, 0, out int _, out int _) : nxgal_screenshot(null, 0, out int _, out int _);
        Check(n == w * h * 4, "定格帧的尺寸与实际输入一致");
        byte[] data = new byte[n];
        int actualW, actualH, got;
        fixed (byte* p = data) got = processed ? nxgal_screenshot_processed(p, n, out actualW, out actualH) : nxgal_screenshot(p, n, out actualW, out actualH);
        Check(got == n && actualW == w && actualH == h, "读取同一尺寸的完整定格帧");
        return data;
    }

    static int Main(string[] args)
    {
        if (args.Length != 2) return 2;
        string[] previous = Variables.Select(Environment.GetEnvironmentVariable).ToArray();
        NativeLibrary.SetDllImportResolver(typeof(Program).Assembly, (name, assembly, search) =>
            name == "nxgal" ? NativeLibrary.Load(Environment.GetEnvironmentVariable("NXGAL_LIB")) : IntPtr.Zero);
        try
        {
            using JsonDocument manifest = JsonDocument.Parse(File.ReadAllText(args[0]));
            JsonElement root = manifest.RootElement;
            string[] scales = root.GetProperty("scales").EnumerateArray().Select(x => x.GetString()).ToArray();
            string[] modes = root.GetProperty("aa").EnumerateArray().Select(x => x.GetString()).ToArray();
            string[] filters = root.GetProperty("filters").EnumerateArray().Select(x => x.GetString()).ToArray();
            int w = root.GetProperty("width").GetInt32(), h = root.GetProperty("height").GetInt32();
            byte[] image = File.ReadAllBytes(root.GetProperty("pixels").GetString());
            Check(image.Length == w * h * 4, "真实游戏图像完整");
            Directory.CreateDirectory(args[1]);
            foreach (string variable in Variables) Environment.SetEnvironmentVariable(variable, null);
            using var renderer = new NxRenderer();
            renderer.Initialize(GraphicsDebugLevel.None);
            GraphicsSettings.Apply(renderer);
            Check(GraphicsConfig.ResScale == 1, "首次启动默认1x");
            var source = renderer.CreateTexture(Info(w, h));
            source.SetData(MemoryOwner<byte>.RentCopy(image));
            var destination = (NxTexture)renderer.CreateTexture(Info(w * 3 / 2, h * 3 / 2));
            var crop = new ImageCrop(0, 0, 0, 0, false, false, true, w, h);
            var reports = new List<object>();
            var modeHashes = new Dictionary<string, string>();
            var filterHashes = new Dictionary<string, string>();
            int cases = 0;
            foreach (string scale in scales)
            foreach (string mode in modes)
            foreach (string filter in filters)
            {
                Environment.SetEnvironmentVariable(Variables[0], scale);
                Environment.SetEnvironmentVariable(Variables[1], mode);
                Environment.SetEnvironmentVariable(Variables[2], filter);
                GraphicsSettings.Apply(renderer);
                Check(GraphicsConfig.ResScale == float.Parse(scale, CultureInfo.InvariantCulture), "菜单倍率传入GPU配置");
                renderer.Window.Present(source, crop, null);
                byte[] raw = Snapshot(false, w, h), processed = Snapshot(true, w, h);
                Check(raw.AsSpan().SequenceEqual(image), "原始诊断截图不受后处理设置影响");
                int changed = 0;
                for (int i = 0; i < processed.Length; i += 4)
                {
                    Check(processed[i + 3] == 255, "抗锯齿输出保持不透明");
                    if (!processed.AsSpan(i, 3).SequenceEqual(raw.AsSpan(i, 3))) changed++;
                }
                Check(mode == "None" ? changed == 0 : changed > 0, "关闭时逐字节一致，开启时真实游戏帧产生抗锯齿效果");
                Check(nxgal_window_render_to(destination.Id) == 0, "后处理结果通过真实上屏缩放路径");
                using var pixels = destination.GetData(0, 0);
                string processedHash = Convert.ToHexString(SHA256.HashData(processed));
                string displayHash = Convert.ToHexString(SHA256.HashData(pixels.Get()));
                if (scale == "1")
                {
                    modeHashes[mode] = processedHash;
                    filterHashes[$"{mode}/{filter}"] = displayHash;
                    if (filter == "Bilinear") File.WriteAllBytes(Path.Combine(args[1], $"{mode}.bgra"), processed);
                }
                reports.Add(new { scale, mode, filter, width = w, height = h, changedPixels = changed, processedHash, displayHash });
                cases++;
            }
            Check(modeHashes.Values.Distinct().Count() == modes.Length, "关闭、SMAA中、高实际输出不同");
            foreach (string mode in modes) Check(filterHashes[$"{mode}/Bilinear"] != filterHashes[$"{mode}/Nearest"], "双线性与最近邻实际缩放输出不同");

            foreach ((string variable, string invalid) in new[] { (Variables[0], "0"), (Variables[0], "NaN"), (Variables[0], "1,5"), (Variables[1], "Msaa"), (Variables[2], "Fsr") })
            {
                Environment.SetEnvironmentVariable(Variables[0], "1");
                Environment.SetEnvironmentVariable(Variables[1], "None");
                Environment.SetEnvironmentVariable(Variables[2], "Bilinear");
                Environment.SetEnvironmentVariable(variable, invalid);
                bool rejected = false;
                try { GraphicsSettings.Apply(renderer); }
                catch (ArgumentOutOfRangeException exception) { rejected = exception.ParamName == variable; }
                Check(rejected, $"非法参数 {variable}={invalid} 被明确拒绝");
            }
            File.WriteAllText(Path.Combine(args[1], "results.json"), JsonSerializer.Serialize(reports, new JsonSerializerOptions { WriteIndented = true }));
            source.Release();
            destination.Release();
            Console.WriteLine($"画面设置真实Metal集成：{cases} 个菜单组合通过；四种AA与两种缩放滤镜输出已核对。分辨率纹理创建另由真实游戏局验证。");
            return 0;
        }
        finally
        {
            for (int i = 0; i < Variables.Length; i++) Environment.SetEnvironmentVariable(Variables[i], previous[i]);
        }
    }
}
