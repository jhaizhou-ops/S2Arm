// S2A: 本文件为 S2A 新增（非 Ryujinx 原版）。宏（MME）程序离线编译：NativeAOT 没有 Reflection.Emit（MacroJit 用不了），
// 改为事先把游戏上传的宏程序翻成 C# 静态方法（旧库 ryu_judge --macrogen 生成 S2AMacroTable.g.cs），运行时按代码内容查表，命中就跑编好的方法，
// 否则照旧 MacroInterpreter。语义以 MacroInterpreter 为准（AOT 下原本就走它）：生成器只编「与解释器逐条等价可静态确定」的程序，
// 其余（延迟槽 / 退出槽里是分支、跳转目标越界、非法操作码、程序尾超出宏内存）一律不编、回解释器。
// 旧库 10-19 precise 口径双算核对：宏离线编 9542 万次执行与解释器读写序列 / 退出寄存器 / 参数队列 0 不一致。
using Ryujinx.Graphics.Device;
using System;
using System.Collections.Generic;

namespace Ryujinx.Graphics.Gpu.Engine.MME
{
    /// <summary>S2A: 宏程序退出时的寄存器状态（生成的方法签名带它；r0 恒 0 不记）。</summary>
    struct S2AMacroRegs
    {
        public int R1, R2, R3, R4, R5, R6, R7;
        public bool Carry;
        public int MethAddr, MethIncr;
    }

    /// <summary>S2A: 离线编好的宏程序入口。</summary>
    delegate void S2AMacroFn(MacroJitContext ctx, IDeviceState state, int arg0, ref S2AMacroRegs regs);

    /// <summary>S2A: 离线编译表与程序范围判定。公开：生成器（graphics/tools/macrogen）用 Hash / Analyze 与运行时同一口径。</summary>
    public static partial class S2AMacroAot
    {
        internal sealed class Entry
        {
            public readonly int[] Code;
            public readonly S2AMacroFn Fn;

            public Entry(int[] code, S2AMacroFn fn)
            {
                Code = code;
                Fn = fn;
            }
        }

        private static Dictionary<ulong, Entry> _table;

        /// <summary>生成文件（S2AMacroTable.g.cs）实现：把全部离线编好的程序登记进表。没有生成文件时表为空。</summary>
        static partial void Register(Dictionary<ulong, Entry> table);

        private static Dictionary<ulong, Entry> Table
        {
            get
            {
                if (_table == null)
                {
                    Dictionary<ulong, Entry> t = new();
                    Register(t);
                    _table = t;
                }

                return _table;
            }
        }

        /// <summary>
        /// 程序范围与可编性。范围照 MacroJitCompiler.Compile 收集分支目标那一遍：从头扫到第一个「带退出标志且不小于已见最远分支目标」的字 E，
        /// 程序 = [0, E+1]（E+1 是退出后照硬件再执行的那一条），长度 E+2；解释器执行 E+1 时还会预取 E+2，所以要求 E+2 仍在宏内存内。
        /// 返回长度（找不到 E 或越界返回 -1）；reason 为 null 表示可编。
        /// </summary>
        public static int Analyze(ReadOnlySpan<int> code, out string reason)
        {
            int lastTarget = 0;
            int e = -1;

            for (int i = 0; i < code.Length; i++)
            {
                int op = code[i];

                if ((op & 7) == 7)
                {
                    int target = i + (op >> 14);

                    if (lastTarget < target)
                    {
                        lastTarget = target;
                    }
                }

                if ((op & 0x80) != 0 && i >= lastTarget)
                {
                    e = i;
                    break;
                }
            }

            if (e < 0 || e + 2 >= code.Length)
            {
                reason = "no_end";
                return -1;
            }

            reason = null;

            for (int p = 0; p <= e + 1; p++)
            {
                int op = code[p];
                bool branch = (op & 7) == 7;

                if (!branch)
                {
                    if (!ValidAlu(op))
                    {
                        reason ??= $"invalid_op@{p}";
                    }

                    if (p <= e && (op & 0x80) != 0 && (code[p + 1] & 7) == 7)
                    {
                        reason ??= $"branch_in_exit_slot@{p + 1}";
                    }

                    continue;
                }

                if (p > e)
                {
                    continue; // E+1 是分支：只在被当作槽执行时才有影响，那时上面 / 下面已判不可编
                }

                int t = p + (op >> 14);

                if (t < 0 || t > e)
                {
                    reason ??= $"target_out@{p}";
                }

                if ((op & 0x20) == 0 && (code[p + 1] & 7) == 7)
                {
                    reason ??= $"branch_in_delay_slot@{p + 1}";
                }

                if ((op & 0x80) != 0 && (code[p + 1] & 7) == 7)
                {
                    reason ??= $"branch_in_exit_slot@{p + 1}";
                }
            }

            return e + 2;
        }

        private static bool ValidAlu(int op)
        {
            switch (op & 7)
            {
                case 0:
                    int sub = (op >> 17) & 0x1f;
                    return sub <= 3 || (sub >= 8 && sub <= 12);
                case 1:
                case 2:
                case 3:
                case 4:
                case 5:
                    return true;
                default:
                    return false;
            }
        }

        /// <summary>按字 FNV-1a 64 位（表里还存全文，命中时逐字比，哈希只用来查）。</summary>
        public static ulong Hash(ReadOnlySpan<int> words)
        {
            ulong h = 0xcbf29ce484222325UL;

            foreach (int w in words)
            {
                h = (h ^ (uint)w) * 0x100000001b3UL;
            }

            return (h ^ (ulong)words.Length) * 0x100000001b3UL;
        }

        /// <summary>按代码内容查离线编译表；命中返回 Entry。</summary>
        internal static Entry Lookup(ReadOnlySpan<int> code)
        {
            int len = Analyze(code, out string reason);

            if (len < 0 || reason != null)
            {
                return null;
            }

            ReadOnlySpan<int> prog = code[..len];

            return Table.TryGetValue(Hash(prog), out Entry entry) && prog.SequenceEqual(entry.Code) ? entry : null;
        }

        /// <summary>Macro.StartExecution 建执行引擎时调用（只在 EnableMacroJit 为假时）：命中返回离线编版本，否则记表外、返回解释器。</summary>
        internal static IMacroEE Create(ReadOnlySpan<int> code)
        {
            Entry entry = Lookup(code);

            if (entry != null)
            {
                return new S2AMacroAotEE(entry);
            }

            ReportMiss(code);

            return new MacroInterpreter();
        }

        // 表外的宏：每支（按代码哈希）首次出现报红一行并计数，不静默；设了 S2A_MACRO_DUMP=<目录> 时导出 <哈希>.mme（小端 int32 字），
        // 供 graphics/tools/macrogen 重生成本表（出包流程按游戏收）。只在 GPU 线程上调；去重表只在首次出现时分配
        private static readonly HashSet<ulong> _missed = new();
        private static readonly string _dumpDir = Environment.GetEnvironmentVariable("S2A_MACRO_DUMP");

        // 宏执行累计（GPU 线程上写；宿主按帧差分写 frames.tsv）：按执行引擎分 HLE 宏 / 离线编 / 解释器，各计次数与 Stopwatch 刻度。
        // 用途：量表外宏走解释器的真实代价，定离线表要不要留 / 要不要做快速解释器（10-19 总指挥：不靠采集局）
        public static long HleN, AotN, InterpN, HleTicks, AotTicks, InterpTicks;

        internal static void Account(IMacroEE ee, long ticks)
        {
            switch (ee)
            {
                case MacroInterpreter: InterpN++; InterpTicks += ticks; break;
                case S2AMacroAotEE: AotN++; AotTicks += ticks; break;
                case null: break;
                default: HleN++; HleTicks += ticks; break;
            }
        }

        /// <summary>表外、走解释器的宏程序支数（健康表 / 单测读）。</summary>
        public static int MissCount => _missed.Count;

        internal static void ReportMiss(ReadOnlySpan<int> code)
        {
            int len = Analyze(code, out string reason);
            ReadOnlySpan<int> prog = len > 0 ? code[..len] : code[..Math.Min(code.Length, 64)];
            ulong h = Hash(prog);

            if (!_missed.Add(h))
            {
                return;
            }

            Console.Error.WriteLine($"[gal] 【红】宏未离线编：程序 {h:x16}（{prog.Length} 字），走解释器{(reason != null ? "；不可编：" + reason : "")}（表外第 {_missed.Count} 支）");

            if (!string.IsNullOrEmpty(_dumpDir) && len > 0)
            {
                try
                {
                    System.IO.Directory.CreateDirectory(_dumpDir);
                    System.IO.File.WriteAllBytes(System.IO.Path.Combine(_dumpDir, $"{h:x16}.mme"), System.Runtime.InteropServices.MemoryMarshal.AsBytes(prog).ToArray());
                }
                catch (Exception e)
                {
                    Console.Error.WriteLine($"[gal] 【红】宏导出失败：{e.Message}");
                }
            }
        }
    }

    /// <summary>
    /// S2A: 离线编版本的执行引擎。每次执行前核对宏内存里的程序仍与编时相同（游戏不换起始地址只改代码时，解释器读的是新代码；
    /// 这里同样跟着走：不同就按新代码重查表，查不到用同一参数队列的解释器）。
    /// </summary>
    sealed class S2AMacroAotEE : IMacroEE
    {
        private readonly MacroJitContext _ctx = new();
        private S2AMacroAot.Entry _entry;
        private MacroInterpreter _interp;
        private S2AMacroRegs _regs;

        public Queue<FifoWord> Fifo => _ctx.Fifo;

        public S2AMacroAotEE(S2AMacroAot.Entry entry)
        {
            _entry = entry;
        }

        public void Execute(ReadOnlySpan<int> code, IDeviceState state, int arg0)
        {
            int[] snap = _entry?.Code;

            if (snap == null || code.Length < snap.Length || !code[..snap.Length].SequenceEqual(snap))
            {
                _entry = S2AMacroAot.Lookup(code);
            }

            if (_entry == null)
            {
                S2AMacroAot.ReportMiss(code);
                (_interp ??= new MacroInterpreter(_ctx.Fifo)).Execute(code, state, arg0);
                return;
            }

            _entry.Fn(_ctx, state, arg0, ref _regs);
        }
    }
}
