using Ryujinx.Common;
using Ryujinx.HLE.HOS.Ipc;
using System;
using System.IO;
using System.Text;

namespace Ryujinx.HLE.HOS.Services
{
    // S2Arm differential IPC record, HLE framework side (see Ryujinx.Common.S2ARecord). Called once per handled command,
    // after the result has been written to the response.
    static class S2AIpcRecord
    {
        // The check stays in its own method: the record body captures parameters in lambdas, and the compiler allocates that
        // closure at method entry — it must not run (allocate) on the hot path when recording is off
        public static void Command(IpcService service, int commandId, ServiceCtx context, long result, bool tipc)
        {
            if (S2ARecord.Enabled)
            {
                Write(service, commandId, context, result, tipc);
            }
        }

        [System.Runtime.CompilerServices.MethodImpl(System.Runtime.CompilerServices.MethodImplOptions.NoInlining)]
        private static void Write(IpcService service, int commandId, ServiceCtx context, long result, bool tipc)
        {
            IpcMessage req = context.Request;
            IpcMessage resp = context.Response;
            StringBuilder sb = new();

            sb.Append(tipc ? "HLE-TIPC" : "HLE").Append('\t');
            sb.Append(service is DummyService dummy ? dummy.ServiceName : service.GetType().FullName).Append('\t').Append(commandId);

            S2ARecord.AppendHash(sb, "in", ReadAll(context.RequestData.BaseStream));
            S2ARecord.AppendBuffers(sb, "x", req.PtrBuff.Count, i => (req.PtrBuff[i].Position, req.PtrBuff[i].Size), Read(context));
            S2ARecord.AppendBuffers(sb, "a", req.SendBuff.Count, i => (req.SendBuff[i].Position, req.SendBuff[i].Size), Read(context));
            sb.Append("\th=").Append(req.HandleDesc?.ToCopy.Length ?? 0).Append('/').Append(req.HandleDesc?.ToMove.Length ?? 0);
            sb.Append(req.HandleDesc?.HasPId == true ? "+pid" : "");

            sb.Append("\trc=").Append(result.ToString("x"));
            S2ARecord.AppendHash(sb, "out", ReadAll(context.ResponseData.BaseStream));
            S2ARecord.AppendBuffers(sb, "b", req.ReceiveBuff.Count, i => (req.ReceiveBuff[i].Position, req.ReceiveBuff[i].Size), Read(context));
            S2ARecord.AppendBuffers(sb, "w", req.ExchangeBuff.Count, i => (req.ExchangeBuff[i].Position, req.ExchangeBuff[i].Size), Read(context));
            // c：按应答 X 描述符回告的长度记实际交回的字节（上游服务端接收长度取原始数据末尾的 u16，定长缓冲游戏不发、读成 0，
            // 真值记 0 字节而游戏实际收到 WithSize 的长度；两边同口径才可比）
            S2ARecord.AppendBuffers(sb, "c", req.RecvListBuff.Count, i => (req.RecvListBuff[i].Position, i < resp.PtrBuff.Count ? resp.PtrBuff[i].Size : req.RecvListBuff[i].Size), Read(context));
            sb.Append("\toh=").Append(resp.HandleDesc?.ToCopy.Length ?? 0).Append('/').Append(resp.HandleDesc?.ToMove.Length ?? 0);
            sb.Append("\tobj=").Append(resp.ObjectIds.Count);

            S2ARecord.Line(sb);
        }

        private static Action<ulong, Span<byte>> Read(ServiceCtx context) => (address, dest) => context.Memory.Read(address, dest);

        private static byte[] ReadAll(Stream s)
        {
            long pos = s.Position;
            byte[] data = new byte[s.Length];
            s.Position = 0;
            s.ReadExactly(data);
            s.Position = pos;

            return data;
        }
    }
}
