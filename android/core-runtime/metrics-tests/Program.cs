using S2A.Android.Aot;
using System;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Threading;
using System.Text.Json;

string root = args.Length == 1 ? Path.GetFullPath(args[0]) : Path.Combine(Path.GetTempPath(), "s2a-metrics-" + Guid.NewGuid().ToString("N"));
if (Directory.Exists(root)) throw new Exception("test output must be new");
Directory.CreateDirectory(root);
int checks = 0;
void Check(bool condition, string name)
{
    if (!condition) throw new Exception("FAIL " + name);
    checks++; Console.WriteLine("PASS " + name);
}
void ConcurrentClose()
{
    using var callbackInside = new ManualResetEventSlim();
    using var releaseCallback = new ManualResetEventSlim();
    using var closeStarted = new ManualResetEventSlim();
    using var closeClock = new ManualResetEventSlim();
    int callbackThread = 0, closerThread = 0;
    long clock = 0, callbackTime = 0;
    long Now()
    {
        if (Environment.CurrentManagedThreadId == Volatile.Read(ref callbackThread))
        {
            callbackInside.Set();
            if (!releaseCallback.Wait(3000)) throw new Exception("callback was not released");
            return callbackTime = Interlocked.Add(ref clock, 100);
        }
        long value = Interlocked.Add(ref clock, 100);
        if (Environment.CurrentManagedThreadId == Volatile.Read(ref closerThread)) closeClock.Set();
        return value;
    }
    using var metrics = new AndroidRunMetrics(root, 3, Now);
    metrics.SetRefresh(60); metrics.FrameInterval(1f / 60);
    Exception callbackError = null, closeError = null;
    var callback = new Thread(() =>
    {
        Volatile.Write(ref callbackThread, Environment.CurrentManagedThreadId);
        try { metrics.FrameInterval(1f / 30); } catch (Exception error) { callbackError = error; }
    });
    var closer = new Thread(() =>
    {
        Volatile.Write(ref closerThread, Environment.CurrentManagedThreadId);
        closeStarted.Set();
        try { metrics.Dispose(); } catch (Exception error) { closeError = error; }
    });
    callback.Start();
    try
    {
        Check(callbackInside.Wait(2000), "interval callback holds the actual producer lock");
        closer.Start();
        Check(closeStarted.Wait(2000), "concurrent Dispose starts");
        // New source blocks at Monitor.Enter. Old source samples its end clock first;
        // either observation makes this interleaving deterministic without a timed sleep.
        Check(SpinWait.SpinUntil(() => closeClock.IsSet || (closer.ThreadState & ThreadState.WaitSleepJoin) != 0, 2000),
            "Dispose reaches its clock or waits for the held interval lock");
    }
    finally { releaseCallback.Set(); }
    Check(callback.Join(2000) && closer.Join(2000) && callbackError == null && closeError == null,
        "in-flight interval and close finish successfully");
    var intervals = (long[])typeof(AndroidRunMetrics).GetField("_intervalTime", BindingFlags.Instance | BindingFlags.NonPublic).GetValue(metrics);
    using var metadata = JsonDocument.Parse(File.ReadAllText(Path.Combine(metrics.DirectoryPath, "runtime-metrics.json")));
    long end = metadata.RootElement.GetProperty("endBootUs").GetInt64();
    Check(intervals[2] >= 0 && end >= callbackTime, "interval close must wait for in-flight callback clock");
    Check(intervals[1] == 100 && intervals[2] == 100, "interval accounting closes after callback without negative duration");
    long closedClock = clock;
    metrics.FrameInterval(1f / 60);
    Check(clock == closedClock, "late interval callback rejected without sampling after close");
}
try
{
    Check(AndroidRunMetrics.TryStart(root, 1) == null, "default disabled without creating capture");
    long now = 1_000_000;
    string path;
    long lastFrame;
    var originalError = Console.Error;
    var capturedLog = new StringWriter();
    Console.SetError(capturedLog);
    using (var metrics = new AndroidRunMetrics(root, 1, () => now))
    {
        path = metrics.DirectoryPath;
        metrics.SetRefresh(60);
        metrics.FrameInterval(1f / 30);
        metrics.Present(1);
        now += 33_334; metrics.Present(2);
        metrics.RequestMark();
        now += 33_334; metrics.Present(3);
        for (int i = 0; i < 1900; i++) { now += 33_334; metrics.Present((ulong)i + 4); }
        metrics.RequestMark(); now += 33_334; metrics.Present(1904);
        var lines = File.ReadAllLines(Path.Combine(path, "frames.tsv"));
        Check(lines.Length == 1905, "actual producer writes one row per accepted callback");
        Check(lines[1].Split('\t')[1] == "0", "first row has no invented interval");
        Check(lines[2].Split('\t')[1] == "33334", "microsecond interval from shared boot clock");
        Check(lines[2].Split('\t')[7] == "1033334", "absolute boot timestamp exported");
        Check(!lines[0].Contains("rb_us") && !lines[0].Contains("draw_n"), "unmeasured counters omitted");
        using var during = JsonDocument.Parse(File.ReadAllText(Path.Combine(path, "runtime-metrics.json")));
        Check(during.RootElement.GetProperty("status").GetString() == "capturing", "live capture not marked completed");
        Check(during.RootElement.GetProperty("endBootUs").GetInt64() == -1, "capturing has no invented end");
        lastFrame = now;
        now += 2_000_000; // No more presents: this tail must not vanish from the window.
    }
    Console.SetError(originalError);
    File.WriteAllText(Path.Combine(path, "host.log"), capturedLog.ToString());
    string emitted = capturedLog.ToString();
    Check(emitted.Contains("帧节拍：交换间隔 2，每帧 33.3 ms（30.0 帧/秒） boot_us=1000000"),
          "interval declaration carries the injected BOOTTIME clock at line end");
    Check(emitted.Contains($"收局 帧节拍：交换间隔 2，每帧 33.3 ms（30.0 帧/秒） boot_us={now}"),
          "closing declaration carries the actual end clock at line end");
    Check(emitted.Split('\n').Where(l => l.Contains("帧节拍")).All(l => l.Contains("boot_us=")),
          "every declaration line is self-timestamped");
    using var metadata = JsonDocument.Parse(File.ReadAllText(Path.Combine(path, "runtime-metrics.json")));
    Check(metadata.RootElement.GetProperty("status").GetString() == "completed", "dispose flushes completed capture");
    Check(metadata.RootElement.GetProperty("markFrame").GetInt64() == 2, "MARK is one-shot and frame-linked");
    Check(metadata.RootElement.GetProperty("markBootUs").GetInt64() == 1_066_668, "MARK shares power clock");
    Check(metadata.RootElement.GetProperty("startBootUs").GetInt64() == 1_000_000, "capture has actual start clock");
    Check(metadata.RootElement.GetProperty("lastFrameBootUs").GetInt64() == lastFrame, "last present clock retained separately");
    Check(metadata.RootElement.GetProperty("endBootUs").GetInt64() == now && now - lastFrame == 2_000_000, "terminal stall retained at actual stop");
    string empty;
    long emptyStart = now;
    using (var second = new AndroidRunMetrics(root, 2, () => now))
    {
        empty = second.DirectoryPath;
        Check(empty != path && File.Exists(Path.Combine(path, "frames.tsv")), "new run preserves old capture");
        now += 3_000_000;
    }
    using var noFrame = JsonDocument.Parse(File.ReadAllText(Path.Combine(empty, "runtime-metrics.json")));
    Check(noFrame.RootElement.GetProperty("frames").GetInt64() == 0 && noFrame.RootElement.GetProperty("lastFrameBootUs").GetInt64() == -1, "no-present run does not manufacture a frame");
    Check(noFrame.RootElement.GetProperty("endBootUs").GetInt64() - noFrame.RootElement.GetProperty("startBootUs").GetInt64() == now - emptyStart, "no-present window retains actual duration");
    ConcurrentClose();
    Console.WriteLine($"Metrics producer: {checks}/{checks} PASS (injected host clock; not Android/Vulkan measurement)");
}
finally
{
    if (args.Length == 0)
    {
        if (!Path.GetFullPath(root).StartsWith(Path.GetFullPath(Path.GetTempPath()).TrimEnd(Path.DirectorySeparatorChar) + Path.DirectorySeparatorChar))
            throw new Exception("unexpected cleanup root");
        Directory.Delete(root, true);
    }
}
