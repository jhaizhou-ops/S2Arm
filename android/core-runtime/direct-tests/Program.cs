using System;
using Ryujinx.Graphics.Gpu;
using S2A.Android.Aot;

int checks = 0;
void Reject(Action action)
{
    checks++;
    try { action(); }
    catch (InvalidOperationException e) when (e.Message.Contains("generic renderer")) { return; }
    throw new Exception("Unexpected generic operation was not rejected");
}
// The actual HLE GPU context must construct and dispose without issuing GAL work.
using (var context = new GpuContext(new DirectServiceRenderer(), default))
{
    if (context.Renderer.PreferThreading || context.Renderer.ProgramCount != 0) throw new Exception("wrong direct service identity");
    checks++;
    var renderer = context.Renderer;
    Reject(() => renderer.CreateBuffer(16));
    Reject(() => renderer.GetCurrentSync());
    Reject(() => renderer.CreateSync(1, true));
    Reject(() => renderer.GetCapabilities());
    Reject(() => renderer.PreFrame());
    Reject(() => renderer.Screenshot());
    Reject(() => { var pipeline = renderer.Pipeline; });
    Reject(() => { var window = renderer.Window; });
    Reject(() => renderer.BackgroundContextAction(() => throw new Exception("must not run")));
}
Console.WriteLine($"PASS {checks} direct service renderer lifecycle/command rejection checks");
var horizon = new TestHorizon();
DirectAppletExit.Request(horizon);
if (!horizon.State.Messages.TryDequeue(out var message) || message != TestMessage.Exit || horizon.State.MessageEvent.ReadableEvent.Signals != 1)
    throw new Exception("Exit message/event contract failed");
try { DirectAppletExit.Request(new object()); throw new Exception("Missing applet state accepted"); }
catch (MissingMemberException) { }
Console.WriteLine("PASS applet Exit enqueue + event and missing-state rejection");

enum TestMessage { Exit = 4 }
sealed class TestEvent { public TestReadable ReadableEvent { get; } = new(); }
sealed class TestReadable { public int Signals; public void Signal() => Signals++; }
sealed class TestState
{
    public System.Collections.Concurrent.ConcurrentQueue<TestMessage> Messages { get; } = new();
    public TestEvent MessageEvent { get; } = new();
}
sealed class TestHorizon { public TestState State { get; } = new(); private TestState AppletState => State; }
