// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using Ryujinx.HLE;
using Ryujinx.HLE.HOS.Kernel;
using Ryujinx.HLE.HOS.Kernel.Common;
using Ryujinx.HLE.HOS.Kernel.Threading;
using Ryujinx.Horizon.Common;
using System;
using System.Reflection;
using System.Runtime.CompilerServices;

namespace S2A.Services.Tests
{
    static class ReadableEventClearTest
    {
        [SoloTest("--readable-event-clear", Booted = true)]
        public static void Run()
        {
            KEvent ev = new(Dispatcher.Instance.Kernel);
            uint handle = Dispatcher.EventHandleFor(ev.ReadableEvent);
            ulong native = FakeNative.CookieOf(handle);
            try
            {
                // Native-only signals must survive rejection: managed state is the
                // upstream ClearIfSignaled precondition, not the native event state.
                FakeNative.EventSignal(native);
                CheckClear("未触发托管事件", ev, native, KernelResult.InvalidState, true);

                ev.WritableEvent.Signal();
                CheckClear("已触发托管事件", ev, native, Result.Success, false);

                // Re-arm only the native side to make a repeated clear observable.
                FakeNative.EventSignal(native);
                CheckClear("重复清除", ev, native, KernelResult.InvalidState, true);

                KEvent unbound = new(Dispatcher.Instance.Kernel);
                Program.Check("未绑定事件：未触发清除", KernelResult.InvalidState.ToString(), unbound.ReadableEvent.ClearIfSignaled().ToString());
                unbound.WritableEvent.Signal();
                Program.Check("未绑定事件：触发后清除", Result.Success.ToString(), unbound.ReadableEvent.ClearIfSignaled().ToString());
                Program.Check("未绑定事件：清除后托管状态", "False", unbound.ReadableEvent.IsSignaled().ToString());
            }
            finally
            {
                FakeNative.HandleClose(handle);
                FakeNative.Events.Remove(native);
            }
        }

        private static bool _isolatedNativeSignaled;
        private static int _isolatedNativeClears;

        private static void IsolatedSignal(ulong cookie) => _isolatedNativeSignaled = true;
        private static void IsolatedClear(ulong cookie)
        {
            _isolatedNativeSignaled = false;
            _isolatedNativeClears++;
        }

        // Component-only fixture: actual HLE event/lock/synchronization objects,
        // not a booted kernel. No guest memory, waiters or scheduling are involved.
        // Keep the Booted test above: this does not replace host integration coverage.
        [SoloTest("--readable-event-clear-isolated")]
        public static unsafe int RunIsolated()
        {
            var context = (KernelContext)RuntimeHelpers.GetUninitializedObject(typeof(KernelContext));
            typeof(KernelContext).GetField("<CriticalSection>k__BackingField", BindingFlags.Instance | BindingFlags.NonPublic)!
                .SetValue(context, new KCriticalSection(context));
            typeof(KernelContext).GetField("<Synchronization>k__BackingField", BindingFlags.Instance | BindingFlags.NonPublic)!
                .SetValue(context, new KSynchronization(context));
            KEvent ev = new(context);
            ev.ReadableEvent.S2ANativeEvent = 1;

            void RequireIsolatedContext()
            {
                // With no reselection request SelectThreads returns 0; the foreign
                // thread path therefore never touches the absent scheduler array.
                if (KernelStatic.GetCurrentThread() != null || ev.ReadableEvent.WaitingThreads.Count != 0 ||
                    context.ThreadReselectionRequested || KScheduler.SelectThreads(context) != 0)
                {
                    throw new InvalidOperationException("Isolated event fixture requires a foreign thread, no waiters and no scheduling mask.");
                }
            }

            int failures = 0;
            int cases = 0;
            void Check(string name, Result expected, bool nativeExpected, int clearsExpected)
            {
                RequireIsolatedContext();
                Result actual = ev.ReadableEvent.ClearIfSignaled();
                RequireIsolatedContext();
                bool managed = ev.ReadableEvent.IsSignaled();
                bool ok = actual == expected && !managed && _isolatedNativeSignaled == nativeExpected &&
                    _isolatedNativeClears == clearsExpected;
                Console.WriteLine($"{name}: expected {expected}/False/{nativeExpected}/{clearsExpected}; " +
                    $"actual {actual}/{managed}/{_isolatedNativeSignaled}/{_isolatedNativeClears}; {(ok ? "PASS" : "FAIL")}");
                cases++;
                if (!ok) failures++;
            }

            delegate*<ulong, void> previousSignal = S2AHooks.EventSignal;
            delegate*<ulong, void> previousClear = S2AHooks.EventClear;
            try
            {
                RequireIsolatedContext();
                S2AHooks.EventSignal = &IsolatedSignal;
                S2AHooks.EventClear = &IsolatedClear;
                _isolatedNativeSignaled = true;
                _isolatedNativeClears = 0;
                Check("managed false / native true", KernelResult.InvalidState, true, 0);

                ev.WritableEvent.Signal();
                _isolatedNativeClears = 0;
                Check("managed true / native true", Result.Success, false, 1);

                _isolatedNativeSignaled = true;
                _isolatedNativeClears = 0;
                Check("repeated clear / native rearmed", KernelResult.InvalidState, true, 0);

                ev.ReadableEvent.S2ANativeEvent = 0;
                _isolatedNativeSignaled = true;
                _isolatedNativeClears = 0;
                Check("unbound false", KernelResult.InvalidState, true, 0);
                ev.WritableEvent.Signal();
                Check("unbound true", Result.Success, true, 0);
            }
            finally
            {
                S2AHooks.EventSignal = previousSignal;
                S2AHooks.EventClear = previousClear;
            }

            Console.WriteLine($"Actual HLE event component: {cases} cases, {failures} failures; not Services Boot or concurrency coverage.");
            return failures == 0 && cases == 5 ? 0 : 1;
        }

        private static void CheckClear(string scenario, KEvent ev, ulong native, Result expected, bool nativeExpected)
        {
            Result actual = ev.ReadableEvent.ClearIfSignaled();
            Program.Check($"ClearIfSignaled {scenario}：结果", expected.ToString(), actual.ToString());
            Program.Check($"ClearIfSignaled {scenario}：托管状态", "False", ev.ReadableEvent.IsSignaled().ToString());
            Program.Check($"ClearIfSignaled {scenario}：原生状态", nativeExpected.ToString(), FakeNative.Events[native].ToString());
        }
    }
}
