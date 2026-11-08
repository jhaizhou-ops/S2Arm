using System.Runtime.InteropServices;
using System.Text.Json;
using Ryujinx.Common;

if (args.Length != 2) throw new ArgumentException("native library and output directory required");
NativeLibrary.SetDllImportResolver(typeof(S2ACompileEvents).Assembly,
    (name, _, _) => name == "s2a_native" ? NativeLibrary.Load(args[0]) : IntPtr.Zero);
if (!S2ACompileEvents.BeginSession(args[1], 42)) throw new Exception("session did not start");
using (var hit = S2ACompileEvents.Begin(S2ACompileEvents.Kind.Translation)) hit?.Complete(S2ACompileEvents.Result.Hit);
using (var miss = S2ACompileEvents.Begin(S2ACompileEvents.Kind.GraphicsPipeline)) miss?.Complete(S2ACompileEvents.Result.Miss);
using (S2ACompileEvents.Begin(S2ACompileEvents.Kind.ComputePipeline)) { }
if (!S2ACompileEvents.EndSession()) throw new Exception("session did not finish");
var path = Directory.GetFiles(args[1], "compile-events-*.jsonl").Single();
var lines = File.ReadAllLines(path);
if (lines.Length != 4) throw new Exception("unexpected record count");
using var h = JsonDocument.Parse(lines[0]);
if (h.RootElement.GetProperty("session").GetUInt64() != 42) throw new Exception("session mismatch");
string[] kinds = ["graphics_pipeline", "compute_pipeline"];
string[] results = ["miss", "failure"];
for (int i = 0; i < 2; i++) {
    using var e = JsonDocument.Parse(lines[i+1]);
    if (e.RootElement.GetProperty("kind").GetString() != kinds[i] || e.RootElement.GetProperty("result").GetString() != results[i])
        throw new Exception("scope event mismatch");
    if (e.RootElement.GetProperty("end_us").GetUInt64() < e.RootElement.GetProperty("start_us").GetUInt64())
        throw new Exception("event time order");
}
using var foot = JsonDocument.Parse(lines[^1]);
if (foot.RootElement.GetProperty("hits").GetUInt64() != 1) throw new Exception("hit not aggregated");
Console.WriteLine("managed scope test: hit aggregated; miss and failure recorded");
