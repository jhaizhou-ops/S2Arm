// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 S2Arm contributors
using Ryujinx.HLE.HOS.Kernel.Threading;
using Ryujinx.HLE.HOS.Services.Account.Acc.AsyncContext;
using System.Diagnostics;
using System.Threading;
using System.Threading.Tasks;

namespace S2A.Services.Tests
{
    // 账号异步任务（nn::account IAsyncContext）的「完成了没」按任务本身回答，不看事件（11-05 时之笛开局 Break 2162-0001）：
    //   SDK 把完成事件当自动清除的 nn::os::SystemEvent 用，先 HasDone 为假就去等事件、等到即复位；之后 nn::account::AsyncContext 析构再问 HasDone，
    //   假就 AbortImpl。期望按 HOS 语义手写：任务完成 → 事件亮；事件被复位后，完成状态仍为真、事件为灭（旧实现以事件状态作答，这里会是假）
    static class AccAsyncHasDoneTest
    {
        [SoloTest("--acc-async-hasdone", Booted = true)]
        public static void Run()
        {
            KEvent ev = new(Dispatcher.Instance.Kernel);
            AsyncExecution ex = new(ev);
            Program.Check("账号异步任务：开始前未完成", "False", ex.IsDone.ToString());
            ex.Initialize(10000, async token => await Task.Delay(50, token));
            Stopwatch sw = Stopwatch.StartNew();
            while (!ev.ReadableEvent.IsSignaled() && sw.ElapsedMilliseconds < 5000) Thread.Sleep(1);
            Program.Check("账号异步任务：完成后事件亮、已完成", "True / True", $"{ev.ReadableEvent.IsSignaled()} / {ex.IsDone}");
            ev.ReadableEvent.ClearIfSignaled();   // SDK 等到自动清除事件后复位
            Program.Check("账号异步任务：事件被复位后仍是已完成（HasDone / GetResult 的依据）", "False / True", $"{ev.ReadableEvent.IsSignaled()} / {ex.IsDone}");
        }
    }
}
