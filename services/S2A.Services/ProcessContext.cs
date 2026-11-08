using Ryujinx.Cpu;
using Ryujinx.HLE.HOS.Kernel.Process;
using Ryujinx.Memory;
using System;

namespace S2A.Services
{
    // 原生执行的进程在 Ryujinx 眼里的「进程上下文」：只有内存视图（游戏地址 = 宿主地址），没有 CPU 引擎。
    sealed class ProcessContext : IProcessContext
    {
        public ProcessContext(IVirtualMemoryManager memory)
        {
            AddressSpace = memory;
        }

        public IVirtualMemoryManager AddressSpace { get; }

        public ulong AddressSpaceSize => 1UL << 39;

        public IExecutionContext CreateExecutionContext(ExceptionCallbacks exceptionCallbacks)
            => throw new NotSupportedException("S2Arm：游戏代码原生执行，Ryujinx 不建执行上下文");

        public void Execute(IExecutionContext context, ulong codeAddress)
            => throw new NotSupportedException("S2Arm：游戏代码原生执行");

        public void InvalidateCacheRegion(ulong address, ulong size)
        {
        }

        public void Dispose()
        {
        }
    }
}
