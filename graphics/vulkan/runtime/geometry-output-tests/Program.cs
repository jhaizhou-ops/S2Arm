using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Gpu.Engine.Threed.ComputeDraw;

static class Program
{
    static int failures;
    static void Check(bool condition, string message)
    {
        if (!condition) { Console.WriteLine("FAIL " + message); failures++; }
        else Console.WriteLine("PASS " + message);
    }

    static void Case(int count, int instances, int primitives, int maxOut, int vpp, int threads, string name)
    {
        var (slots, vertices, indices) = VtgAsComputeGeometryOutput.Layout(count, instances, primitives, maxOut, vpp, threads);
        int stride = (maxOut + maxOut / vpp) * threads;
        var written = new HashSet<int>();
        for (int instance = 0; instance < instances; instance++)
            for (int primitive = 0; primitive < primitives; primitive++)
                for (int i = 0; i < stride; i++)
                    written.Add((instance * count + primitive) * stride + i);
        Check(written.All(i => i < indices), name + " shader writes fit index allocation");
        Check(vertices == slots * maxOut * threads, name + " vertex allocation");
        var pipe = new FakePipeline(indices);
        var range = new BufferRange(7, 64, indices * sizeof(uint));
        VtgAsComputeGeometryOutput.ClearAndDispatch(pipe, range, 2, 3, threads);
        Check(pipe.Events.SequenceEqual(new[] { $"clear:7:64:{indices * 4}:FFFFFFFF", $"dispatch:2:3:{threads}" }), name + " clear covers draw before dispatch");
        foreach (int i in written.Where(i => i < indices)) pipe.Data[i] = 42;
        Check(Enumerable.Range(0, indices).Where(i => !written.Contains(i)).All(i => pipe.Data[i] == uint.MaxValue), name + " holes are restart indices");
    }

    static int Main()
    {
        Case(4, 32, 2, 3, 3, 1, "strip 4x32");
        Case(3, 32, 1, 3, 3, 1, "triangles 3x32");
        Case(4, 32, 2, 3, 3, 1, "quads 4x32");
        Case(3, 2, 1, 3, 3, 4, "multiple invocations");
        var (_, _, one) = VtgAsComputeGeometryOutput.Layout(4, 1, 2, 3, 3, 1);
        Check(one == 8, "single instance unchanged");
        Check(VtgAsComputeGeometryOutput.Layout(1, 32, 0, 3, 3, 1).Indices == 0, "no primitives allocates no indices");
        Check(VtgAsComputeGeometryOutput.Layout(4, 0, 2, 3, 3, 1).Indices == 0, "zero instances allocates no indices");
        try { VtgAsComputeGeometryOutput.Layout(int.MaxValue, 2, 1, 3, 3, 1); Check(false, "overflow rejected"); }
        catch (OverflowException) { Check(true, "overflow rejected"); }
        Console.WriteLine($"geometry output: {failures} failures");
        return failures == 0 ? 0 : 1;
    }
}

namespace Ryujinx.Graphics.GAL
{
    public readonly record struct BufferRange(int Handle, int Offset, int Size);
    public interface IPipeline
    {
        void ClearBuffer(int handle, int offset, int size, uint value);
        void DispatchCompute(int x, int y, int z);
    }
    public class FakePipeline : IPipeline
    {
        public List<string> Events = new();
        public uint[] Data;
        public FakePipeline(int count) { Data = new uint[count]; }
        public void ClearBuffer(int h, int o, int s, uint v) { Events.Add($"clear:{h}:{o}:{s}:{v:X8}"); Array.Fill(Data, v); }
        public void DispatchCompute(int x, int y, int z) => Events.Add($"dispatch:{x}:{y}:{z}");
    }
}
