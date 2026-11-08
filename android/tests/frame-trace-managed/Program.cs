using System.Runtime.InteropServices;
using Ryujinx.Graphics.Vulkan;

NativeLibrary.SetDllImportResolver(typeof(S2AFrameTrace).Assembly, (name, assembly, path) =>
    name == "s2a_native" ? NativeLibrary.Load(Environment.GetEnvironmentVariable("S2A_FRAME_TEST_LIB")!) : IntPtr.Zero);
Check(S2AFrameTrace.Begin() == 0, "disabled begin");
S2AFrameTrace.EndFence(0);
Check(Native.Count() == 0, "disabled no record");
Native.SetEnabled(1);
S2AFrameTrace.InitializeAndroid();
long start = S2AFrameTrace.Begin();
Check(start != 0, "enabled start");
Thread.Sleep(2);
S2AFrameTrace.EndFence(start);
Check(Native.Count() == 1 && Native.Last() > 0, "enabled records time");
S2AFrameTrace.Disable();
Check(S2AFrameTrace.Begin() == 0, "disabled again");
S2AFrameTrace.EndFence(0);
Check(Native.Count() == 1, "disabled no further writes");
Console.WriteLine("frame trace managed gate: pass");
static void Check(bool c, string message) { if (!c) throw new Exception(message); }
static class Native
{
    [DllImport("s2a_native", EntryPoint="test_enabled")] public static extern void SetEnabled(int value);
    [DllImport("s2a_native", EntryPoint="test_count")] public static extern int Count();
    [DllImport("s2a_native", EntryPoint="test_last")] public static extern ulong Last();
}
