using Microsoft.IO;
using Ryujinx.Common;
using Ryujinx.Common.Memory;
using Ryujinx.HLE.HOS;
using Ryujinx.HLE.HOS.Ipc;
using Ryujinx.HLE.HOS.Services;
using System;
using System.Buffers;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;

namespace S2A.Services
{
    // 服务管理器 sm: 的直调版：游戏 ConnectToNamedPort("sm:") 拿到的就是这个会话。
    // 服务名 → Ryujinx 服务的对应关系用上游同一份 [Service] 标注（与 Ryujinx sm IUserInterface 相同的反射表），
    // 不另写服务名单；Horizon 新框架的服务由 HorizonTarget 接（未接的服务名报红）。
    sealed class SmDirect : SessionTarget
    {
        private static readonly Dictionary<string, (Type Type, object Parameter)> _hle =
            typeof(IpcService).Assembly.GetTypes()
                .SelectMany(t => t.GetCustomAttributes<ServiceAttribute>(false).Select(a => (a.Name, t, a.Parameter)))
                .ToDictionary(x => x.Name, x => (x.t, x.Parameter));

        private readonly Dispatcher _d;

        // Horizon 新框架服务的工厂（服务名 → 新会话），由 HorizonServices 登记
        internal readonly System.Collections.Concurrent.ConcurrentDictionary<string, Func<SessionTarget>> Horizon = new();

        public SmDirect(Dispatcher d)
        {
            _d = d;
        }

        public override string Name => "sm:";

        public static bool IsHleService(string name) => _hle.ContainsKey(name);

        public override unsafe uint Process(Dispatcher d, byte* msg, int size)
        {
            IpcMessage request = new(new ReadOnlySpan<byte>(msg, Math.Min(size, 0x100)), (long)msg);
            IpcMessage response = new();
            Dispatcher.Streams s = Dispatcher.ThreadStreams;

            bool tipc = request.Type > IpcMessageType.TipcCloseSession;
            uint cmd;
            int payload;

            if (request.Type is IpcMessageType.CmifCloseSession or IpcMessageType.TipcCloseSession)
            {
                return 0;
            }

            if (request.Type is IpcMessageType.CmifControl or IpcMessageType.CmifControlWithContext)
            {
                // 控制消息（老 SDK 的 nninitInitializeSdkModule 连上 sm 后即发）：sm 在 Ryujinx 是普通 ServerBase 会话，同一套控制命令。
                // 克隆出的句柄仍派回本对象（sm 无会话状态）；转域不支持（本类按原始字节解析，不走域协议），报红。
                // 句柄已是游戏句柄（NewSessionHandle），不翻译；不进差分记录（见 SessionTarget.Control）
                s.Resp.SetLength(0);
                Control(d, BitConverter.ToUInt32(request.RawData, 8), response, s);
                response.RawData = s.Resp.ToArray();
                WriteResponse(msg, response, tipc: false);
                return 0;
            }

            if (tipc)
            {
                cmd = (uint)request.Type - 0x10;
                payload = 0;
                response.Type = request.Type;
            }
            else if (request.Type is IpcMessageType.CmifRequest or IpcMessageType.CmifRequestWithContext)
            {
                cmd = BitConverter.ToUInt32(request.RawData, 8);
                payload = 16;
                response.Type = IpcMessageType.CmifResponse;
            }
            else
            {
                Red.Report($"sm: 消息类型未支持 {request.Type}");
                return 0xF601;
            }

            uint result = 0;
            uint handle = 0;

            switch (cmd)
            {
                case 0: // RegisterClient / Initialize
                case 4: // DetachClient
                    break;

                case 1: // GetService(name) -> move 会话
                    {
                        string name = ReadName(request.RawData, payload);
                        result = OpenService(name, request, out handle);
                        break;
                    }

                case 2: // RegisterService(name, isLight, maxSessions) -> move 端口：Horizon 服务在我方线程上注册（见 HorizonHost）
                    {
                        string name = ReadName(request.RawData, payload);
                        handle = (uint)HorizonHost.NewPort(name);
                        break;
                    }

                case 3: // UnregisterService
                    break;

                default:
                    Red.Report($"sm: 命令未支持 {cmd}");
                    result = Red.ResultUnknownCommand;
                    break;
            }

            s.Resp.SetLength(0);

            if (tipc)
            {
                s.Writer.Write(result);
            }
            else
            {
                s.Writer.Write(IpcMagic.Sfco);
                s.Writer.Write((long)result);
            }

            response.RawData = s.Resp.ToArray();

            if ((cmd == 1 || cmd == 2) && (handle != 0 || tipc))
            {
                // TIPC 的 GetService 无论成败都带一个 move 句柄位（上游 GetServiceTipc 同此）
                response.HandleDesc = IpcHandleDesc.MakeMove((int)handle);
            }

            if (S2ARecord.Enabled)
            {
                Record(request, response, cmd, result, tipc);
            }

            WriteResponse(msg, response, tipc);
            return 0;
        }

        private static unsafe void WriteResponse(byte* msg, IpcMessage response, bool tipc)
        {
            RecyclableMemoryStream rs = tipc ? response.GetStreamTipc() : response.GetStream((long)msg, 0);

            try
            {
                rs.GetReadOnlySequence().CopyTo(new Span<byte>(msg, (int)rs.Length));
            }
            finally
            {
                MemoryStreamManager.Shared.ReleaseStream(rs);
            }
        }

        // 差分 IPC 记录：与真值 Ryujinx sm IUserInterface 同一行格式（S2AIpcRecord.Write），否则对拍里 sm 整类只真值有
        [System.Runtime.CompilerServices.MethodImpl(System.Runtime.CompilerServices.MethodImplOptions.NoInlining)]
        private static void Record(IpcMessage req, IpcMessage resp, uint cmd, uint result, bool tipc)
        {
            System.Text.StringBuilder sb = new();

            sb.Append(tipc ? "HLE-TIPC" : "HLE").Append("\tRyujinx.HLE.HOS.Services.Sm.IUserInterface\t").Append(cmd);
            S2ARecord.AppendHash(sb, "in", req.RawData);
            sb.Append("\th=").Append(req.HandleDesc?.ToCopy.Length ?? 0).Append('/').Append(req.HandleDesc?.ToMove.Length ?? 0);
            sb.Append(req.HandleDesc?.HasPId == true ? "+pid" : "");
            sb.Append("\trc=").Append(result.ToString("x"));
            S2ARecord.AppendHash(sb, "out", resp.RawData);
            sb.Append("\toh=").Append(resp.HandleDesc?.ToCopy.Length ?? 0).Append('/').Append(resp.HandleDesc?.ToMove.Length ?? 0);
            sb.Append("\tobj=").Append(resp.ObjectIds.Count);
            S2ARecord.Line(sb);
        }

        private static string ReadName(byte[] raw, int offset)
        {
            int n = 0;

            while (n < 8 && offset + n < raw.Length && raw[offset + n] != 0)
            {
                n++;
            }

            return System.Text.Encoding.ASCII.GetString(raw, offset, n);
        }

        private uint OpenService(string name, IpcMessage request, out uint handle)
        {
            handle = 0;

            if (name.Length == 0)
            {
                return (6u << 9) | 21u; // sm InvalidServiceName
            }

            SessionTarget target;

            if (Horizon.TryGetValue(name, out Func<SessionTarget> factory))
            {
                target = factory();

                if (target == null)
                {
                    return Red.ResultSmNotRegistered; // 受理失败已报红
                }
            }
            else if (_hle.TryGetValue(name, out (Type Type, object Parameter) svc))
            {
                Dispatcher.Streams s = Dispatcher.ThreadStreams;
                ServiceCtx ctx = new(_d.Device, _d.ServerProcess, _d.Memory, null, request, new IpcMessage(), s.Reader, s.Writer);

                IpcService service = svc.Parameter == null
                    ? (IpcService)Activator.CreateInstance(svc.Type, ctx)
                    : (IpcService)Activator.CreateInstance(svc.Type, ctx, svc.Parameter);

                target = new HleTarget(service);
            }
            else
            {
                Red.Report($"未实现服务 {name}");
                return Red.ResultSmNotRegistered;
            }

            handle = _d.NewSessionHandle(target);
            return handle != 0 ? 0u : 0xD201u;
        }
    }
}
