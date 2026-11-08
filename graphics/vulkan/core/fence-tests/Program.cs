using Ryujinx.Common;
using Ryujinx.Graphics.Vulkan;
using Silk.NET.Core;
using Silk.NET.Core.Contexts;
using Silk.NET.Vulkan;
using System;
using System.Collections.Generic;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;

// Only vkWaitForFences is controlled. Compile the actual production helper and
// exception code, and call through Silk's real dispatch. No GPU or loader runs.
internal static unsafe class Program
{
    private static readonly Queue<Result> Results = new();
    private static readonly List<Call> Calls = new();
    private static int _checks;
    private static int _failures;

    private readonly record struct Call(nint Device, uint Count, bool All, ulong Timeout, ulong First, ulong Second);

    private static int Main()
    {
        using Vk api = new(new Dispatch());
        Device device = new(0x123);
        Fence[] fences = [new(0x456), new(0x789)];

        foreach (bool all in new[] { false, true })
        {
            foreach (Result result in new[] { Result.Success, Result.Timeout, Result.NotReady })
            {
                Reset(result);
                bool signaled = all
                    ? FenceHelper.AllSignaled(api, device, fences, 37)
                    : FenceHelper.AnySignaled(api, device, fences, 37);
                Check(signaled == (result == Result.Success), $"{all}/{result}: wrong bool result");
                CheckCall(all, 37, 1);
            }

            foreach (Result result in new[] { Result.ErrorDeviceLost, Result.ErrorOutOfHostMemory, Result.ErrorOutOfDeviceMemory })
            {
                Reset(result);
                ExpectError(() => all
                    ? FenceHelper.AllSignaled(api, device, fences, 37)
                    : FenceHelper.AnySignaled(api, device, fences, 37), result, $"{all}/{result}");
                CheckCall(all, 37, 1);
            }

            Reset(Result.Timeout);
            _ = all
                ? FenceHelper.AllSignaled(api, device, fences)
                : FenceHelper.AnySignaled(api, device, fences);
            CheckCall(all, 0, 1);
        }

        Reset(Result.Timeout, Result.Success);
        FenceHelper.WaitAllIndefinitely(api, device, fences);
        CheckCall(true, 100000000, 2);

        Reset(Result.Timeout, Result.ErrorDeviceLost);
        ExpectError(() =>
        {
            FenceHelper.WaitAllIndefinitely(api, device, fences);
            return true;
        }, Result.ErrorDeviceLost, "indefinite after timeout");
        CheckCall(true, 100000000, 2);

        S2AGsDiag.S2ATestReset();
        S2AGsDiag.s_gateOpen = () => true;
        Environment.SetEnvironmentVariable("S2A_GS_DIAG", "1");
        S2AGsDiag.s_emit = _ => throw new InvalidOperationException("diagnostic sink failure");
        Reset(Result.ErrorDeviceLost);
        ExpectError(() => FenceHelper.AllSignaled(api, device, fences, 37),
            Result.ErrorDeviceLost, "diagnostic sink failure preserves DeviceLost");
        CheckCall(true, 37, 1);
        S2AGsDiag.S2ATestReset();
        Environment.SetEnvironmentVariable("S2A_GS_DIAG", null);

        Console.WriteLine($"Fence result dispatch: {_checks} checks, {_failures} failures; no GPU execution.");
        return _failures == 0 ? 0 : 1;
    }

    private static void Reset(params Result[] results)
    {
        Results.Clear();
        Calls.Clear();
        foreach (Result result in results)
        {
            Results.Enqueue(result);
        }
    }

    private static void ExpectError(Func<bool> action, Result expected, string label)
    {
        try
        {
            _ = action();
            Check(false, $"{label}: negative VkResult was swallowed");
        }
        catch (VulkanException exception)
        {
            Check(exception.Message.Contains(expected.ToString(), StringComparison.Ordinal),
                $"{label}: original VkResult was lost");
        }
    }

    private static void CheckCall(bool all, ulong timeout, int expectedCalls)
    {
        Check(Calls.Count == expectedCalls && Results.Count == 0, "unexpected retry or missing Vulkan call");
        foreach (Call call in Calls)
        {
            Check(call == new Call(0x123, 2, all, timeout, 0x456, 0x789), "wait arguments changed");
        }
    }

    private static void Check(bool condition, string message)
    {
        _checks++;
        if (!condition)
        {
            _failures++;
            Console.Error.WriteLine($"FAIL: {message}");
        }
    }

    [UnmanagedCallersOnly(CallConvs = new[] { typeof(CallConvCdecl) })]
    private static Result WaitForFences(Device device, uint count, Fence* fences, Bool32 all, ulong timeout)
    {
        Calls.Add(new Call(device.Handle, count, all, timeout,
            count > 0 ? fences[0].Handle : 0, count > 1 ? fences[1].Handle : 0));
        return Results.Count == 0 ? Result.ErrorUnknown : Results.Dequeue();
    }

    private sealed class Dispatch : INativeContext
    {
        public nint GetProcAddress(string name, int? slot = null) => name == "vkWaitForFences"
            ? (nint)(delegate* unmanaged[Cdecl]<Device, uint, Fence*, Bool32, ulong, Result>)&WaitForFences
            : 0;

        public bool TryGetProcAddress(string name, out nint address, int? slot = null)
        {
            address = GetProcAddress(name, slot);
            return address != 0;
        }

        public void Dispose() { }
    }
}
