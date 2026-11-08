using Ryujinx.Horizon;
using System;
using System.Collections;
using System.Reflection;
using System.Runtime.CompilerServices;
using System.Threading;
using System.Threading.Tasks;

namespace S2A.Services.Tests
{
    public static unsafe partial class Program
    {
        private sealed class MergeAudioOwner : IDisposable
        {
            public int Calls;
            public void Dispose() => Calls++;
        }

        private static int HorizonMergeLifecycleTest()
        {
            var dispatcher = (Dispatcher)RuntimeHelpers.GetUninitializedObject(typeof(Dispatcher));
            typeof(Dispatcher).GetField("<Memory>k__BackingField", BindingFlags.NonPublic | BindingFlags.Instance).SetValue(dispatcher, new GuestMemory());
            typeof(Dispatcher).GetProperty("Instance").SetValue(null, dispatcher);
            var table = new ServiceTable();
            using var entered = new ManualResetEventSlim();
            using var release = new ManualResetEventSlim();
            using var failed = new ManualResetEventSlim();
            var original = new InvalidOperationException("merge lifecycle sentinel");
            Exception notified = null;
            HorizonHost.ObserveFailures(e => { notified = e; failed.Set(); });
            var audio = new MergeAudioOwner();
            S2AHorizonHooks.AudioCreated(audio);
            var start = typeof(HorizonHost).GetMethod("Start", BindingFlags.Static | BindingFlags.NonPublic);
            void Start(Action<ServiceTable> body) => start.Invoke(null, new object[] { new ServiceEntry(body, table, default, "merge-fixture") });
            HorizonHost.Ready();
            Start(_ => { entered.Set(); release.Wait(); });
            if (!entered.Wait(3000)) throw new Exception("worker did not start");
            Start(_ => throw original);
            if (!failed.Wait(3000)) throw new Exception("failure not delivered");
            Exception waitError = null;
            try { HorizonHost.WaitServicesReady(table, TimeSpan.FromSeconds(3)); } catch (Exception e) { waitError = e; }
            var stop = Task.Run(() => { try { HorizonHost.Stop(); return (Exception)null; } catch (Exception e) { return e; } });
            bool joinedTooEarly = stop.Wait(100);
            release.Set();
            if (!stop.Wait(3000)) throw new Exception("stop failed to join");
            var wake = typeof(NativeSyscall).GetField("_threadWake", BindingFlags.Static | BindingFlags.NonPublic).GetValue(null);
            int registered = (int)wake.GetType().GetProperty("Count").GetValue(wake);
            Host.DisposeAudioForShutdown();
            Host.DisposeAudioForShutdown();
            bool ok = !joinedTooEarly && ReferenceEquals(notified, original) && ReferenceEquals(waitError, original)
                && stop.Result is InvalidOperationException && ReferenceEquals(stop.Result.InnerException, original)
                && registered == 0 && audio.Calls == 1;
            Console.WriteLine($"Horizon 合流: join等待={!joinedTooEarly}, 原错误通知/取消={ReferenceEquals(notified, original)}/{ReferenceEquals(waitError, original)}, stop保留错误={ReferenceEquals(stop.Result?.InnerException, original)}, 注销剩余={registered}, 音频释放={audio.Calls} {(ok ? "✓" : "✗")}");
            return ok ? 0 : 1;
        }
    }
}
