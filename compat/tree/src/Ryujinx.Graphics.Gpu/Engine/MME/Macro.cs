using Ryujinx.Graphics.Device;
using Ryujinx.Graphics.Gpu.Engine.GPFifo;
using System;

namespace Ryujinx.Graphics.Gpu.Engine.MME
{
    /// <summary>
    /// GPU macro program.
    /// </summary>
    struct Macro
    {
        /// <summary>
        /// Word offset of the code on the code memory.
        /// </summary>
        public int Position { get; }

        private IMacroEE _executionEngine;
        private bool _executionPending;
        private int _argument;
        private MacroHLEFunctionName _hleFunction;

        /// <summary>
        /// Creates a new instance of the GPU cached macro program.
        /// </summary>
        /// <param name="position">Macro code start position</param>
        public Macro(int position)
        {
            Position = position;

            _executionEngine = null;
            _executionPending = false;
            _argument = 0;
            _hleFunction = MacroHLEFunctionName.None;
        }

        /// <summary>
        /// Sets the first argument for the macro call.
        /// </summary>
        /// <param name="context">GPU context where the macro code is being executed</param>
        /// <param name="processor">GPU GP FIFO command processor</param>
        /// <param name="code">Code to be executed</param>
        /// <param name="argument">First argument</param>
        public void StartExecution(GpuContext context, GPFifoProcessor processor, ReadOnlySpan<int> code, int argument)
        {
            _argument = argument;

            _executionPending = true;

            if (_executionEngine == null)
            {
                if (GraphicsConfig.EnableMacroHLE && MacroHLETable.TryGetMacroHLEFunction(code[Position..], context.Capabilities, out _hleFunction))
                {
                    _executionEngine = new MacroHLE(processor, _hleFunction);
                }
                else if (GraphicsConfig.EnableMacroJit)
                {
                    _executionEngine = new MacroJit();
                }
                else
                {
                    // S2A：没有 JIT（NativeAOT）时先按代码内容查离线编译表，命中用编好的方法；表外的报红计数后走解释器
                    _executionEngine = S2AMacroAot.Create(code[Position..]);
                }
            }

            // We don't consume the parameter buffer value, so we don't need to flush it.
            // Doing so improves performance if the value was written by a GPU shader.
            if (_hleFunction == MacroHLEFunctionName.DrawElementsIndirect)
            {
                context.GPFifo.SetFlushSkips(1);
            }
            else if (_hleFunction == MacroHLEFunctionName.MultiDrawElementsIndirectCount)
            {
                context.GPFifo.SetFlushSkips(2);
            }
        }

        /// <summary>
        /// Starts executing the macro program code.
        /// </summary>
        /// <param name="code">Program code</param>
        /// <param name="state">Current GPU state</param>
        public void Execute(ReadOnlySpan<int> code, IDeviceState state)
        {
            if (_executionPending)
            {
                _executionPending = false;
                long t0 = System.Diagnostics.Stopwatch.GetTimestamp();   // S2A：宏执行计时（定「要不要预编」用，见 S2AMacroAot.Account）
                long s2aA = S2AAllocTrace.On ? S2AAllocTrace.Now() : 0;   // S2A：拆账诊断——哪种宏引擎在执行中分配（每种只报第一次）
                _executionEngine?.Execute(code[Position..], state, _argument);
                if (S2AAllocTrace.On)
                {
                    long d = S2AAllocTrace.Now() - s2aA;   // 只在有分配时才拼标签（诊断自己不能每次执行都分配：10-20 第一版每次插值字符串，污染读数）
                    // 按 HLE 函数累计；非 HLE 分开记：0xff = 离线编（S2AMacroAotEE）、0xfe = 解释器（10-23 合成一行被读成「落进解释器」）
                    S2AAllocTrace.Raw(0x60_0000 | (_executionEngine is MacroHLE ? (int)_hleFunction : _executionEngine is MacroInterpreter ? 0xfe : 0xff), d);
                    if (d > 0 && S2AAllocTrace.FirstSeen(_executionEngine?.GetType(), (int)_hleFunction)) Console.Error.WriteLine($"[分配·宏] {_executionEngine?.GetType().Name}/{_hleFunction} 位置 {Position} 一次执行分配 {d} B");
                }
                S2AMacroAot.Account(_executionEngine, System.Diagnostics.Stopwatch.GetTimestamp() - t0);
            }
        }

        /// <summary>
        /// Pushes an argument to the macro call argument FIFO.
        /// </summary>
        /// <param name="gpuVa">GPU virtual address where the command word is located</param>
        /// <param name="argument">Argument to be pushed</param>
        public readonly void PushArgument(ulong gpuVa, int argument)
        {
            _executionEngine?.Fifo.Enqueue(new FifoWord(gpuVa, argument));
        }
    }
}
