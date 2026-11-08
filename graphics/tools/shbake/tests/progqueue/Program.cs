// 多线程渲染器等程序（Ryujinx.Graphics.GAL.Multithreading.Resources.ProgramQueue.WaitForProgram）单测。
// 假程序：非阻塞查询永远「未完成」，只有阻塞查询才编完——即现场「所等程序的作业排在后台现编队列后面 / 卡在写缓存」的形状。
// 期望全手算：WaitForProgram 5 秒内返回、阻塞查询次数、Create 次数。反证（旧写法只自旋轮询）：① 永不返回（5 秒超时判红）。
using System;
using System.Threading;
using Ryujinx.Graphics.GAL;
using Ryujinx.Graphics.GAL.Multithreading.Resources;
using Ryujinx.Graphics.GAL.Multithreading.Resources.Programs;

class FakeProg : IProgram
{
    public volatile bool Done;
    public int Blocking;
    public ProgramLinkStatus Result = ProgramLinkStatus.Success;
    public ProgramLinkStatus CheckProgramLink(bool blocking)
    {
        if (blocking) { Interlocked.Increment(ref Blocking); Done = true; return Result; }
        return Done ? Result : ProgramLinkStatus.Incomplete;
    }
    public byte[] GetBinary() => Array.Empty<byte>();
    public void Dispose() { }
}

class Req : IProgramRequest
{
    public ThreadedProgram Threaded { get; set; }
    public readonly FakeProg P = new();
    public int Creates;
    public Req() { Threaded = new ThreadedProgram(null); }
    public IProgram Create(IRenderer renderer) { Creates++; return P; }
}

static class T
{
    static int n, bad;
    static void Expect(string what, object want, object got) { n++; bool ok = Equals(want, got); if (!ok) bad++; Console.WriteLine($"{(ok ? "✓" : "✗")} {what}：期望 {want} → 真结果 {got}"); }

    // 在另一条线程上等，5 秒没返回判超时（线程设后台，不挡进程退出）
    static bool WaitWithin(ProgramQueue q, ThreadedProgram p)
    {
        var th = new Thread(() => q.WaitForProgram(p)) { IsBackground = true };
        th.Start();
        return th.Join(5000);
    }

    static int Main()
    {
        // ① 所等程序在编、后台永不编完：阻塞查询一次就返回
        {
            var q = new ProgramQueue(null); var r = new Req(); q.Add(r);
            q.ProcessQueue();   // 出队、建宿主程序、进在编
            Expect("① 5 秒内返回", true, WaitWithin(q, r.Threaded));
            Expect("① 阻塞查询次数", 1, r.P.Blocking);
            Expect("① 已记编好", true, r.Threaded.Compiled);
            q.ProcessQueue();
            Expect("① Create 次数", 1, r.Creates);
        }
        // ② 在编已满 8 个、所等是第 9 个（还在待编队列、宿主程序没建）：当场建并阻塞查询；之后出队不再建
        {
            var q = new ProgramQueue(null); var rs = new Req[9];
            for (int i = 0; i < 9; i++) { rs[i] = new Req(); q.Add(rs[i]); }
            q.ProcessQueue();
            Expect("② 第 9 个等之前未建", 0, rs[8].Creates);
            Expect("② 5 秒内返回", true, WaitWithin(q, rs[8].Threaded));
            Expect("② 第 9 个 Create 次数", 1, rs[8].Creates);
            Expect("② 第 9 个阻塞查询次数", 1, rs[8].P.Blocking);
            for (int i = 0; i < 8; i++) rs[i].P.Done = true;   // 前 8 个后台编好
            q.ProcessQueue(); q.ProcessQueue();
            int creates = 0, blocking = 0; bool all = true;
            for (int i = 0; i < 9; i++) { creates += rs[i].Creates; blocking += rs[i].P.Blocking; all &= rs[i].Threaded.Compiled; }
            Expect("② 出队后 9 个 Create 总数（第 9 个不重建）", 9, creates);
            Expect("② 阻塞查询总数（只有所等那个）", 1, blocking);
            Expect("② 9 个全记编好", true, all);
        }
        // ③ 阻塞查询结果是失败：照样返回、记已编（上层按失败处理）
        {
            var q = new ProgramQueue(null); var r = new Req(); r.P.Result = ProgramLinkStatus.Failure; q.Add(r);
            q.ProcessQueue();
            Expect("③ 失败也 5 秒内返回", true, WaitWithin(q, r.Threaded));
            Expect("③ 已记编好", true, r.Threaded.Compiled);
        }
        // ④ 已在后台编好、轮询已记下：直接返回，不发阻塞查询
        {
            var q = new ProgramQueue(null); var r = new Req(); r.P.Done = true; q.Add(r);
            q.ProcessQueue(); q.ProcessQueue();   // 第一轮建、第二轮查到编好
            Expect("④ 5 秒内返回", true, WaitWithin(q, r.Threaded));
            Expect("④ 阻塞查询次数", 0, r.P.Blocking);
        }
        Console.WriteLine($"progqueue：{n} 项，失败 {bad}");
        return bad == 0 ? 0 : 1;
    }
}
