using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using Ryujinx.Graphics.Device;
using Ryujinx.Graphics.Gpu.Engine.MME;

internal static class Program
{
    static int Main(string[] args)
    {
        try { return Run(args); }
        catch (Exception e) { Console.Error.WriteLine(e.Message); return 1; }
    }

    static int Run(string[] args)
    {
        if (args[0] == "generate")
            return S2A.MacroGen.MacroGen.GenCmd(args[1..]);
        // Fixed expectations do not come from the generator or interpreter.
        (string name, int address, int value)[] cases =
        {
            ("send_7", 0x80, 7),
            ("send_minus_3", 0x90, -3),
            ("send_arg_plus_5", 0xa0, 16),
        };
        int n = 0;
        foreach (var c in cases)
        {
            int[] words = MemoryMarshal.Cast<byte,int>(
                File.ReadAllBytes(Path.Combine(args[1], c.name + ".mme"))).ToArray();
            int[] code = new int[words.Length + 2];
            words.CopyTo(code, 0);
            var entry = S2AMacroAot.Lookup(code);
            if (entry == null) throw new Exception("synthetic AOT entry missing: " + c.name);
            foreach (IMacroEE engine in new IMacroEE[] {new S2AMacroAotEE(entry), new MacroInterpreter()})
            {
                var state = new RecordingState();
                engine.Execute(code, state, 11);
                if (state.Writes.Count != 1 || state.Writes[0] != (c.address,c.value))
                    throw new Exception("literal write expectation failed: " + c.name);
                n++;
            }
        }
        // Malformed authored opcode: not accepted as compilable.
        if (S2AMacroAot.Analyze(new int[] {0x86, 0x11, 0, 0}, out var reason) != 2 ||
            reason != "invalid_op@0")
            throw new Exception("invalid opcode must be rejected");
        Console.WriteLine($"synthetic MME: {n} engine/literal comparisons + invalid opcode passed");
        return 0;
    }

    sealed class RecordingState : IDeviceState
    {
        public List<(int,int)> Writes = new();
        public int Read(int offset) => throw new Exception("unexpected device read");
        public void Write(int offset, int value) => Writes.Add((offset,value));
    }
}
// Only logging is a test shim; no GPU/device implementation is simulated as a
// real device. An unexpected FIFO warning is a hard failure in these fixtures.
namespace Ryujinx.Common.Logging
{
    enum LogClass { Gpu }
    static class Logger { public static Sink Warning = new(); }
    sealed class Sink { public void Print(LogClass c, string s) => throw new Exception(s); }
}
