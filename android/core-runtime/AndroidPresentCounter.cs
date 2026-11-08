using System.Threading;

namespace S2A.Android.Aot
{
    // GPU writer, UI reader. Counts successful queue-present returns, not panel
    // refreshes or physical scanout; no per-frame file IO or managed allocation.
    public sealed class AndroidPresentCounter
    {
        private long _count;
        public long Count => Interlocked.Read(ref _count);
        public void Observe(ulong count) => Interlocked.Exchange(ref _count, unchecked((long)count));
    }
}
