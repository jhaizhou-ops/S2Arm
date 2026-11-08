using Ryujinx.Horizon;
using Ryujinx.Horizon.Common;
using Ryujinx.Horizon.Sdk.Sf.Cmif;
using Ryujinx.Horizon.Sdk.Sf.Hipc;
using System;
using System.Collections.Generic;
using System.Runtime.ExceptionServices;
using System.Runtime.InteropServices;
using System.Threading;

namespace S2A.Services
{
    // Ryujinx.Horizon 新框架服务（audren / audout / hwopus / ngc / lm …）的承载。
    // 服务照上游自己的入口初始化（建管理器、向 sm 注册端口），只是跑在我方线程上、内核换成 NativeSyscall；
    // 注册成功经挂钩登记到这里，游戏 GetService 时在游戏线程上就地受理会话、处理请求（服务线程的主循环只挂起，不处理任何请求）。
    // 不按服务名写任何分支：上游有多少 Horizon 服务就接多少。
    static unsafe class HorizonHost
    {
        private static readonly ManualResetEventSlim _ready = new(false);
        private static CancellationTokenSource _startupCancellation = new();
        private static ExceptionDispatchInfo _failure;
        private static Action<Exception> _failureHandler;
        private static readonly object _lock = new();
        private static readonly Dictionary<int, string> _portNames = new();                                       // 端口记号 → 服务名（sm RegisterService 时发）
        private static readonly Dictionary<string, (ServerManagerBase Manager, Server Server)> _ports = new();    // 服务名 → 管理器 / 端口
        private static readonly Dictionary<int, (ServerManagerBase Manager, ServerSession Session)> _sessions = new(); // 服务端会话记号 → 会话

        [ThreadStatic] private static int t_pendingAccept;
        [ThreadStatic] internal static ServerManagerBase t_manager;

        internal static NativeSyscall Syscall { get; private set; }
        internal static HorizonOptions Options { get; private set; }
        private static bool _haveOptions;
        public static int Started;
        private static HorizonAudioLifetime AudioLifetime = new();
        internal static void DisposeAudio() => AudioLifetime.Dispose();
        private static readonly List<Thread> _threads = new();
        private static bool _stopping;
        private static int _generation;

        // Shutdown wakers live for the process, so never capture a retired CTS.
        static HorizonHost() => Ryujinx.Common.S2AShutdown.OnRequest(CancelStartup);

        private static void CancelStartup()
        {
            lock (_lock)
                if (_failureHandler != null) _startupCancellation.Cancel();
        }

        internal static void InstallHooks(GuestMemory memory)
        {
            if (_threads.Count != 0) throw new InvalidOperationException("上一局 Horizon 服务线程尚未回收");
            _ready.Reset();
            _stopping = false;
            _generation++;
            _failure = null;
            NativeSyscall.Reset();
            Syscall = new NativeSyscall(memory);
            Ryujinx.HLE.S2AHooks.StartHorizonService = &Start;
            S2AHorizonHooks.PortRegistered = OnPortRegistered;
            S2AHorizonHooks.SessionRegistered = OnSessionRegistered;
        }

        // 分发器就绪后才让服务线程跑入口（服务初始化要连 sm）
        internal static void Ready() => _ready.Set();

        // Android's single process/session owner installs this before Host.Boot
        // starts any service threads. The legacy host leaves it unset.
        internal static void ObserveFailures(Action<Exception> handler)
        {
            ArgumentNullException.ThrowIfNull(handler);
            if (Interlocked.CompareExchange(ref _failureHandler, handler, null) != null)
                throw new InvalidOperationException("Horizon failure owner is already installed");
            S2AHorizonHooks.AudioCreated = AudioLifetime.Register;
            if (Ryujinx.Common.S2AShutdown.Requested) CancelStartup();
        }

        internal static void WaitServicesReady(ServiceTable table, TimeSpan timeout)
        {
            if (_failureHandler == null)
                throw new InvalidOperationException("Checked Horizon startup requires a failure owner");
            try
            {
                table.WaitServicesReady(timeout, _startupCancellation.Token);
                Volatile.Read(ref _failure)?.Throw();
                _startupCancellation.Token.ThrowIfCancellationRequested();
            }
            catch (OperationCanceledException)
            {
                // A failed service cancels the waiter. Preserve the original
                // exception/stack instead of turning it into generic cancellation.
                Volatile.Read(ref _failure)?.Throw();
                throw;
            }
        }

        internal static void Stop() => Stop(rethrowFailure: true);

        internal static void Stop(bool rethrowFailure, Action joined = null)
        {
            Thread[] threads;
            // RequestStopProcessing → Os.SignalEvent → MultiWaitImpl.NotifyAndWakeUpThread 取 HorizonStatic.Syscall（线程局部，只在服务线程入口登记过）：
            //   收局跑在自动玩家线程 / dispatch 队列 / iOS 终止回调上，没登记就是空引用，收局崩（10-29 IML 档八方2 Mac 局）。
            //   绑定本代对象；同一宿主线程若曾绑定旧代，不能继续使用那个旧内核。
            if (Syscall != null && !ReferenceEquals(HorizonStatic.Syscall, Syscall))
            {
                Ryujinx.Horizon.HorizonStatic.Register(Options, Syscall, Dispatcher.Instance?.Memory, null, 0);
            }
            lock (_lock)
            {
                _stopping = true;
                foreach (var port in _ports.Values) port.Manager.RequestStopProcessing();
                threads = _threads.ToArray();
            }
            if (_failureHandler != null) _startupCancellation.Cancel();
            NativeSyscall.Shutdown();
            _ready.Set();
            long until = Environment.TickCount64 + 10_000;
            foreach (Thread thread in threads)
                if (!thread.Join((int)Math.Max(0, until - Environment.TickCount64)))
                    throw new TimeoutException($"Horizon 服务线程 {thread.Name} 关停超过 10 秒，禁止释放服务资源");
            joined?.Invoke();
            if (rethrowFailure && Volatile.Read(ref _failure) is ExceptionDispatchInfo failure)
                throw new InvalidOperationException("Horizon 服务线程退出时发生异常", failure.SourceException);
        }

        public static string[] Services
        {
            get { lock (_lock) { return [.. _ports.Keys]; } }
        }

        internal static void Reset()
        {
            lock (_lock)
            {
                if (_threads.Exists(t => t.IsAlive)) throw new InvalidOperationException("Horizon 服务线程仍在运行");
                AudioLifetime.Dispose();
                _threads.Clear();
                _ports.Clear();
                _portNames.Clear();
                _sessions.Clear();
                Started = 0;
                Options = default;
                _haveOptions = false;
                Syscall = null;
                _ready.Reset();
                _failureHandler = null;
                _failure = null;
                _startupCancellation.Dispose();
                _startupCancellation = new();
                AudioLifetime = new();
            }
            S2AHorizonHooks.PortRegistered = null;
            S2AHorizonHooks.SessionRegistered = null;
            S2AHorizonHooks.AudioCreated = null;
            NativeSyscall.Reset();
            ResetThread();
        }

        internal static void ResetThread()
        {
            t_pendingAccept = 0;
            t_manager = null;
            t_ctx = null;
            HorizonStatic.Register(default, null, null, null, 0);
        }

        private static void Start(ServiceEntry entry)
        {
            Interlocked.Increment(ref Started);
            int token = NativeSyscall.NewToken();
            // Reset cannot replace these until this generation's real threads
            // (including their failure notifications/finally blocks) are joined.
            Action<Exception> handler = _failureHandler;
            CancellationTokenSource cancellation = _startupCancellation;
            NativeSyscall syscall = Syscall;

            Thread t = new(() =>
            {
                bool entered = false;
                try
                {
                    if (handler == null) _ready.Wait();
                    else _ready.Wait(cancellation.Token);
                    NativeSyscall.RegisterServiceThread(token);
                    using S2AThreadContext ctx = new(token);
                    ctx.Bind();
                    entered = true;
                    entry.Start(syscall, Dispatcher.Instance.Memory, ctx);
                }
                catch (OperationCanceledException) when (handler != null && cancellation.IsCancellationRequested)
                {
                    // The owning failure/stop already revokes this session.
                }
                catch (Exception e) when (handler != null || entered)
                {
                    ThreadFailure(entry.Name, e, handler, cancellation);
                }
                finally
                {
                    try { NativeSyscall.UnregisterServiceThread(token); }
                    catch (Exception cleanup) when (handler != null || entered)
                    {
                        ThreadFailure(entry.Name, cleanup, handler, cancellation);
                    }
                }
            })
            {
                Name = $"{{{entry.Name}}}",
                IsBackground = true,
            };

            lock (_lock)
            {
                if (_stopping) throw new InvalidOperationException("Horizon 正在关停，不能启动新服务");
                _threads.Add(t);
                t.Start();
            }
        }

        private static void ThreadFailure(string service, Exception error, Action<Exception> handler, CancellationTokenSource cancellation)
        {
            if (Interlocked.CompareExchange(ref _failure, ExceptionDispatchInfo.Capture(error), null) == null && handler != null)
            {
                try { cancellation.Cancel(); }
                catch (Exception cleanup) { Red.Report($"Horizon 服务 {service} 取消异常（原异常已保留）", cleanup.ToString(), allowFailFast: false); }
                try { handler(error); }
                catch (Exception notification) { Red.Report($"Horizon 服务 {service} 失败通知异常（原异常已保留）", notification.ToString(), allowFailFast: false); }
            }
            if (handler == null) Red.Report($"Horizon 服务 {service} 入口/清理异常", error.ToString());
        }

        // ---------- sm（服务线程上） ----------

        internal static int NewPort(string name)
        {
            int token = NativeSyscall.NewToken();

            lock (_lock)
            {
                _portNames[token] = name;
            }

            CaptureOptions();
            return token;
        }

        // 游戏线程直调要用上游给服务的同一份 HorizonOptions（服务线程上 HorizonStatic.Options 有值）
        private static void CaptureOptions()
        {
            if (!_haveOptions)
            {
                Options = HorizonStatic.Options;
                _haveOptions = true;
            }
        }

        private static void OnPortRegistered(ServerManagerBase manager, Server server)
        {
            string name;

            lock (_lock)
            {
                if (!_portNames.TryGetValue(server.PortHandle, out name))
                {
                    name = server.Name.ToString();
                }

                _ports[name] = (manager, server);
                if (_stopping) manager.RequestStopProcessing();
            }

            Dispatcher.Instance.Sm.Horizon[name] = () => Open(name);
        }

        private static void OnSessionRegistered(ServerManagerBase manager, ServerSession session)
        {
            lock (_lock)
            {
                _sessions[session.SessionHandle] = (manager, session);
            }
        }

        // ---------- 会话 ----------

        // 游戏 GetService(name)：在本线程上让该服务的管理器受理一个会话（与服务主循环里「端口有连接」同一路径）
        private static SessionTarget Open(string name)
        {
            ServerManagerBase manager;
            Server server;

            lock (_lock)
            {
                (manager, server) = _ports[name];
            }

            int token = NativeSyscall.NewToken();
            Result r;

            lock (manager)
            {
                EnterHorizonThread();
                t_pendingAccept = token;
                r = manager.S2AProcessForServer(server);
                t_pendingAccept = 0;
            }

            lock (_lock)
            {
                if (r.IsFailure || !_sessions.ContainsKey(token))
                {
                    Red.Report($"Horizon 服务 {name} 受理会话失败", r.ToString());
                    return null;
                }
            }

            return new HorizonTarget(name, manager, token);
        }

        internal static Result AcceptSession(out int sessionHandle, int portHandle)
        {
            sessionHandle = t_pendingAccept;

            if (sessionHandle == 0)
            {
                Red.Report("Horizon 服务在无待受理连接时 AcceptSession");
                return KernelResult.NotFound;
            }

            return Result.Success;
        }

        // 服务递出子对象 / 克隆会话：同一管理器下新会话；游戏拿到客户端会话句柄
        internal static Result CreateSession(out int serverSessionHandle, out int clientSessionHandle)
        {
            ServerManagerBase manager = t_manager;
            serverSessionHandle = clientSessionHandle = 0;

            if (manager == null)
            {
                Red.Report("Horizon 服务在请求处理之外建会话（S2Arm 未支持）");
                return KernelResult.OutOfResource;
            }

            int token = NativeSyscall.NewToken();
            uint h = Dispatcher.Instance.NewSessionHandle(new HorizonTarget("子对象", manager, token));

            if (h == 0)
            {
                return KernelResult.HandleTableFull;
            }

            serverSessionHandle = token;
            clientSessionHandle = (int)h;
            return Result.Success;
        }

        internal static ServerSession LookupSession(int token)
        {
            lock (_lock)
            {
                return _sessions.TryGetValue(token, out (ServerManagerBase, ServerSession Session) e) ? e.Session : null;
            }
        }

        internal static void ForgetSession(int token)
        {
            lock (_lock)
            {
                _sessions.Remove(token);
            }
        }

        // 游戏线程第一次进 Horizon 服务代码：登记 HorizonStatic（服务代码经它取内核与内存）。
        // 线程上下文的 TLS 每次请求指到该请求的消息缓冲：上游应答路径（Api.Reply）要求「消息缓冲 = 本线程 TLS」
        [ThreadStatic] private static GameThreadContext t_ctx;
        [ThreadStatic] private static int t_generation;

        internal static void EnterHorizonThread(ulong message = 0)
        {
            // Nested client/session cleanup also runs on real Horizon service
            // threads. Keep their owned TLS and cancellation thread handle.
            if (HorizonStatic.ThreadContext is S2AThreadContext service && ReferenceEquals(HorizonStatic.Syscall, Syscall))
            {
                if (message != 0 && message != service.TlsAddress)
                    throw new InvalidOperationException("Horizon 服务请求缓冲不是本线程 TLS");
                return;
            }
            if (t_ctx == null || t_generation != _generation)
            {
                t_generation = _generation;
                t_ctx = new GameThreadContext();
                HorizonStatic.Register(Options, Syscall, Dispatcher.Instance.Memory, t_ctx, 0);
            }

            if (message != 0)
            {
                t_ctx.TlsAddress = message;
            }
        }

        private sealed class GameThreadContext : IThreadContext
        {
            public bool Running => true;
            public ulong TlsAddress { get; set; }
            public ulong GetX(int index) => 0;
        }
    }

    // 一个 Horizon 服务会话（游戏侧句柄背后）：请求在游戏线程上经该服务管理器的 ProcessRequest 处理，消息原地读写
    sealed class HorizonTarget : SessionTarget
    {
        private readonly string _name;
        private readonly ServerManagerBase _manager;
        private readonly int _token;

        public HorizonTarget(string name, ServerManagerBase manager, int token)
        {
            _name = name;
            _manager = manager;
            _token = token;
        }

        // 子对象会话建时服务对象还没挂上（服务端 ProcessRequest 之后才登记）：名字在第一次取时按服务对象类型补全并缓存
        // （「子对象 HardwareOpusDecoder」），拆账 / 报红才分得清是哪个接口；取一次，之后零分配
        private string _resolved;

        public override string Name => _resolved ?? Resolve();

        private string Resolve()
        {
            if (_name != "子对象")
            {
                return _resolved = _name;
            }

            object obj = HorizonHost.LookupSession(_token)?.ServiceObjectHolder?.ServiceObject;

            // 服务对象还没挂上：先答通称，不缓存
            return obj == null ? _name : _resolved = $"子对象 {obj.GetType().Name}";
        }

        // 域会话：拆账细到域里被调的那个对象（「子对象 Domain→AudioOut」）；名字按（会话名, 对象类型）缓存，只拼一次
        private static readonly Dictionary<(string, Type), string> _domainNames = new();

        public override unsafe string TraceName(byte* msg, int size)
        {
            if (HorizonHost.LookupSession(_token)?.ServiceObjectHolder?.ServiceObject is not DomainServiceObject domain)
            {
                return Name;
            }

            int id = Dispatcher.DomainObjectId(msg, size);
            object obj = id != 0 ? domain.GetObject(id)?.ServiceObject : null;

            if (obj == null)
            {
                return Name;
            }

            lock (_domainNames)
            {
                if (!_domainNames.TryGetValue((Name, obj.GetType()), out string n))
                {
                    _domainNames[(Name, obj.GetType())] = n = $"{Name}→{obj.GetType().Name}";
                }

                return n;
            }
        }

        public override unsafe uint Process(Dispatcher d, byte* msg, int size)
        {
            ServerSession session = HorizonHost.LookupSession(_token);

            if (session == null)
            {
                Red.Report($"Horizon 会话不存在（{_name}）");
                return Dispatcher.KernelInvalidHandle;
            }

            CopyHandlesIn(msg);
            Span<byte> message = new(msg, 0x100);

            // 游戏给的接收列表（C 缓冲）：应答前记下（处理后消息缓冲已是应答）
            Span<ulong> receiveList = stackalloc ulong[16];
            int receiveType = (int)((((uint*)msg)[1] >> 10) & 0xF);
            int receiveCount = 0;

            if (receiveType >= 2)
            {
                Span<ulong> rl = MemoryMarshal.Cast<HipcReceiveListEntry, ulong>(new HipcMessage(message).Data.ReceiveList);
                receiveCount = Math.Min(rl.Length, receiveList.Length);
                rl[..receiveCount].CopyTo(receiveList);
            }

            lock (_manager)
            {
                HorizonHost.EnterHorizonThread((ulong)msg);
                ServerManagerBase prev = HorizonHost.t_manager;
                HorizonHost.t_manager = _manager;

                try
                {
                    Result r = _manager.ProcessRequest(session, message);

                    if (r.IsSuccess)
                    {
                        // 指针缓冲放不进游戏的接收区 / 复制句柄翻译失败 = 这次应答送不到游戏：回内核结果（审计 #1534 P1-81 / P1-52）。
                        //   指针缓冲先拷（不新发句柄），失败时只需关服务已移交出的 move 句柄
                        uint replyResult = CopyPointerBuffersOut(d, msg, message, receiveType, receiveList[..receiveCount]);

                        if (replyResult == 0)
                        {
                            replyResult = CopyHandlesOut(msg);
                        }

                        if (replyResult != 0)
                        {
                            CloseMovedHandles(msg);
                            return replyResult;
                        }
                    }
                    else
                    {
                        // 延后应答（服务要等某事件后再答）：直调下不支持，报红
                        Red.Report($"Horizon 服务 {_name} 要求延后应答（S2Arm 未支持）", r.ToString());
                        WriteCmifError(message, (uint)r.ErrorCode);
                    }
                }
                catch (NotImplementedException e)
                {
                    // 上游 ThrowOnInvalidCommandIds：「对象名 command ID: N is not implemented」
                    Red.Report($"未实现服务命令 {e.Message}");
                    WriteCmifError(message, Red.ResultUnknownCommand);
                }
                finally
                {
                    HorizonHost.t_manager = prev;
                }
            }

            return 0;
        }

        // 应答里的指针缓冲（X 描述符，数据在服务端会话的指针缓冲里）：真机由内核按游戏的接收列表拷过去并把描述符地址改成游戏那块缓冲
        // （同 Ryujinx KServerSession.Reply / GetReceiveListAddress）。直调没有内核，原先不拷——游戏从 C 缓冲读到的是旧内容
        // （巫师3 GetReleasedAudioOutBuffersAuto 回了计数却读不到缓冲标签，不再追加声音缓冲，空转后崩）。
        // 放不下 / 没给接收列表时上游回 OutOfResource 给客户端（游戏的 SendSyncRequest），不回成功（审计 #1534 P1-81）
        private const uint KernelOutOfResource = 0xCE01;   // 模块 1、描述 103

        private unsafe uint CopyPointerBuffersOut(Dispatcher d, byte* msg, Span<byte> message, int receiveType, ReadOnlySpan<ulong> receiveList)
        {
            HipcMessage response = new(message);
            Span<ulong> statics = MemoryMarshal.Cast<HipcStaticDescriptor, ulong>(response.Data.SendStatics);
            uint dstOffset = 0;

            for (int i = 0; i < statics.Length; i++)
            {
                ulong desc = statics[i];
                ulong src = ((((desc >> 2) & 0x70) | ((desc >> 12) & 0xf)) << 32) | (desc >> 32);
                uint size = (uint)(desc >> 16) & 0xffff;
                int index = (int)(desc & 0xf);
                ulong dst = 0;

                if (size != 0)
                {
                    if (receiveType == 1 || receiveType == 2)
                    {
                        // 1 = 接收区紧跟在应答消息之后（消息缓冲余下部分）；2 = 一块接收缓冲。各段依次放、按 0x10 对齐
                        ulong baseAddr, end;

                        if (receiveType == 1)
                        {
                            baseAddr = (ulong)msg + ResponseWords((uint*)msg) * 4;
                            end = (ulong)msg + (ulong)message.Length;
                        }
                        else
                        {
                            baseAddr = receiveList[0] & 0x7fffffffff;
                            end = baseAddr + (receiveList[0] >> 48);
                        }

                        dst = (baseAddr + dstOffset + 0xf) & ~0xfUL;
                        dstOffset = (uint)(dst + size - baseAddr);

                        if (end == baseAddr || dst + size <= dst || dst + size > end)
                        {
                            Red.Report($"Horizon 应答指针缓冲放不进游戏的接收缓冲（{_name}），应答回 OutOfResource", $"接收列表类型 {receiveType}、需 {size} 字节");
                            return KernelOutOfResource;
                        }
                    }
                    else if (receiveType > 2 && index < receiveList.Length)
                    {
                        dst = receiveList[index] & 0x7fffffffff;
                        ulong cap = receiveList[index] >> 48;

                        if (dst == 0 || cap == 0 || cap < size)
                        {
                            Red.Report($"Horizon 应答指针缓冲放不进游戏的接收缓冲（{_name}），应答回 OutOfResource", $"第 {index} 块 {cap} 字节、需 {size}");
                            return KernelOutOfResource;
                        }
                    }
                    else
                    {
                        Red.Report($"Horizon 应答带指针缓冲，游戏没给接收列表（{_name}），应答回 OutOfResource", $"接收列表类型 {receiveType}、序号 {index}");
                        return KernelOutOfResource;
                    }

                    d.Memory.Write(dst, new ReadOnlySpan<byte>((void*)src, (int)size));
                }

                statics[i] = (dst << 32) | ((dst >> 20) & 0xf000) | ((dst >> 30) & 0xffc0) | (desc & 0xffff000f);
            }

            return 0;
        }

        // HIPC 消息总字数（同上游 MessageHeader.MessageSizeInWords）：头 2 字 + 特殊头 / 进程号 / 句柄 + X 各 2 字 + A / B / W 各 3 字 + 原始数据
        private static unsafe uint ResponseWords(uint* w)
        {
            uint words = 2 + ((w[0] >> 16) & 0xF) * 2 + (((w[0] >> 20) & 0xF) + ((w[0] >> 24) & 0xF) + ((w[0] >> 28) & 0xF)) * 3 + (w[1] & 0x3FF);

            if ((w[1] >> 31) != 0)
            {
                words += 1 + ((w[2] & 1) != 0 ? 2u : 0) + ((w[2] >> 1) & 0xF) + ((w[2] >> 5) & 0xF);
            }

            return words;
        }

        // 应答送不到游戏时，服务已移交出来的句柄（Horizon 服务经 NativeSyscall 建的原生句柄：子会话客户端、事件）没人接：
        //   同上游 KServerSession.Reply 失败清理（CloseAllHandles），关掉，子会话随之关闭
        private static unsafe void CloseMovedHandles(byte* msg)
        {
            uint* w = (uint*)msg;

            if ((w[1] >> 31) == 0)
            {
                return;
            }

            uint special = w[2];
            int copies = (int)((special >> 1) & 0xF), moves = (int)((special >> 5) & 0xF);
            int at = 3 + ((special & 1) != 0 ? 2 : 0) + copies;

            for (int i = 0; i < moves; i++)
            {
                uint h = w[at + i];

                if (h != 0 && !NativeSyscall.IsToken((int)h))
                {
                    Native.HandleClose(h);
                }
            }
        }

        // 游戏消息里的复制句柄换成记号（见 NativeSyscall.CopyIn）
        private static unsafe void CopyHandlesIn(byte* msg)
        {
            uint* w = (uint*)msg;

            if ((w[1] >> 31) == 0)
            {
                return;
            }

            uint special = w[2];
            int copies = (int)((special >> 1) & 0xF);
            int at = 3 + ((special & 1) != 0 ? 2 : 0);

            for (int i = 0; i < copies; i++)
            {
                w[at + i] = (uint)NativeSyscall.CopyIn(w[at + i]);
            }
        }

        // 应答里的复制句柄：内核给游戏发新句柄，服务手里那份不变（服务之后关自己的，游戏关它的，互不影响）。
        // 直调没有内核：事件给游戏另发一个读端；其余种类未支持。返回内核结果（审计 #1534 P1-52，同 Dispatcher.TranslateResponseHandles）：
        //   未支持的种类回 InvalidHandle、发不出读端回 HandleTableFull，本次已发的读端收回，消息里的复制句柄不改
        private unsafe uint CopyHandlesOut(byte* msg)
        {
            uint* w = (uint*)msg;

            if ((w[1] >> 31) == 0)
            {
                return 0;
            }

            uint special = w[2];
            int copies = (int)((special >> 1) & 0xF);
            int at = 3 + ((special & 1) != 0 ? 2 : 0);
            Span<uint> dup = stackalloc uint[copies];

            for (int i = 0; i < copies; i++)
            {
                uint h = w[at + i];
                dup[i] = h;

                if (h == 0 || h == 0xFFFF8001)
                {
                    continue;
                }

                uint result = 0;

                if (NativeSyscall.ResolveForCopy((int)h, out ObjKind kind, out ulong cookie) && kind is ObjKind.EventR or ObjKind.EventW)
                {
                    dup[i] = Native.EventDupRead(cookie);

                    if (dup[i] == 0)
                    {
                        Red.Report($"Horizon 服务 {_name} 应答复制事件：给游戏发读端失败（原生句柄表满）", $"0x{h:X}");
                        result = Dispatcher.KernelHandleTableFull;
                    }
                }
                else
                {
                    Red.Report($"Horizon 服务 {_name} 应答复制句柄（种类 {kind}）S2Arm 未支持，应答翻译失败", $"0x{h:X}");
                    result = Dispatcher.KernelInvalidHandle;
                }

                if (result != 0)
                {
                    for (int j = 0; j < i; j++)
                    {
                        if (dup[j] != w[at + j])
                        {
                            Native.HandleClose(dup[j]);
                        }
                    }

                    return result;
                }
            }

            for (int i = 0; i < copies; i++)
            {
                w[at + i] = dup[i];
            }

            return 0;
        }

        // CMIF 错误应答（与上游 PrepareForStubReply 同格式）
        private static void WriteCmifError(Span<byte> message, uint result)
        {
            HipcMessageData response = HipcMessage.WriteResponse(message, 0, 0x20 / sizeof(uint), 0, 0);
            Span<byte> raw = MemoryMarshal.Cast<uint, byte>(response.DataWords);
            Span<CmifOutHeader> header = Span<CmifOutHeader>.Empty;
            Ryujinx.Horizon.Sdk.Sf.CommandHandler.GetCmifOutHeaderPointer(ref header, ref raw);
            header[0] = new CmifOutHeader { Magic = CmifMessage.CmifOutHeaderMagic, Result = new Result((int)result) };
        }

        public override void Closed()
        {
            ServerSession session = HorizonHost.LookupSession(_token);

            if (session == null)
            {
                return;
            }

            lock (_manager)
            {
                HorizonHost.EnterHorizonThread();
                // 上游 ProcessRequest 对已关闭会话走 CloseSessionImpl（释放服务端会话与其对象）
                session.IsClosed = true;
                Span<byte> dummy = stackalloc byte[0x10];
                _manager.ProcessRequest(session, dummy);
            }

            HorizonHost.ForgetSession(_token);
        }
    }
}
