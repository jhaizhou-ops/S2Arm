using Ryujinx.Memory;
using System;
using System.Collections.Generic;

namespace S2A.Services.Tests
{
    // 收口回写（歧路旅人 II 崩溃线 #199）：不跟踪的托管读碰到 GPU 改过、还没回写的子页前，先发和客机缺页同一个
    //   readflush 读事件（MemoryTracking.S2AReadFlush），回写动作跑完、页恢复可读再取数。信号侧不接管：
    //   NativeAOT 托管缺页在协作上下文，回写要走托管跟踪层，进不了信号。
    //   假 hook + 记录型跟踪句柄：动作里把字节写成回写后的新值并清标记。
    //   先红后绿：拿掉入口的 ReadFlushIfGpuModified 调用，正控每一项都红（0 事件 / 读到旧值）
    public static unsafe partial class Program
    {
        [SvcCase]
        [SoloTest("--readflush", Booted = true)]
        private static void GuestMemoryReadFlush()
        {
            delegate*<ulong, ulong, bool> gmWas = GuestMemory.GpuModifiedHook;
            byte* g = FakeNative.Alloc(0x4000);
            ulong rbase = ((ulong)g + 0xFFF) & ~0xFFFUL;
            GuestMemory gm = new();
            IVirtualMemoryManager rm = gm;

            try
            {
                GuestMemory.GpuModifiedHook = &FakeGpuModified;
                Ryujinx.Memory.Tracking.RegionHandle rhd = gm.BeginTracking(rbase, 0x1000, 0);
                int events = 0;
                ulong evVa = 0, evSize = 0;
                void Arm()
                {
                    rhd.RegisterAction((a, n) =>
                    {
                        events++;
                        evVa = a;
                        evSize = n;
                        _gpuMod = false;
                        new Span<byte>((void*)rbase, 0x20).Fill(0x5A);
                    });
                }

                // 正控：每个不跟踪读入口各一次读事件、发生在取数之前（返回回写后的 0x5A，不是旧值 0x11）
                List<string> got = new();
                _gpuMod = true; new Span<byte>((void*)rbase, 0x20).Fill(0x11); Arm();
                ReadOnlySpan<byte> sp = rm.GetSpan(rbase, 0x20);
                got.Add($"GetSpan {events} 次 {sp[0]:X2}");
                _gpuMod = true; Arm();
                System.Buffers.ReadOnlySequence<byte> sq = rm.GetReadOnlySequence(rbase, 0x20);
                got.Add($"Seq {events} 次 {sq.FirstSpan[0]:X2}");
                _gpuMod = true; Arm();
                byte[] dst8 = new byte[8];
                rm.Read(rbase, dst8);
                got.Add($"Read {events} 次 {dst8[0]:X2}");
                _gpuMod = true; Arm();
                ulong r64 = rm.Read<ulong>(rbase);
                got.Add($"ReadT {events} 次 {r64 & 0xFF:X2}");
                _gpuMod = true; Arm();
                rm.TryReadUnsafe(rbase, 0x20, out Span<byte> us);
                got.Add($"Try {events} 次 {us[0]:X2}");
                _gpuMod = true; Arm();
                using (WritableRegion rw = rm.GetWritableRegion(rbase, 0x20))
                {
                    got.Add($"WReg {events} 次 {rw.Memory.Span[0]:X2}");
                }
                Check("收口回写正控：六个不跟踪读入口各 1 次事件、读到回写后值",
                    "GetSpan 1 次 5A、Seq 2 次 5A、Read 3 次 5A、ReadT 4 次 5A、Try 5 次 5A、WReg 6 次 5A", string.Join("、", got));
                Check("收口回写正控：事件按句柄内区间裁剪", "va 0 size 20",
                    $"{(evVa >= rbase && evVa + evSize <= rbase + 0x1000 ? $"va {evVa - rbase:X} size {evSize:X}" : $"越界 va {evVa:X} size {evSize:X}")}");

                // tracked 分支已经发过读事件：不重复发，GPU 改过在信号里已回写
                _gpuMod = true; Arm();
                int ev0 = events;
                ReadOnlySpan<byte> tsp = rm.GetSpan(rbase, 0x20, tracked: true);
                Check("tracked GetSpan 不重复发事件", "1 次、5A", $"{events - ev0} 次、{tsp[0]:X2}");
                _gpuMod = true; Arm();
                ev0 = events;
                ulong t64 = ((Ryujinx.Cpu.IVirtualMemoryManagerTracked)rm).ReadTracked<ulong>(rbase);
                Check("ReadTracked 不重复发事件", "1 次、5A", $"{events - ev0} 次、{t64 & 0xFF:X2}");

                // 反控 1：区间没标 GPU 改过 → 0 事件、GetSpan 仍是零拷贝指针、Read<T> 结果不变
                _gpuMod = false;
                Arm();
                ev0 = events;
                new Span<byte>((void*)rbase, 0x20).Fill(0x33);
                ReadOnlySpan<byte> nsp = rm.GetSpan(rbase, 0x20);
                ulong nval = rm.Read<ulong>(rbase + 8);
                bool zerocopy = (ulong)System.Runtime.CompilerServices.Unsafe.AsPointer(ref System.Runtime.InteropServices.MemoryMarshal.GetReference(nsp)) == rbase;
                Check("未标 GPU 改过：0 事件、零拷贝指针不变、内容原值", "0、是、值不变",
                    $"{events - ev0}、{(zerocopy ? "是" : "否")}、{(nsp[0] == 0x33 && (nval & 0xFF) == 0x33 ? "值不变" : $"值变 {nsp[0]:X2}/{nval & 0xFF:X2}")}");

                // 反控 2：GpuModifiedHook 空（Mac 现状）→ 行为逐字节不变、事件 0 次
                GuestMemory.GpuModifiedHook = null;
                ev0 = events;
                ReadOnlySpan<byte> hsp = rm.GetSpan(rbase, 0x20);
                ulong hv = rm.Read<ulong>(rbase + 8);
                byte[] hd8 = new byte[4];
                rm.Read(rbase, hd8);
                Check("hook 空（Mac 现状）：0 事件、行为不变", "0、值不变",
                    $"{events - ev0}、{(hsp[0] == 0x33 && (hv & 0xFF) == 0x33 && hd8[0] == 0x33 ? "值不变" : "值变")}");
                GuestMemory.GpuModifiedHook = &FakeGpuModified;

                // 计数器：私有静态累计，每次回写 +1（日志行「收口回写 N 次」的设备判据 N > 0 靠它）
                System.Reflection.FieldInfo rf = typeof(GuestMemory).GetField("_readFlush", System.Reflection.BindingFlags.Static | System.Reflection.BindingFlags.NonPublic);
                Check("收口回写计数器", "有 6 次", rf != null && (long)rf.GetValue(null) >= 1 ? $"有 {(long)rf.GetValue(null)} 次" : "无");

                // 死锁负控：读线程触发回写、回写在另一线程执行（双线程渲染时回写在渲染线程上执行），循环 1000 次带超时。
                //   回写线程进跟踪层（要 TrackingLock）：事件若在锁内跑动作，读线程等回写、回写等锁 = WriteQuietHook 注释记过的互等
                {
                    System.Threading.ManualResetEventSlim wrReady = new(), wrDone = new();
                    Exception werr = null;
                    System.Threading.Thread writer = new(() =>
                    {
                        try
                        {
                            while (wrReady.Wait(TimeSpan.FromSeconds(30)))
                            {
                                wrReady.Reset();
                                gm.Tracking.VirtualMemoryEvent(rbase + 0x1000, 8, false);
                                new Span<byte>((void*)rbase, 0x20).Fill(0x5C);
                                wrDone.Set();
                            }
                        }
                        catch (Exception e) { werr = e; }
                    }) { IsBackground = true };
                    writer.Start();
                    int loops = 0;
                    Exception rerr = null;
                    System.Threading.Thread reader = new(() =>
                    {
                        try
                        {
                            for (int i = 0; i < 1000; i++)
                            {
                                _gpuMod = true;
                                rhd.RegisterAction((a, n) =>
                                {
                                    wrReady.Set();
                                    if (!wrDone.Wait(TimeSpan.FromSeconds(30)))
                                    {
                                        throw new TimeoutException("writeback wait");
                                    }
                                    wrDone.Reset();
                                });
                                ReadOnlySpan<byte> s = rm.GetSpan(rbase, 4);
                                if (s[0] != 0x5C)
                                {
                                    throw new Exception($"stale read {s[0]:X2}");
                                }
                                loops++;
                            }
                        }
                        catch (Exception e) { rerr = e; }
                    });
                    reader.Start();
                    if (!reader.Join(TimeSpan.FromMinutes(2)))
                    {
                        rerr = new TimeoutException("readflush loop did not finish in 2 minutes");
                    }
                    Check("死锁负控：1000 次跨线程回写不互等", "1000、无异常", $"{loops}、{rerr?.Message ?? werr?.Message ?? "无异常"}");
                }

                rhd.Dispose();
            }
            finally
            {
                GuestMemory.GpuModifiedHook = gmWas;
                FakeNative.Free(g);
            }
        }
    }
}
