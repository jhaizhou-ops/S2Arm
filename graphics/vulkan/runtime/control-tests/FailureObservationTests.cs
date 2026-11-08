using S2Arm.Backends.Vulkan.Runtime;
using System;
using System.Collections;
using System.IO;
using System.Reflection;
using System.Text;
using System.Threading;

// Exercises the production Fail method, with a capturing fatal callback rather than
// AndroidGameRuntime's existing synchronous log sink. No GPU or native tracking.
internal static class FailureObservationTests
{
    private const BindingFlags Private = BindingFlags.Instance | BindingFlags.NonPublic;

    private sealed class Sink : TextWriter
    {
        internal readonly ManualResetEventSlim Entered = new();
        internal readonly ManualResetEventSlim Release = new();
        internal bool Blocking;
        internal int Calls;
        public override Encoding Encoding => Encoding.UTF8;
        public override void WriteLine(string value)
        {
            Interlocked.Increment(ref Calls);
            Entered.Set();
            if (Blocking) Release.Wait();
            else throw new IOException("fixture diagnostic sink failure");
        }
    }

    private sealed class BrokenDataException : Exception
    {
        public override IDictionary Data => throw new IOException("fixture metadata failure");
    }

    private static void Check(bool condition, string message)
    {
        if (!condition) throw new Exception(message);
    }

    internal static void Run()
    {
        foreach (bool blocking in new[] { false, true })
            Failure(blocking, new InvalidOperationException("original DeviceLost fixture", new Exception("original inner")));
        Failure(false, new BrokenDataException());
        Console.WriteLine("PASS: failure metadata preserves the original exception, completion state and fatal delivery without touching blocking/throwing diagnostic sinks; no GPU dispatch tested.");
    }

    private static void Failure(bool blocking, Exception original)
    {
        using var delivered = new ManualResetEventSlim();
        Exception seen = null, workerFailure = null;
        var runtime = new AndroidVulkanRuntime(1, 1, error => { seen = error; delivered.Set(); });
        Type changeType = typeof(AndroidVulkanRuntime).GetNestedType("BackingChange", BindingFlags.NonPublic);
        object change = Activator.CreateInstance(changeType, nonPublic: true);
        void Set(string name, object value) => changeType.GetField(name).SetValue(change, value);
        Set("Id", 17L);
        Set("Phase", "queue-marker-after-old-backing-flush");
        Set("Address", 0x10000UL); Set("Size", 0x1000UL); Set("Source", 0x30000UL);
        Set("ThreadId", 42); Set("NeedsGpu", true); Set("Direct", false);
        typeof(AndroidVulkanRuntime).GetField("_backingChange", Private).SetValue(runtime, change);
        MethodInfo fail = typeof(AndroidVulkanRuntime).GetMethod("Fail", Private);
        var sink = new Sink { Blocking = blocking };
        TextWriter previous = Console.Error;
        var worker = new Thread(() =>
        {
            try { fail.Invoke(runtime, new object[] { original }); }
            catch (Exception error) { workerFailure = error; delivered.Set(); }
        });
        int first;
        try
        {
            Console.SetError(sink);
            worker.Start();
            first = WaitHandle.WaitAny(new[] { sink.Entered.WaitHandle, delivered.WaitHandle }, 2000);
        }
        finally
        {
            sink.Release.Set(); // A red implementation must still settle its test thread.
            if (worker.IsAlive && !worker.Join(2000))
                Environment.FailFast("Failure-observation fixture did not settle its owned thread.");
            Console.SetError(previous);
        }

        Check(workerFailure == null, "Failure metadata replaced the original failure with an exception.");
        Check(first == 1 && sink.Calls == 0, "Diagnostic sink was touched before the fatal callback.");
        Check(ReferenceEquals(seen, original), "Fatal callback did not receive the same exception object.");
        Check(ReferenceEquals(typeof(AndroidVulkanRuntime).GetField("_failure", Private).GetValue(runtime), original),
            "The runtime did not latch the same original exception.");
        foreach (string signal in new[] { "Prepared", "Replaced", "Finished" })
            Check(!((ManualResetEventSlim)changeType.GetField(signal).GetValue(change)).IsSet,
                "Failure observation incorrectly completed or permitted a backing transaction.");
        if (original is not BrokenDataException)
        {
            string context = original.Data[nameof(AndroidVulkanRuntime)] as string;
            Check(context != null && context.Contains("transaction=17") &&
                context.Contains("phase=queue-marker-after-old-backing-flush") &&
                context.Contains("callerManagedThread=42") && context.Contains("target=0x10000+0x1000") &&
                context.Contains("source=0x30000") && context.Contains("sourceSize=0x1000"),
                "Actual backing metadata was missing or misattributed.");
            Check(original.Message == "original DeviceLost fixture" && original.InnerException.Message == "original inner",
                "Diagnostic metadata changed the original message or inner exception.");
        }
        // Repeated Fail may not overwrite the first failure or redispatch fatal.
        fail.Invoke(runtime, new object[] { new Exception("later failure") });
        Check(ReferenceEquals(seen, original), "Later failure replaced the first fatal error.");
    }
}
