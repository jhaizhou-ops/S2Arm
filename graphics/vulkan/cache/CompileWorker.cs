using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace S2Arm.Backends.Vulkan.ProgramCache;

/// <summary>
/// One serialized driver-call lane for the Android Vulkan renderer. Shader modules and
/// pipelines are created here; the GPU owner waits with a bounded pump loop instead of an
/// unbounded Task.Wait, so window lease/stop events keep being serviced. Calls made on the
/// worker itself run inline (background pipeline creation submits from this lane).
/// </summary>
public sealed class CompileWorker : IDisposable
{
    private sealed class WorkItem
    {
        public required Func<object> Work;
        public required TaskCompletionSource<object> Completion;
    }

    private readonly object _gate = new();
    private readonly Queue<WorkItem> _high = new();
    private readonly Queue<WorkItem> _normal = new();
    private readonly SemaphoreSlim _signal = new(0);
    private readonly Thread _thread;
    private readonly int _maximumQueued;
    private int _queued;
    private volatile bool _stopping;
    private bool _disposed;

    public CompileWorker(int maximumQueued = 4096)
    {
        if (maximumQueued <= 0) throw new ArgumentOutOfRangeException(nameof(maximumQueued));
        _maximumQueued = maximumQueued;
        _thread = new Thread(Loop)
        {
            Name = "S2A.VkCompile",
            IsBackground = true,
        };
        _thread.Start();
    }

    public bool IsWorkerThread => Thread.CurrentThread == _thread;

    public bool IsStopping => _stopping;

    public Task<T> Run<T>(Func<T> work, bool highPriority = false)
    {
        ArgumentNullException.ThrowIfNull(work);
        TaskCompletionSource<object> completion = new(TaskCreationOptions.RunContinuationsAsynchronously);
        WorkItem item = new()
        {
            Work = () => work(),
            Completion = completion,
        };

        lock (_gate)
        {
            if (_stopping)
                return Task.FromException<T>(new OperationCanceledException("Compile worker is stopping."));
            if (_queued >= _maximumQueued)
                return Task.FromException<T>(new InvalidOperationException("Compile worker queue is full."));
            (highPriority ? _high : _normal).Enqueue(item);
            _queued++;
        }

        _signal.Release();
        return AwaitTyped<T>(completion.Task);
    }

    /// <summary>
    /// Runs on the owner when no worker exists or already on the worker; otherwise submits
    /// with priority and waits through <paramref name="pump"/>.
    /// </summary>
    public T RunInline<T>(Func<T> work, Action pump, int timeoutMilliseconds = 120_000)
    {
        ArgumentNullException.ThrowIfNull(work);
        if (IsWorkerThread)
            return work();
        if (_stopping)
            throw new OperationCanceledException("Compile worker is stopping.");

        Task<T> task = Run(work, highPriority: true);
        Wait(task, pump, timeoutMilliseconds);
        return task.GetAwaiter().GetResult();
    }

    public void Wait(Task task, Action pump, int timeoutMilliseconds = 120_000)
    {
        ArgumentNullException.ThrowIfNull(task);
        if (IsWorkerThread)
            throw new InvalidOperationException("The compile worker cannot wait for its own work.");
        if (timeoutMilliseconds <= 0) throw new ArgumentOutOfRangeException(nameof(timeoutMilliseconds));

        long deadline = Environment.TickCount64 + timeoutMilliseconds;
        while (!task.IsCompleted)
        {
            try
            {
                task.Wait(2);
            }
            catch (AggregateException)
            {
                break; // faulted/canceled; GetResult below preserves the original exception
            }

            pump?.Invoke();

            if (_stopping)
                throw new OperationCanceledException("Compile worker stopped while waiting.");
            if (Environment.TickCount64 >= deadline)
                throw new TimeoutException(
                    $"Vulkan driver call did not finish within {timeoutMilliseconds} ms; retain device resources.");
        }

        task.GetAwaiter().GetResult();
    }

    private static async Task<T> AwaitTyped<T>(Task<object> task)
    {
        object value = await task.ConfigureAwait(false);
        return (T)value;
    }

    private void Loop()
    {
        while (true)
        {
            _signal.Wait();

            WorkItem item;
            lock (_gate)
            {
                if (_stopping)
                    return;
                if (!_high.TryDequeue(out item) && !_normal.TryDequeue(out item))
                    continue;
                _queued--;
            }

            try
            {
                item.Completion.TrySetResult(item.Work());
            }
            catch (Exception e)
            {
                item.Completion.TrySetException(e);
            }
        }
    }

    /// <summary>
    /// Rejects new work, cancels queued items and joins the in-flight driver call. A timeout
    /// means the device must not be destroyed; the caller reports and terminates the host.
    /// </summary>
    public bool Stop(int timeoutMilliseconds = 30_000)
    {
        if (IsWorkerThread)
            throw new InvalidOperationException("The compile worker cannot stop itself.");
        if (timeoutMilliseconds <= 0) throw new ArgumentOutOfRangeException(nameof(timeoutMilliseconds));

        List<WorkItem> dropped = new();
        lock (_gate)
        {
            if (_stopping)
                return !_thread.IsAlive;
            _stopping = true;
            while (_high.TryDequeue(out WorkItem item)) dropped.Add(item);
            while (_normal.TryDequeue(out WorkItem item)) dropped.Add(item);
            _queued = 0;
        }

        foreach (WorkItem item in dropped)
            item.Completion.TrySetCanceled();

        _signal.Release();
        return _thread.Join(timeoutMilliseconds);
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        if (!Stop())
            throw new TimeoutException("Vulkan compile worker did not stop; the device must be retained.");
    }
}
