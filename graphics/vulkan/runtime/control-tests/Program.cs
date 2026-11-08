using Ryujinx.Graphics.Gpu;
using Ryujinx.Graphics.Gpu.Engine.GPFifo;
using System;
using System.Reflection;
using System.Threading;

internal static class Program
{
    internal static readonly int[] Barrier = [unchecked((int)((4U << 29) | (0x50U / 4)))];
    private static int Main()
    {
        try { QueuedControl(); RepeatedControl(); RuntimeChecks.Run(); ThreadedChecks.Run(); return 0; }
        catch (Exception error) { Console.Error.WriteLine(error); return 1; }
        finally { GPFifoDevice.S2ATrackSync = null; }
    }

    internal static void Poll(GPFifoDevice fifo, Action baseline)
    {
        MethodInfo poll = typeof(GPFifoDevice).GetMethod("S2APollControl");
        if (poll == null) baseline(); else poll.Invoke(fifo, null);
    }

    private static void RepeatedControl()
    {
        var context = new GpuContext(new NullRenderer(default), null);
        var fifo = context.GPFifo;
        int handled = 0;
        Action signal = () => typeof(GPFifoDevice).GetMethod("S2ASignalControl").Invoke(fifo, null);
        Action consume = () => { if (++handled == 1) signal(); };
        typeof(GPFifoDevice).GetProperty("S2AControlPoll").SetValue(fifo, consume);
        for (int i = 0; i < 64; i++) signal();
        Poll(fifo, consume);
        if (handled != 1) throw new Exception("Repeated pending signals were not coalesced.");
        Poll(fifo, consume);
        if (handled != 2) throw new Exception("Signal published during the prior callback was lost.");
        Poll(fifo, consume);
        if (handled != 2) throw new Exception("Completed control was replayed without a signal.");
        fifo.Dispose();
        Console.WriteLine("PASS: coalesced signals and a new request inside the previous callback.");
    }

    private static void QueuedControl()
    {
        var renderer = new NullRenderer(default);
        var context = new GpuContext(renderer, null);
        var channel = context.CreateChannel();
        var fifo = context.GPFifo;
        for (int i = 0; i < 64; i++) channel.PushHostCommandBuffer(Barrier);
        using var firstCommand = new ManualResetEventSlim();
        using var published = new ManualResetEventSlim();
        int pending = 0, handled = 0, commands = 0;
        Exception workerError = null;
        Action consume = () => { if (Interlocked.Exchange(ref pending, 0) != 0) Interlocked.Increment(ref handled); };
        GPFifoDevice.S2ATrackSync = consume;
        // Baseline has no independent control path; both versions use their real signal path.
        typeof(GPFifoDevice).GetProperty("S2AControlPoll")?.SetValue(fifo, consume);
        ((NullPipeline)renderer.Pipeline).OnCommandBarrier = () =>
        {
            int current = Interlocked.Increment(ref commands);
            if (current == 1)
            {
                firstCommand.Set();
                if (!published.Wait(2000)) throw new Exception("Fixture CPU did not publish control.");
                if (Volatile.Read(ref handled) != 0) throw new Exception("Control reentered an active processor operation.");
            }
            else if (Volatile.Read(ref handled) != 1)
                throw new Exception("REGRESSION: second prequeued entry executed before backing control; push sequence did not advance.");
        };
        var gpu = new Thread(() =>
        {
            try { context.SetGpuThread(); fifo.S2ASync(); fifo.DispatchCalls(); }
            catch (Exception error) { workerError = error; }
        });
        gpu.Start();
        if (!firstCommand.Wait(2000)) throw new Exception("Fixture GPU did not enter real SetReference command.");
        Volatile.Write(ref pending, 1);
        MethodInfo signal = typeof(GPFifoDevice).GetMethod("S2ASignalControl");
        if (signal == null) fifo.SignalNewEntries(); else signal.Invoke(fifo, null);
        published.Set();
        if (!gpu.Join(2000)) throw new Exception("Fixture GPU did not leave bounded dispatch.");
        if (workerError != null) throw workerError;
        if (handled != 1 || commands != 64) throw new Exception("Control or queued commands were lost.");
        fifo.Dispose();
        Console.WriteLine("PASS: real GPFifoDevice + GPFifoProcessor; 64 prequeued SetReference entries, no new push, control consumed before entry 2.");
    }
}
