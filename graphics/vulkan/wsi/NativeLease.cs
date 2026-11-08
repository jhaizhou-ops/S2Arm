using System;
using System.Runtime.InteropServices;

namespace S2Arm.Backends.Vulkan.Wsi;

// Exact LP64 v1 layouts from android/native/wsi_lease.h. These are a binding of
// the existing ABI, not a new public contract. The native lease outlives this consumer.
[StructLayout(LayoutKind.Sequential)]
internal struct NativeLeaseState
{
    public ulong Session, Generation, Revision;
    public nint Window;
    public int Width, Height;
    public uint Transform;
    public int InsetLeft, InsetTop, InsetRight, InsetBottom;
    public float RefreshHz;
    public int Foreground, Stopping;
    public uint WakeSequence;

    public readonly WindowStamp Stamp => new(Session, Generation, Revision);
}

[StructLayout(LayoutKind.Sequential)]
internal unsafe struct NativeLeaseApi
{
    public uint Size, Version;
    public nint Lease;
    public delegate* unmanaged[Cdecl]<nint, NativeLeaseState*, int, int> Wait;
    public delegate* unmanaged[Cdecl]<nint, NativeLeaseState*, int> Take;
    public delegate* unmanaged[Cdecl]<nint, nint, void> ReleaseWindow;
    public delegate* unmanaged[Cdecl]<nint, ulong, void> Released;
    public delegate* unmanaged[Cdecl]<nint, void> Wake;
}

// Owns exactly one take reference. Poll and retirement methods run on the backend thread;
// Wake alone may run on another thread while the host guarantees the native lease is alive.
// There is deliberately no finalizer: GC must not invent GPU completion or acknowledge a lease.
internal sealed unsafe class NativeLease
{
    private const int Busy = 16; // EBUSY in the existing Android/Linux producer.
    private readonly NativeLeaseApi _api;
    private readonly int _thread = Environment.CurrentManagedThreadId;
    private NativeLeaseState _seen;
    private nint _window;
    private ulong _held;
    private bool _retiring;
    private bool _stopped;
    private ulong _acknowledged;
    private volatile bool _foreground;

    public RetirementLedger Retirement { get; }
    public NativeLeaseState State => _seen;
    public ulong HeldGeneration => _held;
    public bool RetirementRequested => _retiring;
    // A backgrounded host may freeze the whole process; waiters must not measure a deadline
    // across that freeze. Only the owner thread writes this.
    public bool Foreground => _foreground;

    // Only expose a window that may still be used to create the current surface. The host is
    // concurrently allowed to revoke; Poll is required at control safe points, not only frames.
    public nint WindowForSurface => !_retiring && !_stopped && !Retirement.DeviceLost ? _window : 0;

    public NativeLease(nint api, ulong session, ulong deviceGeneration)
    {
        if (IntPtr.Size != 8 || api == 0)
        {
            throw new ArgumentException("WSI lease v1 requires a non-null LP64 function table.");
        }
        // Inspect the fixed prefix before copying function pointers from an undersized table.
        uint* prefix = (uint*)api;
        if (prefix[0] < sizeof(NativeLeaseApi) || prefix[1] != 1)
        {
            throw new ArgumentException("Unsupported WSI lease function table.");
        }
        _api = *(NativeLeaseApi*)api;
        if (_api.Lease == 0 || _api.Wait == null || _api.Take == null ||
            _api.ReleaseWindow == null || _api.Released == null || _api.Wake == null)
        {
            throw new ArgumentException("Incomplete WSI lease function table.");
        }
        Retirement = new RetirementLedger(session, deviceGeneration);
    }

    public void Poll()
    {
        CheckThread();
        NativeLeaseState current = default;
        int status = _api.Take(_api.Lease, &current);
        if (status != 0 && status != Busy)
        {
            throw new InvalidOperationException($"WSI take failed: {status}.");
        }
        if (current.Session != Retirement.Session ||
            (status == Busy && (current.Window != 0 || _held == 0)) ||
            current.Generation < _seen.Generation ||
            (current.Generation == _seen.Generation && current.Revision < _seen.Revision))
        {
            if (status == 0 && current.Window != 0)
            {
                _api.ReleaseWindow(_api.Lease, current.Window);
            }
            throw new InvalidOperationException("WSI lease identity/order violation; no ACK issued.");
        }
        _seen = current;
        // Read by non-owner waiters (GPU handshakes) without touching the mutable lease state.
        _foreground = current.Foreground != 0 && current.Stopping == 0 && current.Window != 0;
        if (current.Stopping != 0)
        {
            _stopped = true;
            Retirement.Stop();
        }
        if (_held != 0 && (status == Busy || current.Stopping != 0 || Retirement.DeviceLost ||
            current.Window == 0 || current.Generation != _held))
        {
            _retiring = true;
            Retirement.RetireGeneration(_held);
        }
        if (current.Window != 0)
        {
            if (_held == 0)
            {
                // Once ACKed, a generation cannot be adopted again even if a bad producer
                // reoffers its pointer. Correct producers increment generation for every offer.
                if (current.Generation == 0 || current.Generation <= _acknowledged)
                {
                    _api.ReleaseWindow(_api.Lease, current.Window);
                    throw new InvalidOperationException("Attempt to readopt a retired generation.");
                }
                _window = current.Window;
                _held = current.Generation;
                _retiring = _stopped || Retirement.DeviceLost;
                if (_retiring)
                {
                    Retirement.RetireGeneration(_held);
                }
            }
            else
            {
                // Same-generation revisions/foreground changes add a take ref, not a surface.
                _api.ReleaseWindow(_api.Lease, current.Window);
            }
        }
    }

    // Only before the first VkSurface/swapchain exists. Background is a lifecycle state,
    // not startup failure. Retire a revoked take without inventing GPU completion.
    public void WaitForInitialSurface()
    {
        while (true)
        {
            Poll();
            if (RetirementRequested && !TryReleaseRetired(() => { }))
                throw new InvalidOperationException("Initial surface wait cannot release live GPU ownership.");
            if (_stopped || Retirement.DeviceLost)
                throw new OperationCanceledException("Android surface startup was stopped.");
            if (MayPresent(State.Stamp)) return;
            WaitForChange(25);
        }
    }

    public bool MayPresent(WindowStamp enqueued)
    {
        CheckThread();
        return !Retirement.DeviceLost && !_stopped && !_retiring && _window != 0 &&
            _seen.Foreground != 0 && _seen.Width > 0 && _seen.Height > 0 &&
            enqueued == _seen.Stamp && enqueued.Generation == _held;
    }

    public int WaitForChange(int timeoutMilliseconds)
    {
        CheckThread();
        if (timeoutMilliseconds < 0)
        {
            throw new ArgumentOutOfRangeException(nameof(timeoutMilliseconds), "Wait must be bounded.");
        }
        NativeLeaseState seen = _seen;
        int status = _api.Wait(_api.Lease, &seen, timeoutMilliseconds);
        if (status is not (0 or 1))
        {
            throw new InvalidOperationException($"WSI wait failed: {status}.");
        }
        return status;
    }

    public void Wake() => _api.Wake(_api.Lease);

    // For a caller-requested stop independent of another frame or a platform state change.
    // It does not claim to wake GAL; the shared control-mailbox seam remains necessary.
    public void Stop()
    {
        CheckThread();
        _stopped = true;
        Retirement.Stop();
        if (_held != 0)
        {
            _retiring = true;
            Retirement.RetireGeneration(_held);
        }
    }

    // Swapchains must already have passed ledger checks and actually been destroyed. A failed
    // surface destructor retains both the reference and ACK obligation. The caller supplies the
    // real surface destruction, not a callback that merely schedules eventual destruction.
    public bool TryReleaseRetired(Action destroySurface)
    {
        CheckThread();
        ArgumentNullException.ThrowIfNull(destroySurface);
        if (!_retiring || _held == 0 || !Retirement.CanDestroySurface(_held))
        {
            return false;
        }
        destroySurface();
        _api.ReleaseWindow(_api.Lease, _window);
        _api.Released(_api.Lease, _held);
        _acknowledged = _held;
        _window = 0;
        _held = 0;
        _retiring = false;
        return true;
    }

    private void CheckThread()
    {
        RetirementLedger.Require(Environment.CurrentManagedThreadId == _thread,
            "Only the backend owner thread may mutate WSI state.");
    }
}
