using Microsoft.IO;
using Ryujinx.Common;
using Ryujinx.Common.Memory;
using Ryujinx.HLE.Exceptions;
using Ryujinx.HLE.HOS;
using Ryujinx.HLE.HOS.Ipc;
using Ryujinx.HLE.HOS.Services;
using System;
using System.Buffers;
using System.Buffers.Binary;
using System.IO;

namespace S2A.Services
{
    // Ryujinx 旧 HLE 框架服务（IpcService）的会话：Ryujinx ServerBase.Process 的同线程直调版。
    // 与上游的差别只有三处，都是「没有内核在中间」带来的：
    //   1. 消息原地读写游戏内存（游戏地址 = 宿主地址），服务看到的缓冲地址就是游戏地址；
    //   2. C 缓冲（接收列表）不换成服务进程的临时堆再由内核拷回，服务直接写进游戏给的缓冲；
    //   3. 句柄由 Dispatcher 翻译（游戏句柄 ↔ 影子句柄表）。
    // 同一个 Ryujinx 服务端（ServerBase）上的请求按上游语义串行：上游每个 ServerBase 只有一个服务线程。
    // 例外：bsd（套接字）不串行。Horizon 的 bsd 有多个工作线程，select / poll 会阻塞到超时；串行时一个阻塞的 select
    // 会挡住唤醒它的那次写入（同一 eventfd 的 Write）。bsd 的状态自带锁（BsdContext、EventFileDescriptor、宿主套接字）。
    // 没有自己服务端的服务共用一把通用锁；其中会等宿主网络的两个（sfdnsres 解析、ssl 握手 / 收发——Horizon 上各是独立的系统模块）
    // 各用自己的锁：联网时一次慢解析 / 握手只挡同模块的请求，不挡通用锁上的 am / acc / nifm 等（否则所有游戏线程跟着停帧）。
    sealed class HleTarget : SessionTarget
    {
        private static readonly object _commonLock = new();
        private static readonly object _sfdnsresLock = new();
        private static readonly object _sslLock = new();

        public readonly IpcService Service;
        private readonly object _lock;
        private sealed class ServiceOwner
        {
            public readonly IpcService Service;
            public int References = 1;
            public ServiceOwner(IpcService service) => Service = service;
        }
        private readonly ServiceOwner _owner;
        private bool _closed; // guarded by _owner; every wrapper owns exactly one reference

        private readonly string _name;

        public HleTarget(IpcService service) : this(new ServiceOwner(service)) { }

        private HleTarget(ServiceOwner owner)
        {
            _owner = owner;
            IpcService service = owner.Service;
            Service = service;
            _name = service.GetType().Name;   // 取一次：每次请求都取类型名在 NativeAOT 下会新建字符串
            // fs 的数据存储（IStorage：RomFS / 系统数据，只读）每个会话各自串行，不排在 fs 服务端那把锁后面——真 Switch 的 fs 多线程并发服务；
            //   原先所有 fs 请求共用一把锁，一次阻塞的 pread 让整个游戏卡住（10-26 动森 Mac 满载 90 秒黑屏）。存档等其余 fs 对象照旧走服务端锁
            _lock = service is Ryujinx.HLE.HOS.Services.Sockets.Bsd.IClient ? null
                : service is Ryujinx.HLE.HOS.Services.Fs.FileSystemProxy.IStorage ? new object()
                : (object)service.Server ?? NetworkModuleLock(service) ?? _commonLock;
        }

        private static object NetworkModuleLock(IpcService service)
        {
            string ns = service.GetType().Namespace ?? string.Empty;

            return ns.StartsWith("Ryujinx.HLE.HOS.Services.Sockets.Sfdnsres", StringComparison.Ordinal) ? _sfdnsresLock
                : ns.StartsWith("Ryujinx.HLE.HOS.Services.Ssl", StringComparison.Ordinal) ? _sslLock
                : null;
        }

        // 单测用：两个会话是否在同一串行域
        internal bool SharesLockWith(HleTarget other) => _lock != null && ReferenceEquals(_lock, other._lock);

        public override string Name => _name;

        private HleTarget(HleTarget original)
        {
            _owner = original._owner;
            Service = original.Service;
            _name = original._name;
            _lock = original._lock;
        }

        public override SessionTarget Clone()
        {
            lock (_owner)
            {
                ObjectDisposedException.ThrowIf(_closed, this);
                HleTarget clone = new(this);
                _owner.References++;
                return clone;
            }
        }

        public override void Closed()
        {
            lock (_owner)
            {
                if (_closed) return;
                _closed = true;
            }
            ReleaseOwner();
        }

        private void ReleaseOwner()
        {
            lock (_owner)
            {
                if (--_owner.References != 0) return;
            }

            // Sessions and in-flight requests share the owner. The final
            // reference destroys the domain only after all requests finish.
            try { Service.DestroyAtExit(); }
            finally { (Service as IDisposable)?.Dispose(); }
        }

        public override unsafe uint Process(Dispatcher d, byte* msg, int size)
        {
            lock (_owner)
            {
                if (_closed) return Dispatcher.KernelInvalidHandle;
                checked { _owner.References++; }
            }
            try { return ProcessRetained(d, msg, size); }
            finally { ReleaseOwner(); }
        }

        private unsafe uint ProcessRetained(Dispatcher d, byte* msg, int size)
        {
            // 每个游戏线程复用一套请求 / 应答 / 上下文 / 数据流：稳态零分配（方案 §3-4）
            Dispatcher.Streams s = Dispatcher.ThreadStreams;
            IpcMessage request = s.Request;
            IpcMessage response = s.Response;
            Span<byte> buffer = new(msg, size);

            request.S2AParse(buffer[..Math.Min(size, 0x100)], (long)msg);
            response.S2AReset();

            // 应答的 X 描述符：每个客户端 C 缓冲一条（同 Ryujinx ServerBase），服务用它回告写了多少字节（PtrBuff[i].WithSize）。
            // 直调时地址就是游戏给的 C 缓冲，服务直接写进去，不经临时堆
            bool noReceive = true;

            for (int i = 0; i < request.ReceiveBuff.Count; i++)
            {
                noReceive &= request.ReceiveBuff[i].Position == 0;
            }

            for (int i = 0; noReceive && i < request.RecvListBuff.Count; i++)
            {
                response.PtrBuff.Add(new IpcPtrBuffDesc(request.RecvListBuff[i].Position, (uint)i, request.RecvListBuff[i].Size));
            }

            uint handleResult = d.TranslateRequestHandles(request.HandleDesc);
            if (handleResult != 0) return handleResult;

            s.Req.SetLength(0);
            s.Req.Write(buffer.Slice(request.S2ARawOffset, request.S2ARawSize));
            s.Req.Position = 0;
            s.Resp.SetLength(0);

            bool tipc = false;
            bool nativeHandles = false;

            switch (request.Type)
            {
                case IpcMessageType.CmifRequest:
                case IpcMessageType.CmifRequestWithContext:
                    response.Type = IpcMessageType.CmifResponse;
                    Call(d, request, response, s, tipc: false);
                    break;

                case IpcMessageType.CmifControl:
                case IpcMessageType.CmifControlWithContext:
                    nativeHandles = Control(d, request, response, s);
                    break;

                case IpcMessageType.CmifCloseSession:
                case IpcMessageType.TipcCloseSession:
                    return 0; // 游戏随后 CloseHandle，会话在 HandleClosed 里释放

                default:
                    if (request.Type > IpcMessageType.TipcCloseSession)
                    {
                        tipc = true;
                        response.Type = request.Type;
                        Call(d, request, response, s, tipc: true);
                        break;
                    }

                    Red.Report($"IPC 消息类型未支持 {request.Type}", Name);
                    return 0xF601; // kernel InvalidCombination 类
            }

            if (!nativeHandles)
            {
                // 翻译失败 = 这次应答送不到游戏：游戏的 SendSyncRequest 收内核结果，不收成功（审计 #1534 P1-52）
                uint handleOut = d.TranslateResponseHandles(response.HandleDesc);
                if (handleOut != 0) return handleOut;
            }

            ReadOnlySpan<byte> raw = new(s.Resp.GetBuffer(), 0, (int)s.Resp.Length);
            int n = tipc ? response.S2AWriteTipc(buffer, raw) : response.S2AWriteCmif(buffer, (long)msg, raw);

            if (n < 0)
            {
                Red.Report("IPC 应答超出消息缓冲", $"{Name} {-n} > {size}");
                return 0xF601;
            }

            return 0;
        }

        private void Call(Dispatcher d, IpcMessage request, IpcMessage response, Dispatcher.Streams s, bool tipc)
        {
            ServiceCtx ctx = s.Context;
            ctx.S2AReset(d.Device, d.ServerProcess, d.Memory, null, request, response, s.Reader, s.Writer);
            // 域会话（游戏对会话根调过 ConvertCurrentObjectToDomain）：错误应答也得带域出头，否则游戏 SF 客户端在 SFCO 位置读到 0、
            //   判 ResultSfInvalidCmifOutHeader 后断言终止整局（10-28 双人成行建房：错误小程序 Start 抛参数异常 → 畸形应答 → Break）
            bool domain = !tipc && Service.S2AIsDomain;

            try
            {
                if (_lock == null)
                {
                    Invoke(ctx, tipc);
                }
                else
                {
                    lock (_lock)
                    {
                        Invoke(ctx, tipc);
                    }
                }
            }
            catch (ServiceNotImplementedException e)
            {
                // 不用 e.Message：上游 BuildMessage 要回溯客体栈（我们没有 Ryujinx 线程上下文）
                Red.Report($"未实现服务命令 {e.Service.GetType().Name} 命令 {CommandId(request, s, tipc)}");
                WriteError(response, s, tipc, domain, Red.ResultUnknownCommand);
                return;
            }
            catch (NotImplementedException e)
            {
                Red.Report($"未实现 {Target(s, tipc, domain)}：{e.Message}", e.StackTrace);
                WriteError(response, s, tipc, domain, Red.ResultUnknownCommand);
                return;
            }
            catch (Exception e) when (e is IndexOutOfRangeException or ArgumentException)
            {
                // 命令参数出错不许带走整局（真机闪退：越界手柄号取样式变更事件 → IndexOutOfRangeException 穿出 HLE 边界终止整局）：
                // 报一行红、回未知命令，这条游戏线程照常返回，下次请求照发。
                // 红行要点名命令真正落在的对象（域内子对象，会话根的类型名会误导：「IApplicationProxyService 命令 10」其实是 ILibraryAppletAccessor.Start）并带异常栈
                Red.Report($"服务命令参数异常 {Target(s, tipc, domain)} 命令 {CommandId(request, s, tipc)}", $"{e.GetType().Name}：{e.Message}\n{e.StackTrace}");
                WriteError(response, s, tipc, domain, Red.ResultUnknownCommand);
                return;
            }
        }

        // 报红用的目标名：域消息 = 「会话根（域内 子对象类型）」，否则会话根类型名
        private string Target(Dispatcher.Streams s, bool tipc, bool domain)
        {
            if (!domain)
            {
                return Name;
            }

            // 域头：字 0 = 命令 / 入对象数 / 数据长，字 1 = 目标对象号
            ReadOnlySpan<byte> raw = new(s.Req.GetBuffer(), 0, (int)s.Req.Length);
            string obj = raw.Length >= 8 ? Service.S2ADomainObjectName(BitConverter.ToInt32(raw[4..])) : null;

            return $"{Name}（域内 {obj ?? "?"}）";
        }

        private void Invoke(ServiceCtx ctx, bool tipc)
        {
            if (tipc)
            {
                Service.CallTipcMethod(ctx);
            }
            else
            {
                Service.CallCmifMethod(ctx);
            }
        }

        // CMIF：原始数据 SFCI(8) 之后是命令号；域消息前面多 0x10 字节域头。TIPC：消息类型 - 0x10
        private static int CommandId(IpcMessage request, Dispatcher.Streams s, bool tipc)
        {
            if (tipc)
            {
                return (int)request.Type - 0x10;
            }

            // 原始数据在请求流里（本路径不填 RawData）
            ReadOnlySpan<byte> raw = new(s.Req.GetBuffer(), 0, (int)s.Req.Length);
            bool domain = raw.Length >= 0x18 && BitConverter.ToUInt32(raw[0x10..]) == 0x49434653;
            int off = domain ? 0x18 : 8;
            return raw.Length >= off + 4 ? BitConverter.ToInt32(raw[off..]) : -1;
        }

        private static void WriteError(IpcMessage response, Dispatcher.Streams s, bool tipc, bool domain, uint result)
        {
            s.Resp.SetLength(0);

            if (tipc)
            {
                s.Writer.Write(result);
            }
            else
            {
                if (domain)
                {
                    // 域出头 16 字节：出对象数 0 + 填充（同 IpcService.CallCmifMethod 正常路径）
                    s.Writer.Write(0L);
                    s.Writer.Write(0L);
                }

                s.Writer.Write(IpcMagic.Sfco);
                s.Writer.Write((long)result);
            }

            response.HandleDesc = null;
        }

        // CMIF 控制命令（公共处理见 SessionTarget.Control）；返回 true = 应答句柄已是游戏句柄（不再翻译）
        private bool Control(Dispatcher d, IpcMessage request, IpcMessage response, Dispatcher.Streams s)
        {
            s.Reader.ReadUInt64(); // SFCI
            return Control(d, (uint)s.Reader.ReadUInt64(), response, s);
        }

        protected override int? ConvertToDomain() => Service.ConvertToDomain();
    }
}
