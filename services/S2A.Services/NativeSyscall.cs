using Ryujinx.Horizon.Common;
using Ryujinx.Memory;
using System;
using System.Runtime.InteropServices;
using System.Threading;

namespace S2A.Services
{
    // Horizon 新框架服务眼里的「内核」：Ryujinx.Horizon 的服务代码只经 ISyscallApi 碰内核对象，
    // 这里把它接到 S2Arm 原生层（句柄、事件全在原生层），所以服务建的事件 / 递出的句柄天然就是游戏句柄，不用翻译。
    // 端口与服务端会话是 C# 内部记号（HorizonHost 管），不进原生句柄表。
    sealed unsafe class NativeSyscall : ISyscallApi
    {
        // C# 内部记号：服务端口、服务端会话、sm 连接、服务线程。高位 0xA 与原生句柄（低 15 位下标 + 序号）、伪句柄 0xFFFF80xx 不相交
        internal const int TokenBase = unchecked((int)0xA0000000);
        internal const int SmToken = TokenBase | 1;
        private static int _nextToken = 0x100;

        internal static int NewToken() => TokenBase | Interlocked.Increment(ref _nextToken);
        internal static bool IsToken(int h) => ((uint)h & 0xF0000000u) == 0xA0000000u; // 按无符号比：int 与 uint 混算会提升成 long，负数句柄恒不等

        private static readonly ManualResetEventSlim _shutdown = new(false);
        internal static void Shutdown() => _shutdown.Set();

        internal static void Reset()
        {
            if (!_threadWake.IsEmpty) throw new InvalidOperationException("Horizon 服务线程尚未退出");
            lock (_copyLock)
            {
                foreach (var copy in _copies.Values)
                    if (copy.Kind is ObjKind.EventR or ObjKind.EventW) Native.EventRelease(copy.Cookie);
                _copies.Clear();
            }
            _nextToken = 0x100;
            s_maxHeapSize = 0;
            _shutdown.Reset();
        }

        // 服务线程等待（主循环停在这里）：被取消（CancelSynchronization）或关停唤醒
        [ThreadStatic] private static AutoResetEvent t_wake;
        private static readonly System.Collections.Concurrent.ConcurrentDictionary<int, AutoResetEvent> _threadWake = new();

        internal static void RegisterServiceThread(int threadToken)
        {
            t_wake = new AutoResetEvent(false);
            _threadWake[threadToken] = t_wake;
        }

        internal static void UnregisterServiceThread(int threadToken)
        {
            _threadWake.TryRemove(threadToken, out _);
            t_wake?.Dispose();
            t_wake = null;
            t_heapBlock?.Dispose();
            t_heapBlock = null;
            t_heap = 0;
            Ryujinx.Horizon.HorizonStatic.Register(default, null, null, null, 0);
        }

        // 游戏随请求递来的复制句柄：内核会给服务端复制一份新句柄（服务关它不影响游戏手里的）。直调没有内核，
        // HorizonTarget 把消息里的复制句柄换成这里的记号，服务对记号的操作解析回原生对象，关记号只删记录
        private static readonly object _copyLock = new();
        private static readonly System.Collections.Generic.Dictionary<int, (uint Native, ObjKind Kind, ulong Cookie)> _copies = new();

        internal static int CopyIn(uint nativeHandle)
        {
            uint kind;
            ulong cookie;

            if (Native.HandleGet(nativeHandle, &kind, &cookie) == 0)
            {
                Red.Report("Horizon 服务请求递来无效复制句柄", $"0x{nativeHandle:X}");
                return 0;
            }

            int token = NewToken();

            // 事件可能被服务跨请求持有（游戏关了自己的句柄也要有效）：retain，关记号时 release（接口 v2.1）
            if ((ObjKind)kind is ObjKind.EventR or ObjKind.EventW)
            {
                Native.EventRetain(cookie);
            }

            lock (_copyLock)
            {
                _copies[token] = (nativeHandle, (ObjKind)kind, cookie);
            }

            return token;
        }

        internal static int CopyCount { get { lock (_copyLock) { return _copies.Count; } } }

        internal static bool ResolveForCopy(int handle, out ObjKind kind, out ulong cookie) => Resolve(handle, out _, out kind, out cookie);

        private static bool Resolve(int handle, out uint native, out ObjKind kind, out ulong cookie)
        {
            if (IsToken(handle))
            {
                lock (_copyLock)
                {
                    if (_copies.TryGetValue(handle, out (uint Native, ObjKind Kind, ulong Cookie) e))
                    {
                        (native, kind, cookie) = e;
                        return true;
                    }
                }

                native = 0;
                kind = ObjKind.None;
                cookie = 0;
                return false;
            }

            uint k;
            ulong c;
            native = (uint)handle;

            if (Native.HandleGet((uint)handle, &k, &c) == 0)
            {
                kind = ObjKind.None;
                cookie = 0;
                return false;
            }

            kind = (ObjKind)k;
            cookie = c;
            return true;
        }

        private readonly GuestMemory _memory;

        public NativeSyscall(GuestMemory memory)
        {
            _memory = memory;
        }

        // 每个 Horizon 服务线程一块「进程堆」（上游 HeapAllocator 按 2 MB 递增扩堆，要求基址不变、新增部分紧接其后）：
        // 一次占 HeapReserve 的宿主内存（未触碰的页不占物理内存），游戏地址 = 宿主地址，服务经 GuestMemory 原地访问。
        // 用 mmap（MemoryBlock）不用 malloc：堆地址游戏看得见，HIPC 描述符只装得下 39 位地址；malloc 的大块落点由分配器定
        // （Mac xzm 放在 0x80_0000_0000 以上，10-20 Mac 复现 iPhone 地址约束时回写被截断成访问违例），mmap 按首个放得下的空洞放，与 iPhone 同落低区
        // 预留 4 MB（原 16 MB × 10 条服务线程 = iPhone 低区 160 MB，VAMM 款窗口外只剩约 1.5 GB）：各 Horizon 服务只从这块堆里分
        // 「最大会话数 ×（指针缓冲 + 0x100 消息缓冲）」与 arp 的控制数据缓冲，最大的 wlan 是 129 ×（0x1000 + 0x100）= 561 KB，
        // HeapAllocator 按 2 MB 步长扩堆 ⇒ 每条线程恰好扩一次到 2 MB，与游戏无关；4 MB = 2 倍余量。超了照旧报红并回 OutOfMemory（服务 AbortOnFailure，响亮）
        internal const ulong HeapReserve = 4UL << 20;
        private static long s_maxHeapSize;
        // 各服务线程扩堆的最大请求（单测核「每条线程恰好 2 MB」，有服务开始要更多时先在单测里红）
        internal static ulong MaxHeapSize => (ulong)Interlocked.Read(ref s_maxHeapSize);
        private const ulong HipcAddrLimit = 1UL << 39;
        [ThreadStatic] private static ulong t_heap;
        [ThreadStatic] private static MemoryBlock t_heapBlock;

        // [ptr, ptr + len) 整段在 HIPC 描述符的 39 位地址内（结尾恰好 = 1<<39 算装得下）；先比 ptr 再比余量，不在 ptr + len 上溢出
        internal static bool FitsHipcAddr(ulong ptr, ulong len) => ptr <= HipcAddrLimit && len <= HipcAddrLimit - ptr;

        public Result SetHeapSize(out ulong address, ulong size)
        {
            if (size > HeapReserve)
            {
                Red.Report("Horizon 服务堆超过预留", $"{size >> 20} MB > {HeapReserve >> 20} MB");
                address = 0;
                return KernelResult.OutOfMemory;
            }

            if (t_heap == 0)
            {
                // 落在 39 位以外的块不当堆用（审计 #859：原先只报红、照样回 Success，服务拿截断的地址回写）：放掉、不记，回内存不足（服务 AbortOnFailure，响亮）
                MemoryBlock block = new(HeapReserve);
                ulong ptr = (ulong)block.Pointer;

                if (!FitsHipcAddr(ptr, HeapReserve))
                {
                    block.Dispose();
                    Red.Report("Horizon 服务堆超出 39 位地址", $"0x{ptr:x} + {HeapReserve >> 20} MB（HIPC 描述符装不下，回写会被截断），已回内存不足");
                    address = 0;
                    return KernelResult.OutOfMemory;
                }

                t_heapBlock = block;
                t_heap = ptr;
            }

            address = t_heap;
            for (long m = Interlocked.Read(ref s_maxHeapSize); (long)size > m; m = Interlocked.Read(ref s_maxHeapSize))
            {
                if (Interlocked.CompareExchange(ref s_maxHeapSize, (long)size, m) == m)
                {
                    break;
                }
            }

            return Result.Success;
        }

        // 睡眠可被关停打断（Horizon：线程终止叫醒睡眠；取消等待不作用于睡眠）。0 / 负数 = 让出。
        //   上游 Horizon 服务里唯一的调用是 SmApi.Initialize「连 sm: 回 NotFound 就睡 50 ms 重试」，这里连 sm: 恒成功（审计 P2-24）
        public void SleepThread(long timeout)
        {
            if (timeout <= 0) Thread.Sleep(0);
            else _shutdown.Wait(TimeSpan.FromTicks(timeout / 100));
        }

        public Result CloseHandle(int handle)
        {
            if (IsToken(handle))
            {
                (uint Native, ObjKind Kind, ulong Cookie) e;
                bool had;

                lock (_copyLock)
                {
                    had = _copies.Remove(handle, out e); // 复制句柄记号：删记录；其余内部记号无需释放（会话关闭走 HorizonTarget.Closed）
                }

                if (had && e.Kind is ObjKind.EventR or ObjKind.EventW)
                {
                    Native.EventRelease(e.Cookie);
                }

                return Result.Success;
            }

            if (Dispatcher.TraceIpc)
            {
                Console.Error.WriteLine($"[IPC] Horizon 关句柄 0x{handle:X}（线程 {Environment.CurrentManagedThreadId}）");
            }

            if (Native.HandleClose((uint)handle) != 0) // 接口 v2.4：1 = 关掉了，0 = 无此句柄
            {
                return Result.Success;
            }

            Red.Report("Horizon 服务关句柄失败（句柄已不在表里）", $"0x{handle:X}");
            return KernelResult.InvalidHandle;
        }

        public Result WaitSynchronization(out int handleIndex, ReadOnlySpan<int> handles, long timeout) => Park(out handleIndex, timeout);

        public Result ReplyAndReceive(out int handleIndex, ReadOnlySpan<int> handles, int replyTargetHandle, long timeout)
        {
            if (handles.Length == 0)
            {
                // 只应答：游戏线程上直调时应答已原地写进游戏的消息缓冲。真内核「应答后不接收（超时 0）」回 TimedOut，上游 Api.Reply 按此判
                handleIndex = 0;
                return KernelResult.TimedOut;
            }

            return Park(out handleIndex, timeout);
        }

        // 服务线程的主循环不处理任何请求（请求在游戏线程上直调），等待一律挂起到被取消 / 关停
        private static Result Park(out int handleIndex, long timeout)
        {
            handleIndex = -1;

            if (t_wake == null)
            {
                Red.Report("游戏线程上的 Horizon 服务代码要等待内核对象（S2Arm 未支持）");
                return KernelResult.InvalidState;
            }

            if (timeout == 0)
            {
                return KernelResult.TimedOut;
            }

            int ms = timeout < 0 ? Timeout.Infinite : (int)Math.Min(int.MaxValue, timeout / 1_000_000);
            int which = WaitHandle.WaitAny([t_wake, _shutdown.WaitHandle], ms);

            return which switch
            {
                0 => KernelResult.Cancelled,
                1 => KernelResult.ThreadTerminating,
                _ => KernelResult.TimedOut,
            };
        }

        // 取消等待（照 Horizon svcCancelSynchronization）：句柄是服务线程记号（S2AThreadContext x1）→ 叫醒它正在的等待，
        //   没在等就记一次待取消（AutoResetEvent），下一次等待立即回 Cancelled；不是活着的服务线程 → InvalidHandle。
        //   上游 MultiWaitImpl 在本地事件（关停请求、等待表有新对象）触发时用它叫醒主循环（审计 P2-24）。
        //   能真叫醒的前提：游戏线程受理会话不再把端口挂回等待表（ServerManagerBase.S2AProcessForServer），醒来不会重复挂入
        public Result CancelSynchronization(int handle)
        {
            if (!_threadWake.TryGetValue(handle, out AutoResetEvent wake))
            {
                return KernelResult.InvalidHandle;
            }

            try
            {
                wake.Set();
            }
            catch (ObjectDisposedException)
            {
                return KernelResult.InvalidHandle;   // 线程正在退出（注销与这里交错）
            }

            return Result.Success;
        }

        public Result GetProcessId(out ulong pid, int handle)
        {
            if (Resolve(handle, out _, out ObjKind kind, out ulong cookie) && kind == ObjKind.Process)
            {
                pid = cookie;
                return Result.Success;
            }

            pid = 0;
            return KernelResult.InvalidHandle;
        }

        public Result ConnectToNamedPort(out int handle, string name)
        {
            if (name == "sm:")
            {
                handle = SmToken;
                return Result.Success;
            }

            Red.Report($"Horizon 服务连命名端口 {name}（S2Arm 未支持）");
            handle = 0;
            return KernelResult.NotFound;
        }

        // 服务发请求（连 sm、服务调别的服务）：消息在本线程 TLS，即上游客户端代码（ServiceUtil 等）写请求的
        // HorizonStatic.ThreadContext.TlsAddress——服务线程上是 S2AThreadContext，游戏线程上直调时是当前请求的消息缓冲
        // （服务处理请求中途再调别的服务，同上游在服务线程上一样就地覆盖 TLS）
        public Result SendSyncRequest(int handle)
        {
            byte* msg = (byte*)(Ryujinx.Horizon.HorizonStatic.ThreadContext?.TlsAddress ?? 0);

            if (msg == null)
            {
                Red.Report("Horizon 服务在没有 TLS 的线程上发请求");
                return KernelResult.InvalidState;
            }

            Dispatcher d = Dispatcher.Instance;

            if (handle == SmToken)
            {
                return new Result((int)d.Sm.Process(d, msg, 0x100));
            }

            uint kind;
            ulong cookie;

            if (Native.HandleGet((uint)handle, &kind, &cookie) == 0 || (ObjKind)kind != ObjKind.Session)
            {
                return KernelResult.InvalidHandle;
            }

            SessionTarget t = d.GetSession(cookie);
            return t != null ? new Result((int)t.Process(d, msg, 0x100)) : KernelResult.InvalidHandle;
        }

        // 服务端建会话（CMIF 递出子对象、会话克隆）：服务端是内部记号，客户端是游戏会话句柄
        public Result CreateSession(out int serverSessionHandle, out int clientSessionHandle, bool isLight, string name)
            => HorizonHost.CreateSession(out serverSessionHandle, out clientSessionHandle);

        public Result AcceptSession(out int sessionHandle, int portHandle)
            => HorizonHost.AcceptSession(out sessionHandle, portHandle);

        public Result CreateEvent(out int writableHandle, out int readableHandle)
        {
            uint r, w;
            ulong ev = Native.EventCreate(&r, &w);

            // 服务只经句柄用事件，不另持事件号：立即 release（接口 v2.4），两端句柄都关了事件才释放
            if (ev != 0)
            {
                Native.EventRelease(ev);
            }

            readableHandle = (int)r;
            writableHandle = (int)w;

            if (Dispatcher.TraceIpc)
            {
                Console.Error.WriteLine($"[IPC] Horizon 建事件 读 0x{r:X} 写 0x{w:X}（线程 {Environment.CurrentManagedThreadId}）");
            }
            return r != 0 && w != 0 ? Result.Success : KernelResult.HandleTableFull;
        }

        public Result SignalEvent(int handle) => EventOp(handle, signal: true);
        public Result ClearEvent(int handle) => EventOp(handle, signal: false);
        public Result ResetSignal(int handle) => EventOp(handle, signal: false);

        private static Result EventOp(int handle, bool signal)
        {
            if (!Resolve(handle, out _, out ObjKind kind, out ulong ev) || (kind != ObjKind.EventW && kind != ObjKind.EventR))
            {
                return KernelResult.InvalidHandle;
            }

            if (signal)
            {
                Native.EventSignal(ev);
            }
            else
            {
                Native.EventClear(ev);
            }

            return Result.Success;
        }

        public Result CreatePort(out int serverPortHandle, out int clientPortHandle, int maxSessions, bool isLight, string name)
        {
            Red.Report("Horizon 服务建私有端口（S2Arm 未支持）", name);
            serverPortHandle = clientPortHandle = 0;
            return KernelResult.OutOfResource;
        }

        public Result ManageNamedPort(out int handle, string name, int maxSessions)
        {
            Red.Report("Horizon 服务管命名端口（S2Arm 未支持）", name);
            handle = 0;
            return KernelResult.OutOfResource;
        }

        public Result ConnectToPort(out int clientSessionHandle, int clientPortHandle)
        {
            Red.Report("Horizon 服务连私有端口（S2Arm 未支持）");
            clientSessionHandle = 0;
            return KernelResult.NotFound;
        }

        public IExternalEvent GetExternalEvent(int handle)
        {
            if (!Resolve(handle, out _, out ObjKind kind, out ulong ev) || (kind != ObjKind.EventW && kind != ObjKind.EventR))
            {
                Red.Report("GetExternalEvent 的句柄不是原生事件", $"0x{handle:X}");
                return null;
            }

            return new NativeExternalEvent(ev);
        }

        public IVirtualMemoryManager GetMemoryManagerByProcessHandle(int handle)
        {
            if (Resolve(handle, out _, out ObjKind kind, out _) && kind == ObjKind.Process)
            {
                return _memory;
            }

            Red.Report("GetMemoryManagerByProcessHandle 的句柄不是游戏进程", $"0x{handle:X}");
            return null;
        }

        public ulong GetTransferMemoryAddress(int handle)
        {
            ulong addr, size;
            uint perm;

            if (Resolve(handle, out uint native, out ObjKind kind, out _) && kind == ObjKind.Tmem && Native.TmemGet(native, &addr, &size, &perm) != 0)
            {
                return addr;
            }

            Red.Report("GetTransferMemoryAddress 的句柄不是传输内存", $"0x{handle:X}");
            return 0;
        }
    }

    sealed class NativeExternalEvent : IExternalEvent
    {
        private readonly ulong _ev;

        public NativeExternalEvent(ulong ev)
        {
            _ev = ev;
        }

        public unsafe void Signal() => Native.EventSignal(_ev);

        public unsafe void Clear() => Native.EventClear(_ev);
    }

    // Horizon 服务线程的线程上下文：TLS（服务自己发请求用的消息缓冲）+ 线程记号（x1，CancelSynchronization 用）
    sealed unsafe class S2AThreadContext : IThreadContext, IDisposable
    {
        [ThreadStatic] private static ulong t_tls;

        public static ulong CurrentTls => t_tls;

        private readonly int _threadToken;

        public S2AThreadContext(int threadToken)
        {
            _threadToken = threadToken;
            TlsAddress = (ulong)NativeMemory.AlignedAlloc(0x200, 0x200);
            new Span<byte>((void*)TlsAddress, 0x200).Clear();
        }

        // 由线程自己调：登记本线程 TLS
        public void Bind() => t_tls = TlsAddress;

        public bool Running => true;

        public ulong TlsAddress { get; }

        public ulong GetX(int index) => index == 1 ? (ulong)(uint)_threadToken : 0;

        public void Dispose()
        {
            t_tls = 0;
            NativeMemory.AlignedFree((void*)TlsAddress);
        }
    }
}
