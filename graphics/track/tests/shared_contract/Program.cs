using System;
class Program { static int Main() { int a=QueueCheck.Run(), b=SyncpointCheck.Run(), c=NvHostCheck.Run(); Console.WriteLine($"shared GPU contracts: queue={a} syncpoint={b} nvhost={c}"); return a==0 && b==0 && c==0 ? 0 : 1; } }
