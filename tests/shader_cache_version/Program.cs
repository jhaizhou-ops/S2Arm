using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using NxGal;
using Ryujinx.Common.Configuration;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Gpu;
using Ryujinx.Graphics.Gpu.Shader.DiskCache;
using S2A.Gfx;

static class Program
{
    [DllImport("libc", SetLastError = true)]
    private static extern int setenv(string name, string value, int overwrite);

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new InvalidOperationException(message);
    }

    private static void SetEnvironment(string name, string value)
    {
        Environment.SetEnvironmentVariable(name, value);
        Check(setenv(name, value, 1) == 0, $"setenv {name} failed: {Marshal.GetLastPInvokeError()}");
    }

    private static Dictionary<string, byte[]> ReadFiles(string directory) =>
        Directory.GetFiles(directory, "*", SearchOption.AllDirectories)
            .ToDictionary(path => Path.GetRelativePath(directory, path), File.ReadAllBytes, StringComparer.Ordinal);

    private static void Compare(string directory, Dictionary<string, byte[]> expected, string label)
    {
        Dictionary<string, byte[]> actual = ReadFiles(directory);
        Check(expected.Keys.Order().SequenceEqual(actual.Keys.Order()), $"{label}: file list changed");
        foreach ((string name, byte[] bytes) in expected)
        {
            Check(bytes.AsSpan().SequenceEqual(actual[name]), $"{label}: bytes changed: {name}");
            Check(SHA256.HashData(bytes).AsSpan().SequenceEqual(SHA256.HashData(actual[name])),
                $"{label}: SHA256 changed: {name}");
        }
    }

    private static int Main(string[] args)
    {
        if (args.Length != 3) throw new ArgumentException(
            "ShaderCacheVersionTest <real-runtime-cache-directory> <real-old-shader-pack-directory> <title-id>");
        string input = Path.GetFullPath(args[0]), pack = Path.GetFullPath(args[1]), title = args[2].ToLowerInvariant();
        Check(title.Length == 16 && title.All(Uri.IsHexDigit), "Title ID must be 16 hexadecimal digits");
        string source = Path.Combine(pack, "shcache", title);
        Check(S2AShaderCacheGuard.HasCurrentCode(input, out uint runtimeVersion), "Input must be a current real runtime cache");
        Check(!S2AShaderCacheGuard.HasCurrentCode(source, out uint packVersion), "Pack must contain an older real cache");
        Check(runtimeVersion == 7360 && packVersion == 7359, "This regression requires real 7360 runtime and 7359 pack inputs");
        Check(new FileInfo(Path.Combine(input, "shared.toc")).Length < new FileInfo(Path.Combine(source, "shared.toc")).Length,
            "Runtime cache must be shorter than the old pack, reproducing the overwrite trigger");
        Dictionary<string, byte[]> original = ReadFiles(input);
        Check(original.Count > 0, "Input cache is empty");

        // Custom mode writes macOS logs outside BaseDirPath. Real portable mode keeps all AppDataManager paths here.
        string root = Path.Combine(AppContext.BaseDirectory, "portable");
        Check(!Directory.Exists(root), $"Use a fresh output directory; test will not overwrite {root}");
        Directory.CreateDirectory(root);
        AppDataManager.Initialize(null);
        Check(AppDataManager.Mode == AppDataManager.LaunchMode.Portable, "AppDataManager did not select portable mode");
        Check(AppDataManager.BaseDirPath == root, "AppDataManager root escaped the isolated directory");
        Check(AppDataManager.GamesDirPath == Path.Combine(root, "games"), "Games directory escaped the isolated root");
        Check(AppDataManager.LogsDirPath == Path.Combine(root, "Logs"), "Logs directory escaped the isolated root");
        Console.WriteLine($"Isolated AppDataManager root: {root}");

        string destination = Path.Combine(AppDataManager.GamesDirPath, title, "cache", "shader");
        Directory.CreateDirectory(destination);
        foreach ((string name, byte[] bytes) in original)
        {
            string target = Path.Combine(destination, name);
            Directory.CreateDirectory(Path.GetDirectoryName(target)!);
            using FileStream file = new(target, FileMode.CreateNew);
            file.Write(bytes);
        }
        SetEnvironment("S2A_COLD_START", "0");
        SetEnvironment("S2A_RYU_DATA", root);
        SetEnvironment("S2A_DOCS", root);
        SetEnvironment("NXGAL_SHADER_CACHE_DIR", Path.Combine(root, "gal_msl"));
        SetEnvironment("NXGAL_PSO_DEV_DIR", Path.Combine(root, "pso_dev"));
        SetEnvironment("S2A_SHADER_PACK", pack);
        GraphicsConfig.TitleId = title;
        GraphicsConfig.EnableShaderCache = true;

        using var renderer = new NxRenderer();
        renderer.Initialize(GraphicsDebugLevel.None);
        Console.WriteLine("Real NxRenderer Metal initialization succeeded");
        Type shaderPack = typeof(RenderLoop).Assembly.GetType("S2A.Gfx.ShaderPack", throwOnError: true)!;
        MethodInfo mount = shaderPack.GetMethod("Mount", BindingFlags.Static | BindingFlags.Public)!;
        for (int attempt = 1; attempt <= 2; attempt++)
        {
            // Use the real old pack's program count to detect stale static metadata surviving a repeated mount.
            S2AShaderCacheGuard.PackPrograms = checked((int)((new FileInfo(Path.Combine(source, "shared.toc")).Length - 32) / 8));
            mount.Invoke(null, null);
            Check(S2AShaderCacheGuard.PackPrograms == 0, $"Mount {attempt}: old pack programs enabled");
            Check(S2AShaderCacheGuard.WarmList == null, $"Mount {attempt}: old pack warm list enabled");
            Check(S2AShaderCacheGuard.HasCurrentCode(destination, out uint version) && version == runtimeVersion,
                $"Mount {attempt}: runtime translator version changed");
            Compare(destination, original, $"Mount {attempt}");
            Compare(input, original, $"Input after mount {attempt}");
            Console.WriteLine($"PASS mount {attempt}: {original.Count} real cache files byte/SHA256 identical, version {version}, PackPrograms=0, WarmList=null");
        }
        foreach ((string name, byte[] bytes) in original.OrderBy(entry => entry.Key))
            Console.WriteLine($"SHA256 {Convert.ToHexStringLower(SHA256.HashData(bytes))} {bytes.Length} {name}");
        Console.WriteLine("PASS: two real production mounts preserved the complete runtime cache; no cache was cleared");
        return 0;
    }
}
