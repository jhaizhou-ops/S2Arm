// SPDX-License-Identifier: MIT
// Composes the existing Ryujinx renderer; no second instance/device/queue is created here.
using Ryujinx.Common;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.Vulkan;
using Silk.NET.Core.Contexts;
using Silk.NET.Vulkan;
using Silk.NET.Vulkan.Extensions.KHR;
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;

namespace S2Arm.Backends.Vulkan.Wsi;

public sealed unsafe class AndroidVulkanSurface
{
    [DllImport("s2arm_android")]
    private static extern int s2a_android_qa_no_present_fence();

    private readonly nint _leaseApi;
    private readonly ulong _session;
    private NativeLease _lease;
    private VulkanRenderer _renderer;
    private AndroidWindow _window;
    private Instance _instance;
    private Device _device;
    private Vk _api;
    private SurfaceKHR _surface;
    private KhrAndroidSurface _android;
    private static readonly long _s2aCreated = Environment.TickCount64;
    private long _markerSequence;

    private readonly bool _transferFullClears;
    // Producer lifecycle epoch (nonnegative foreground, -1 background), the same clock the
    // runtime's startup/swap waits read. Internal: the window's acquire and retirement budgets
    // consume it, fresh on every iteration — the lease's owner-thread Foreground flag cannot observe
    // a background transition while the owner is frozen inside a driver call.
    private readonly Func<long> _lifecycle;

    public AndroidVulkanSurface(nint leaseApi, ulong session, bool transferFullClears,
        Func<long> lifecycle)
    {
        if (leaseApi == 0 || session == 0) throw new ArgumentException("A live Android WSI lease is required.");
        _leaseApi = leaseApi;
        _session = session;
        _transferFullClears = transferFullClears;
        _lifecycle = lifecycle ?? throw new ArgumentNullException(nameof(lifecycle));
    }

    internal Func<long> Lifecycle => _lifecycle;

    public IRenderer CreateRenderer()
    {
        if (_renderer != null) throw new InvalidOperationException("One renderer is allowed per game session.");
        int qaNoPresentFence = s2a_android_qa_no_present_fence();
        if (qaNoPresentFence is not (0 or 1)) throw new InvalidOperationException("Invalid QA present-fence capability setting.");
        _api = new Vk(new DefaultNativeContext("libvulkan.so"));
        _renderer = new VulkanRenderer(_api, CreateInitialSurface, InstanceExtensions, "");
        _renderer.S2AForceNoSwapchainMaintenance = qaNoPresentFence == 1;
        // Native VM may replace a guest mapping. Until imported allocation revocation exists,
        // use Ryujinx's ordinary buffer upload/readback paths for this instance.
        _renderer.AllowHostMemoryImport = false;
        _renderer.UseSingleQueue = true;
        _renderer.TransferFullClears = _transferFullClears;
        _renderer.WindowFactory = (renderer, surface, physical, device) =>
        {
            _device = device;
            return _window = new AndroidWindow(renderer, this, physical, device);
        };
        return _renderer;
    }

    private string[] InstanceExtensions()
    {
        IReadOnlySet<string> supported = VulkanInstance.GetInstanceExtensions(_api);
        List<string> required = ["VK_KHR_surface", "VK_KHR_android_surface"];
        // EXT swapchain maintenance depends on both instance extensions. Device enablement
        // is separately based on its advertised extension and queried feature bit.
        if (supported.Contains("VK_KHR_get_surface_capabilities2") && supported.Contains("VK_EXT_surface_maintenance1"))
        {
            required.Add("VK_KHR_get_surface_capabilities2");
            required.Add("VK_EXT_surface_maintenance1");
        }
        return required.ToArray();
    }

    private SurfaceKHR CreateInitialSurface(Instance instance, Vk api)
    {
        _instance = instance;
        _lease = new NativeLease(_leaseApi, _session, 1); // This session never recreates its device.
        _lease.WaitForInitialSurface();
        if (!api.TryGetInstanceExtension(instance, out _android))
            throw new NotSupportedException("VK_KHR_android_surface entry points are unavailable.");
        return CreateSurface();
    }

    internal SurfaceKHR CreateSurface()
    {
        if (_surface.Handle != 0) throw new InvalidOperationException("The previous leased surface is still live.");
        nint window = _lease.WindowForSurface;
        if (window == 0 || !_lease.MayPresent(_lease.State.Stamp))
            throw new InvalidOperationException("No foreground Android surface is available for game startup.");
        AndroidSurfaceCreateInfoKHR info = new()
        {
            SType = StructureType.AndroidSurfaceCreateInfoKhr,
            Window = (nint*)window,
        };
        _android.CreateAndroidSurface(_instance, in info, null, out _surface).ThrowOnError();
        return _surface;
    }

    internal NativeLease Lease => _lease;
    internal SurfaceKHR Surface => _surface;
    public ulong QueuedGamePresents => _window?.QueuedGamePresents ?? 0;
    public string RetirementSummary => _window?.RetirementSummary ?? "WSI=uninitialized";
    public bool HasPresentFences => _renderer?.EnabledDeviceFeatures?.SwapchainMaintenance1 == true;

    internal void DestroySurface()
    {
        if (_surface.Handle != 0)
        {
            _renderer.SurfaceApi.DestroySurface(_instance, _surface, null);
            _surface = default;
        }
    }

    public void Poll() => (_window ?? throw new InvalidOperationException("Vulkan WSI has not initialized.")).Poll();

    /// <summary>Lease/stop pump usable while the GPU owner waits for a driver call.</summary>
    public void PollIfReady() => _window?.Poll();

    /// <summary>Installs the host pump the renderer's single compile lane services while waiting.</summary>
    public void SetWaitPump(Action pump)
    {
        if (_renderer == null) throw new InvalidOperationException("Vulkan WSI has not initialized.");
        _renderer.S2AWaitPump = pump;
    }

    /// <summary>Application-controlled driver pipeline cache location; null disables persistence.</summary>
    public void SetPipelineCachePath(string path)
    {
        if (_renderer == null) throw new InvalidOperationException("Vulkan WSI has not initialized.");
        _renderer.S2APipelineCachePath = path;
    }
    public void Wake() => _lease?.Wake();
    public void Stop() => _window?.Stop();
    public bool Retired => _window != null && _window.Retired;
    public bool Stopping => _lease != null && _lease.State.Stopping != 0;
    // Backgrounded activity: Android may freeze the whole process, so a wall-clock GPU handshake
    // deadline measured here would expire on resume even though no thread was running.
    public bool Foreground => _lease != null && _lease.Foreground;
    // S2A: session construction tick, before GPU/window creation (startup timeline起点).
    internal long S2AStartedTick => _s2aCreated;

    public void CompletePendingCommands(int timeoutMilliseconds)
    {
        if (timeoutMilliseconds <= 0) throw new ArgumentOutOfRangeException(nameof(timeoutMilliseconds));
        _renderer.FlushAllCommands();
        CommandBufferScoped marker = _renderer.CommandBufferPool.Rent();
        FenceHolder holder = marker.GetFence();
        Fence fence = holder.Get();
        try
        {
            long markerId = Interlocked.Increment(ref _markerSequence);
            _renderer.CommandBufferPool.Return(marker);
            long started = Stopwatch.GetTimestamp();
            long traceStarted = S2AFrameTrace.Begin();
            Result result;
            try { result = _api.WaitForFences(_device, 1, in fence, true, checked((ulong)timeoutMilliseconds * 1_000_000)); }
            finally { S2AFrameTrace.EndFence(traceStarted); }
            if (result != Result.Success)
            {
                long finished = Stopwatch.GetTimestamp();
                var error = new InvalidOperationException($"GPU backing-change fence did not complete: {result}.");
                AttachMarkerFailure(error, markerId, marker, fence, result, started, finished, timeoutMilliseconds);
                if (result == Result.ErrorDeviceLost)
                {
                    // Diagnostics must not replace the original fence failure if the sink fails.
                    try { S2AGsDiag.DumpLost(); }
                    catch (Exception) { }
                }
                throw error;
            }
        }
        finally { holder.Put(); }
    }

    private void AttachMarkerFailure(Exception error, long markerId, CommandBufferScoped marker,
        Fence fence, Result result, long started, long finished, int timeoutMilliseconds)
    {
        // These are existing handles/indices, not new Vulkan queries. The elapsed time
        // covers only the existing WaitForFences, not FlushAllCommands or queue submit.
        // Attach metadata only: I/O must not block the throw or holder.Put. Formatting
        // or Data failures must not replace the original exception.
        try
        {
            long elapsedUs = Stopwatch.GetElapsedTime(started, finished).Ticks / 10;
            error.Data[nameof(AndroidVulkanSurface)] = $"[GPU backing-change marker failure] session={_session} marker={markerId} managedThread={Environment.CurrentManagedThreadId} result={result} rawResult={(int)result} elapsedUs={elapsedUs} timeoutMs={timeoutMilliseconds} queueFamily={_renderer.QueueFamilyIndex} queue=0x{_renderer.Queue.Handle:x} commandBufferIndex={marker.CommandBufferIndex} commandBuffer=0x{marker.CommandBuffer.Handle:x} fence=0x{fence.Handle:x}";
        }
        catch { }
    }
}
