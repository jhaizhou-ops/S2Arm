using System;

namespace S2A.Services.Tests
{
    public static unsafe partial class Program
    {
        private sealed class TrackedAudioOwner : IDisposable
        {
            internal int Calls;
            internal bool FailFirst;
            public void Dispose()
            {
                Calls++;
                if (FailFirst && Calls == 1) throw new InvalidOperationException("injected audio disposal failure");
            }
        }

        private static void AudioLifetimeTest()
        {
            var lifetime = new HorizonAudioLifetime();
            var first = new TrackedAudioOwner();
            var failing = new TrackedAudioOwner { FailFirst = true };
            lifetime.Register(first);
            lifetime.Register(failing);
            bool failed = false;
            try { lifetime.Dispose(); } catch (InvalidOperationException) { failed = true; }
            bool lateRejected = false;
            try { lifetime.Register(new TrackedAudioOwner()); } catch (InvalidOperationException) { lateRejected = true; }
            lifetime.Dispose();
            lifetime.Dispose();
            Check("音频清理失败后重试：保留错误，拒绝新 owner，不重复释放已完成对象", "True / True / 1 / 2",
                $"{failed} / {lateRejected} / {first.Calls} / {failing.Calls}");
        }
    }
}
