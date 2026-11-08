// CPU execution of the production helper IR: no GPU, texture stand-in or shader
// fixture is needed. Reflection keeps translator internals out of the public API.
using System.Collections;
using System.Reflection;
using System.Runtime.InteropServices;
using Ryujinx.Graphics.Shader;

static class Program
{
    static int checks;
    static void Check(bool ok, string name) { checks++; if (!ok) throw new Exception(name); }
    static object P(object o, string name) => o.GetType().GetProperty(name)!.GetValue(o);
    static int N(object o, string name) => (int)P(o, name);
    static int Bits(float f) => BitConverter.SingleToInt32Bits(f);
    static float Float(int b) => BitConverter.Int32BitsToSingle(b);

    sealed class Helpers
    {
        readonly IList functions;
        readonly object manager;
        readonly Type names;
        public readonly int Fetch, Size;
        public float FragmentX = 3.5f, FragmentY = 7.5f;

        public Helpers(ShaderStage stage)
        {
            var asm = typeof(SupportBuffer).Assembly;
            Type fn = asm.GetType("Ryujinx.Graphics.Shader.IntermediateRepresentation.Function")!;
            functions = (IList)Activator.CreateInstance(typeof(List<>).MakeGenericType(fn))!;
            Type hfm = asm.GetType("Ryujinx.Graphics.Shader.Translation.HelperFunctionManager")!;
            names = asm.GetType("Ryujinx.Graphics.Shader.Translation.HelperFunctionName")!;
            manager = Activator.CreateInstance(hfm, functions, stage)!;
            Fetch = Id("TexelFetchScaleExact"); Size = Id("TextureSizeExact");
        }
        public int Id(string name) => (int)manager.GetType().GetMethod("GetOrCreateFunctionId", [names])!.Invoke(manager, [Enum.Parse(names, name)])!;

        public int Run(int id, byte[] support, params int[] args)
        {
            var values = new Dictionary<object, int>();
            int Read(object operand) => P(operand, "Type").ToString() switch
            {
                "Constant" => N(operand, "Value"),
                "Argument" => args[N(operand, "Value")],
                "LocalVariable" => values[operand],
                _ => throw new Exception("Unexpected operand " + P(operand, "Type")),
            };
            object block = ((Array)P(functions[id], "Blocks")).GetValue(0)!;
            while (block != null)
            {
                object next = P(block, "Next");
                foreach (object op in (IEnumerable)P(block, "Operations"))
                {
                    var inst = P(op, "Inst"); int code = Convert.ToInt32(inst);
                    string name = Enum.GetName(inst.GetType(), code & 0xffff)!;
                    bool fp = (code & (1 << 16)) != 0;
                    object Source(int i) => op.GetType().GetMethod("GetSource")!.Invoke(op, [i])!;
                    int A(int i) => Read(Source(i));
                    if (name == "Return") return A(0);
                    if (name is "BranchIfTrue" or "BranchIfFalse")
                    {
                        if ((A(0) != 0) == (name == "BranchIfTrue")) next = P(block, "Branch");
                        continue;
                    }
                    if (name == "Branch") { next = P(block, "Branch"); continue; }
                    int result;
                    if (name == "Load")
                    {
                        if (P(op, "StorageKind").ToString() == "Input") result = Bits(A(N(op, "SourcesCount") - 1) == 1 ? FragmentY : FragmentX);
                        else
                        {
                            Check(A(0) == 0, "production helper support binding");
                            int field = A(1), offset = field switch { 4 => 176, 5 => 192, 11 => 1440, 12 => 2608, _ => throw new Exception("Unexpected field " + field) };
                            if (N(op, "SourcesCount") > 2) offset += 16 * A(2);
                            if (N(op, "SourcesCount") > 3) offset += 4 * A(3);
                            result = BitConverter.ToInt32(support, offset);
                        }
                    }
                    else if (name == "Call") result = Run(A(0), support, Enumerable.Range(1, N(op, "SourcesCount") - 1).Select(A).ToArray());
                    else result = name switch
                    {
                        "Add" => fp ? Bits(Float(A(0)) + Float(A(1))) : unchecked(A(0) + A(1)),
                        "Multiply" => fp ? Bits(Float(A(0)) * Float(A(1))) : unchecked(A(0) * A(1)),
                        "BitwiseAnd" => A(0) & A(1),
                        "Divide" => fp ? Bits(Float(A(0)) / Float(A(1))) : A(0) / A(1),
                        "ShiftRightU32" => (int)((uint)A(0) >> A(1)),
                        "Maximum" => Math.Max(A(0), A(1)),
                        "MaximumU32" => (int)Math.Max((uint)A(0), (uint)A(1)),
                        "MinimumU32" => (int)Math.Min((uint)A(0), (uint)A(1)),
                        "CompareEqual" => (fp ? Float(A(0)) == Float(A(1)) : A(0) == A(1)) ? -1 : 0,
                        "CompareNotEqual" => A(0) != A(1) ? -1 : 0,
                        "CompareLess" => (fp ? Float(A(0)) < Float(A(1)) : A(0) < A(1)) ? -1 : 0,
                        "ConditionalSelect" => A(0) != 0 ? A(1) : A(2),
                        "ConvertS32ToFP32" => Bits(A(0)),
                        "ConvertFP32ToS32" => (int)Float(A(0)),
                        "Absolute" when fp => Bits(MathF.Abs(Float(A(0)))),
                        "Negate" when fp => Bits(-Float(A(0))),
                        "Modulo" when fp => Bits(Float(A(0)) - Float(A(1)) * MathF.Floor(Float(A(0)) / Float(A(1)))),
                        _ => throw new Exception("Unexpected production IR " + inst),
                    };
                    values[P(op, "Dest")] = result;
                }
                block = next;
            }
            throw new Exception("Production helper did not return");
        }
    }

    static byte[] Buffer(int logicalW, int logicalH, int physicalW, int physicalH, float x = 1f, float y = 1f, int targetW = 0, int targetH = 0, int physicalTargetW = 0, int physicalTargetH = 0)
    {
        SupportBuffer sb = new();
        for (int i = 0; i < SupportBuffer.RenderScaleMaxCount; i++) { sb.RenderScale[i].X = x; sb.RenderScaleY[i].X = y; }
        sb.TextureSizes[3] = new Vector4<int> { X = logicalW, Y = logicalH, Z = physicalW, W = physicalH };
        sb.TextureSizes[0] = new Vector4<int> { X = targetW, Y = targetH, Z = physicalTargetW, W = physicalTargetH };
        return MemoryMarshal.AsBytes(MemoryMarshal.CreateSpan(ref sb, 1)).ToArray();
    }

    static void Main()
    {
        Check(SupportBuffer.TextureSizeTableAbi == 2 && SupportBuffer.TextureSizesOffset == 2608 && SupportBuffer.RequiredSize == 3776, "support table ABI");
        int[][] physical = [[4, 3], [6, 4], [7, 5], [11, 8], [14, 10]];
        int[][] logicalMips = [[7, 5], [3, 2], [1, 1], [1, 1]];
        foreach (ShaderStage stage in new[] { ShaderStage.Vertex, ShaderStage.Fragment, ShaderStage.Compute })
        {
            var h = new Helpers(stage);
            foreach (int[] dimensions in physical)
            {
                // A deliberately different target ratio disables phase while
                // keeping F consistent with the real selected target.
                byte[] sb = Buffer(7, 5, dimensions[0], dimensions[1], 3f, 3f, 100, 100, 300, 300);
                for (int lod = 0; lod < 4; lod++) for (int axis = 0; axis < 2; axis++)
                {
                    int logical = logicalMips[lod][axis], actual = dimensions[axis];
                    for (int l = 0; l < lod; l++) actual = Math.Max(actual / 2, 1);
                    Check(h.Run(h.Size, sb, actual, 2, axis, lod) == logical, $"{stage} odd mip logical size");
                    for (int coordinate = 0; coordinate < logical; coordinate++)
                        Check(h.Run(h.Fetch, sb, coordinate, 2, axis, lod, 2) == (int)decimal.Floor((decimal)coordinate * actual / logical), $"{stage} mip coordinate");
                }
                Check(h.Run(h.Size, sb, 1, 2, 0, 80) == 1, "oversized LOD shift is defined");
            }
            byte[] zero = Buffer(0, 0, 0, 0);
            foreach (int axis in new[] { 0, 1 }) foreach (int value in new[] { int.MinValue, -16777217, -1, 0, 1, 7, 16383, 16777217, int.MaxValue })
            {
                Check(h.Run(h.Fetch, zero, value, 2, axis, 1, 2) == value, "zero table 1x fetch identity");
                Check(h.Run(h.Size, zero, value, 2, axis, 1) == value, "zero table 1x size identity");
            }
            byte[] identity = Buffer(16383, 8191, 16383, 8191, -1f, -1f, 16383, 8191, 16383, 8191);
            h.FragmentX = h.FragmentY = 0.5f;
            foreach (int axis in new[] { 0, 1 }) foreach (int lod in new[] { -1, 0, 1, 31, 80 })
                foreach (int value in new[] { int.MinValue, -16777217, -1, 0, 1, 16777217, int.MaxValue })
                    Check(h.Run(h.Fetch, identity, value, 2, axis, lod, 2) == value, "filled 1x table preserves every integer before phase and multiplication");
            byte[] old = Buffer(0, 0, 0, 0, 2f, 1.5f);
            foreach (int axis in new[] { 0, 1 })
            {
                string suffix = axis == 1 && stage == ShaderStage.Fragment ? "Y" : "";
                Check(h.Run(h.Fetch, old, 7, 2, axis, 1, 2) == h.Run(h.Id("TexelFetchScale" + suffix), old, 7, 2, axis), "zero table legacy fetch parity");
                Check(h.Run(h.Size, old, 7, 2, axis, 1) == h.Run(h.Id("TextureSizeUnscale" + suffix), old, 7, 2), "zero table legacy query parity");
            }
            if (stage == ShaderStage.Fragment)
            {
                byte[] mipTarget = Buffer(7, 5, 11, 8, 5f / 3f, 2f, 3, 2, 5, 4);
                for (int pixel = 0; pixel < 5; pixel++)
                {
                    h.FragmentX = pixel + 0.5f;
                    int logicalCoordinate = (int)((pixel + 0.5f) / (5f / 3f));
                    Check(h.Run(h.Fetch, mipTarget, logicalCoordinate, 2, 0, 1, 2) == pixel, "LOD1 7→11 uses target 3→5 phase despite positive base sign");
                }
                byte[] baseTarget = Buffer(7, 5, 11, 8, -11f / 7f, -8f / 5f, 7, 5, 11, 8);
                // The fragment divisor remains positive even though a matching
                // source uses a negative legacy scale to enable its phase.
                BitConverter.GetBytes(11f / 7f).CopyTo(baseTarget, 192);
                BitConverter.GetBytes(8f / 5f).CopyTo(baseTarget, 1440);
                h.FragmentX = 0.5f;
                Check(h.Run(h.Fetch, baseTarget, 1, 2, 0, 1, 2) == 1, "LOD1 ratio differs from base target, suppress legacy negative phase");
                foreach (int[] dimensions in physical)
                {
                    for (int lod = 0; lod < 4; lod++) foreach (int axis in new[] { 0, 1 })
                    {
                        int logical = logicalMips[lod][axis], actual = dimensions[axis];
                        for (int l = 0; l < lod; l++) actual = Math.Max(actual / 2, 1);
                        byte[] phased = Buffer(7, 5, dimensions[0], dimensions[1], (float)actual / logical, (float)actual / logical,
                            logical, logical, actual, actual);
                        for (int pixel = 0; pixel < actual; pixel++)
                        {
                            h.FragmentX = h.FragmentY = pixel + 0.5f;
                            int coord = (int)((pixel + 0.5f) / ((float)actual / logical));
                            Check(h.Run(h.Fetch, phased, coord, 2, axis, lod, 2) == pixel, "same-target fragment phase keeps each physical mip pixel");
                        }
                    }
                }
                // PAGE/KEEP use an existing F that differs from the target's P/L.
                // Both positive and negative legacy source signs must remain exact.
                foreach (float signedScale in new[] { -1.5f, 1.5f })
                    foreach (bool targetKnown in new[] { false, true })
                    {
                        byte[] page = Buffer(8, 8, 12, 12, signedScale, signedScale,
                            targetKnown ? 8 : 0, targetKnown ? 8 : 0, targetKnown ? 16 : 0, targetKnown ? 16 : 0);
                        BitConverter.GetBytes(1f).CopyTo(page, 192);
                        BitConverter.GetBytes(1f).CopyTo(page, 1440);
                        foreach (int axis in new[] { 0, 1 }) foreach (int value in new[] { -3, -1, 0, 1, 7 })
                            foreach (float frag in new[] { 0.5f, 3.5f, 9.5f })
                            {
                                h.FragmentX = h.FragmentY = frag;
                                string suffix = axis == 1 ? "Y" : "";
                                Check(h.Run(h.Fetch, page, value, 2, axis, 0, 2) == h.Run(h.Id("TexelFetchScale" + suffix), page, value, 2, axis),
                                    "F mismatch or unknown target retains legacy signed-scale phase");
                            }
                    }
                foreach (bool targetKnown in new[] { false, true })
                    {
                        byte[] selectedMip = Buffer(7, 5, 11, 8, -11f / 7f, -8f / 5f,
                            targetKnown ? 8 : 0, targetKnown ? 8 : 0, targetKnown ? 16 : 0, targetKnown ? 16 : 0);
                        BitConverter.GetBytes(11f / 7f).CopyTo(selectedMip, 192);
                        BitConverter.GetBytes(8f / 5f).CopyTo(selectedMip, 1440);
                        h.FragmentX = 0.35f;
                        Check(h.Run(h.Fetch, selectedMip, 1, 2, 0, 1, 2) == 2,
                            "F mismatch retains selected-mip input ratio and only legacy phase");
                        Check(h.Run(h.Id("TexelFetchScale"), selectedMip, 1, 2, 0) == 1,
                            "selected-mip regression distinguishes whole-helper legacy fallback");
                    }
            }
        }
        Check((int)(1 / (3f / 5f)) != 2, "old float reverse-scale loses odd mip size (5→3 base, mip 1 is 2→1)");
        Console.WriteLine($"Direct resolution production helper IR: {checks} checks passed (CPU only)");
    }
}
