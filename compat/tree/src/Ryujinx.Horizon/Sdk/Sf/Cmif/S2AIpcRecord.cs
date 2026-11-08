using Ryujinx.Common;
using Ryujinx.Horizon.Common;
using Ryujinx.Horizon.Sdk.Sf.Hipc;
using System;
using System.Runtime.InteropServices;
using System.Text;

namespace Ryujinx.Horizon.Sdk.Sf.Cmif
{
    // S2Arm differential IPC record, Horizon framework side (see Ryujinx.Common.S2ARecord). Called once per handled command,
    // after the CMIF out header has been written.
    static class S2AIpcRecord
    {
        // The check stays in its own method (the body's lambdas allocate a closure at method entry)
        public static void Command(scoped ref ServiceDispatchContext context, string objectName, uint commandId, ReadOnlySpan<byte> inRawData, Result result)
        {
            if (S2ARecord.Enabled)
            {
                Write(ref context, objectName, commandId, inRawData, result);
            }
        }

        [System.Runtime.CompilerServices.MethodImpl(System.Runtime.CompilerServices.MethodImplOptions.NoInlining)]
        private static void Write(scoped ref ServiceDispatchContext context, string objectName, uint commandId, ReadOnlySpan<byte> inRawData, Result result)
        {
            HipcMessageData req = context.Request.Data;
            StringBuilder sb = new();

            sb.Append("HZN\t").Append(objectName).Append('\t').Append(commandId);

            S2ARecord.AppendHash(sb, "in", inRawData);

            HipcStaticDescriptor[] statics = req.SendStatics.ToArray();
            HipcBufferDescriptor[] send = req.SendBuffers.ToArray();
            HipcBufferDescriptor[] recv = req.ReceiveBuffers.ToArray();
            HipcBufferDescriptor[] exch = req.ExchangeBuffers.ToArray();

            S2ARecord.AppendBuffers(sb, "x", statics.Length, i => (statics[i].Address, statics[i].Size), Read);
            S2ARecord.AppendBuffers(sb, "a", send.Length, i => (send[i].Address, send[i].Size), Read);
            sb.Append("\th=").Append(req.CopyHandles.Length).Append('/').Append(req.MoveHandles.Length);
            sb.Append(context.Request.Meta.SendPid ? "+pid" : "");

            sb.Append("\trc=").Append(((long)result.ErrorCode).ToString("x"));

            HipcMessage resp = new(context.OutMessageBuffer);
            S2ARecord.AppendHash(sb, "out", MemoryMarshal.AsBytes(resp.Data.DataWords));
            S2ARecord.AppendBuffers(sb, "b", recv.Length, i => (recv[i].Address, recv[i].Size), Read);
            S2ARecord.AppendBuffers(sb, "w", exch.Length, i => (exch[i].Address, exch[i].Size), Read);
            sb.Append("\tc=").Append(req.ReceiveList.Length);
            sb.Append("\toh=").Append(resp.Data.CopyHandles.Length).Append('/').Append(resp.Data.MoveHandles.Length);

            S2ARecord.Line(sb);
        }

        private static void Read(ulong address, Span<byte> dest) => HorizonStatic.AddressSpace.Read(address, dest);
    }
}
