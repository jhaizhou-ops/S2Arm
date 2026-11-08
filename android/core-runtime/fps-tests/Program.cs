using System;
using System.Threading;
using S2A.Android.Aot;

var counter = new AndroidPresentCounter();
if (counter.Count != 0) throw new Exception("initial count");
counter.Observe(0x100000001UL);
if (counter.Count != 0x100000001L) throw new Exception("64-bit count");
var writer = new Thread(() => { for (ulong i = 2; i <= 100000; i++) counter.Observe(0x100000000UL + i); });
writer.Start();
long previous = counter.Count;
while (writer.IsAlive)
{
    long now = counter.Count;
    if (now < previous) throw new Exception("torn/regressing counter");
    previous = now;
}
writer.Join();
if (counter.Count != 0x100000000L + 100000) throw new Exception("final count");
long allocated = GC.GetAllocatedBytesForCurrentThread();
for (ulong i = 0; i < 10000; i++) counter.Observe(i);
if (GC.GetAllocatedBytesForCurrentThread() != allocated) throw new Exception("per-frame allocation");
Console.WriteLine("PASS FPS counter: initial, 64-bit, concurrent monotonic read, final value, no per-frame allocations");
