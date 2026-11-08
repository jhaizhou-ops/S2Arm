using System;
using System.Buffers.Binary;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using Ryujinx.Graphics.Shader;
using Ryujinx.Graphics.Shader.Translation;

// #199：共享着色器翻译器发出的 SPIR-V 必须过 spirv-val（vulkan1.2）。两种形状各一支手造 Maxwell 程序，经真实解码器与 SPIR-V 翻译器：
//   ① 片元 + 透明测试运行时化（QueryS2ARuntimeState、AlphaTestCompare ≠ Always）：读支撑缓冲 alpha_test 的 x / y 分量；
//      alpha_test 声明成标量 U32 时访问链多一级索引（Wonder 8,532 支 "OpAccessChain reached non-composite type"）
//   ② 计算 + SUST.P（按分量写）且宿主支持无格式读（QueryHostSupportsImageLoadFormatted → ShaderProperties.GetTextureFormat 给 Unknown）：
//      存储图像按 ImageFormat.Unknown 声明，写它须声明 StorageImageWriteWithoutFormat（Wonder 24 支）
//   ③ 客体 texel buffer 数值型（VUID-07753）：SULD.P / SUST.P 1dBuffer 与 TLD（QueryTextureIsBuffer）都按 QueryTextureFormat 回的描述符
//      数值型声明 OpTypeImage Sampled Type——R32Uint 视图必须出 %uint 图像 / 采样类型，R32Float 为负对照。修复前恒按 %float 声明。
// 不跑 GPU / 设备，只证翻译器输出合法且声明类型正确；spirv-val 从 PATH 取（tests/vulkan_backend_test.sh 已要求它在）。
static class SpirvValidityChecks
{
    const ulong Sched = 0x001F8000FC0007E0UL, Exit = 0xE30000000007000FUL;
    // SUST.P 1D、RGBA 四分量、R0 坐标、R0..R3 数据、句柄 0x10、谓词 PT（InstSust 字段位）
    const ulong SustP = (0x1D65UL << 51) | (0x10UL << 36) | (0xFUL << 20) | (7UL << 16);
    // SuDim 在 33..35 位；=1 即 1dBuffer（texel buffer）
    const ulong Dim1dBuffer = 1UL << 33;
    // SULD.P 1D（0x1D61）RGBA 四分量读、R0 坐标、R0..R3 目的、句柄 0x10；加 Dim1dBuffer 变 texel buffer 读
    const ulong SuldP = (0x1D61UL << 51) | (0x10UL << 36) | (0xFUL << 20) | (7UL << 16);
    // SURED 1dBuffer（0x1D6B）SuatomSize.Sd32 原子加、R0 坐标/值、句柄 0x10；原子的图像格式必须具体（OpImageTexelPointer）
    const ulong SuredP = (0x1D6BUL << 51) | (0x10UL << 36) | Dim1dBuffer | (6UL << 20) | (7UL << 16);
    // TLD 1D（0xDC）WMask 全量、R0 坐标、R0..R3 目的、句柄 0x10；descriptor 是 buffer 时翻成 texel buffer 采样
    const ulong Tld = (0xDCUL << 56) | (0x10UL << 36) | (0xFUL << 31) | (7UL << 16);

    sealed class Accessor(byte[] code, bool fragment, TextureFormat texelFormat = TextureFormat.Unknown, bool texelIsBuffer = true, bool imageLoadFormatted = true, bool imageStoreFormatted = true) : IGpuAccessor
    {
        public ReadOnlySpan<ulong> GetCode(ulong address, int minimumSize) => MemoryMarshal.Cast<byte, ulong>(code.AsSpan(checked((int)address)));
        public bool QueryS2ARuntimeState() => true;
        public bool QueryHostSupportsImageLoadFormatted() => imageLoadFormatted;
        public bool QueryHostSupportsImageStoreFormatted() => imageStoreFormatted;
        public TextureFormat QueryTextureFormat(int handle, int cbufSlot) => texelFormat;
        public bool QueryTextureIsBuffer(int handle, int cbufSlot) => texelIsBuffer;
        public GpuGraphicsState QueryGraphicsState() => new(false, InputTopology.Triangles, false, TessPatchType.Triangles, TessSpacing.EqualSpacing, false, false, false, false, false, 1f,
            fragment ? AlphaTestOp.Greater : AlphaTestOp.Always, 0.5f, default, true, default, false, false, true, false);
        public SetBindingPair CreateConstantBufferBinding(int index) => new(0, index);
        public SetBindingPair CreateStorageBufferBinding(int index) => new(1, index);
        public SetBindingPair CreateImageBinding(int count, bool isBuffer) => new(3, 0);
        public SetBindingPair CreateTextureBinding(int count, bool isBuffer) => new(2, 0);
        public int QuerySamplerArrayLengthFromPool() => 0;
        public int QueryTextureArrayLengthFromBuffer(int index) => 0;
        public int QueryTextureArrayLengthFromPool() => 0;
    }

    // 指令流：每 4 个 8 字节一组（调度字 + 3 条），不足补 EXIT；片元前加 0x50 字节程序头（类型 2 = 片元、输出 RT0 四分量）
    static byte[] Guest(bool fragment, ulong[] ops)
    {
        int head = fragment ? 0x50 : 0, blocks = (ops.Length + 1 + 2) / 3;
        byte[] b = new byte[head + blocks * 32];
        if (fragment)
        {
            BinaryPrimitives.WriteUInt32LittleEndian(b, 2u | (3u << 5) | (5u << 10));
            BinaryPrimitives.WriteUInt32LittleEndian(b.AsSpan(72), 15);
        }
        for (int i = 0; i < blocks * 4; i++)
        {
            int oi = i / 4 * 3 + i % 4 - 1;
            BinaryPrimitives.WriteUInt64LittleEndian(b.AsSpan(head + i * 8), i % 4 == 0 ? Sched : oi < ops.Length ? ops[oi] : Exit);
        }
        return b;
    }

    static string Validate(byte[] spv)
    {
        string f = Path.Combine(Path.GetTempPath(), "s2a-spv-" + Guid.NewGuid().ToString("N") + ".spv");
        File.WriteAllBytes(f, spv);
        try
        {
            using var p = Process.Start(new ProcessStartInfo("spirv-val", $"--target-env vulkan1.2 \"{f}\"") { RedirectStandardOutput = true, RedirectStandardError = true });
            string o = p.StandardOutput.ReadToEnd() + p.StandardError.ReadToEnd();
            if (!p.WaitForExit(60_000)) { p.Kill(true); return "spirv-val 超时"; }
            return p.ExitCode == 0 ? null : o.Trim();
        }
        finally { File.Delete(f); }
    }

    static void Require(string name, byte[] spv)
    {
        if (spv is not { Length: > 4 } || BitConverter.ToUInt32(spv, 0) != 0x07230203) throw new Exception($"FAIL spirv validity {name}: 没出 SPIR-V");
        string err = Validate(spv);
        if (err != null) throw new Exception($"FAIL spirv validity {name}: {err}");
        Console.WriteLine($"PASS spirv validity {name}");
    }

    // #1339：IADD.PO（AvgMode 3）= A + B + 1。片元 MOV32I R0 = 0x12345678、R1 = 0xdeadbeef，IADD.PO R0 = R0 + R1 后由 R0 输出；翻译器常量折叠后
    //   输出里应是手算的 0x12345678 + 0xdeadbeef + 1 = 0xf0e21568，而不是忽略 .PO 的 0xf0e21567
    static ulong Mov32i(int rd, uint imm) => (0x010UL << 52) | ((ulong)imm << 20) | (0xFUL << 12) | (7UL << 16) | (uint)rd;
    const ulong IaddPoR0R0R1 = 0x5C10000000000000UL | (3UL << 48) | (1UL << 20) | (7UL << 16);
    static void IaddPlusOne()
    {
        byte[] fs = Guest(true, [Mov32i(0, 0x12345678), Mov32i(1, 0xdeadbeef), IaddPoR0R0R1]);
        string glsl = Translator.CreateContext(0, new Accessor(fs, false), new TranslationOptions(TargetLanguage.Glsl, TargetApi.Vulkan, TranslationFlags.None)).Translate().Code;
        // 折叠后 R0 作为浮点常量写到 out_attr0.x（9 位有效数字，按位可逆）
        var m = System.Text.RegularExpressions.Regex.Match(glsl, @"out_attr0\.x = ([-+0-9.Ee]+);");
        uint got = m.Success ? BitConverter.SingleToUInt32Bits(float.Parse(m.Groups[1].Value, System.Globalization.CultureInfo.InvariantCulture)) : 0;
        if (got != 0xf0e21568u) throw new Exception($"FAIL IADD.PO: 期望输出 A + B + 1 = 0xf0e21568，实际 {(m.Success ? $"0x{got:x8}" : "没折叠成常量")}：{glsl}");
        Console.WriteLine("PASS IADD.PO folds to A + B + 1 (0xf0e21568)");
    }

    // 找到声明 Dim=Buffer（操作数 =5）的 OpTypeImage（opcode 25），回报其 Sampled Type 的数值种类与
    // Image Format 操作数（第 8 个，枚举值：Unknown=0、R32ui=33、R16ui=38、R8ui=39）。
    // 采样绑定的 OpTypeSampledImage 与存储绑定的图像类型共用同一种 OpTypeImage 指令，按指令扫不必区分。
    static (string component, int imageFormat) TexelComponent(byte[] spv)
    {
        uint[] words = MemoryMarshal.Cast<byte, uint>(spv).ToArray();
        uint component = 0;
        int imageFormat = -1;
        for (int i = 5; i < words.Length;)
        {
            int length = (int)(words[i] >> 16);
            if (length == 0 || i + length > words.Length) throw new InvalidDataException("Invalid SPIR-V instruction length");
            if ((words[i] & 65535) == 25 && words[i + 3] == 5) { component = words[i + 2]; imageFormat = (int)words[i + 8]; }
            i += length;
        }
        if (component == 0) return (null, -1);
        for (int i = 5; i < words.Length;)
        {
            int length = (int)(words[i] >> 16);
            uint op = words[i] & 65535;
            if (length > 1 && (op == 21 || op == 22) && words[i + 1] == component)
                return (op == 22 ? "float" : words[i + 3] == 0 ? "uint" : "sint", imageFormat);
            i += length;
        }
        return (null, -1);
    }

    // 客体 texel buffer 的声明数值型必须跟绑定视图走（VUID-07753，9000 整屏洗白嫌疑①）：sampled（TLD，QueryTextureIsBuffer）
    // 与 storage（SULD.P / SUST.P 1dBuffer）两路径都断 OpTypeImage Sampled Type 与 GLSL 声明。修复前三者恒按 float 声明。
    // 修复后宿主支持无格式读/写时 storage texel buffer 的 Image Format 操作数必须保持 Unknown（VUID-08737：
    //   R16ui/R8ui 等扩展格式要求 StorageImageExtendedFormats capability，声明了具体格式但模块没声明 capability 被拒）；
    //   宿主不支持无格式时才回落到具体格式（扩展格式由 Declarations 补 capability）；原子（OpImageTexelPointer）永远具体格式。
    static void TexelNumericType()
    {
        const int FmtUnknown = 0, FmtR32ui = 33, FmtR16ui = 38;
        var cases = new (string name, ulong op, TextureFormat format, string expected, int imageFmt, string glslDecl, bool loadFmt, bool storeFmt)[]
        {
            ("SUST.P 1dBuffer 写 R16Uint 视图", SustP | Dim1dBuffer, TextureFormat.R16Uint, "uint", FmtUnknown, "uniform uimageBuffer", true, true),
            ("SULD.P 1dBuffer 读 R16Uint 视图", SuldP | Dim1dBuffer, TextureFormat.R16Uint, "uint", FmtUnknown, "uniform uimageBuffer", true, true),
            ("SUST.P 1dBuffer 写 R8Uint 视图", SustP | Dim1dBuffer, TextureFormat.R8Uint, "uint", FmtUnknown, "uniform uimageBuffer", true, true),
            ("SULD.P 1dBuffer 读 R8Uint 视图", SuldP | Dim1dBuffer, TextureFormat.R8Uint, "uint", FmtUnknown, "uniform uimageBuffer", true, true),
            ("SUST.P 1dBuffer 写 R32Uint 视图", SustP | Dim1dBuffer, TextureFormat.R32Uint, "uint", FmtUnknown, "uniform uimageBuffer", true, true),
            ("SULD.P 1dBuffer 读 R32Uint 视图", SuldP | Dim1dBuffer, TextureFormat.R32Uint, "uint", FmtUnknown, "uniform uimageBuffer", true, true),
            ("TLD buffer 采样 R32Uint 视图", Tld, TextureFormat.R32Uint, "uint", FmtUnknown, "uniform usamplerBuffer", true, true),
            ("SUST.P 1dBuffer 写 R32Sint 视图", SustP | Dim1dBuffer, TextureFormat.R32Sint, "sint", FmtUnknown, "uniform iimageBuffer", true, true),
            ("TLD buffer 采样 R32Sint 视图", Tld, TextureFormat.R32Sint, "sint", FmtUnknown, "uniform isamplerBuffer", true, true),
            // 宿主不支持无格式读/写：只能写具体格式，扩展格式由 Declarations 声明 StorageImageExtendedFormats 补合法（spirv-val 绿）
            ("SUST.P 1dBuffer 写 R16Uint 视图（宿主无无格式）", SustP | Dim1dBuffer, TextureFormat.R16Uint, "uint", FmtR16ui, "uniform uimageBuffer", false, false),
            ("SULD.P 1dBuffer 读 R16Uint 视图（宿主无无格式）", SuldP | Dim1dBuffer, TextureFormat.R16Uint, "uint", FmtR16ui, "uniform uimageBuffer", false, false),
            ("SUST.P 1dBuffer 写 R32Uint 视图（宿主无无格式）", SustP | Dim1dBuffer, TextureFormat.R32Uint, "uint", FmtR32ui, "uniform uimageBuffer", false, false),
            // 宿主只缺无格式写：SUST 必须写具体格式，SULD 只读仍可 Unknown
            ("SUST.P 1dBuffer 写 R16Uint 视图（宿主只缺无格式写）", SustP | Dim1dBuffer, TextureFormat.R16Uint, "uint", FmtR16ui, "uniform uimageBuffer", true, false),
            ("SULD.P 1dBuffer 读 R16Uint 视图（宿主只缺无格式写）", SuldP | Dim1dBuffer, TextureFormat.R16Uint, "uint", FmtUnknown, "uniform uimageBuffer", true, false),
            // SURED 原子（OpImageTexelPointer）必须保留具体格式：Vulkan 只接受 R64i/R64ui/R32f/R32i/R32ui（VUID-04658）
            ("SURED 1dBuffer 原子 R32Uint 视图", SuredP, TextureFormat.R32Uint, "uint", FmtR32ui, "uniform uimageBuffer", true, true),
            // 负对照：浮点 / 归一化视图仍按 float 声明——修复不是无条件 uint 化
            ("SUST.P 1dBuffer 写 R32Float 视图", SustP | Dim1dBuffer, TextureFormat.R32Float, "float", FmtUnknown, "uniform imageBuffer", true, true),
            ("SULD.P 1dBuffer 读 R8G8B8A8Unorm 视图", SuldP | Dim1dBuffer, TextureFormat.R8G8B8A8Unorm, "float", FmtUnknown, "uniform imageBuffer", true, true),
            ("TLD buffer 采样 R8G8B8A8Unorm 视图", Tld, TextureFormat.R8G8B8A8Unorm, "float", FmtUnknown, "uniform samplerBuffer", true, true),
        };
        var sopt = new TranslationOptions(TargetLanguage.Spirv, TargetApi.Vulkan, TranslationFlags.Compute);
        var gopt = new TranslationOptions(TargetLanguage.Glsl, TargetApi.Vulkan, TranslationFlags.Compute);
        foreach (var (name, op, format, expected, imageFmt, glslDecl, loadFmt, storeFmt) in cases)
        {
            byte[] guestCode = Guest(false, [op]);
            byte[] spv = Translator.CreateContext(0, new Accessor(guestCode, false, format, true, loadFmt, storeFmt), sopt).Translate().BinaryCode;
            var (got, gotFmt) = TexelComponent(spv);
            if (got != expected) throw new Exception($"FAIL texel numeric {name}: 期望 {expected} 实际 {got ?? "none"}");
            Require(name, spv);
            if (gotFmt != imageFmt) throw new Exception($"FAIL texel image format {name}: 期望操作数 {imageFmt} 实际 {gotFmt}");
            string glsl = Translator.CreateContext(0, new Accessor(guestCode, false, format), gopt).Translate().Code;
            if (!glsl.Contains(glslDecl)) throw new Exception($"FAIL texel numeric {name}: GLSL 缺 {glslDecl}：{glsl}");
            Console.WriteLine($"PASS texel numeric {name} = {got} fmt={gotFmt}（GLSL {glslDecl}）");
        }
    }

    public static void Run()
    {
        IaddPlusOne();
        var opt = new TranslationOptions(TargetLanguage.Spirv, TargetApi.Vulkan, TranslationFlags.None);
        byte[] fs = Guest(true, []);
        Require("fragment alpha-test runtime reads support_buffer.alpha_test", Translator.CreateContext(0, new Accessor(fs, true), opt).Translate().BinaryCode);
        byte[] cs = Guest(false, [SustP]);
        var copt = new TranslationOptions(TargetLanguage.Spirv, TargetApi.Vulkan, TranslationFlags.Compute);
        Require("compute SUST.P unknown-format image write", Translator.CreateContext(0, new Accessor(cs, false), copt).Translate().BinaryCode);
        TexelNumericType();
    }
}
